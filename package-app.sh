#!/bin/bash
# Packages the built universal binary + the two shell scripts it shells
# out to (usage.sh, notif.sh) into a proper macOS .app bundle:
#
#   Claude Usage Bar.app/
#     Contents/
#       Info.plist
#       MacOS/claude-usage-bar
#       Resources/{usage.sh, notif.sh}
#
# The bundle is ad-hoc signed (free, no Apple Developer ID). That's
# enough for Apple Silicon to launch it; it does NOT bypass Gatekeeper
# for a quarantine-marked download — the user still has to click "Open
# Anyway" in System Settings the first time after a browser download.
# Installs that go through install.sh use curl, which doesn't set
# quarantine, so that path stays one-step.

set -euo pipefail
cd "$(dirname "$0")"

BIN="claude-usage-bar"
APP="Claude Usage Bar.app"

if [ ! -x "$BIN" ]; then
  echo "missing built binary '$BIN' — run ./build.sh first" >&2
  exit 1
fi

VERSION=$(grep '^let WIDGET_VERSION' main.swift | sed 's/.*"\(.*\)".*/\1/')
if [ -z "$VERSION" ]; then
  echo "couldn't parse WIDGET_VERSION from main.swift" >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/$BIN"
chmod +x "$APP/Contents/MacOS/$BIN"
cp usage.sh notif.sh "$APP/Contents/Resources/"
chmod +x "$APP/Contents/Resources/usage.sh" "$APP/Contents/Resources/notif.sh"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>            <string>com.local.claude-usage-bar</string>
  <key>CFBundleName</key>                  <string>Claude Usage Bar</string>
  <key>CFBundleDisplayName</key>           <string>Claude Usage Bar</string>
  <key>CFBundleExecutable</key>            <string>$BIN</string>
  <key>CFBundleShortVersionString</key>    <string>$VERSION</string>
  <key>CFBundleVersion</key>               <string>$VERSION</string>
  <key>CFBundlePackageType</key>           <string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key> <string>6.0</string>
  <key>LSMinimumSystemVersion</key>        <string>12.0</string>
  <key>LSUIElement</key>                   <true/>
  <key>NSHighResolutionCapable</key>       <true/>
</dict>
</plist>
EOF

# Ad-hoc sign the whole bundle. --deep re-signs the inner Mach-O too,
# replacing the ad-hoc signature that swiftc already put there.
codesign --sign - --force --deep "$APP" >/dev/null

echo "packaged: $(pwd)/$APP"
echo "version:  $VERSION"
