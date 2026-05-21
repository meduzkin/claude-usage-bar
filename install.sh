#!/bin/bash
# Installs the widget. Prefers the pre-built universal binary committed
# in this repo — only rebuilds if main.swift is newer than the binary or
# the binary is missing. On request, registers a LaunchAgent so the
# widget starts at login. Idempotent: safe to re-run.
#
# Flags:
#   --autostart   skip the prompt and install the LaunchAgent
#   --build       force a rebuild even if the pre-built binary is fresh

set -euo pipefail
cd "$(dirname "$0")"
HERE=$(pwd -P)
BIN="$HERE/claude-usage-bar"
LABEL="com.local.claude-usage-bar"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

autostart=0
force_build=0
for arg in "$@"; do
  case "$arg" in
    --autostart) autostart=1 ;;
    --build)     force_build=1 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

# decide whether we need swiftc this run
need_build=0
if [ "$force_build" -eq 1 ] || [ ! -x "$BIN" ] || [ main.swift -nt "$BIN" ]; then
  need_build=1
fi

echo "==> checking prerequisites"
missing=()

if [ "$need_build" -eq 1 ] && ! command -v swiftc >/dev/null 2>&1; then
  missing+=("swiftc — install Xcode command-line tools: xcode-select --install")
fi
if ! command -v python3 >/dev/null 2>&1; then
  missing+=("python3 — required for JSON parsing in usage.sh")
fi
if ! command -v jq >/dev/null 2>&1; then
  missing+=("jq — required by the notification hook scripts (brew install jq)")
fi
if ! command -v npx >/dev/null 2>&1 && ! command -v ccusage >/dev/null 2>&1; then
  missing+=("npx or ccusage — install Node.js (or 'npm i -g ccusage') for cost data")
fi

# Surface the keychain prompt during install rather than at first widget
# launch. On first run macOS pops the standard "allow access" dialog —
# click "Always Allow" and subsequent reads from usage.sh (via the same
# /usr/bin/security caller) are silent.
echo "==> verifying keychain access (you may see a macOS password prompt)"
if ! security find-generic-password -s "Claude Code-credentials" -w >/dev/null 2>&1; then
  missing+=("keychain entry 'Claude Code-credentials' is missing or unreadable — log in to Claude Code at least once, then re-run this script")
fi

if [ ${#missing[@]} -gt 0 ]; then
  echo "" >&2
  echo "missing prerequisites:" >&2
  for m in "${missing[@]}"; do echo "  - $m" >&2; done
  exit 1
fi

if [ "$need_build" -eq 1 ]; then
  echo "==> building (main.swift is newer than the binary, or no binary present)"
  ./build.sh
else
  echo "==> using pre-built binary: $BIN"
fi

# Deploy notification hook scripts to ~/.claude/scripts/ so the widget's
# "notifications" toggle has something to enable. Files are overwritten
# unconditionally — they are stateless and identical across versions.
SCRIPTS_TARGET="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/scripts"
mkdir -p "$SCRIPTS_TARGET"
cp "$HERE/scripts/claude-notify.sh" "$HERE/scripts/claude-notify-cancel.sh" "$SCRIPTS_TARGET/"
chmod +x "$SCRIPTS_TARGET/claude-notify.sh" "$SCRIPTS_TARGET/claude-notify-cancel.sh"
echo "==> notification hook scripts deployed to $SCRIPTS_TARGET/"
echo "    enable them later from the menu bar dropdown (notifications ▸)"

if [ "$autostart" -eq 0 ]; then
  printf "\nInstall LaunchAgent so the widget starts at login? [y/N] "
  read -r ans
  [[ "$ans" =~ ^[Yy]$ ]] && autostart=1
fi

if [ "$autostart" -eq 1 ]; then
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>           <string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$BIN</string></array>
  <key>RunAtLoad</key>       <true/>
  <key>KeepAlive</key>       <true/>
  <key>StandardOutPath</key> <string>/tmp/$LABEL.log</string>
  <key>StandardErrorPath</key><string>/tmp/$LABEL.log</string>
</dict>
</plist>
EOF
  launchctl unload "$PLIST" 2>/dev/null || true
  launchctl load "$PLIST"
  echo "==> LaunchAgent installed: $PLIST"
  echo "    widget should appear in the menu bar shortly"
else
  echo ""
  echo "==> not autostarting. To run manually:"
  echo "    $BIN &"
fi
