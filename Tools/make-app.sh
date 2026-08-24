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
# Ad-hoc (`-`) gives the bundle a fresh code hash on EVERY build, and TCC permissions are
# bound to that hash — so each rebuild silently revokes both Screen Recording (capture
# stops) and Accessibility (pinch zoom stops). Signing with a real (even self-signed)
# certificate keeps the identity stable, so both grants survive rebuilds.
#
# To make one, once:
#   Keychain Access > Certificate Assistant > Create a Certificate...
#     Name: HoloFrame Dev     Identity Type: Self Signed Root
#     Certificate Type: Code Signing
#
# Nothing to export afterwards: if that identity exists it is found and used. An env var
# you have to remember to set in every new shell is a stable identity that silently is not
# one, which is the same failure it was meant to fix.
#
# Searched WITHOUT `-v`, and signed by SHA-1 rather than by name, both deliberately. A
# self-signed root is never "valid" to the trust policy — `find-identity -v` reports zero
# and hides it completely — but codesign only needs the private key, and the signature it
# produces is structurally sound. Trust would only matter to Gatekeeper, which is not what
# is being solved here: what matters is the designated requirement, which becomes
#
#   identifier "id.prasetya.holoframe" and certificate leaf = H"<hash>"
#
# with no cdhash in it. That is what TCC records, and it no longer changes when the binary
# does — so Screen Recording and Accessibility both survive every rebuild.
IDENTITY_NAME="HoloFrame Dev"
if [ -n "${HOLOFRAME_SIGN_IDENTITY:-}" ]; then
  IDENTITY="$HOLOFRAME_SIGN_IDENTITY"
else
  MATCHES=$(security find-identity -p codesigning 2>/dev/null \
            | grep -F "\"$IDENTITY_NAME" \
            | sed -E 's/^[[:space:]]*[0-9]+\)[[:space:]]*([0-9A-F]+)[[:space:]]+"(.*)".*$/\1 \2/')
  COUNT=$(printf '%s' "$MATCHES" | grep -c . || true)
  if [ "$COUNT" -eq 0 ]; then
    IDENTITY="-"
  else
    IDENTITY=$(printf '%s' "$MATCHES" | head -1 | cut -d' ' -f1)
    IDENTITY_LABEL=$(printf '%s' "$MATCHES" | head -1 | cut -d' ' -f2-)
    if [ "$COUNT" -gt 1 ]; then
      echo "  note: $COUNT certificates match \"$IDENTITY_NAME\"; using \"$IDENTITY_LABEL\"."
      echo "        Delete the spares, or set HOLOFRAME_SIGN_IDENTITY, so the choice cannot drift."
    fi
  fi
fi

codesign --force --sign "$IDENTITY" --identifier id.prasetya.holoframe "$APP"

echo "built $APP"
if [ "$IDENTITY" = "-" ]; then
  cat <<'WARN'

  NOTE: signed ad-hoc, so this rebuild just invalidated every TCC grant it had:
    - Screen Recording  (capture will not start)
    - Accessibility     (right-option + pinch zoom will not work)
  Re-enable both in System Settings > Privacy & Security, or create the "HoloFrame Dev"
  certificate once (see the comment in this script) to stop it happening on every build.
WARN
else
  echo "  signed as: ${IDENTITY_LABEL:-$IDENTITY}"
  echo "  ($IDENTITY)"
  echo "  TCC grants now survive rebuilds. Deleting that certificate revokes them."
fi

echo
echo "run:  open -a $APP"
echo "      open -a $APP --stdout /tmp/holoframe.log --stderr /tmp/holoframe.log   # with logs"
echo
echo "Launch with 'open -a', NOT the binary directly: running it from a shell makes TCC"
echo "attribute Screen Recording to the parent process and capture will fail."
