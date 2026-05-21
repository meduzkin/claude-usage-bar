#!/bin/bash
# Installs the widget.
#
# Three ways to get the binary:
#   1. If `swiftc` is available (Xcode Command Line Tools) — build from
#      source. Default for anyone with the toolchain.
#   2. Else — download the pre-built universal binary from the GitHub
#      Releases page of this repo. No swiftc needed.
#   3. With `--build` to force a rebuild even if a fresh binary is
#      already present; with `--download` to skip building and pull the
#      release artifact unconditionally.
#
# On request, registers a LaunchAgent so the widget starts at login.
# Idempotent: safe to re-run.
#
# Flags:
#   --autostart   skip the prompt and install the LaunchAgent
#   --build       force a rebuild even if the binary is already there
#   --download    skip building, fetch the release artifact

set -euo pipefail
cd "$(dirname "$0")"
HERE=$(pwd -P)
BIN="$HERE/claude-usage-bar"
LABEL="com.local.claude-usage-bar"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
RELEASE_URL="https://github.com/meduzkin/claude-usage-bar/releases/latest/download/claude-usage-bar"

autostart=0
force_build=0
force_download=0
for arg in "$@"; do
  case "$arg" in
    --autostart) autostart=1 ;;
    --build)     force_build=1 ;;
    --download)  force_download=1 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

if [ "$force_build" -eq 1 ] && [ "$force_download" -eq 1 ]; then
  echo "--build and --download are mutually exclusive" >&2; exit 2
fi

echo "==> checking prerequisites"
missing=()

if ! command -v python3 >/dev/null 2>&1; then
  missing+=("python3 — required for JSON parsing in usage.sh")
fi
if ! command -v jq >/dev/null 2>&1; then
  missing+=("jq — required by the notification hook scripts (brew install jq)")
fi
if ! command -v npx >/dev/null 2>&1 && ! command -v ccusage >/dev/null 2>&1; then
  missing+=("npx or ccusage — install Node.js (or 'npm i -g ccusage') for cost data")
fi
if [ "$force_download" -eq 1 ] && ! command -v curl >/dev/null 2>&1; then
  missing+=("curl — required to download the release artifact")
fi

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

# Decide build vs download. Force flags win; otherwise build if swiftc,
# download if not.
mode=""
if [ "$force_build" -eq 1 ]; then
  mode="build"
elif [ "$force_download" -eq 1 ]; then
  mode="download"
elif command -v swiftc >/dev/null 2>&1; then
  mode="build"
else
  mode="download"
fi

if [ "$mode" = "build" ]; then
  if ! command -v swiftc >/dev/null 2>&1; then
    echo "missing swiftc — run: xcode-select --install (or re-run without --build to download a pre-built binary)" >&2
    exit 1
  fi
  echo "==> building from source"
  ./build.sh
else
  if ! command -v curl >/dev/null 2>&1; then
    echo "missing curl — cannot fetch release artifact" >&2; exit 1
  fi
  echo "==> downloading pre-built binary from $RELEASE_URL"
  if ! curl -fsSL "$RELEASE_URL" -o "$BIN"; then
    echo "download failed. Check the URL or run with --build if you have swiftc." >&2
    rm -f "$BIN"; exit 1
  fi
  chmod +x "$BIN"
  echo "    written: $BIN"
fi

# Deploy notification hook scripts to ~/.claude/scripts/ so the widget's
# "notifications" toggle has something to enable. Files are stateless and
# overwriting is safe.
SCRIPTS_TARGET="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/scripts"
mkdir -p "$SCRIPTS_TARGET"
cp "$HERE/scripts/claude-notify.sh" "$HERE/scripts/claude-notify-cancel.sh" "$SCRIPTS_TARGET/"
chmod +x "$SCRIPTS_TARGET/claude-notify.sh" "$SCRIPTS_TARGET/claude-notify-cancel.sh"
echo "==> notification hook scripts deployed to $SCRIPTS_TARGET/"
echo "    enable them later from the menu bar dropdown (notifications)"

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
