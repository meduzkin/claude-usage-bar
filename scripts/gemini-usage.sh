#!/bin/bash
# Fetches Gemini Code Assist quota and emits a JSON blob with per-model
# utilization. Output shape:
#
#   {"models": [
#       {"name": "gemini-2.5-pro",   "utilization": 45.0, "resets_at": "ISO"},
#       {"name": "gemini-2.5-flash", "utilization": 12.0, "resets_at": "ISO"}
#   ]}
#
# Empty `{}` on any error (no auth, network down, schema drift, expired
# token without refresh logic). The widget hides the section silently.
#
# Flow:
#   1. Read OAuth access token from ~/.gemini/oauth_creds.json.
#   2. POST cloudcode-pa.googleapis.com/v1internal:loadCodeAssist with the
#      ideType/pluginType to obtain the cloudaicompanionProject id.
#   3. POST cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota with
#      {"project": "<id>"} (or {} if unavailable) and parse the response.
#
# We don't implement token refresh — extracting client_id/secret from the
# Gemini CLI binary is fragile. If the access token has expired, the user
# runs `gemini` once and the CLI refreshes it locally.

set -euo pipefail

GEMINI_HOME="${GEMINI_HOME:-$HOME/.gemini}"
CREDS_FILE="${GEMINI_OAUTH_FILE:-$GEMINI_HOME/oauth_creds.json}"

if [ ! -r "$CREDS_FILE" ]; then
  echo '{}'; exit 0
fi

python3 - "$CREDS_FILE" <<'PY'
import json, sys, urllib.request, urllib.error

try:
    creds = json.load(open(sys.argv[1]))
except Exception:
    print('{}'); sys.exit(0)

token = creds.get("access_token")
if not token:
    print('{}'); sys.exit(0)

def post(url, body, timeout=10):
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        url, data=data,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except Exception:
        return None

# Step 1: project lookup
load = post(
    "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist",
    {"metadata": {"ideType": "GEMINI_CLI", "pluginType": "GEMINI"}},
)
project = None
if isinstance(load, dict):
    project = load.get("cloudaicompanionProject")

# Step 2: quota — try with project first, fall back to bare {} if no project
quota = post(
    "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota",
    {"project": project} if project else {},
)
if not isinstance(quota, dict):
    print('{}'); sys.exit(0)

# Response shape: a list/dict of buckets keyed by model with
# {remainingFraction, resetTime, modelId}. Both list-of-dicts and
# dict-of-buckets shapes are seen in the wild — handle both.
buckets = []
if isinstance(quota.get("quotaBuckets"), list):
    buckets = quota["quotaBuckets"]
elif isinstance(quota.get("buckets"), list):
    buckets = quota["buckets"]
elif isinstance(quota.get("quotaBuckets"), dict):
    buckets = list(quota["quotaBuckets"].values())

models = []
for b in buckets:
    if not isinstance(b, dict): continue
    name = b.get("modelId") or b.get("model") or b.get("name")
    rem  = b.get("remainingFraction")
    if rem is None and "usedFraction" in b:
        rem = 1.0 - float(b["usedFraction"])
    reset = b.get("resetTime") or b.get("resets_at") or b.get("resetAt")
    if name and isinstance(rem, (int, float)):
        models.append({
            "name": name,
            "utilization": max(0.0, min(100.0, (1.0 - float(rem)) * 100.0)),
            "resets_at": reset,
        })

# Cap at top 4 most-utilised models, sorted descending so the "tightest"
# bucket leads.
models.sort(key=lambda m: m["utilization"], reverse=True)
models = models[:4]

out = {"models": models} if models else {}
print(json.dumps(out))
PY
