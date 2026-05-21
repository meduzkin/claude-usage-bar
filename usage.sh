#!/bin/bash
# Pulls plan utilization (% from anthropic api/oauth/usage — same numbers
# Claude Code's /usage shows) plus ccusage cost/token breakdowns, and emits
# one JSON blob on stdout. Consumed by the menu bar widget.
#
# Token source: the macOS keychain entry "Claude Code-credentials" that
# Claude Code itself manages. Read via `security find-generic-password`,
# which triggers the standard macOS keychain prompt on first run — click
# "Always Allow" once and subsequent calls are silent.
#
# Escape hatch for non-interactive setups: set CLAUDE_CREDS to a path
# containing the same `{"claudeAiOauth": {...}}` JSON and that file wins.

set -euo pipefail

KEYCHAIN_SERVICE="Claude Code-credentials"
CACHE_DIR="${CLAUDE_USAGE_CACHE_DIR:-$HOME/.cache/claude-usage-bar}"
CACHE_FILE="$CACHE_DIR/oauth.json"
mkdir -p "$CACHE_DIR"

# Parse first JSON line of stdin, print accessToken if present.
# Doesn't check expiry — Claude Code refreshes its keychain entry on its
# own; if our copy is stale we'll see a 401 from the API and re-read.
extract_token() {
  python3 -c '
import json, sys
for line in sys.stdin.read().splitlines():
    line = line.strip()
    if not line: continue
    try:
        d = json.loads(line)
    except Exception:
        continue
    tok = (d.get("claudeAiOauth") or {}).get("accessToken")
    if tok:
        print(tok); sys.exit(0)
sys.exit(1)
'
}

read_keychain() {
  security find-generic-password -s "$KEYCHAIN_SERVICE" -w 2>/dev/null | extract_token
}

get_token() {
  # explicit file override (CI, custom setups)
  if [ -n "${CLAUDE_CREDS:-}" ] && [ -r "$CLAUDE_CREDS" ]; then
    extract_token < "$CLAUDE_CREDS" && return 0
  fi
  read_keychain
}

fetch_oauth_usage() {
  local token="$1" body code
  body=$(mktemp)
  code=$(curl -sS --max-time 10 -o "$body" -w "%{http_code}" \
    -H "Authorization: Bearer $token" \
    -H "anthropic-beta: oauth-2025-04-20" \
    https://api.anthropic.com/api/oauth/usage 2>/dev/null || echo "000")
  if [ "$code" = "200" ] && python3 -c "import json,sys; json.loads(open(sys.argv[1]).read())" "$body" 2>/dev/null; then
    cat "$body"; rm -f "$body"; return 0
  fi
  rm -f "$body"
  case "$code" in
    401|403|000) return 2 ;;  # token rejected / network
    *)           return 1 ;;  # 429s, 5xx etc — try cache
  esac
}

oauth='{}'
TOKEN=$(get_token 2>/dev/null || true)
if [ -n "$TOKEN" ]; then
  if resp=$(fetch_oauth_usage "$TOKEN"); then
    oauth="$resp"
  elif [ $? = 2 ]; then
    # token rejected — pull fresh from keychain once and retry
    if TOKEN=$(read_keychain 2>/dev/null) && [ -n "$TOKEN" ]; then
      resp=$(fetch_oauth_usage "$TOKEN") && oauth="$resp" || true
    fi
  fi
fi

# Cache successful responses; fall back to cache on failure (e.g. 429s
# from the usage endpoint, which throttles aggressively on rapid polls).
if [ "$oauth" != "{}" ]; then
  printf '%s' "$oauth" > "$CACHE_FILE.tmp" && mv "$CACHE_FILE.tmp" "$CACHE_FILE"
elif [ -r "$CACHE_FILE" ]; then
  oauth=$(cat "$CACHE_FILE")
fi

find_ccusage() {
  if command -v ccusage >/dev/null 2>&1; then
    command -v ccusage
    return
  fi
  local cached
  cached=$(ls -t "$HOME"/.npm/_npx/*/node_modules/.bin/ccusage 2>/dev/null | head -1 || true)
  if [ -n "$cached" ] && [ -x "$cached" ]; then
    echo "$cached"
    return
  fi
  echo "npx -y ccusage@latest"
}

CC=$(find_ccusage)

blocks=$($CC blocks --active --json 2>/dev/null  || echo '{"blocks":[]}')
daily=$($CC  daily          --json 2>/dev/null   || echo '{"daily":[],"totals":{}}')
weekly=$($CC weekly         --json 2>/dev/null   || echo '{"weekly":[],"totals":{}}')
session=$($CC session       --json 2>/dev/null   || echo '{"session":[],"totals":{}}')

# Notification hook state from ~/.claude/settings.json (handled by notif.sh
# living alongside this script). Cheap to read on every refresh — pure
# local file, no I/O over the network.
notif=$("$(dirname "$0")/notif.sh" state 2>/dev/null || echo '{"enabled":false,"delay":60}')

python3 - "$oauth" "$blocks" "$daily" "$weekly" "$session" "$notif" <<'PY'
import json, sys
ou, b, d, w, s, n = (json.loads(x) for x in sys.argv[1:7])
sessions = s.get("session") or []
def last_activity(x):
    return (x.get("metadata") or {}).get("lastActivity") or ""
sessions_sorted = sorted(sessions, key=last_activity)
out = {
    "oauth":   ou,
    "active":  (b.get("blocks") or [None])[0],
    "daily":   (d.get("daily")  or [])[-7:],
    "weekly":  (w.get("weekly") or [])[-4:],
    "session": sessions_sorted[-1] if sessions_sorted else None,
    "notif":   n,
}
print(json.dumps(out))
PY
