#!/bin/bash
# Project Reclaimer Mac Port: installs Halo 3 (MCC) + Project Reclaimer under Wine on Apple Silicon.
#
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/mattromano/project-reclaimer-mac-port/main/install.sh)"
#
# Everything lives in ~/Games/ProjectReclaimer (override with RECLAIMER_HOME). Safe to re-run: finished steps are skipped.
# Options (environment variables):
#   RECLAIMER_MCC_FROM=<dir>    copy existing MCC game files from <dir> instead of downloading them from Steam
#   RECLAIMER_ODST=1            also download Halo 3: ODST (~9 GB more) for its campaign and Firefight; re-running
#                               the installer with it adds ODST to an existing install
#   RECLAIMER_CACHE=<dir>       reuse already-downloaded archives from <dir>
#   RECLAIMER_UPDATE=1          update an existing install without questions (run by the launcher's updater.py):
#                               admin steps use macOS's password dialog instead of sudo
#   RECLAIMER_RESET_GRAPHICS=1  put back the tuned graphics settings (otherwise only a fresh install gets them)
#   RECLAIMER_GUI=1             run by the launcher window's Setup/Upgrade: no Terminal questions, the macOS password
#                               dialog for admin steps, the Steam QR code and download progress for the window
set -euo pipefail

REPO_RAW=${RECLAIMER_REPO_RAW:-https://raw.githubusercontent.com/mattromano/project-reclaimer-mac-port/main}
BASE=${RECLAIMER_HOME:-$HOME/Games/ProjectReclaimer}
CACHE=${RECLAIMER_CACHE:-$BASE/downloads}
STEAM_REL="drive_c/Program Files (x86)/Steam"
MCC_REL="$STEAM_REL/steamapps/common/Halo The Master Chief Collection"
MCC_APP=976730
MCC_DEPOTS="976731 976738 976739"   # MCC base, Halo 3, Halo 3 multiplayer (~35 GB)
ODST_DEPOT=1064222                  # Halo 3: ODST (~9 GB, optional; Project Reclaimer 0.9.19+ plays it)
ODST=${RECLAIMER_ODST:-}

# name|url|sha256
WINE_PKG="wine-staging-11.18-osx64.tar.xz|https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.18/wine-staging-11.18-osx64.tar.xz|b63704b91af269bc026a87f12bd297c4a50caaf570c322e600b6621ef918f127"
DXVK_PKG="dxvk-macOS-async-v1.10.3-20230507-repack.tar.gz|https://github.com/Gcenx/DXVK-macOS/releases/download/v1.10.3-20230507-repack/dxvk-macOS-async-v1.10.3-20230507-repack.tar.gz|acd1520ad105d8ef124a09c8e11a259a5dc8bdc565ad18e0e52693f9807b2477"
MOLTENVK_PKG="MoltenVK-macos-1.4.2.tar|https://github.com/KhronosGroup/MoltenVK/releases/download/v1.4.2/MoltenVK-macos.tar|f95765a6229cb7b915990a2890ce12ebe36a730b021545d3d52ae69ce4c4024e"
MESA_PKG="mesa3d-26.2.4-release-msvc.7z|https://github.com/pal1000/mesa-dist-win/releases/download/26.2.4/mesa3d-26.2.4-release-msvc.7z|351fc8c8b695878ffb3eaa044b3ead08672a48b1a045e3c3e3975811df0f6695"
DEPOT_PKG="DepotDownloader-macos-arm64.zip|https://github.com/SteamRE/DepotDownloader/releases/download/DepotDownloader_3.4.0/DepotDownloader-macos-arm64.zip|60e80c7c496f3f9a079cd3c62036b35d088c27bc0149baf38f009eb57a52f6a5"
SPINFIX_SHA=0ec56a555b7b420c381f7cf5010719c86c3626c3c99efcb376981089f5d4f847  # spinfix/d3d11.dll (built from spinfix/spinfix.c)
# the root startup task (scripts/reclaimer-loopback.sh and its plist): checked as root after they're copied where only
# root can write, so a file swapped in the meantime never runs at boot (also in tools.py; the tests check all match)
LOOPBACK_SHA=23c93f7c5e587da1dba205534b4661042dd13b5142cbac6846f1ffdcf4a3cd83
LOOPBACK_PLIST_SHA=27fcc35a99d21f2b266cca4041bbd8388e72738c8b3d1797e43f243b7556d7cd
LAUNCHER_SHA=c15000f1b528d509c1049c0c266ce004b19ad2e31d0cf4d91b625e4dd79b2cd6  # launcher/ProjectReclaimer (built by scripts/make_launcher.sh)
UPDATE=${RECLAIMER_UPDATE:-}
GUI=${RECLAIMER_GUI:-}
# give up on a stalled connection instead of hanging (the launcher waits for this when updating)
CURL_LIMITS="--connect-timeout 20 --speed-limit 1024 --speed-time 60 --proto =https --proto-redir =https"

exec 3>&1  # the real output, for error lines from inside $(...) (the window reads them)
STEP=starting
bold() { STEP=$*; printf '\n\033[1m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die() {
  printf '\n\033[31mError: %s\033[0m\n' "$*" >&2
  [ -n "$GUI" ] && printf 'error: %s\n' "$*" >&3  # (the window shows this line)
  exit 1
}

fetch() {  # fetch "name|url|sha256" -> path of the verified file in $CACHE
  local name=${1%%|*} rest=${1#*|}; local url=${rest%%|*} sum=${rest##*|} f="$CACHE/${1%%|*}"
  if [ ! -f "$f" ] || [ "$(shasum -a 256 "$f" | cut -d' ' -f1)" != "$sum" ]; then
    note "downloading $name" >&2
    curl -fL $CURL_LIMITS --progress-bar -o "$f.part" "$url" ||
      die "Couldn't download $name. Check your internet connection and try again."
    mv "$f.part" "$f"
  fi
  [ "$(shasum -a 256 "$f" | cut -d' ' -f1)" = "$sum" ] ||
    { rm -f "$f"; die "The download of $name was damaged. Press Try Again to download it again."; }
  printf '%s' "$f"
}

script_file() {  # copy a file from this repo (local checkout or GitHub) to $2
  local here; here=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)
  if [ -n "$here" ] && [ -f "$here/$1" ]; then cp "$here/$1" "$2"; else curl -fsSL $CURL_LIMITS "$REPO_RAW/$1" -o "$2"; fi
}

as_admin() {  # as_admin "<shell command>" "<why>": sudo in Terminal; macOS's password dialog when run by the launcher
  if [ -n "$UPDATE" ] || [ -n "$GUI" ]; then
    local cmd=${1//\\/\\\\}; cmd=${cmd//\"/\\\"}
    local why=${2:-Project Reclaimer is changing a system setting.}
    /usr/bin/osascript -e "do shell script \"$cmd\" with prompt \"$why\" with administrator privileges" >/dev/null
  else
    sudo /bin/sh -c "$1" </dev/tty
  fi
}

installed() {  # installed <name> <version>: true when <name> is already installed at <version>
  [ "$(cat "$BASE/.installed/$1" 2>/dev/null)" = "$2" ]
}

mark_installed() { mkdir -p "$BASE/.installed"; printf '%s\n' "$2" > "$BASE/.installed/$1"; }

unlink_documents() {  # give a prefix its own Documents folder instead of Wine's link to ~/Documents
  local d
  for d in "$1"/drive_c/users/*/Documents; do
    [ -L "$d" ] && { rm "$d"; mkdir -p "$d"; }
  done
  return 0
}

# ---------------------------------------------------------------------------------------------------------------
bold "Project Reclaimer Mac Port"
note "Installs into: $BASE"
[ "$(uname -m)" = arm64 ] || die "This needs an Apple Silicon Mac (M1 or newer)."
MACOS_MAJOR=$(sw_vers -productVersion | cut -d. -f1)
[ "$MACOS_MAJOR" -ge 14 ] || die "This needs macOS 14 Sonoma or newer."
# every helper script runs on Apple's /usr/bin/python3 (part of the developer tools). With Xcode installed but its
# license not accepted it refuses to start, and the install used to fail much later as "check your internet" (#10)
if ! PY_OUT=$("${RECLAIMER_TEST_PYTHON:-/usr/bin/python3}" -c pass 2>&1); then
  case "$PY_OUT" in
    *"xcodebuild -license"*|*"Xcode license"*)
      die "Xcode's license hasn't been accepted, so the helper scripts can't run. Run this in Terminal (it asks for your Mac password), then run the installer again:  sudo xcodebuild -license accept" ;;
    *) die "Apple's developer tools are needed. Run this in Terminal, then run the installer again:  xcode-select --install" ;;
  esac
fi
FREE_GB=$(df -g "$HOME" | awk 'NR==2 {print $4}')
NEED_GB=45; [ -n "$ODST" ] && NEED_GB=54
# (only a first install downloads the ~35 GB of game files; re-running it over an existing install needs ~1 GB)
[ "$FREE_GB" -ge "$NEED_GB" ] || [ -n "${RECLAIMER_MCC_FROM:-}" ] || [ -n "$UPDATE" ] ||
  [ -f "$BASE/prefix-wine/$MCC_REL/halo3/halo3.dll" ] || die "Need about $NEED_GB GB free disk space (have ${FREE_GB} GB)."
mkdir -p "$BASE"/{game,tools,logs} "$CACHE"
chmod 700 "$BASE"  # (other accounts on this Mac can look into the home folder: the Steam login and logs stay private)
if [ -n "$GUI" ]; then
  # anything failing without its own message still tells the window which step it was
  trap 'printf "error: Something went wrong at the step “%s”. Check your internet connection and disk space, then press Try Again.\n" "$STEP" >&3' ERR
  # a first install in progress: if it stops, the window offers Setup again (not the 1.0 Upgrade)
  [ -f "$BASE/version" ] || [ -f "$BASE/prefix-wine/$MCC_REL/halo3/halo3.dll" ] || touch "$BASE/.setup-incomplete"
fi

if ! /usr/bin/pgrep -q oahd; then
  bold "Installing Rosetta 2 (runs Intel Windows code on Apple Silicon)"
  if [ -n "$GUI" ]; then
    as_admin "softwareupdate --install-rosetta --agree-to-license" \
      "Project Reclaimer needs Rosetta, Apple's translator for Intel apps." ||
      die "Rosetta (Apple's Intel translator) didn't install. If you cancelled the password box, press Try Again."
  else
    softwareupdate --install-rosetta --agree-to-license || die "Rosetta install failed."
  fi
fi

bold "Wine (Gcenx Wine Staging 11.18) with MoltenVK 1.4.2"
if [ ! -x "$BASE/wine/Wine Staging.app/Contents/Resources/wine/bin/wine" ]; then
  mkdir -p "$BASE/wine"; tar -xf "$(fetch "$WINE_PKG")" -C "$BASE/wine"
fi
# Wine bundles MoltenVK 1.4.0; 1.4.2 fixes device-loss / argument-buffer bugs behind a GPU address fault seen on
# heavy modded maps, and used ~25% less GPU at the menu
MVK_LIB="$BASE/wine/Wine Staging.app/Contents/Resources/wine/lib/libMoltenVK.dylib"
# (grep -c reads everything: an early-exiting grep SIGPIPEs strings, and under pipefail the check always failed)
if [ "$(strings "$MVK_LIB" | grep -cx '1.4.2')" = 0 ]; then
  tar -xf "$(fetch "$MOLTENVK_PKG")" -C "$CACHE" MoltenVK/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib
  # replace, don't overwrite in place: macOS caches a signed library's code signature per file, and Rosetta then
  # refuses the rewritten file ("Attachment of code signature supplement failed")
  rm -f "$MVK_LIB"
  cp "$CACHE/MoltenVK/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib" "$MVK_LIB"
fi
note "ok"

bold "Menu library (Mesa)"
if ! installed mesa "${MESA_PKG%%|*}" || [ ! -f "$BASE/game/opengl32.dll" ]; then
  tar -xf "$(fetch "$MESA_PKG")" -C "$CACHE" x64/opengl32.dll x64/libgallium_wgl.dll
  cp "$CACHE/x64/opengl32.dll" "$CACHE/x64/libgallium_wgl.dll" "$BASE/game/"
  mark_installed mesa "${MESA_PKG%%|*}"
fi
note "ok"

bold "Game scripts and Workshop mod helper"
# (the network files are kept here too, so the window's network fix can reinstall the startup task)
for f in run.sh launch.sh gamecontrollerdb.txt workshop_helper.py presets.py fit.py game_process.py updater.py tools.py reclaimer-loopback.sh \
         local.projectreclaimer.loopback.plist; do script_file "scripts/$f" "$BASE/game/$f"; done
chmod +x "$BASE/game/run.sh" "$BASE/game/launch.sh" "$BASE/game/workshop_helper.py" "$BASE/game/updater.py" \
  "$BASE/game/tools.py"
note "ok"

bold "This Mac"
# fit.py is the one place that answers "how much Mac is this?"; the launcher's Setup reads the same script
/usr/bin/python3 -I "$BASE/game/fit.py" || true
if [ "$(/usr/bin/python3 -I "$BASE/game/fit.py" --get tier 2>/dev/null || true)" = constrained ]; then
  note "Project Reclaimer recommends 16 GB of RAM. With less, the first Forge asset library build may not fit,"
  note "and the game can sit on \"Building Asset Library\" for a long time. Everything else still works."
fi

bold "Project Reclaimer (latest release, checksum-verified)"
# updater.py installs it as its own file and removes older ones; the game's own updater is off (see run.sh)
RECLAIMER_HOME="$BASE" /usr/bin/python3 -I "$BASE/game/updater.py" game 2>>"$BASE/logs/launcher.log" |
  awk '!/^progress: / {sub(/^(status|done|error|offline): /, ""); print "    " $0; fflush()}' ||
  die "Could not install Project Reclaimer. Check your internet connection and run the installer again."
ls "$BASE"/game/project-reclaimer-v*.exe >/dev/null 2>&1 ||
  die "Could not download Project Reclaimer. Check your internet connection and run the installer again."

bold "Windows environment for the Wine version"
WINE_BIN="$BASE/wine/Wine Staging.app/Contents/Resources/wine/bin"
if [ ! -f "$BASE/prefix-wine/system.reg" ]; then
  # (mscoree/mshtml off: no Wine Mono/Gecko install dialogs; the game doesn't use them)
  WINEPREFIX="$BASE/prefix-wine" WINEDEBUG=-all WINEDLLOVERRIDES="mscoree,mshtml=" "$WINE_BIN/wine" wineboot -i >/dev/null 2>&1 || true
  WINEPREFIX="$BASE/prefix-wine" WINEDEBUG=-all "$WINE_BIN/wineserver" -w
fi
# controllers come to the game from SDL. For PlayStation pads Wine otherwise drops SDL's gamepad for a raw PS device
# ("hidraw"), which the game can't use: "no gamepad detected" (#17). Xbox and other pads come from SDL either way.
if ! grep -q '"DisableHidraw"=dword:00000001' "$BASE/prefix-wine/system.reg" 2>/dev/null; then
  WINEPREFIX="$BASE/prefix-wine" WINEDEBUG=-all "$WINE_BIN/wine" reg add 'HKLM\System\CurrentControlSet\Services\winebus' \
    /v DisableHidraw /t REG_DWORD /d 1 /f >/dev/null 2>&1 || true
  WINEPREFIX="$BASE/prefix-wine" WINEDEBUG=-all "$WINE_BIN/wineserver" -w
fi
unlink_documents "$BASE/prefix-wine"
# DXVK-macOS goes into this prefix's system32 so the shared game folder stays free of graphics DLLs. Its d3d11.dll is
# renamed d3d11_dxvk.dll behind spinfix's d3d11.dll, which forwards to it and stops Halo 3's engine thread from
# spinning a full CPU core on the clock between frames (see spinfix/spinfix.c)
SYS32="$BASE/prefix-wine/drive_c/windows/system32"
if ! installed dxvk "${DXVK_PKG%%|*}" || [ ! -f "$SYS32/d3d11_dxvk.dll" ]; then
  tar -xzf "$(fetch "$DXVK_PKG")" -C "$CACHE"
  cp "$CACHE/dxvk-macOS-async-v1.10.3-20230507-repack/x64/d3d10core.dll" "$SYS32/"
  cp "$CACHE/dxvk-macOS-async-v1.10.3-20230507-repack/x64/d3d11.dll" "$SYS32/d3d11_dxvk.dll"
  mark_installed dxvk "${DXVK_PKG%%|*}"
fi
script_file spinfix/d3d11.dll "$CACHE/spinfix-d3d11.dll"
[ "$(shasum -a 256 "$CACHE/spinfix-d3d11.dll" | cut -d' ' -f1)" = "$SPINFIX_SHA" ] || die "checksum mismatch for spinfix/d3d11.dll"
cp "$CACHE/spinfix-d3d11.dll" "$SYS32/d3d11.dll"
note "ok"

bold "DepotDownloader (downloads your game files from Steam)"
if [ ! -x "$BASE/tools/DepotDownloader" ]; then
  unzip -oq "$(fetch "$DEPOT_PKG")" -d "$BASE/tools"; chmod +x "$BASE/tools/DepotDownloader"
fi
note "ok"

bold "Halo 3 game files (your Steam copy of Halo: The Master Chief Collection)"
MCC_DIR="$BASE/prefix-wine/$MCC_REL"
[ -n "$ODST" ] && [ ! -f "$MCC_DIR/halo3odst/halo3odst.dll" ] && MCC_DEPOTS="$MCC_DEPOTS $ODST_DEPOT"
if [ -f "$MCC_DIR/halo3/halo3.dll" ] && [ -d "$MCC_DIR/halo3/maps" ] && [ -z "$UPDATE" ] && [ -n "$ODST" ] &&
   [ ! -f "$MCC_DIR/halo3odst/halo3odst.dll" ]; then
  note "Halo 3 is installed; adding Halo 3: ODST (~9 GB). Sign in with the QR code if one appears."
  if [ -n "$GUI" ]; then
    RECLAIMER_HOME="$BASE" /usr/bin/python3 -I "$BASE/game/workshop_helper.py" game-download "$MCC_DIR" --odst \
      2>>"$BASE/logs/launcher.log" || exit 1
  else
    "$BASE/tools/DepotDownloader" -app $MCC_APP -depot $ODST_DEPOT -os windows -qr -remember-password \
      -dir "$MCC_DIR" -validate </dev/tty || die "Steam download failed. Re-run the installer to resume."
  fi
elif [ -f "$MCC_DIR/halo3/halo3.dll" ] && [ -d "$MCC_DIR/halo3/maps" ]; then
  note "already installed"
elif [ -n "$UPDATE" ] && [ -f "$BASE/halo3-removed" ]; then
  note "Halo 3 was removed in Tools; add it again from the launcher (Play > Install Halo 3)."
elif [ -n "$UPDATE" ]; then
  die "Halo 3's game files are missing. Open the Project Reclaimer disk image and run the installer again."
elif [ -n "${RECLAIMER_MCC_FROM:-}" ]; then
  mkdir -p "$(dirname "$MCC_DIR")"; cp -cR "$RECLAIMER_MCC_FROM" "$MCC_DIR" 2>/dev/null || cp -R "$RECLAIMER_MCC_FROM" "$MCC_DIR"
  note "copied from $RECLAIMER_MCC_FROM"
elif [ -n "$GUI" ]; then
  # the window shows the QR code and a progress bar; the account name is saved, so mods never ask to sign in
  RECLAIMER_HOME="$BASE" /usr/bin/python3 -I "$BASE/game/workshop_helper.py" game-download "$MCC_DIR" ${ODST:+--odst} \
    2>>"$BASE/logs/launcher.log" ||
    exit 1  # (it printed the reason)
  [ -f "$MCC_DIR/halo3/halo3.dll" ] || die "Halo 3's files are missing after the download. Try again to resume."
else
  note "You need to own Halo: The Master Chief Collection on Steam."
  note "A QR code will appear: open the Steam app on your phone > Steam Guard / sign-in QR and scan it."
  if [ -n "$ODST" ]; then note "Halo 3 and Halo 3: ODST are downloaded (~44 GB). This can take a while."
  else note "Only Halo 3 is downloaded (~35 GB; RECLAIMER_ODST=1 adds ODST). This can take a while."; fi
  read -r -p "    Press Return to continue..." _ </dev/tty
  mkdir -p "$MCC_DIR"
  # shellcheck disable=SC2086
  "$BASE/tools/DepotDownloader" -app $MCC_APP -depot $MCC_DEPOTS -os windows -qr -remember-password \
    -dir "$MCC_DIR" -validate </dev/tty || die "Steam download failed. Re-run the installer to resume."
  [ -f "$MCC_DIR/halo3/halo3.dll" ] || die "Halo 3 files are missing after the download. Re-run the installer to resume."
fi
mkdir -p "$BASE/prefix-wine/$STEAM_REL/steamapps/workshop/content/$MCC_APP"

bold "Local network addresses (needs your Mac password once)"
note "Reclaimer talks to the game over 127.0.0-3.x / 127.3.1.x; macOS only enables 127.0.0.1."
note "This installs a small startup task (/Library/LaunchDaemons/local.projectreclaimer.loopback.plist)."
T=$(mktemp -d)
script_file scripts/reclaimer-loopback.sh "$T/reclaimer-loopback.sh"
script_file scripts/local.projectreclaimer.loopback.plist "$T/local.projectreclaimer.loopback.plist"
LB_DIR="/Library/Application Support/ProjectReclaimer"
# (re)install when missing or when a Reclaimer release needed new address ranges
if ! cmp -s "$T/reclaimer-loopback.sh" "$LB_DIR/reclaimer-loopback.sh" ||
   [ ! -f /Library/LaunchDaemons/local.projectreclaimer.loopback.plist ]; then
  as_admin "mkdir -p '$LB_DIR' &&
    install -o root -g wheel -m 755 '$T/reclaimer-loopback.sh' '$LB_DIR/reclaimer-loopback.sh' &&
    install -o root -g wheel -m 644 '$T/local.projectreclaimer.loopback.plist' /Library/LaunchDaemons/local.projectreclaimer.loopback.plist &&
    { printf '%s  %s\\n' $LOOPBACK_SHA '$LB_DIR/reclaimer-loopback.sh' $LOOPBACK_PLIST_SHA /Library/LaunchDaemons/local.projectreclaimer.loopback.plist |
      shasum -a 256 -c -s || { rm -f '$LB_DIR/reclaimer-loopback.sh' /Library/LaunchDaemons/local.projectreclaimer.loopback.plist; false; }; } &&
    { launchctl bootout system/local.projectreclaimer.loopback 2>/dev/null; true; } &&
    launchctl bootstrap system /Library/LaunchDaemons/local.projectreclaimer.loopback.plist" \
    "Project Reclaimer is setting up the local network addresses the game needs." ||
    die "The network setting wasn't installed (the password box was cancelled or refused). Press Try Again."
fi
rm -rf "$T"
note "ok"

# only a fresh install (or RECLAIMER_RESET_GRAPHICS=1) gets the tuned settings; otherwise the player's own stay
if [ -n "${RECLAIMER_RESET_GRAPHICS:-}" ] ||
   ! ls "$BASE"/prefix-wine/drive_c/users/*/Documents/"My Games/Project Reclaimer/settings.json" >/dev/null 2>&1; then
  bold "Tuned graphics settings"
  /usr/bin/python3 -I "$BASE/game/presets.py" wine
fi

bold "Launcher app"
script_file launcher/ProjectReclaimer "$CACHE/launcher"
[ "$(shasum -a 256 "$CACHE/launcher" | cut -d' ' -f1)" = "$LAUNCHER_SHA" ] || die "checksum mismatch for the launcher"
# replace, don't overwrite in place: the old launcher may be running (and macOS caches a binary's signature per file)
rm -f "$BASE/tools/ProjectReclaimer"
mv "$CACHE/launcher" "$BASE/tools/ProjectReclaimer"
chmod +x "$BASE/tools/ProjectReclaimer"
mkdir -p "${RECLAIMER_APPS_DIR:-$HOME/Applications}"
script_file scripts/make_app.sh "$BASE/tools/make_app.sh"
# the version the launcher's updater asked for (it checks this afterwards), else this copy's own
if [ -n "${RECLAIMER_EXPECT_VERSION:-}" ]; then echo "$RECLAIMER_EXPECT_VERSION" > "$CACHE/VERSION"
else script_file VERSION "$CACHE/VERSION"; fi
/bin/bash "$BASE/tools/make_app.sh" "Project Reclaimer" "$(cat "$CACHE/VERSION")"
rm -rf "$CACHE/x64" "$CACHE/dxvk-macOS-async-v1.10.3-20230507-repack" "$CACHE/MoltenVK" "$CACHE/spinfix-d3d11.dll"
# last: the launcher compares this with GitHub's VERSION, so a failed update is tried again next launch
mv "$CACHE/VERSION" "$BASE/version"
rm -f "$BASE/.setup-incomplete"
# the downloaded archives (~1 GB) aren't needed any more, unless they're a cache the caller asked to keep
[ -z "${RECLAIMER_CACHE:-}" ] && rm -rf "$CACHE"
[ -n "$UPDATE" ] && { bold "Updated to $(cat "$BASE/version")"; exit 0; }

bold "Done"
note "Open \"Project Reclaimer\" from Spotlight, Launchpad or ~/Applications."
note "It keeps itself and the game up to date, and signs you in to Steam for Workshop mods with a QR code."
note "The first match builds a Forge cache (~1 min)."
