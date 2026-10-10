#!/bin/bash
# make_dmg.sh [out.dmg]: build Project-Reclaimer-Mac-Port.dmg with double-click installer/uninstaller files.
# They run the same one-line installer from GitHub, so the disk image never goes stale.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=${1:-dist/Project-Reclaimer-Mac-Port.dmg}
RAW=https://raw.githubusercontent.com/mattromano/project-reclaimer-mac-port/main
STAGE=$(mktemp -d)/"Project Reclaimer"
mkdir -p "$STAGE" "$(dirname "$OUT")"

cat > "$STAGE/Install Project Reclaimer.command" <<CMD
#!/bin/bash
# Installs Halo 3 + Project Reclaimer under Wine (https://github.com/mattromano/project-reclaimer-mac-port).
# Safe to run again: finished steps are skipped.
clear
/bin/bash -c "\$(curl -fsSL $RAW/install.sh)"
echo; read -r -p "Press Return to close this window." _
CMD

cat > "$STAGE/Uninstall Project Reclaimer.command" <<CMD
#!/bin/bash
# Removes Project Reclaimer Mac Port (apps, ~/Games/ProjectReclaimer, the network startup task).
clear
/bin/bash -c "\$(curl -fsSL $RAW/uninstall.sh)"
echo; read -r -p "Press Return to close this window." _
CMD
chmod +x "$STAGE/"*.command

cat > "$STAGE/Read Me First.txt" <<'TXT'
Project Reclaimer for Mac (Halo 3 community servers, Forge, Workshop mods)

You need: an Apple Silicon Mac (M1 or newer) on macOS 14 or newer, Halo: The Master Chief Collection on
Steam, the Steam app on your phone, ~45 GB free disk space, and your Mac password once.

1. Double-click "Install Project Reclaimer".
   The first time, macOS says it can't verify the developer (this isn't from the App Store). Click Done,
   open System Settings > Privacy & Security, scroll down and click "Open Anyway" next to
   "Install Project Reclaimer", then confirm.
2. A Terminal window opens and does the rest. When a QR code appears, open the Steam app on your phone and
   scan it: Halo 3 (~35 GB) downloads from your own Steam account. Type your Mac password when asked.
3. When it says Done, open "Project Reclaimer" from Spotlight or Launchpad. Its window updates everything,
   shows a QR code to scan with the Steam app if mods need you to sign in, and then you press Play.

You only need this disk image once: the app keeps itself and the game up to date each time you open it.
If anything fails, run the installer again: it picks up where it stopped.
More help: https://github.com/mattromano/project-reclaimer-mac-port
TXT

rm -f "$OUT"
hdiutil create -quiet -volname "Project Reclaimer" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$OUT"
rm -rf "$(dirname "$STAGE")"
echo "$OUT"
