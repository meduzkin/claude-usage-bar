#!/bin/bash
# Stop / PreToolUse hook: cancel a pending notification scheduled by claude-notify.sh.
INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "default"' 2>/dev/null)
PIDFILE="/tmp/claude-notify-pending-${SESSION_ID}.pid"
if [ -f "$PIDFILE" ]; then
  kill "$(cat "$PIDFILE")" 2>/dev/null
  rm -f "$PIDFILE"
fi
exit 0
