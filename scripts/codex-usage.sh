#!/bin/bash
# Fetches Codex (OpenAI Codex CLI) rate-limit windows and emits a JSON
# blob normalised to the same shape this widget uses for Claude:
#
#   {"five_hour":  {"utilization": N, "resets_at": ISO},
#    "seven_day":  {"utilization": N, "resets_at": ISO},
#    "stale":      bool,           # auth file is older than the 8d refresh window
#    "source":     "http"|"rpc"}   # which path produced the data
#
# Empty `{}` on any error (no auth, RPC unavailable, schema drift).
#
# Resolution order:
#   1. HTTP: GET https://chatgpt.com/backend-api/wham/usage with the
#      OAuth access_token from ~/.codex/auth.json. Fast, no subprocess.
#   2. CLI RPC: spawn `codex -s read-only -a untrusted app-server`, send
#      JSON-RPC `initialize` + `account/rateLimits/read` over stdin, parse
#      the reply, kill the subprocess on exit. Used when the HTTP token
#      is missing or rejected. Matches CodexBar's dual-path approach.
#
# The auth file may also be older than 8 days (Codex CLI refresh window).
# When that happens we flag `stale: true` so the widget can hint the user
# to run `codex` once to refresh credentials.

set -euo pipefail

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
AUTH="${CODEX_AUTH_FILE:-$CODEX_HOME/auth.json}"

http_path_result=""
if [ -r "$AUTH" ]; then
  http_path_result=$(python3 - "$AUTH" <<'PY'
import json, sys, urllib.request, urllib.error, datetime, time

try:
    data = json.load(open(sys.argv[1]))
except Exception:
    print('{}'); sys.exit(0)

def deep_get(obj, *paths):
    for p in paths:
        cur = obj; ok = True
        for k in p:
            if isinstance(cur, dict) and k in cur:
                cur = cur[k]
            else:
                ok = False; break
        if ok and cur not in (None, ""):
            return cur
    return None

token = deep_get(
    data,
    ("tokens", "access_token"),
    ("access_token",),
    ("oauth", "access_token"),
)
account_id = deep_get(
    data,
    ("tokens", "account_id"),
    ("account_id",),
    ("oauth", "account_id"),
)

# Heuristic for stale credentials: Codex refreshes once per <= 8d.
last_refresh_str = data.get("last_refresh")
stale = False
if isinstance(last_refresh_str, str):
    try:
        t = datetime.datetime.fromisoformat(last_refresh_str.replace("Z", "+00:00"))
        if (datetime.datetime.now(datetime.timezone.utc) - t).total_seconds() > 8 * 86400:
            stale = True
    except Exception:
        pass

if not token:
    print('{}'); sys.exit(0)

req = urllib.request.Request(
    "https://chatgpt.com/backend-api/wham/usage",
    headers={
        "Authorization": f"Bearer {token}",
        "Accept": "application/json",
        "Origin": "https://chatgpt.com",
        "Referer": "https://chatgpt.com/",
        "User-Agent": "claude-usage-bar (Codex probe)",
    },
)
if account_id:
    req.add_header("ChatGPT-Account-Id", account_id)

try:
    with urllib.request.urlopen(req, timeout=10) as resp:
        body = json.loads(resp.read().decode("utf-8"))
except Exception:
    print('{}'); sys.exit(0)

def pick_window(body, *candidate_keys):
    for k in candidate_keys:
        v = body.get(k)
        if isinstance(v, dict): return v
    return None

def normalise(w):
    if not isinstance(w, dict): return None
    pct = None
    for k in ("utilization", "usedPercent", "used_percent", "percent_used"):
        if isinstance(w.get(k), (int, float)):
            pct = float(w[k]); break
    if pct is None:
        for k in ("percent_left", "remaining_percent", "remainingPercent"):
            if isinstance(w.get(k), (int, float)):
                pct = 100.0 - float(w[k]); break
    if pct is None: return None
    reset = None
    for k in ("resets_at", "reset_at", "resetsAt"):
        if isinstance(w.get(k), str):
            reset = w[k]; break
    if reset is None and isinstance(w.get("reset_time_ms"), (int, float)):
        reset = datetime.datetime.fromtimestamp(
            w["reset_time_ms"] / 1000.0, datetime.timezone.utc
        ).isoformat()
    return {"utilization": pct, "resets_at": reset}

primary   = pick_window(body, "five_hour", "five_hour_limit", "primary_window", "primary")
secondary = pick_window(body, "weekly", "weekly_limit", "secondary_window", "secondary")

out = {"source": "http", "stale": stale}
if (n := normalise(primary)):   out["five_hour"]  = n
if (n := normalise(secondary)): out["seven_day"] = n
if "five_hour" not in out and "seven_day" not in out:
    print('{}'); sys.exit(0)
print(json.dumps(out))
PY
  )
