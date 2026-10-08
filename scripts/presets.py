#!/usr/bin/env python3
"""Write tuned Project Reclaimer graphics settings, keeping every other setting.

Usage: presets.py wine

Measured on an M2 Max at the main menu (uncapped):
  wine, borderless       ~95 fps  (DXVK rebuilds its swapchain every frame: the 1080p swapchain never
                                   matches the full-screen window, and each rebuild idles the GPU)
  wine, windowed at render size  ~120 fps, no rebuilds
Then capped at 60 fps. Reclaimer accepts only uniform "low"/"high" detail presets.
"""
import json
import os
import subprocess
import sys
from pathlib import Path

BASE = Path(os.environ.get("RECLAIMER_HOME", Path.home() / "Games" / "ProjectReclaimer"))
PREFIXES = {"wine": BASE / "prefix-wine"}
# (window width, height, Reclaimer render_resolution) from largest to smallest
WINDOW_SIZES = [(1920, 1080, "r1080p"), (1600, 900, "r900p"), (1280, 720, "r720p")]
TITLE_BAR = 30  # points the window title bar takes (visibleFrame already excludes the menu bar and Dock)


def screen_points():
    js = ('ObjC.import("AppKit"); var f = $.NSScreen.mainScreen.visibleFrame; '
          'Math.round(f.size.width) + "x" + Math.round(f.size.height)')
    out = subprocess.run(["osascript", "-l", "JavaScript", "-e", js], capture_output=True, text=True).stdout
    try:
        w, h = (int(x) for x in out.strip().split("x"))
        return w, h
    except ValueError:
        return 1920, 1200


def detail(level):
    return {k: level for k in ("shadows", "lighting", "effects", "draw_distance", "level_of_detail", "decals", "water")}


def profile_dir(variant):
    """Reclaimer's profile lives in the prefix user's Documents\\My Games\\Project Reclaimer."""
    users = [u for u in (PREFIXES[variant] / "drive_c" / "users").iterdir() if u.name != "Public"]
    return users[0] / "Documents" / "My Games" / "Project Reclaimer"


def main(variant):
    profile = profile_dir(variant)
    profile.mkdir(parents=True, exist_ok=True)
    path = profile / "settings.json"
    settings = json.loads(path.read_text()) if path.exists() else {"version": 1}
    graphics = settings.setdefault("graphics", {})
    sw, sh = screen_points()
    w, h, res = next(((w, h, r) for w, h, r in WINDOW_SIZES if w <= sw and h + TITLE_BAR <= sh), WINDOW_SIZES[-1])
    # windowed at exactly the render size: the swapchain matches the window, so DXVK never rebuilds it
    graphics.update(display_mode="windowed", width=w, height=h, render_resolution=res, frame_limit=60, vsync=False)
    level = "low"
    settings["quality"] = {"detail": detail(level), "split_screen": detail(level), "texture_filtering": "original",
                           "motion_blur": level == "high", "antialiasing": level == "high"}
    path.write_text(json.dumps(settings, indent=2) + "\n")
    print(f"{variant}: {graphics['display_mode']} {graphics.get('width')}x{graphics.get('height')} "
          f"render={graphics['render_resolution']} quality={level} cap=60")


if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1] not in PREFIXES:
        sys.exit(__doc__)
    main(sys.argv[1])
