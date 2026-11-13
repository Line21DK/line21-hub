#!/bin/bash
# Builds "LINE21 Hub.app" (universal) into app/dist/.
#   CATALOG_URL=https://hub.line21.dk PUBLIC_KEY=<base64> VERSION=0.1.0 app/scripts/build-app.sh
# SIGN_IDENTITY="Developer ID Application: …" signs for distribution; without it the app is ad-hoc
# signed, which is fine on your own Mac but blocked by Gatekeeper on other people's Macs.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.1.0}"
CATALOG_URL="${CATALOG_URL:-http://localhost:8080}"
PUBLIC_KEY="${PUBLIC_KEY:?Set PUBLIC_KEY to the base64 key printed by npm run keygen}"

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/LINE21Hub"

APP="dist/LINE21 Hub.app"
/bin/rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LINE21Hub"
sed -e "s|@VERSION@|$VERSION|g" -e "s|@CATALOG_URL@|$CATALOG_URL|g" -e "s|@PUBLIC_KEY@|$PUBLIC_KEY|g" \
  Resources/Info.plist > "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/" && \
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"

if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
else
  codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP"
echo "Built $APP ($VERSION) → catalog $CATALOG_URL"
