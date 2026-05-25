#!/bin/bash
# Removes the LaunchAgent, the installed .app bundle, and stops any
# running widget. Does not touch the source repo, build artefacts, or
# the keychain entry.

set -euo pipefail
LABEL="com.local.claude-usage-bar"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
APP_INSTALLED="$HOME/Applications/Claude Usage Bar.app"

if [ -f "$PLIST" ]; then
  launchctl unload "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  echo "==> removed LaunchAgent: $PLIST"
else
  echo "==> no LaunchAgent installed"
fi

if pkill -f "claude-usage-bar/claude-usage-bar" 2>/dev/null \
   || pkill -f "Claude Usage Bar.app/Contents/MacOS/claude-usage-bar" 2>/dev/null; then
  echo "==> stopped running widget"
fi

if [ -d "$APP_INSTALLED" ]; then
  rm -rf "$APP_INSTALLED"
  echo "==> removed bundle: $APP_INSTALLED"
fi

echo ""
echo "To also drop the keychain ACL entry that allowed silent access:"
echo "    open /Applications/Utilities/Keychain\\ Access.app"
echo "    → search 'Claude Code-credentials' → Access Control → remove /usr/bin/security"
