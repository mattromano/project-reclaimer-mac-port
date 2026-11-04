#!/bin/bash
# Rebuild rumble/librumble_bridge.dylib for Wine on macOS.
set -euo pipefail
cd "$(dirname "$0")"
WINE_LIB="${1:-${RECLAIMER_HOME:-$HOME/Games/ProjectReclaimer}/wine/Wine Staging.app/Contents/Resources/wine/lib}"
if [ ! -d "$WINE_LIB" ]; then
  echo "error: Wine lib directory not found: $WINE_LIB" >&2
  echo "usage: $0 [path/to/wine/lib]" >&2
  exit 1
fi

clang -O2 -arch x86_64 -mmacosx-version-min=14.0 -dynamiclib \
  -L"$WINE_LIB" -lSDL2 \
  -Wl,-rpath,@loader_path \
  -framework IOKit -framework CoreFoundation -Wall -o librumble_bridge.dylib rumble_bridge.c drivers/8bitdo.c

install_name_tool -change libSDL2.dylib @loader_path/libSDL2-2.0.0.dylib librumble_bridge.dylib
codesign --remove-signature librumble_bridge.dylib
SUM=$(shasum -a 256 librumble_bridge.dylib | cut -d' ' -f1)
echo "librumble_bridge.dylib $SUM"
