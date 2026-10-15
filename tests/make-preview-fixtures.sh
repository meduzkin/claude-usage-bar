#!/bin/bash
# Writes demo usage.json + sessions.json for `--render-preview`, with
# timestamps relative to now so countdowns and "today" render as live.
# Names, tasks and titles are made up: safe for README screenshots.
#
#   tests/make-preview-fixtures.sh <out-dir>
set -euo pipefail
out="${1:?usage: make-preview-fixtures.sh <out-dir>}"
mkdir -p "$out"
now=$(date +%s)
iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%S.000000+00:00 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.000000+00:00; }
today=$(date +%Y-%m-%d)

cat > "$out/usage.json" <<EOF
{
  "oauth": {
    "five_hour":        {"utilization": 31.0, "resets_at": "$(iso $((now + 7800)))"},
    "seven_day":        {"utilization": 12.0, "resets_at": "$(iso $((now + 5 * 86400)))"},
    "seven_day_sonnet": {"utilization": 0.0,  "resets_at": "$(iso $((now + 5 * 86400)))"}
  },
  "active": {"costUSD": 18.4, "projection": {"totalCost": 29.1, "remainingMinutes": 130},
             "burnRate": {"costPerHour": 6.2, "tokensPerMinute": 41000},
             "endTime": "$(iso $((now + 7800)))", "models": ["claude-opus-4-7"], "totalTokens": 12400000},
  "daily":  [{"period": "$today", "totalCost": 41.2, "modelsUsed": ["claude-opus-4-7"], "inputTokens": 1, "outputTokens": 1}],
  "weekly": [{"period": "$today", "totalCost": 312.0, "modelsUsed": ["claude-opus-4-7"], "inputTokens": 1, "outputTokens": 1}],
  "codex": {"five_hour": {"utilization": 12.0, "resets_at": "$(iso $((now + 11400)))"},
            "seven_day": {"utilization": 7.0,  "resets_at": "$(iso $((now + 4 * 86400)))"}, "source": "http"},
  "notif": {"enabled": true, "delay": 60},
  "service": {"indicator": "none", "description": "All Systems Operational"}
}
EOF

cat > "$out/sessions.json" <<EOF
{
  "generatedAt": $now,
  "today": {"date": "$today", "loggedSeconds": 22500, "tasks": 5, "targetSeconds": 28800},
  "sessions": [
    {"id": "11111111-aaaa", "name": "api-gateway-3f", "pid": 1, "kind": "interactive", "cwd": "/Users/demo/src/api-gateway",
     "project": "api-gateway", "state": "waiting", "waitingSince": $((now - 190)), "lastActivity": $((now - 190)),
     "title": "Rate limiter for the public API", "task": "OPS-1204", "taskStatus": "In Progress", "taskDone": false, "ctx": 41},
    {"id": "22222222-bbbb", "name": "infra-7c", "pid": 1, "kind": "interactive", "cwd": "/Users/demo/src/infra",
     "project": "infra", "state": "waiting", "waitingSince": $((now - 60)), "lastActivity": $((now - 60)),
     "title": "Terraform plan for the new cache cluster", "task": "OPS-1198", "taskStatus": "In Progress", "taskDone": false, "ctx": 63},
    {"id": "33333333-cccc", "name": "web-app-29", "pid": 1, "kind": "interactive", "cwd": "/Users/demo/src/web-app",
     "project": "web-app", "state": "busy", "lastActivity": $((now - 5)),
     "title": "Checkout page performance", "task": "WEB-311", "taskStatus": "In Progress", "taskDone": false, "ctx": 34},
    {"id": "44444444-dddd", "name": "infra-8c", "pid": 1, "kind": "interactive", "cwd": "/Users/demo/src/infra",
     "project": "infra", "state": "idle", "lastActivity": $((now - 1500)),
     "title": "Monthly impact report review", "task": "OPS-1150", "taskStatus": "Done", "taskDone": true, "ctx": 78},
    {"id": "55555555-eeee", "name": "docs-02", "pid": 1, "kind": "interactive", "cwd": "/Users/demo/src/docs",
     "project": "docs", "state": "idle", "lastActivity": $((now - 7300)),
     "title": "Onboarding guide for new engineers", "task": null, "taskDone": false, "ctx": 12}
  ]
}
EOF
echo "$out/usage.json $out/sessions.json"