fi

# Fall back to the JSON-RPC subprocess path when HTTP failed.
if [ -z "$http_path_result" ] || [ "$http_path_result" = "{}" ]; then
  # Only attempt RPC if codex CLI is on PATH — otherwise nothing to fall back to.
  if command -v codex >/dev/null 2>&1; then
    rpc_result=$(python3 - <<'PY' 2>/dev/null || echo '{}'
import json, subprocess, sys, datetime, signal

try:
    proc = subprocess.Popen(
        ["codex", "-s", "read-only", "-a", "untrusted", "app-server"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        text=True, bufsize=1,
    )
except Exception:
    print('{}'); sys.exit(0)

def send(method, params, msg_id):
    msg = json.dumps({"jsonrpc": "2.0", "id": msg_id, "method": method, "params": params}) + "\n"
    proc.stdin.write(msg); proc.stdin.flush()

def recv_response(target_id, timeout=5.0):
    import select
    end = datetime.datetime.now() + datetime.timedelta(seconds=timeout)
    while datetime.datetime.now() < end:
        r, _, _ = select.select([proc.stdout], [], [], 0.2)
        if r:
            line = proc.stdout.readline()
            if not line: continue
            try:
                msg = json.loads(line)
            except Exception:
                continue
            if msg.get("id") == target_id and ("result" in msg or "error" in msg):
                return msg
    return None

try:
    send("initialize", {"clientInfo": {"name": "claude-usage-bar", "version": "0.4"}}, 1)
    init = recv_response(1, timeout=5)
    if init is None or "error" in init:
        print('{}'); sys.exit(0)
    send("account/rateLimits/read", {}, 2)
    rl = recv_response(2, timeout=5)
    if rl is None or "error" in rl:
        print('{}'); sys.exit(0)
    result = rl.get("result") or {}
    rl_obj = result.get("rateLimits") or {}

    def norm(w):
        if not isinstance(w, dict): return None
        pct = w.get("usedPercent") or w.get("used_percent") or w.get("utilization")
        if pct is None:
            rem = w.get("percent_left") or w.get("remaining_percent")
            if isinstance(rem, (int, float)):
                pct = 100.0 - float(rem)
        if pct is None: return None
        reset = w.get("resetsAt") or w.get("resets_at") or w.get("reset_at")
        return {"utilization": float(pct), "resets_at": reset}

    out = {"source": "rpc", "stale": False}
    if (n := norm(rl_obj.get("primary"))):   out["five_hour"]  = n
    if (n := norm(rl_obj.get("secondary"))): out["seven_day"] = n
    if "five_hour" in out or "seven_day" in out:
        print(json.dumps(out))
    else:
        print('{}')
finally:
    # Hygiene: ClaudeBar had a notable bug spawning orphaned codex
    # app-server processes. Be explicit about teardown.
    try:
        proc.stdin.close()
    except Exception:
        pass
    try:
        proc.terminate()
        proc.wait(timeout=2)
    except Exception:
        proc.kill()
PY
    )
    if [ -n "$rpc_result" ] && [ "$rpc_result" != "{}" ]; then
      echo "$rpc_result"
      exit 0
    fi
  fi
  echo '{}'
  exit 0
fi

echo "$http_path_result"
