#!/bin/bash
# make_dmg.sh [out.dmg]: build Project-Reclaimer-Mac-Port.dmg: the Project Reclaimer app (the launcher window, which
# installs everything on first open, upgrades a 1.0 install, and otherwise opens the installed app), a picture of
# macOS's one-time "Open Anyway" step, and a read-me. The app fetches the installer from GitHub, so it never goes stale.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=${1:-dist/Project-Reclaimer-Mac-Port.dmg}
STAGE=$(mktemp -d)/"Project Reclaimer"
APP="$STAGE/Project Reclaimer.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$(dirname "$OUT")"

cp launcher/ProjectReclaimer "$APP/Contents/MacOS/ProjectReclaimer"
cp launcher/Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# no ReclaimerHome key: that marks the installed copy (see LauncherApp.swift), this one installs or hands off
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Project Reclaimer</string>
  <key>CFBundleDisplayName</key><string>Project Reclaimer</string>
  <key>CFBundleIdentifier</key><string>local.projectreclaimer.setup</string>
  <key>CFBundleExecutable</key><string>ProjectReclaimer</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$(cat VERSION)</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"

launcher/ProjectReclaimer --render-guide "$STAGE" >/dev/null
mv "$STAGE/guide.png" "$STAGE/How to open it the first time.png"

cat > "$STAGE/Read Me First.txt" <<'TXT'
Project Reclaimer for Mac (Halo 3 community servers, Forge, Workshop mods)

You need: an Apple Silicon Mac (M1 or newer) on macOS 14 or newer, Halo: The Master Chief Collection on
Steam, the Steam app on your phone, ~45 GB free disk space, and your Mac password once.

1. Double-click "Project Reclaimer".
   The first time, macOS blocks it because it isn't from the App Store. The picture
   "How to open it the first time" shows how to allow it (System Settings > Privacy & Security >
   Open Anyway). You only do this once.
2. The Project Reclaimer window checks your Mac and installs everything. When it shows a QR code,
   scan it with the Steam app on your phone: Halo 3 (~35 GB) downloads from your own Steam account.
   Tick "Also download Halo 3: ODST" first for ODST's campaign and Firefight (~9 GB more, ~54 GB free
   in all); you can also add it later from the Tools button.
   macOS asks for your Mac password once.
3. When it's done, it opens Project Reclaimer from your Applications folder: press Play. You can eject
   this disk image and move it to the Trash.

Had the first version (it asked for your Steam account name)? Open "Project Reclaimer" from this disk image:
it offers a one-time Upgrade that keeps your game files, mods and settings.

From then on the app keeps itself and the game up to date, and its Tools button handles the rest
(force quit, repair, mods and disk space, reports, uninstall).
More help: https://github.com/mattromano/project-reclaimer-mac-port
TXT

rm -f "$OUT"
hdiutil create -quiet -volname "Project Reclaimer" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$OUT"
rm -rf "$(dirname "$STAGE")"
echo "$OUT"
