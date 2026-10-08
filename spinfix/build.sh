#!/bin/bash
# Rebuild spinfix/d3d11.dll (needs the free mingw-w64 cross-compiler: `brew install mingw-w64`).
set -euo pipefail
cd "$(dirname "$0")"
x86_64-w64-mingw32-gcc -O2 -shared -s -static-libgcc -Wall -o d3d11.dll spinfix.c d3d11.def
shasum -a 256 d3d11.dll
