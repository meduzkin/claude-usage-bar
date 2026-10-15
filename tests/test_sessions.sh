#!/bin/bash
# Tests for sessions.sh and the notification hooks, on fixtures: a stub
# `claude` binary, a fake projects dir, a temp pending/meta dir.
# What they guard:
#   - "waiting" comes from the hook marker, which survives the notification
#     firing and is cleared only by the cancel hook (you answered);
#   - the transcript is found under Claude Code's munged project path, and
#     the last title wins (custom title over an older ai-title);
#   - optional per-session metadata is merged; a broken file does not break
#     the list; a broken `claude agents` gives an empty list, not an error;
#   - the notification title names the session and its task.
# Runs with /bin/bash (3.2 on macOS), like the widget.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
d=$(mktemp -d); fail=0
trap 'rm -rf "$d"' EXIT
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2', want '$3'"; fail=1; fi; }

export CLAUDE_PROJECTS_DIR="$d/projects" CLAUDE_NOTIFY_PENDING_DIR="$d/pending" \
       CLAUDE_SESSIONS_META_DIR="$d/meta" CLAUDE_BIN="$d/bin/claude" SESSIONS_NOW=2000000000
mkdir -p "$d/bin" "$d/pending" "$d/meta" "$d/projects/-Users-x-src-my-app" "$d/projects/-Users-x-src-infra"

cat > "$d/bin/claude" <<'EOF'
#!/bin/bash
[ "$1 $2" = "agents --json" ] || exit 2
cat "$(dirname "$0")/agents.json"
EOF
chmod +x "$d/bin/claude"
cat > "$d/bin/agents.json" <<'EOF'
[{"sessionId":"s-busy","name":"my-app-3f","pid":101,"kind":"interactive","cwd":"/Users/x/src/my.app","status":"busy","startedAt":1999990000000},
 {"sessionId":"s-idle","name":"infra-7c","pid":102,"kind":"interactive","cwd":"/Users/x/src/infra","status":"idle"},
 {"sessionId":"s-wait","name":"infra-8c","pid":103,"kind":"interactive","cwd":"/Users/x/src/infra","status":"busy"}]
EOF

# transcripts: "my.app" is stored as "my-app"; later custom title beats older ai-title
printf '%s\n' '{"type":"ai-title","aiTitle":"Old title"}' '{"type":"user","message":{"content":"hi"}}' \
  '{"type":"custom-title","customTitle":"Renamed by user"}' > "$d/projects/-Users-x-src-my-app/s-busy.jsonl"
printf '%s\n' '{"type":"ai-title","aiTitle":"Terraform plan"}' > "$d/projects/-Users-x-src-infra/s-idle.jsonl"
echo '{"task":"OPS-1","taskStatus":"Done","taskStatusCategory":"done","taskUrl":"https://j/browse/OPS-1","ctx":41}' > "$d/meta/s-idle.json"
echo 'not json' > "$d/meta/s-busy.json"

run() { /bin/bash "$here/sessions.sh"; }
field() { run | jq -r --arg id "$1" ".sessions[] | select(.id == \$id) | $2"; }

check "lists every session" "$(run | jq -r '[.sessions[].id] | join(",")')" "s-busy,s-idle,s-wait"
check "busy from claude agents" "$(field s-busy .state)" "busy"
check "munged project path, last title wins" "$(field s-busy .title)" "Renamed by user"
check "last activity from transcript mtime" "$(field s-idle '.lastActivity | type')" "number"
check "no transcript: title null" "$(field s-wait .title)" "null"
check "metadata merged" "$(field s-idle '[.task, .taskStatus, (.taskDone|tostring), (.ctx|tostring)] | join(" ")')" "OPS-1 Done true 41"
check "broken metadata file ignored" "$(field s-busy '.task')" "null"
check "project = last cwd component" "$(field s-busy .project)" "my.app"
check "startedAt in seconds" "$(field s-busy .startedAt)" "1999990000"
check "no today.json: today null" "$(run | jq -c .today)" "null"
echo '{"date":"2033-05-18","loggedSeconds":3600,"tasks":2}' > "$d/meta/today.json"
check "today passed through" "$(run | jq -c '.today.loggedSeconds')" "3600"

# waiting: hook sets the marker, notification fires, marker stays until cancel
hook_in='{"session_id":"s-wait","notification_type":"permission_prompt","message":"Allow Bash?"}'
cat > "$d/bin/osa" <<EOF
#!/bin/bash
printf '%s\n' "\$2" >> "$d/osa.log"
EOF
chmod +x "$d/bin/osa"
printf '%s' "$hook_in" | CLAUDE_NOTIFY_OSASCRIPT="$d/bin/osa" /bin/bash "$here/scripts/claude-notify.sh" 0
check "waiting after permission prompt" "$(field s-wait .state)" "waiting"
check "waitingSince set" "$(field s-wait '.waitingSince | type')" "number"
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$d/osa.log" ] && break; sleep 0.3; done
check "notification fired" "$(grep -c 'display notification' "$d/osa.log" 2>/dev/null)" "1"
check "still waiting after the notification fired" "$(field s-wait .state)" "waiting"
printf '%s' '{"session_id":"s-wait"}' | /bin/bash "$here/scripts/claude-notify-cancel.sh"
check "answered: back to busy" "$(field s-wait .state)" "busy"

# notification title: session name + task
echo '{"task":"OPS-7"}' > "$d/meta/s-wait.json"
rm -f "$d/osa.log"
printf '%s' "$hook_in" | CLAUDE_NOTIFY_OSASCRIPT="$d/bin/osa" /bin/bash "$here/scripts/claude-notify.sh" 0
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$d/osa.log" ] && break; sleep 0.3; done
check "notification names session and task" "$(grep -o 'with title "[^"]*"' "$d/osa.log" | head -1)" 'with title "Claude Code · infra-8c · OPS-7"'
printf '%s' '{"session_id":"s-wait"}' | /bin/bash "$here/scripts/claude-notify-cancel.sh"

# task key without metadata: from the title, else from the git branch
cat > "$d/bin/agents.json" <<EOF
[{"sessionId":"s-title","name":"a","cwd":"/Users/x/src/infra","status":"idle"},
 {"sessionId":"s-branch","name":"b","cwd":"$d/repo","status":"idle"},
 {"sessionId":"s-meta","name":"c","cwd":"$d/repo","status":"idle"}]
EOF
printf '%s\n' '{"type":"custom-title","customTitle":"OPS-77 cache cluster"}' > "$d/projects/-Users-x-src-infra/s-title.jsonl"
git -C "$d" init -q repo && git -C "$d/repo" checkout -q -b WEB-12-checkout
echo '{"task":"OPS-1"}' > "$d/meta/s-meta.json"
check "task from title" "$(field s-title '[.task, .taskSource] | join(" ")')" "OPS-77 title"
check "task from git branch" "$(field s-branch '[.task, .taskSource] | join(" ")')" "WEB-12 branch"
check "metadata wins over the branch" "$(field s-meta '[.task, .taskSource] | join(" ")')" "OPS-1 meta"

# claude agents failing must not break the menu
cat > "$d/bin/claude" <<'EOF'
#!/bin/bash
echo "boom" >&2; exit 1
EOF
check "claude agents failing: empty list" "$(run | jq -c .sessions)" "[]"

exit $fail
