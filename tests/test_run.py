"""scripts/run.sh starts the right Project Reclaimer: the newest, or the older release the player chose.

Uses a fake wine that records what it was asked to run. Run: /usr/bin/python3 -I -m unittest discover -s tests
"""
import os
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent


class RunTest(unittest.TestCase):
    def setUp(self):
        self.home = Path(tempfile.mkdtemp())
        game = self.home / "game"
        game.mkdir()
        for f in ("run.sh", "sandboxed.sh", "wine-sandbox.sb"):
            shutil.copy(REPO / "scripts" / f, game / f)
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

    def test_game_runs_in_the_sandbox(self):
        wine = self.home / "wine" / "Wine Staging.app" / "Contents" / "Resources" / "wine" / "bin" / "wine"
        wine.write_text(f'#!/bin/sh\n/bin/ls "{Path.home()}" >/dev/null 2>&1 && echo free || echo boxed\n')
        self.assertEqual(self.run_game(), "boxed")

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


class LaunchTest(unittest.TestCase):
    """scripts/launch.sh (the Play button): the helper and the game start from the game folder, wherever it's run from,
    since that's how the install-scoped process rule (game_process.py) tells this install's processes apart."""

    def setUp(self):
        self.home = Path(tempfile.mkdtemp()).resolve()
        game = self.home / "game"
        game.mkdir()
        shutil.copy(REPO / "scripts" / "launch.sh", game / "launch.sh")
        (game / "workshop_helper.py").write_text(
            f"import os\nopen({str(self.home / 'helper-cwd')!r}, 'w').write(os.getcwd())\n")
        (game / "run.sh").write_text(f'#!/bin/sh\npwd > "{self.home / "game-cwd"}"\n')
        (game / "run.sh").chmod(0o755)

    def tearDown(self):
        shutil.rmtree(self.home)

    def test_helper_and_game_start_from_the_game_folder(self):
        subprocess.run(["/bin/zsh", str(self.home / "game" / "launch.sh")], cwd="/", timeout=30,
                       env=dict(os.environ, RECLAIMER_HOME=str(self.home)))
        for _ in range(50):
            if (self.home / "helper-cwd").exists():
                break
            time.sleep(0.1)
        self.assertEqual((self.home / "game-cwd").read_text().strip(), str(self.home / "game"))
        self.assertEqual((self.home / "helper-cwd").read_text(), str(self.home / "game"))


if __name__ == "__main__":
    unittest.main()
