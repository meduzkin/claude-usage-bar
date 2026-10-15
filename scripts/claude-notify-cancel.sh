#!/bin/bash
# Stop / PreToolUse hook: you answered, so cancel the pending notification
# scheduled by claude-notify.sh and clear the session's "waiting" marker.
INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "default"' 2>/dev/null)
PENDING_DIR="${CLAUDE_NOTIFY_PENDING_DIR:-/tmp}"
PIDFILE="$PENDING_DIR/claude-notify-pending-${SESSION_ID}.pid"
if [ -f "$PIDFILE" ]; then
  kill "$(cat "$PIDFILE")" 2>/dev/null
  rm -f "$PIDFILE"
fi
rm -f "$PENDING_DIR/claude-waiting-${SESSION_ID}"
exit 0
