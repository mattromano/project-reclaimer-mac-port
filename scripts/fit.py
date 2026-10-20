#!/usr/bin/env python3
"""Which machine-fit tier this Mac is in, and what that permits.

    constrained   Less RAM than the README recommends (16 GB).
    standard      Enough RAM for the tuned defaults.

Everything that needs to know "how much Mac is this?" asks here, so the answer
doesn't drift between the installer, the launcher and presets.py.

RAM decides it because RAM is what limits the first Forge build: Project
Reclaimer sizes its engine memory pool at half of physical RAM and the asset
library adds ~2.6 GB of GPU-visible memory. On an 8 GB Mac that outgrows the
machine (measured: ~600 MB/s of swap traffic while "BUILDING ASSET LIBRARY"
never finishes).

What a tier cannot do: shrink the render target below 720p. The game accepts
only r720p, r900p, r1080p and r1440p, so 720p is the floor.

Usage: fit.py [--json]
"""
import json
import os
import platform
import shutil
import subprocess
import sys
from pathlib import Path

RECOMMENDED_RAM_GB = 16  # README.md's recommendation
# (window width, height, Reclaimer render_resolution), largest first
WINDOW_SIZES = [(1920, 1080, "r1080p"), (1600, 900, "r900p"), (1280, 720, "r720p")]
TITLE_BAR = 30  # points the window title bar takes (visibleFrame excludes the menu bar and Dock)
SMALLEST_WINDOW = WINDOW_SIZES[-1]


def ram_gb():
    out = subprocess.run(["sysctl", "-n", "hw.memsize"], capture_output=True, text=True).stdout.strip()
    return int(out) // 2**30 if out.isdigit() else 0


def free_disk_gb(path):
    try:
        return int(shutil.disk_usage(path).free / 2**30)
    except OSError:
        return 0


def screen_points():
    """The usable screen size, for picking a window that fits on it."""
    js = ('ObjC.import("AppKit"); var f = $.NSScreen.mainScreen.visibleFrame; '
          'Math.round(f.size.width) + "x" + Math.round(f.size.height)')
    out = subprocess.run(["osascript", "-l", "JavaScript", "-e", js], capture_output=True, text=True).stdout
    try:
        w, h = (int(x) for x in out.strip().split("x"))
        return w, h
    except ValueError:
        return 1920, 1200


def machine(home=None):
    """This Mac, as the values a tier decision needs."""
    w, h = screen_points()
    return {"arch": platform.machine(), "macos": platform.mac_ver()[0],
            "ram_gb": ram_gb(), "cores": os.cpu_count() or 0,
            "free_disk_gb": free_disk_gb(home or Path.home()), "screen": [w, h]}


def tier(m):
    """Constrained below the recommended RAM; standard otherwise. Unknown RAM stays standard:
    a probe that fails should not quietly downgrade a machine."""
    ram = m.get("ram_gb", 0)
    return "constrained" if 0 < ram < RECOMMENDED_RAM_GB else "standard"


def window(m):
    """The window and render size for this machine. A constrained Mac is held at 720p even
    when its screen is larger, because the memory it saves is the memory the game needs."""
    if tier(m) == "constrained":
        return SMALLEST_WINDOW
    sw, sh = m.get("screen", (1920, 1200))
    return next(((w, h, r) for w, h, r in WINDOW_SIZES if w <= sw and h + TITLE_BAR <= sh), SMALLEST_WINDOW)


def main(argv):
    m = machine()
    if "--json" in argv:
        print(json.dumps(dict(m, tier=tier(m)), sort_keys=True))
    else:
        w, h, res = window(m)
        print(f"{tier(m)}: {m['ram_gb']} GB RAM, {m['cores']} cores, {m['free_disk_gb']} GB free, "
              f"screen {m['screen'][0]}x{m['screen'][1]} -> {w}x{h} {res}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
