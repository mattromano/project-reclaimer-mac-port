#!/bin/bash
# Rebuild rumble/librumble_bridge.dylib for Wine on macOS.
set -euo pipefail
cd "$(dirname "$0")"
GAMES_DIR="${RECLAIMER_HOME:-$HOME/Games/ProjectReclaimer}"
WINE_LIB="$GAMES_DIR/wine/Wine Staging.app/Contents/Resources/wine/lib"

clang -O2 -arch x86_64 -mmacosx-version-min=14.0 -dynamiclib \
  -L"$WINE_LIB" -lSDL2 \
  -Wl,-rpath,@loader_path \
  -framework IOKit -framework CoreFoundation -Wall -o librumble_bridge.dylib rumble_bridge.c

install_name_tool -change libSDL2.dylib @loader_path/libSDL2-2.0.0.dylib librumble_bridge.dylib
codesign --remove-signature librumble_bridge.dylib
SUM=$(shasum -a 256 librumble_bridge.dylib | cut -d' ' -f1)
echo "librumble_bridge.dylib $SUM"
