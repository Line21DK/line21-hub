#!/bin/bash
# Builds "LINE21 Control.app" (universal) into control/app/dist/. Private admin app, not distributed.
#   CONTROL_URL=https://control-production.up.railway.app VERSION=0.1.0 control/app/scripts/build-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.1.0}"
CONTROL_URL="${CONTROL_URL:-}"

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/LINE21Control"

APP="dist/LINE21 Control.app"
/bin/rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LINE21Control"
sed -e "s|@VERSION@|$VERSION|g" -e "s|@CONTROL_URL@|$CONTROL_URL|g" Resources/Info.plist > "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
echo "Built $APP ($VERSION) → server ${CONTROL_URL:-(set on login)}"
