#!/bin/bash
# Remove Project Reclaimer Mac Port: apps, ~/Games/ProjectReclaimer (game files, Wine, mods) and the network startup task.
#   RECLAIMER_YES=1           don't ask for confirmation
#   RECLAIMER_KEEP_NETWORK=1  leave the local-address startup task installed
set -euo pipefail
BASE=${RECLAIMER_HOME:-$HOME/Games/ProjectReclaimer}
APPS=${RECLAIMER_APPS_DIR:-$HOME/Applications}

echo "This deletes $BASE (including the ~35 GB of game files and downloaded mods)"
echo "and the Project Reclaimer apps in $APPS."
if [ -z "${RECLAIMER_YES:-}" ]; then
  read -r -p "Continue? [y/N] " a </dev/tty
  [[ "$a" =~ ^[Yy] ]] || exit 0
fi

pkill -f 'project-reclaimer-v[0-9.]+\.exe' 2>/dev/null || true
pkill -f 'workshop_helper.py watch' 2>/dev/null || true
pkill -f 'Project Reclaimer.app/Contents/MacOS/ProjectReclaimer' 2>/dev/null || true
# (the Metal app came from older versions of the installer)
rm -rf "$APPS/Project Reclaimer.app" "$APPS/Project Reclaimer Metal.app" "$BASE"

if [ -z "${RECLAIMER_KEEP_NETWORK:-}" ] && [ -f /Library/LaunchDaemons/local.projectreclaimer.loopback.plist ]; then
  echo "Removing the network startup task (needs your Mac password)..."
  sudo /bin/sh -c 'launchctl bootout system/local.projectreclaimer.loopback 2>/dev/null;
    rm -f /Library/LaunchDaemons/local.projectreclaimer.loopback.plist;
    rm -rf "/Library/Application Support/ProjectReclaimer"' </dev/tty
  echo "The extra local addresses go away at the next restart."
fi
echo "Done."
