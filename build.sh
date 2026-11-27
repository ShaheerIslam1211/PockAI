#!/bin/zsh
# Builds TouchPlay, installs it to ~/Applications/TouchPlay.app and (re)launches it.
#   ./build.sh            debug build + launch
#   ./build.sh release    optimised build + launch
#   ./build.sh --no-open  build + install only
#   ./build.sh dist       release build → build/TouchPlay.dmg (drag-to-Applications installer for any Touch Bar Mac)
set -e
cd "${0:A:h}"
CONFIG=Debug
OPEN=1
DIST=0
for a in "$@"; do
  [[ "$a" == "release" ]] && CONFIG=Release
  [[ "$a" == "dist" ]] && { CONFIG=Release; DIST=1; OPEN=0; }
  [[ "$a" == "--no-open" ]] && OPEN=0
done
command -v xcodegen >/dev/null && xcodegen generate --quiet
# Sign with your Apple Development certificate when there is one (keeps Accessibility permission across rebuilds),
# otherwise ad-hoc.
IDENTITY=$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')
if [[ -n "$IDENTITY" ]]; then
  CERT_NAME=$(security find-identity -v -p codesigning | awk -F'"' -v h="$IDENTITY" '$0 ~ h {print $2; exit}')
  TEAM_ID=$(security find-certificate -c "$CERT_NAME" -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*OU *= *\([A-Z0-9]*\).*/\1/p')
  TEAM="DEVELOPMENT_TEAM=$TEAM_ID"
else
  IDENTITY="-"; TEAM="DEVELOPMENT_TEAM="
fi
mkdir -p build
if ! xcodebuild -project PockAI.xcodeproj -scheme PockAI -configuration $CONFIG -derivedDataPath build/DD \
  CODE_SIGN_IDENTITY="$IDENTITY" $TEAM build > build/log.txt 2>&1; then
  grep -E "error:|Undefined symbol" build/log.txt | cut -c1-300 | sort -u
  echo "BUILD FAILED (full log: build/log.txt)"; exit 1
fi
echo "BUILD SUCCEEDED ($CONFIG)"
APP_SRC="build/DD/Build/Products/$CONFIG/TouchPlay.app"
[[ -d "$APP_SRC" ]] || { echo "build failed"; exit 1; }
if [[ $DIST == 1 ]]; then
  STAGE=build/dmg
  rm -rf "$STAGE" build/TouchPlay.dmg
  mkdir -p "$STAGE"
  ditto "$APP_SRC" "$STAGE/TouchPlay.app"
  ln -s /Applications "$STAGE/Applications"
  cp README.md "$STAGE/Read Me.md"
  hdiutil create -volname "TouchPlay" -srcfolder "$STAGE" -ov -format UDZO build/TouchPlay.dmg >/dev/null
  rm -rf "$STAGE"
  echo "created build/TouchPlay.dmg ($(du -h build/TouchPlay.dmg | cut -f1))"
  exit 0
fi
APP="$HOME/Applications/TouchPlay.app"
# Stop the watchdog first, or launchd would restart the old copy while we replace it.
for agent in com.touchplay.app.agent com.pockai.app.agent; do /bin/launchctl bootout gui/$(id -u)/$agent 2>/dev/null || true; done
pkill -x TouchPlay 2>/dev/null || true
pkill -x PockAI 2>/dev/null || true
sleep 0.5
mkdir -p "$HOME/Applications"
rm -rf "$APP"
ditto "$APP_SRC" "$APP"
[[ $OPEN == 1 ]] && { sleep 1.5; open "$APP"; }
echo "installed $APP"
