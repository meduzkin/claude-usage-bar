#!/bin/bash
# Claude Code statusline integration.
#
# Hook this into your statusline (settings.json -> "statusline_command")
# to get the current 5-hour-window utilization inline with everything
# else your statusline prints.
#
# Reads exclusively from the cached oauth response written by the widget
# at ~/.cache/claude-usage-bar/oauth.json — never touches the network so
# it stays cheap on every prompt render. If the cache is missing or
# stale (>1h), prints nothing.

set -euo pipefail
CACHE="${CLAUDE_USAGE_CACHE_DIR:-$HOME/.cache/claude-usage-bar}/oauth.json"

[ -r "$CACHE" ] || exit 0

# Refuse stale data (older than the longest configured widget refresh)
if command -v stat >/dev/null 2>&1; then
  mtime=$(stat -f %m "$CACHE" 2>/dev/null || stat -c %Y "$CACHE" 2>/dev/null || echo 0)
  age=$(( $(date +%s) - mtime ))
  [ "$age" -gt 3600 ] && exit 0
fi

python3 - "$CACHE" <<'PY'
import json, sys, datetime
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
fh = d.get("five_hour") or {}
pct = fh.get("utilization")
reset = fh.get("resets_at")
if pct is None:
    sys.exit(0)

# minutes-until-reset, parsed from ISO timestamp
mins_left = None
if reset:
    try:
        t = datetime.datetime.fromisoformat(reset.replace("Z", "+00:00"))
        diff = (t - datetime.datetime.now(datetime.timezone.utc)).total_seconds()
        mins_left = max(0, int(diff // 60))
    except Exception:
        pass

if mins_left is not None and mins_left >= 60:
    reset_str = f"{mins_left // 60}h {mins_left % 60:02d}m"
elif mins_left is not None:
    reset_str = f"{mins_left}m"
else:
    reset_str = "?"

# 6-tier colour for the percentage (ANSI 24-bit). Matches the menu bar
# bar palette: green → yellow → red, with intermediate steps so pace is
# visible at a glance.
def color(p):
    if p < 40:  return "\033[38;5;46m"   # bright green
    if p < 60:  return "\033[38;5;82m"   # green
    if p < 75:  return "\033[38;5;226m"  # yellow
    if p < 85:  return "\033[38;5;208m"  # orange
    if p < 95:  return "\033[38;5;202m"  # red-orange
    return        "\033[38;5;196m"       # red
RESET = "\033[0m"

# Pace marker: projected end-of-window % at current burn rate.
# Window is 5 hours = 300 minutes; elapsed = 300 - mins_left.
pace = None
if mins_left is not None and mins_left < 300:
    elapsed = 300 - mins_left
    if elapsed > 0:
        pace = pct / elapsed * 300

pace_str = ""
if pace is not None:
    arrow = "→" if pace <= 100 else "⚠"
    pace_str = f" {arrow}{min(pace, 999):.0f}%"

print(f"{color(pct)}{pct:.0f}%{RESET}{pace_str} · {reset_str}", end="")
PY
