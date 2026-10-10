#!/bin/bash
# make_launcher.sh [test]: build launcher/ProjectReclaimer (the launcher window, arm64, macOS 14+) from launcher/*.swift
# and pin its SHA-256 in install.sh. "test" builds and runs launcher/Tests instead.
set -euo pipefail
cd "$(dirname "$0")/.."
FLAGS=(-O -target arm64-apple-macos14.0 -swift-version 5)
if [ "${1:-}" = test ]; then
  OUT=$(mktemp -d)/launcher-tests
  swiftc "${FLAGS[@]}" launcher/LauncherCore.swift launcher/Tests/main.swift -o "$OUT"
  "$OUT"
  exit
fi
swiftc "${FLAGS[@]}" -parse-as-library launcher/LauncherCore.swift launcher/LauncherApp.swift -o launcher/ProjectReclaimer
codesign --force --sign - launcher/ProjectReclaimer
SUM=$(shasum -a 256 launcher/ProjectReclaimer | cut -d' ' -f1)
sed -i '' -E "s/^LAUNCHER_SHA=[^ ]*/LAUNCHER_SHA=$SUM/" install.sh
echo "launcher/ProjectReclaimer $SUM (pinned in install.sh)"
