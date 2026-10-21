"""scripts/run.sh starts the right Project Reclaimer: the newest, or the older release the player chose.

Uses a fake wine that records what it was asked to run. Run: /usr/bin/python3 -I -m unittest discover -s tests
"""
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent


class RunTest(unittest.TestCase):
    def setUp(self):
        self.home = Path(tempfile.mkdtemp())
        game = self.home / "game"
        game.mkdir()
        shutil.copy(REPO / "scripts" / "run.sh", game / "run.sh")
        for exe in ("project-reclaimer-v0.9.9.exe", "project-reclaimer-v0.9.13.exe",
                    "project-reclaimer-dedicated-v0.9.13.exe"):
            (game / exe).write_bytes(b"MZ")
        wine = self.home / "wine" / "Wine Staging.app" / "Contents" / "Resources" / "wine" / "bin" / "wine"
        wine.parent.mkdir(parents=True)
        wine.write_text('#!/bin/sh\necho "cwd=$(pwd) exe=$1 mode=$2 cfgfile=$SDL_GAMECONTROLLERCONFIG_FILE cfgstr=$SDL_GAMECONTROLLERCONFIG"\n')
        wine.chmod(0o755)

    def tearDown(self):
        shutil.rmtree(self.home)

    def run_game(self, extra_env=None):
        env = dict(os.environ, RECLAIMER_HOME=str(self.home))
        if extra_env:
            env.update(extra_env)
        p = subprocess.run(["/bin/zsh", str(self.home / "game" / "run.sh")], capture_output=True, text=True,
                           env=env, timeout=30)
        return p.stdout.strip()

    def test_newest_by_default(self):
        out = self.run_game()
        self.assertIn("exe=project-reclaimer-v0.9.13.exe mode=game-client", out)
        self.assertIn(f"cwd={self.home}/game", out)

    def test_chosen_older_version_starts_from_its_own_folder(self):
        versions = self.home / "game" / "versions"
        versions.mkdir()
        (versions / "project-reclaimer-v0.9.11.exe").write_bytes(b"MZ")
        (self.home / "game" / "chosen-version").write_text("0.9.11\n")
        out = self.run_game()
        self.assertIn("exe=project-reclaimer-v0.9.11.exe mode=game-client", out)
        self.assertIn(f"cwd={versions}", out)  # (its menu library sits next to it)

    def test_chosen_version_missing_falls_back_to_the_newest(self):
        (self.home / "game" / "chosen-version").write_text("0.9.11\n")
        self.assertIn("exe=project-reclaimer-v0.9.13.exe", self.run_game())

    def test_bundled_controller_mapping_used_directly(self):
        bundled = "03000000c82d00002f20000000000000,8BitDo,a:b0,b:b1,platform:Mac OS X,\n"
        (self.home / "game" / "gamecontrollerdb.txt").write_text(bundled)

        out = self.run_game()
        self.assertIn(f"cfgfile={self.home}/game/gamecontrollerdb.txt", out)
        self.assertFalse((self.home / "controller-mappings-active.txt").exists())

    def test_controller_mappings_combines_db_and_user_calibrations(self):
        bundled = "03000000c82d00002f20000000000000,8BitDo,a:b0,b:b1,platform:Mac OS X,\n"
        (self.home / "game" / "gamecontrollerdb.txt").write_text(bundled)

        user_line = "030000007e0500000920000000000000,Switch Pro,a:b1,b:b0,platform:Mac OS X,\n"
        (self.home / "controller-mappings.txt").write_text(user_line)

        out = self.run_game()
        active_file = self.home / "controller-mappings-active.txt"
        self.assertIn(f"cfgfile={active_file}", out)

        active_content = active_file.read_text().splitlines()
        self.assertEqual(len(active_content), 2)
        self.assertEqual(active_content[0], "03000000c82d00002f20000000000000,8BitDo,a:b0,b:b1,platform:Mac OS X,")
        self.assertEqual(active_content[1], user_line.strip())

    def test_no_controller_mappings_leaves_config_unset(self):
        out = self.run_game()
        self.assertIn("cfgfile=", out)
        self.assertNotIn("cfgfile=/", out)
        self.assertFalse((self.home / "controller-mappings-active.txt").exists())


if __name__ == "__main__":
    unittest.main()
