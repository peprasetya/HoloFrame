#!/bin/bash
#
# make-app.sh — build HoloFrame and wrap it in a .app bundle.
#
# The bundle is not cosmetic. Screen Recording permission is keyed to a code signature and
# path, and a bare `swift build` binary gets a fresh hash every rebuild — which means macOS
# re-prompts, and the capture silently fails until you grant it again. A stable, ad-hoc
# signed bundle at a fixed path is granted once and stays granted.
#
# Usage: Tools/make-app.sh [debug|release]

set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/HoloFrame.app"

cd "$ROOT"
echo "building ($CONFIG)..."
swift build -c "$CONFIG"

BIN="$ROOT/.build/$CONFIG/HoloFrame"
[ -x "$BIN" ] || { echo "no binary at $BIN"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/HoloFrame"

# Icon. Built on demand if it is missing, so a fresh clone needs no extra step.
if [ ! -f "$ROOT/Design/HoloFrame.icns" ]; then
  echo "building icon..."
  "$ROOT/Tools/make-icon.sh" >/dev/null
fi
cp "$ROOT/Design/HoloFrame.icns" "$APP/Contents/Resources/HoloFrame.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>HoloFrame</string>
  <key>CFBundleIdentifier</key><string>id.prasetya.holoframe</string>
  <key>CFBundleName</key><string>HoloFrame</string>
  <key>CFBundleIconFile</key><string>HoloFrame</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <!-- menu-bar style: no Dock icon, never takes focus from the desktop -->
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Signing identity.
#
# Ad-hoc (`-`) gives the bundle a fresh code hash on EVERY build, and Screen Recording
# permission is bound to that hash — so each rebuild silently revokes the grant and capture
# starts failing again. Signing with a real (even self-signed) certificate keeps the
# identity stable, so the grant survives rebuilds.
#
# To make one, once:
#   Keychain Access > Certificate Assistant > Create a Certificate...
#     Name: HoloFrame Dev     Identity Type: Self Signed Root
#     Certificate Type: Code Signing
#   then:  export HOLOFRAME_SIGN_IDENTITY="HoloFrame Dev"
IDENTITY="${HOLOFRAME_SIGN_IDENTITY:--}"

codesign --force --sign "$IDENTITY" --identifier id.prasetya.holoframe "$APP"

echo "built $APP"
if [ "$IDENTITY" = "-" ]; then
  cat <<'WARN'

  NOTE: signed ad-hoc, so this rebuild just invalidated any Screen Recording grant.
  Re-enable HoloFrame in System Settings > Privacy & Security > Screen Recording,
  or set up a stable identity once (see the comment in this script) to stop it
  happening on every build.
WARN
else
  echo "  signed as: $IDENTITY (grant survives rebuilds)"
fi

echo
echo "run:  open -a $APP"
echo "      open -a $APP --stdout /tmp/holoframe.log --stderr /tmp/holoframe.log   # with logs"
echo
echo "Launch with 'open -a', NOT the binary directly: running it from a shell makes TCC"
echo "attribute Screen Recording to the parent process and capture will fail."
