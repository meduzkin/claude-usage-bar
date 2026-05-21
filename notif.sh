#!/bin/bash
# Manages notification hooks in ~/.claude/settings.json.
#
# Subcommands:
#   state          print {"enabled": bool, "delay": int} JSON to stdout
#   set on [N]     enable hooks (with delay N seconds; default 60)
#   set off        disable hooks
#
# Atomic writes via tempfile+rename so we never half-clobber settings.json
# during a concurrent read from Claude Code. The widget calls this script
# from the menu bar item handlers.

set -euo pipefail

SETTINGS="${CLAUDE_SETTINGS_PATH:-$HOME/.claude/settings.json}"
SCRIPTS_DIR="${CLAUDE_SCRIPTS_DIR:-$HOME/.claude/scripts}"

ACTION="${1:-}"

case "$ACTION" in
  state)
    python3 - "$SETTINGS" <<'PY'
import json, os, sys
path = sys.argv[1]
state = {"enabled": False, "delay": 60}
try:
    with open(path) as f: data = json.load(f)
except Exception:
    print(json.dumps(state)); sys.exit(0)
hooks = (data.get("hooks") or {})
def find(hook_name, marker):
    for entry in (hooks.get(hook_name) or []):
        for h in (entry.get("hooks") or []):
            if marker in (h.get("command") or ""):
                return h
    return None
n = find("Notification", "claude-notify.sh")
s = find("Stop",         "claude-notify-cancel.sh")
p = find("PreToolUse",   "claude-notify-cancel.sh")
state["enabled"] = bool(n and s and p)
if n:
    parts = (n.get("command") or "").split()
    if len(parts) >= 2:
        try: state["delay"] = int(parts[-1])
        except: pass
print(json.dumps(state))
PY
    ;;
  set)
    sub="${2:-}"
    case "$sub" in
      on)
        delay="${3:-60}"
        ;;
      off)
        delay=""
        ;;
      *) echo "usage: notif.sh set on [N] | off" >&2; exit 2 ;;
    esac
    SCRIPTS_DIR="$SCRIPTS_DIR" SUB="$sub" DELAY="$delay" python3 - "$SETTINGS" <<'PY'
import json, os, sys, tempfile
path  = sys.argv[1]
sub   = os.environ["SUB"]
delay = os.environ["DELAY"]
scripts_dir = os.environ["SCRIPTS_DIR"]

NOTIFY_MARKER = "claude-notify.sh"
CANCEL_MARKER = "claude-notify-cancel.sh"

# Load
if os.path.exists(path):
    try:
        with open(path) as f: data = json.load(f)
    except Exception:
        data = {}
else:
    data = {}

data.setdefault("hooks", {})

# Strip ALL our existing entries first (so toggle/delay never duplicates)
def strip(name, marker):
    arr = data["hooks"].get(name) or []
    cleaned = []
    for entry in arr:
        new_hooks = [h for h in (entry.get("hooks") or [])
                     if marker not in (h.get("command") or "")]
        if new_hooks:
            cleaned.append({"matcher": entry.get("matcher", ""), "hooks": new_hooks})
    if cleaned:
        data["hooks"][name] = cleaned
    elif name in data["hooks"]:
        del data["hooks"][name]

strip("Notification", NOTIFY_MARKER)
strip("Stop",         CANCEL_MARKER)
strip("PreToolUse",   CANCEL_MARKER)

# Re-add if enabling
if sub == "on":
    notify_cmd = f"{scripts_dir}/claude-notify.sh {int(delay)}"
    cancel_cmd = f"{scripts_dir}/claude-notify-cancel.sh"
    data["hooks"].setdefault("Notification", []).append({
        "matcher": "",
        "hooks": [{"type": "command", "command": notify_cmd, "timeout": 5}]
    })
    data["hooks"].setdefault("Stop", []).append({
        "matcher": "",
        "hooks": [{"type": "command", "command": cancel_cmd, "timeout": 5}]
    })
    data["hooks"].setdefault("PreToolUse", []).append({
        "matcher": "",
        "hooks": [{"type": "command", "command": cancel_cmd, "timeout": 5}]
    })

# Trim empty hooks dict for cleanliness
if not data["hooks"]:
    del data["hooks"]

# Atomic write
os.makedirs(os.path.dirname(path), exist_ok=True)
fd, tmpname = tempfile.mkstemp(dir=os.path.dirname(path),
                                prefix=".settings-", suffix=".tmp")
with os.fdopen(fd, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.rename(tmpname, path)
PY
    ;;
  ""|-h|--help)
    cat <<EOF
usage: notif.sh state | set on [N] | set off

  state          print {"enabled": bool, "delay": int} as JSON
  set on [N]     enable notification hooks with delay N seconds (default 60)
  set off        remove our notification hooks

Environment overrides:
  CLAUDE_SETTINGS_PATH    default: ~/.claude/settings.json
  CLAUDE_SCRIPTS_DIR      default: ~/.claude/scripts
EOF
    [ -z "$ACTION" ] && exit 2 || exit 0
    ;;
  *)
    echo "notif.sh: unknown action: $ACTION" >&2
    exit 2
    ;;
esac
