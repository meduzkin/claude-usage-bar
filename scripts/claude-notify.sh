#!/bin/bash
# Claude Code Notification hook:
#   - macOS popup + sound + terminal activate after N seconds if the user
#     hasn't responded to a permission prompt.
#   - subtitle = last user prompt (≈ session topic) from transcript.
#
# Pair with claude-notify-cancel.sh on Stop + PreToolUse to kill the timer
# as soon as the user responds.
#
# Args / env:
#   $1                   delay in seconds (positional, wins over env). The
#                        claude-usage-bar widget writes the delay onto the
#                        hook command line, so settings.json carries the
#                        current value.
#   CLAUDE_NOTIFY_DELAY  fallback if no positional arg (default 60).
#   CLAUDE_NOTIFY_DEBUG  set to 1 to dump raw hook input to
#                        /tmp/claude-notify-last.json.

DELAY="${1:-${CLAUDE_NOTIFY_DELAY:-60}}"
OSASCRIPT="${CLAUDE_NOTIFY_OSASCRIPT:-osascript}"   # overridable for tests
PENDING_DIR="${CLAUDE_NOTIFY_PENDING_DIR:-/tmp}"
INPUT=$(cat)

[ "$CLAUDE_NOTIFY_DEBUG" = "1" ] && echo "$INPUT" > /tmp/claude-notify-last.json

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "default"' 2>/dev/null)
MESSAGE=$(echo "$INPUT" | jq -r '.message // ""' 2>/dev/null)
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null)
NOTIF_TYPE=$(echo "$INPUT" | jq -r '.notification_type // ""' 2>/dev/null)

# GC: remove pidfiles whose process is dead (left over from killed/exited claude sessions)
for f in "$PENDING_DIR"/claude-notify-pending-*.pid; do
  [ -f "$f" ] || continue
  pid=$(cat "$f" 2>/dev/null)
  if [ -n "$pid" ] && ! ps -p "$pid" >/dev/null 2>&1; then
    rm -f "$f"
  fi
done

# Only schedule the push for permission_prompt — other types (idle, complete, etc.)
# don't have a guaranteed cancel event and would leak timers.
if [ "$NOTIF_TYPE" != "permission_prompt" ]; then
  exit 0
fi

# Topic = last user prompt from transcript, truncated
TOPIC=""
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  TOPIC=$(grep '"type":"last-prompt"' "$TRANSCRIPT" 2>/dev/null | tail -1 | jq -r '.lastPrompt // ""' 2>/dev/null | tr '\n' ' ' | head -c 80)
fi
[ -z "$TOPIC" ] && TOPIC="Claude is waiting"

PIDFILE="$PENDING_DIR/claude-notify-pending-${SESSION_ID}.pid"

# "Waiting on you" marker for the widget's SESSIONS list (read by sessions.sh).
# Unlike the pidfile it stays after the notification fires, and only
# claude-notify-cancel.sh (Stop / PreToolUse, i.e. you answered) removes it.
date +%s > "$PENDING_DIR/claude-waiting-${SESSION_ID}"

# Cancel any previous pending push
if [ -f "$PIDFILE" ]; then
  kill "$(cat "$PIDFILE")" 2>/dev/null
  rm -f "$PIDFILE"
fi

TITLE="Claude Code"
SUBTITLE="$TOPIC"
BODY=$(echo "$MESSAGE" | head -c 200)
[ -z "$BODY" ] && BODY="Waiting for your input"

escape_as() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
T=$(escape_as "$TITLE"); S=$(escape_as "$SUBTITLE"); B=$(escape_as "$BODY")

case "$TERM_PROGRAM" in
  "Apple_Terminal") APP="Terminal" ;;
  "iTerm.app")      APP="iTerm"    ;;
  "WarpTerminal")   APP="Warp"     ;;
  "ghostty")        APP="Ghostty"  ;;
  "vscode")         APP="Code"     ;;
  "WezTerm")        APP="WezTerm"  ;;
  "tabby")          APP="Tabby"    ;;
  *)                APP="Terminal" ;;
esac

# Title names the session and its task, so with several sessions open you
# know which one to switch to: "Claude Code · aws-terraform-29 · IT-18639".
# The session name comes from `claude agents --json`, the task from the
# optional per-session record in $CLAUDE_SESSIONS_META_DIR (see sessions.sh).
# Resolved after the delay, inside the background job, so the hook returns at once.
META_DIR="${CLAUDE_SESSIONS_META_DIR:-$HOME/.cache/claude-sessions}"
session_title() {
  local name task
  name=$("${CLAUDE_BIN:-claude}" agents --json 2>/dev/null |
         jq -r --arg id "$SESSION_ID" '.[] | select((.sessionId // .id) == $id) | .name' 2>/dev/null | head -1)
  task=$(jq -r '.task // empty' "$META_DIR/$SESSION_ID.json" 2>/dev/null)
  printf '%s' "Claude Code${name:+ · $name}${task:+ · $task}"
}

(
  sleep "$DELAY"
  [ -f "$PIDFILE" ] || exit 0
  T=$(escape_as "$(session_title)")
  "$OSASCRIPT" -e "display notification \"$B\" with title \"$T\" subtitle \"$S\" sound name \"Glass\"" 2>/dev/null
  "$OSASCRIPT" -e "tell application \"$APP\" to activate" 2>/dev/null
  rm -f "$PIDFILE"
) &

echo $! > "$PIDFILE"

exit 0
