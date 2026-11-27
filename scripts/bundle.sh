#!/usr/bin/env bash
# Builds HerdrMac and wraps it in build/HerdrMac.app. `scripts/bundle.sh [debug|release]`.
set -euo pipefail
CONFIG=${1:-release}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
[ -d Vendor/GhosttyKit.xcframework ] || scripts/ghosttykit.sh
swift build -c "$CONFIG" --product HerdrMac
swift build -c "$CONFIG" --product herdr-mac-attach
BIN=$(swift build -c "$CONFIG" --show-bin-path)/HerdrMac
APP=${APP:-build/HerdrMac.app}
# Version from VERSION; the build number (date and time) orders releases for auto-update.
VERSION=$(cat VERSION)
BUILD=${BUILD:-$(date +%Y%m%d%H%M)}
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/HerdrMac"
# The attach relay each terminal surface runs (see Sources/herdr-mac-attach).
cp "$(dirname "$BIN")/herdr-mac-attach" "$APP/Contents/MacOS/herdr-mac-attach"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Licenses travel with the app (Ghostty's MIT notice must accompany libghostty).
cp LICENSE NOTICE "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>HerdrMac</string>
  <key>CFBundleDisplayName</key><string>Herdr (Mac prototype)</string>
  <key>CFBundleIdentifier</key><string>local.herdr-mac.prototype</string>
  <key>CFBundleExecutable</key><string>HerdrMac</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
touch "$APP" # Finder and the Dock pick up a changed icon
echo "$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"
