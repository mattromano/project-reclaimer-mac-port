"""fit.py decides the machine-fit tier; presets.py follows it.

Run: /usr/bin/python3 -I -m unittest discover -s tests
"""
import contextlib
import importlib.util
import io
import json
import os
import shutil
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SCRIPTS = REPO / "scripts"


def load(name, filename):
    """Load a script by path: tests run isolated (-I), so scripts aren't importable by name."""
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


fit = load("fit_under_test", "fit.py")

BIG = {"arch": "arm64", "macos": "14.0", "ram_gb": 32, "cores": 10, "free_disk_gb": 200, "screen": [2560, 1440]}
SMALL = dict(BIG, ram_gb=8)


class TierTest(unittest.TestCase):
    def test_recommended_ram_is_standard_and_8_gb_is_constrained(self):
        self.assertEqual(fit.tier(BIG), "standard")
        self.assertEqual(fit.tier(SMALL), "constrained")

    def test_16_gb_is_the_boundary(self):
        self.assertEqual(fit.tier(dict(BIG, ram_gb=16)), "standard")
        self.assertEqual(fit.tier(dict(BIG, ram_gb=15)), "constrained")

    def test_unknown_ram_does_not_downgrade_a_machine(self):
        self.assertEqual(fit.tier(dict(BIG, ram_gb=0)), "standard")

    def test_constrained_caps_the_window_at_720p_even_on_a_big_screen(self):
        self.assertEqual(fit.window(SMALL), (1280, 720, "r720p"))

    def test_standard_uses_the_screen(self):
        self.assertEqual(fit.window(BIG), (1920, 1080, "r1080p"))

    def test_standard_falls_back_when_the_screen_is_short(self):
        self.assertEqual(fit.window(dict(BIG, screen=[1440, 900])), (1280, 720, "r720p"))


class PresetsTest(unittest.TestCase):
    """presets.py writes the settings; the tier must reach them."""

    def setUp(self):
        self.home = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.home)
        self.profile = self.home / "prefix-wine/drive_c/users/player/Documents/My Games/Project Reclaimer"
        self.profile.mkdir(parents=True)
        (self.profile / "settings.json").write_text(json.dumps(
            {"version": 1, "graphics": {"frame_limit": 240}, "mouse_sensitivity": 3.0}))

    def run_presets(self, machine):
        # BASE is read when presets.py is imported, so the home has to be set first.
        os.environ["RECLAIMER_HOME"] = str(self.home)
        self.addCleanup(os.environ.pop, "RECLAIMER_HOME", None)
        presets = load("presets_under_test", "presets.py")
        with contextlib.redirect_stdout(io.StringIO()):  # presets.py prints what it wrote
            presets.main("wine", machine=machine)
        return json.loads((self.profile / "settings.json").read_text())

    def test_constrained_machine_gets_720p(self):
        graphics = self.run_presets(SMALL)["graphics"]
        self.assertEqual((graphics["width"], graphics["height"], graphics["render_resolution"]), (1280, 720, "r720p"))
        self.assertEqual(graphics["frame_limit"], 60)

    def test_standard_machine_gets_its_screen(self):
        graphics = self.run_presets(BIG)["graphics"]
        self.assertEqual((graphics["width"], graphics["height"], graphics["render_resolution"]), (1920, 1080, "r1080p"))

    def test_settings_other_than_graphics_are_kept(self):
        self.assertEqual(self.run_presets(SMALL)["mouse_sensitivity"], 3.0)


if __name__ == "__main__":
    unittest.main()
