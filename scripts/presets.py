#!/usr/bin/env python3
"""Write tuned Project Reclaimer graphics settings, keeping every other setting.

Usage: presets.py wine

Measured on an M2 Max at the main menu (uncapped):
  wine, borderless       ~95 fps  (DXVK rebuilds its swapchain every frame: the 1080p swapchain never
                                   matches the full-screen window, and each rebuild idles the GPU)
  wine, windowed at render size  ~120 fps, no rebuilds
Then capped at 60 fps. Reclaimer accepts only uniform "low"/"high" detail presets.

Which window and render size a machine gets comes from fit.py: a constrained
Mac (under the recommended RAM) is held at 720p even when its screen is bigger.
"""
import json
import os
import sys
from pathlib import Path

# The installer copies these scripts side by side and runs them as
# `/usr/bin/python3 -I`, which leaves the script's own directory off sys.path.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import fit  # noqa: E402

BASE = Path(os.environ.get("RECLAIMER_HOME", Path.home() / "Games" / "ProjectReclaimer"))
PREFIXES = {"wine": BASE / "prefix-wine"}


def detail(level):
    return {k: level for k in ("shadows", "lighting", "effects", "draw_distance", "level_of_detail", "decals", "water")}


def profile_dir(variant):
    """Reclaimer's profile lives in the prefix user's Documents\\My Games\\Project Reclaimer."""
    users = [u for u in (PREFIXES[variant] / "drive_c" / "users").iterdir() if u.name != "Public"]
    return users[0] / "Documents" / "My Games" / "Project Reclaimer"


def main(variant, machine=None):
    profile = profile_dir(variant)
    profile.mkdir(parents=True, exist_ok=True)
    path = profile / "settings.json"
    settings = json.loads(path.read_text()) if path.exists() else {"version": 1}
    graphics = settings.setdefault("graphics", {})
    m = machine or fit.machine(BASE)
    w, h, res = fit.window(m)
    # windowed at exactly the render size: the swapchain matches the window, so DXVK never rebuilds it
    graphics.update(display_mode="windowed", width=w, height=h, render_resolution=res, frame_limit=60, vsync=False)
    level = "low"
    settings["quality"] = {"detail": detail(level), "split_screen": detail(level), "texture_filtering": "original",
                           "motion_blur": level == "high", "antialiasing": level == "high"}
    path.write_text(json.dumps(settings, indent=2) + "\n")
    print(f"{variant}: {fit.tier(m)} tier, {graphics['display_mode']} {graphics.get('width')}x"
          f"{graphics.get('height')} render={graphics['render_resolution']} quality={level} cap=60")


if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1] not in PREFIXES:
        sys.exit(__doc__)
    main(sys.argv[1])
