#!/bin/zsh
# Start a program (wine, wineserver) in the macOS sandbox in wine-sandbox.sb: it can read the install's Wine, game
# and Windows folders and write only the Windows folder, never the person's own files. Every Wine start goes through
# here, and whatever Wine starts stays inside too.
BASE=${RECLAIMER_HOME:-~/Games/ProjectReclaimer}
BASE=${BASE:A}  # (the sandbox matches real paths)
# ~/.zshenv may inject an arm64 library into every zsh, which kills the x86_64 (Rosetta) Wine at launch
unset DYLD_INSERT_LIBRARIES

BRIDGE="$BASE/wine/Wine Staging.app/Contents/Resources/wine/lib/librumble_bridge.dylib"
SDL_LIB="${BRIDGE:h}/libSDL2-2.0.0.dylib"
if [ "${1:t}" != "wine" ] || [ ! -f "$BRIDGE" ] || [ ! -f "$SDL_LIB" ] || ! /usr/bin/file -b "$BRIDGE" | grep -q x86_64; then
  unset BRIDGE
fi

# (RECLAIMER_NO_SANDBOX: troubleshooting only. A macOS without sandbox-exec still plays, unprotected, and says so)
if [ -n "$RECLAIMER_NO_SANDBOX" ] || [ ! -x /usr/bin/sandbox-exec ]; then
  echo "sandbox: off" >&2
  [ -n "$BRIDGE" ] && exec /usr/bin/env DYLD_INSERT_LIBRARIES="$BRIDGE" "$@"
  exec "$@"
fi
echo "sandbox: on" >&2
TMP=$(getconf DARWIN_USER_TEMP_DIR) CACHE=$(getconf DARWIN_USER_CACHE_DIR)
[ -n "$BRIDGE" ] && exec /usr/bin/sandbox-exec -f "${0:A:h}/wine-sandbox.sb" -D BASE="$BASE" -D TMP="${TMP:A}" -D CACHE="${CACHE:A}" /usr/bin/env DYLD_INSERT_LIBRARIES="$BRIDGE" "$@"
exec /usr/bin/sandbox-exec -f "${0:A:h}/wine-sandbox.sb" -D BASE="$BASE" -D TMP="${TMP:A}" -D CACHE="${CACHE:A}" "$@"
