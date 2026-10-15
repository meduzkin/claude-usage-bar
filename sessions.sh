#!/bin/bash
# Lists the Claude Code sessions running on this Mac as one JSON document
# for the widget's SESSIONS section. Called every few seconds, so it only
# reads local state: no network.
#
# Sources:
#   claude agents --json        name, pid, kind, cwd, busy/idle per session
#   <pending dir>/claude-waiting-<id>
#                               set by scripts/claude-notify.sh on a
#                               permission prompt, cleared by
#                               claude-notify-cancel.sh once you answer:
#                               "waiting on you"
#   <projects>/<cwd munged>/<id>.jsonl
#                               transcript: last ai-title / custom-title and
#                               its mtime as the last activity
#   <meta dir>/<id>.json        optional, written by your status line or any
#                               other tool: {task, taskStatus,
#                               taskStatusCategory, taskUrl, ctx}
#   <meta dir>/today.json       optional: {date, loggedSeconds, tasks}
#   session title / git branch  task key when no metadata names one
#
# Output:
#   {"generatedAt": 1790000000, "today": {...} | null,
#    "sessions": [{"id", "name", "pid", "kind", "cwd", "project",
#                  "startedAt", "state": "waiting|busy|idle",
#                  "waitingSince", "lastActivity", "title",
#                  "task", "taskSource": "meta|title|branch",
#                  "taskStatus", "taskDone", "taskUrl", "ctx"}]}
#
# Overridable for tests: CLAUDE_BIN, CLAUDE_PROJECTS_DIR,
# CLAUDE_NOTIFY_PENDING_DIR, CLAUDE_SESSIONS_META_DIR, SESSIONS_NOW.
# Written for /bin/bash 3.2 (macOS default): no mapfile, no assoc arrays.

# launchd starts the widget with PATH=/usr/bin:/bin:/usr/sbin:/sbin.
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/.npm-global/bin:$HOME/.claude/local:$PATH"

CLAUDE_BIN="${CLAUDE_BIN:-claude}"
PROJECTS_DIR="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
PENDING_DIR="${CLAUDE_NOTIFY_PENDING_DIR:-/tmp}"
META_DIR="${CLAUDE_SESSIONS_META_DIR:-$HOME/.cache/claude-sessions}"
NOW="${SESSIONS_NOW:-$(date +%s)}"

mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }
# Claude Code stores a project's transcripts under its path with every
# non-alphanumeric character replaced by "-".
munge() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }
json_or() { jq -ce "$2" "$1" 2>/dev/null || printf '%s' "$3"; }
# Ticket keys like OPS-1204 or IT-18639.
KEY_RE='[A-Z][A-Z0-9]+-[0-9]+'


agents=$("$CLAUDE_BIN" agents --json 2>/dev/null)
printf '%s' "$agents" | jq -e 'type == "array"' >/dev/null 2>&1 || agents='[]'

extras=$(mktemp)
trap 'rm -f "$extras"' EXIT

printf '%s' "$agents" | jq -r '.[] | [(.sessionId // .id // ""), (.cwd // "")] | @tsv' |
while IFS=$'\t' read -r sid cwd; do
  [ -n "$sid" ] || continue

  title=""; last="null"
  transcript="$PROJECTS_DIR/$(munge "$cwd")/$sid.jsonl"
  if [ -f "$transcript" ]; then
    # Titles are re-appended through the session, so the last megabyte
    # nearly always has one; scan the whole file only when it does not.
    title_line=$(tail -c 1048576 "$transcript" 2>/dev/null | grep -E '"type":"(ai-title|custom-title)"' | tail -1)
    [ -n "$title_line" ] || title_line=$(grep -E '"type":"(ai-title|custom-title)"' "$transcript" 2>/dev/null | tail -1)
    title=$(printf '%s' "$title_line" | jq -r '.customTitle // .aiTitle // empty' 2>/dev/null)
    last=$(mtime "$transcript"); [ -n "$last" ] || last="null"
  fi

  waiting="null"
  marker="$PENDING_DIR/claude-waiting-$sid"
  if [ -f "$marker" ]; then
    waiting=$(mtime "$marker"); [ -n "$waiting" ] || waiting="$NOW"
  fi

  meta='{}'
  [ -f "$META_DIR/$sid.json" ] && meta=$(json_or "$META_DIR/$sid.json" 'if type == "object" then . else empty end' '{}')

  # Task key when no metadata names one: a ticket key in the session title
  # (e.g. set with /rename), else in the git branch of its working directory.
  tkey=""; tsrc=""
  if [ "$(printf '%s' "$meta" | jq -r '.task // empty')" = "" ]; then
    tkey=$(printf '%s' "$title" | grep -oE "$KEY_RE" | head -1)
    if [ -n "$tkey" ]; then tsrc="title"
    elif [ -n "$cwd" ] && [ -d "$cwd" ]; then
      tkey=$(git -C "$cwd" branch --show-current 2>/dev/null | grep -oE "$KEY_RE" | head -1)
      [ -n "$tkey" ] && tsrc="branch"
    fi
  fi

  jq -cn --arg id "$sid" --arg title "$title" --argjson last "$last" \
         --argjson waiting "$waiting" --argjson meta "$meta" --arg tkey "$tkey" --arg tsrc "$tsrc" \
    '{($id): {title: (if $title == "" then null else $title end),
              lastActivity: $last, waitingSince: $waiting, meta: $meta,
              tkey: (if $tkey == "" then null else $tkey end),
              tsrc: (if $tsrc == "" then null else $tsrc end)}}' >> "$extras"
done

today='null'
[ -f "$META_DIR/today.json" ] && today=$(json_or "$META_DIR/today.json" 'if type == "object" then . else empty end' 'null')

jq -n --argjson agents "$agents" --slurpfile x "$extras" \
      --argjson today "$today" --argjson now "$NOW" '
  ($x | add // {}) as $extras
  | {generatedAt: $now, today: $today,
     sessions: [$agents[]
       | (.sessionId // .id) as $id
       | ($extras[$id] // {}) as $e
       | ($e.meta // {}) as $m
       | {id: $id,
          name: (.name // $id[0:8]),
          pid: .pid,
          kind: (.kind // "interactive"),
          cwd: .cwd,
          project: ((.cwd // "") | split("/") | last),
          startedAt: (if .startedAt then (.startedAt / 1000 | floor) else null end),
          state: (if $e.waitingSince then "waiting"
                  elif ((.status // "") | IN("busy", "running", "working")) then "busy"
                  else "idle" end),
          waitingSince: $e.waitingSince,
          lastActivity: $e.lastActivity,
          title: $e.title,
          task: ($m.task // $e.tkey),
          taskSource: (if $m.task then "meta" else $e.tsrc end),
          taskStatus: $m.taskStatus,
          taskDone: ($m.taskStatusCategory == "done"),
          taskUrl: $m.taskUrl,
          ctx: $m.ctx}]}'
