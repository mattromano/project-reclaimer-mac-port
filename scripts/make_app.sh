#!/bin/bash
# make_app.sh "<App Name>" <version>: build ~/Applications/<App Name>.app around the launcher window
# ($RECLAIMER_HOME/tools/ProjectReclaimer, installed by install.sh). Safe to run while the app is open.
set -euo pipefail
NAME=$1 VERSION=${2:-0}
BASE=${RECLAIMER_HOME:-$HOME/Games/ProjectReclaimer}
APP="${RECLAIMER_APPS_DIR:-$HOME/Applications}/$NAME.app"
# an update rebuilds the app the player opened, wherever they moved it (the launcher passes its own path)
case "${RECLAIMER_APP_PATH:-}" in *.app) [ -d "$RECLAIMER_APP_PATH" ] && APP=$RECLAIMER_APP_PATH ;; esac
xml() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' <<< "$1"; }
ID=local.projectreclaimer.$(echo "$NAME" | tr 'A-Z ' 'a-z-')
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# (older versions started the game from a shell script named "launch")
rm -f "$APP/Contents/MacOS/launch" "$APP/Contents/MacOS/ProjectReclaimer"
cp "$BASE/tools/ProjectReclaimer" "$APP/Contents/MacOS/ProjectReclaimer"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$(xml "$NAME")</string>
  <key>CFBundleDisplayName</key><string>$(xml "$NAME")</string>
  <key>CFBundleIdentifier</key><string>$ID</string>
  <key>CFBundleExecutable</key><string>ProjectReclaimer</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
  <key>ReclaimerHome</key><string>$(xml "$BASE")</string>
</dict>
</plist>
PLIST

# icon: MCC's own Reclaimer artwork, cropped square
SRC="$BASE/prefix-wine/drive_c/Program Files (x86)/Steam/steamapps/common/Halo The Master Chief Collection/Data/UI/BackgroundVideos/Images/Reclaimer.png"
if [ -f "$SRC" ] && [ ! -f "$APP/Contents/Resources/AppIcon.icns" ]; then
  T=$(mktemp -d); mkdir "$T/AppIcon.iconset"
  W=$(sips -g pixelWidth "$SRC" | awk '/pixelWidth/{print $2}'); H=$(sips -g pixelHeight "$SRC" | awk '/pixelHeight/{print $2}')
  S=$(( W < H ? W : H ))
  sips -c "$S" "$S" "$SRC" --out "$T/square.png" >/dev/null
  for s in 16 32 128 256 512; do
    sips -z $s $s "$T/square.png" --out "$T/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$T/square.png" --out "$T/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$T/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns" || true
  rm -rf "$T"
fi
# ad-hoc signature over the whole bundle, so macOS treats the binary, Info.plist and icon as one app
codesign --force --sign - "$APP" 2>/dev/null || true
touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" || true
echo "    $APP"
