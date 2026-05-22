#!/bin/bash
# Fetches GitHub Copilot user/quota info and emits a JSON blob normalised
# to:
#
#   {"chat":        {"utilization": N, "resets_at": ISO_or_null},
#    "completions": {"utilization": N, "resets_at": ISO_or_null}}
#
# Empty `{}` on any error (no auth, network down, schema drift).
#
# Token sources tried in order:
#   1. $GITHUB_TOKEN env var
#   2. ~/.copilot/config.json  (Copilot CLI fallback when no keyring)
#   3. ~/.config/gh/hosts.yml  (gh CLI's saved token)
#   4. macOS keychain (best-effort — service name "github.com" for gh CLI)
#
# Endpoint: GET https://api.github.com/copilot_internal/user — unofficial
# but used by every reverse-engineered Copilot wrapper out there.

set -euo pipefail

COPILOT_HOME="${COPILOT_HOME:-$HOME/.copilot}"

# Token lookup
TOKEN="${GITHUB_TOKEN:-}"

# 1) Copilot CLI's plaintext fallback
if [ -z "$TOKEN" ] && [ -r "$COPILOT_HOME/config.json" ]; then
  TOKEN=$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for k in ("oauth_token", "github_token", "token"):
    v = d.get(k)
    if isinstance(v, str) and v:
        print(v); break
' "$COPILOT_HOME/config.json" 2>/dev/null || true)
fi

# 2) gh CLI's hosts.yml
if [ -z "$TOKEN" ] && [ -r "$HOME/.config/gh/hosts.yml" ]; then
  TOKEN=$(python3 -c '
import re, sys
try:
    txt = open(sys.argv[1]).read()
except Exception:
    sys.exit(0)
# minimal YAML parse — find oauth_token: <value> under github.com:
m = re.search(r"github\.com:.*?oauth_token:\s*(\S+)", txt, re.DOTALL)
if m: print(m.group(1).strip())
' "$HOME/.config/gh/hosts.yml" 2>/dev/null || true)
fi

# 3) macOS keychain — gh CLI stores under "gh:github.com"
if [ -z "$TOKEN" ] && command -v security >/dev/null 2>&1; then
  TOKEN=$(security find-internet-password -s github.com -a 'gh-cli' -w 2>/dev/null || true)
fi

if [ -z "$TOKEN" ]; then
  echo '{}'; exit 0
fi

python3 - "$TOKEN" <<'PY'
import json, sys, urllib.request, urllib.error, datetime

token = sys.argv[1]
req = urllib.request.Request(
    "https://api.github.com/copilot_internal/user",
    headers={
        "Authorization": f"token {token}",
        "Accept": "application/json",
        "User-Agent": "claude-usage-bar (Copilot probe)",
        "Editor-Plugin-Version": "claude-usage-bar/0.4",
        "Editor-Version": "vscode/1.95.0",
    },
)
try:
    with urllib.request.urlopen(req, timeout=10) as resp:
        body = json.loads(resp.read().decode("utf-8"))
except Exception:
    print('{}'); sys.exit(0)

# Quotas live under either `quota_snapshots` (current shape) or nested
# differently in older variants. Each entry is typically:
#   {"entitlement": N, "remaining": N, "percent_remaining": N,
#    "unlimited": bool, "resets_at": ISO}
qs = body.get("quota_snapshots") or {}

def normalise(snap):
    if not isinstance(snap, dict): return None
    if snap.get("unlimited"):
        return {"utilization": 0.0, "resets_at": None, "unlimited": True}
    pct = None
    if isinstance(snap.get("percent_remaining"), (int, float)):
        pct = 100.0 - float(snap["percent_remaining"])
    elif isinstance(snap.get("entitlement"), (int, float)) and \
         isinstance(snap.get("remaining"), (int, float)) and snap["entitlement"]:
        pct = 100.0 - (float(snap["remaining"]) / float(snap["entitlement"])) * 100.0
    if pct is None:
        return None
    reset = snap.get("resets_at") or snap.get("reset_at")
    return {"utilization": max(0.0, min(100.0, pct)), "resets_at": reset,
            "unlimited": False}

out = {}
chat = normalise(qs.get("chat") or qs.get("chat_premium"))
if chat: out["chat"] = chat
comps = normalise(qs.get("completions") or qs.get("code_completions"))
if comps: out["completions"] = comps
prem = normalise(qs.get("premium_interactions") or qs.get("premium_requests"))
if prem: out["premium"] = prem

print(json.dumps(out))
PY
