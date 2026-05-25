#!/bin/bash
# Installs the widget as a proper macOS .app bundle in ~/Applications/.
# Finder, Spotlight and Launchpad pick it up by name.
#
# Three ways to obtain the bundle:
#   1. `swiftc` available (Xcode Command Line Tools) — build from source.
#      Default when the toolchain is present.
#   2. Else — download the pre-built bundle zip from the GitHub Releases
#      page of this repo. No swiftc needed.
#   3. With `--build` to force a rebuild; with `--download` to skip
#      building and pull the release artefact unconditionally.
#
# On request, registers a LaunchAgent so the widget starts at login.
# Idempotent: safe to re-run.
#
# Flags:
#   --autostart   skip the prompt and install the LaunchAgent
#   --build       force a rebuild even if a fresh bundle is already there
#   --download    skip building, fetch the release artefact

set -euo pipefail
cd "$(dirname "$0")"
HERE=$(pwd -P)
BIN_LOCAL="$HERE/claude-usage-bar"
APP_NAME="Claude Usage Bar.app"
APP_LOCAL="$HERE/$APP_NAME"
APPS_DIR="$HOME/Applications"
APP_INSTALLED="$APPS_DIR/$APP_NAME"
APP_BIN_INSTALLED="$APP_INSTALLED/Contents/MacOS/claude-usage-bar"
LABEL="com.local.claude-usage-bar"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
RELEASE_URL_BIN="https://github.com/meduzkin/claude-usage-bar/releases/latest/download/claude-usage-bar"
RELEASE_URL_ZIP="https://github.com/meduzkin/claude-usage-bar/releases/latest/download/Claude-Usage-Bar.zip"

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
  missing+=("curl — required to download the release artefact")
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
    echo "missing swiftc — run: xcode-select --install (or re-run without --build to download a pre-built bundle)" >&2
    exit 1
  fi
  echo "==> building from source (produces bare binary + .app bundle)"
  ./build.sh
else
  if ! command -v curl >/dev/null 2>&1; then
    echo "missing curl — cannot fetch release artefact" >&2; exit 1
  fi
  echo "==> downloading pre-built bundle from $RELEASE_URL_ZIP"
  TMPZIP=$(mktemp -t cub.XXXXXX.zip)
  TMPDIR_EXTRACT=$(mktemp -d -t cub.XXXXXX)
  trap 'rm -rf "$TMPZIP" "$TMPDIR_EXTRACT"' EXIT
  if ! curl -fsSL "$RELEASE_URL_ZIP" -o "$TMPZIP"; then
    echo "download failed. Check the URL or run with --build if you have swiftc." >&2
    exit 1
  fi
  unzip -q "$TMPZIP" -d "$TMPDIR_EXTRACT"
  if [ ! -d "$TMPDIR_EXTRACT/$APP_NAME" ]; then
    echo "extracted archive doesn't contain '$APP_NAME'" >&2; exit 1
  fi
  rm -rf "$APP_LOCAL"
  mv "$TMPDIR_EXTRACT/$APP_NAME" "$APP_LOCAL"
  # Also fetch the bare binary so the dev workflow `./claude-usage-bar`
  # keeps working from the repo dir.
  if curl -fsSL "$RELEASE_URL_BIN" -o "$BIN_LOCAL" 2>/dev/null; then
    chmod +x "$BIN_LOCAL"
  fi
  echo "    written: $APP_LOCAL"
fi

# Install the bundle into ~/Applications/ where Spotlight/Finder index it.
mkdir -p "$APPS_DIR"
rm -rf "$APP_INSTALLED"
cp -R "$APP_LOCAL" "$APP_INSTALLED"
# Strip quarantine just in case (no-op for curl-fetched files; safety
# net for users who hand-dropped a downloaded .app and then ran us).
xattr -dr com.apple.quarantine "$APP_INSTALLED" 2>/dev/null || true
echo "==> installed bundle: $APP_INSTALLED"
echo "    launchable from Spotlight, Finder and Launchpad as 'Claude Usage Bar'"

# Deploy notification hook scripts to ~/.claude/scripts/ so the widget's
# "notifications" toggle has something to enable. Files are stateless and
# overwriting is safe.
SCRIPTS_TARGET="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/scripts"
mkdir -p "$SCRIPTS_TARGET"
cp "$HERE/scripts/claude-notify.sh" "$HERE/scripts/claude-notify-cancel.sh" "$HERE/scripts/statusline.sh" "$SCRIPTS_TARGET/"
chmod +x "$SCRIPTS_TARGET/claude-notify.sh" "$SCRIPTS_TARGET/claude-notify-cancel.sh" "$SCRIPTS_TARGET/statusline.sh"
echo "==> hook + statusline scripts deployed to $SCRIPTS_TARGET/"
echo "    enable notifications from the menu bar dropdown"
echo "    add statusline.sh to Claude Code: set \"statusline\": {\"command\": \"$SCRIPTS_TARGET/statusline.sh\"} in ~/.claude/settings.json"

# Self-update source config. The widget reads this to know where to
# check for new releases. The GitHub distribution writes the GitHub
# Releases API endpoint here; the ai-snippets distribution writes the
# GitLab Releases API endpoint.
mkdir -p "$HOME/.cache/claude-usage-bar"
cat > "$HOME/.cache/claude-usage-bar/update.json" <<EOF
{
  "type":       "github",
  "url":        "https://api.github.com/repos/meduzkin/claude-usage-bar/releases/latest",
  "asset_name": "claude-usage-bar"
}
EOF
echo "==> update source pinned to GitHub Releases"

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
  <key>ProgramArguments</key><array><string>$APP_BIN_INSTALLED</string></array>
  <key>RunAtLoad</key>       <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key><false/>
  </dict>
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
  echo "    open '$APP_INSTALLED'"
fi
