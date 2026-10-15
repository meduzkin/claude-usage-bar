#!/bin/bash
# Tests for jira.py against a stub Jira on localhost. What they guard:
#   - "today" is the Mac's local day: a worklog written with a +0300 offset at
#     01:00 Riga on the 16th is 05:00 on the 16th in Krasnoyarsk, not the 15th;
#   - only the caller's own worklogs count;
#   - a task key that does not exist (taken from a branch name) is skipped,
#     not an error for the whole refresh;
#   - a bad token gives a readable error, the token is never printed;
#   - plain http is refused unless explicitly allowed (tests only).
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
d=$(mktemp -d); fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2', want '$3'"; fail=1; fi; }

cat > "$d/stub.py" <<'PY'
import json, sys, http.server, urllib.parse
ME = "acc-me"
WORKLOGS = {
  "OPS-1": [
    {"started": "2026-10-15T06:00:00.000+0300", "timeSpentSeconds": 3600,  "author": {"accountId": ME}},   # 10:00 KRAT 15th
    {"started": "2026-10-15T19:30:00.000+0300", "timeSpentSeconds": 1800,  "author": {"accountId": ME}},   # 23:30 KRAT 15th
    {"started": "2026-10-15T20:30:00.000+0300", "timeSpentSeconds": 7200,  "author": {"accountId": ME}},   # 00:30 KRAT 16th
    {"started": "2026-10-15T06:00:00.000+0300", "timeSpentSeconds": 9999,  "author": {"accountId": "other"}}],
  "OPS-2": [
    {"started": "2026-10-14T19:59:00.000+0300", "timeSpentSeconds": 600,   "author": {"accountId": ME}}],  # 23:59 KRAT 14th
}
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, code, obj):
        b = json.dumps(obj).encode(); self.send_response(code)
        self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(b)))
        self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        if self.headers.get("Authorization") != "Basic " + __import__("base64").b64encode(b"me@x.com:good").decode():
            return self.send(401, {"errorMessages": ["unauthorized"]})
        u = urllib.parse.urlparse(self.path); p = u.path
        if p == "/rest/api/3/myself": return self.send(200, {"accountId": ME, "displayName": "Me Myself"})
        if p == "/rest/api/3/search/jql": return self.send(200, {"issues": [{"key": "OPS-1"}, {"key": "OPS-2"}]})
        if p.endswith("/worklog"): return self.send(200, {"worklogs": WORKLOGS[p.split("/")[-2]]})
        if p == "/rest/api/3/issue/OPS-1": return self.send(200, {"fields": {"status": {"name": "Done", "statusCategory": {"key": "done"}}}})
        if p == "/rest/api/3/issue/WEB-3": return self.send(200, {"fields": {"status": {"name": "In Progress", "statusCategory": {"key": "indeterminate"}}}})
        return self.send(404, {"errorMessages": ["no such issue"]})
s = http.server.HTTPServer(("127.0.0.1", 0), H)
print(s.server_address[1], flush=True)
s.serve_forever()
PY
python3 "$d/stub.py" > "$d/port" & pid=$!
trap 'kill $pid 2>/dev/null; wait $pid 2>/dev/null; rm -rf "$d"' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$d/port" ] && break; sleep 0.2; done
port=$(cat "$d/port")

# 2026-10-15 12:00 in Krasnoyarsk
now=$(TZ=Asia/Krasnoyarsk python3 -c 'import datetime;print(int(datetime.datetime(2026,10,15,12,0).astimezone().timestamp()))')
jira() { TZ=Asia/Krasnoyarsk JIRA_CONFIG="$d/none.json" JIRA_SITE="http://127.0.0.1:$port" JIRA_ALLOW_HTTP=1 \
         JIRA_EMAIL=me@x.com JIRA_TOKEN="${TOKEN:-good}" JIRA_NOW="$now" python3 "$here/jira.py" "$@"; }

r=$(jira refresh OPS-1 WEB-3 NOPE-9)
check "refresh ok" "$(printf '%s' "$r" | jq -r .ok)" "true"
check "today = local day of the Mac" "$(printf '%s' "$r" | jq -r .today.date)" "2026-10-15"
check "only own worklogs inside the local day (3600+1800)" "$(printf '%s' "$r" | jq -r .today.loggedSeconds)" "5400"
check "tasks with time today" "$(printf '%s' "$r" | jq -r .today.tasks)" "1"
check "status + done category + browse url" "$(printf '%s' "$r" | jq -c '.statuses["OPS-1"]')" \
      "{\"name\":\"Done\",\"category\":\"done\",\"url\":\"http://127.0.0.1:$port/browse/OPS-1\"}"
check "unknown key skipped, others kept" "$(printf '%s' "$r" | jq -r '.statuses | keys | join(",")')" "OPS-1,WEB-3"

check "check returns the user" "$(jira check | jq -r .name)" "Me Myself"
r=$(TOKEN=bad-secret-token jira check)
check "bad token: readable error" "$(printf '%s' "$r" | jq -r .error)" "HTTP 401 (check email and token)"
check "bad token: token not printed" "$(printf '%s' "$r" | grep -c bad-secret-token)" "0"
check "not connected" "$(JIRA_CONFIG="$d/none.json" JIRA_EMAIL='' JIRA_SITE='' JIRA_TOKEN='' python3 "$here/jira.py" check | jq -r .error)" "not connected"
check "plain http refused" "$(JIRA_CONFIG="$d/none.json" JIRA_SITE="http://127.0.0.1:$port" JIRA_EMAIL=me@x.com JIRA_TOKEN=good python3 "$here/jira.py" check | jq -r .error)" "site must start with https://"
exit $fail
