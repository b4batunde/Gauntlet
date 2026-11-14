#!/bin/bash
# Builds dist/Gauntlet.app from the Swift package. Needs only the Xcode command-line tools.
#   Scripts/build-app.sh            release build
#   Scripts/build-app.sh debug      debug build
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
echo "› Building Gauntlet ($CONFIG)…"
swift build -c "$CONFIG" --product Gauntlet 2>&1 | grep -v "ld: warning: search path" || true
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Gauntlet"
[ -x "$BIN" ] || { echo "Build failed: $BIN not found" >&2; exit 1; }

if [ ! -f Scripts/AppIcon.icns ]; then
  echo "› Rendering icon…"
  swift Scripts/make-icon.swift >/dev/null
  iconutil -c icns Scripts/AppIcon.iconset -o Scripts/AppIcon.icns
  rm -rf Scripts/AppIcon.iconset
fi

APP="dist/Gauntlet.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Gauntlet"
cp Scripts/Info.plist "$APP/Contents/Info.plist"
cp Scripts/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Sign with your Apple Development certificate when there is one: macOS then recognises every
# rebuild as the same app, so the Accessibility permission survives. The signed copy goes to
# ~/Applications, because folders synced by iCloud (such as Desktop) attach Finder metadata
# that codesign rejects.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')"
if [ -n "$IDENTITY" ]; then
  INSTALLED="$HOME/Applications/Gauntlet.app"
  mkdir -p "$HOME/Applications"
  pkill -x Gauntlet 2>/dev/null || true
  rm -rf "$INSTALLED"
  ditto --norsrc --noextattr --noqtn "$APP" "$INSTALLED"
  xattr -cr "$INSTALLED"
  codesign --force --sign "$IDENTITY" --identifier dev.sunhacks.gauntlet "$INSTALLED"
  rm -rf "$APP"         # keep exactly one Gauntlet on disk, so macOS permissions never point at a stale copy
  echo "✓ Installed and signed $INSTALLED (permissions persist across rebuilds)"
  echo "  Run it:  open \"$INSTALLED\""
else
  codesign --force --sign - --identifier dev.sunhacks.gauntlet "$APP" 2>&1 | grep -v "replacing existing signature" || true
  echo "✓ Built $APP (ad-hoc signed: re-grant Accessibility after each rebuild)"
  echo "  Run it:  open $APP"
fi
