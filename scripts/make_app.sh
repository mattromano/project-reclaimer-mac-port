#!/bin/bash
# make_app.sh "<App Name>" wine|metal: build ~/Applications/<App Name>.app that launches that variant
set -euo pipefail
NAME=$1 GFX=$2
BASE=${RECLAIMER_HOME:-$HOME/Games/ProjectReclaimer}
APP="${RECLAIMER_APPS_DIR:-$HOME/Applications}/$NAME.app"
ID=local.projectreclaimer.$(echo "$NAME" | tr 'A-Z ' 'a-z-')
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/MacOS/launch" <<EOF
#!/bin/zsh
# Start Project Reclaimer ($GFX) with the Workshop mod helper alongside it
export RECLAIMER_HOME="$BASE" RECLAIMER_GFX=$GFX RECLAIMER_LOG="$BASE/logs/client-$GFX.log"
H="\$RECLAIMER_HOME/game/workshop_helper.py"
[ -s "\$RECLAIMER_HOME/steam-account" ] || /usr/bin/python3 -I "\$H" setup
: > "\$RECLAIMER_LOG"
/usr/bin/python3 -I "\$H" watch >> "\$RECLAIMER_HOME/logs/workshop-helper.log" 2>&1 &
exec "\$RECLAIMER_HOME/game/run.sh" > "\$RECLAIMER_LOG" 2>&1
EOF
chmod +x "$APP/Contents/MacOS/launch"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$ID</string>
  <key>CFBundleExecutable</key><string>launch</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
</dict>
</plist>
EOF

# icon: MCC's own Reclaimer artwork, cropped square
SRC="$BASE/prefix-wine/drive_c/Program Files (x86)/Steam/steamapps/common/Halo The Master Chief Collection/Data/UI/BackgroundVideos/Images/Reclaimer.png"
if [ -f "$SRC" ]; then
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
touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" || true
echo "    $APP"
