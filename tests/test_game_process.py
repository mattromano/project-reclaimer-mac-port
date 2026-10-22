"""Tests for scripts/game_process.py: which running processes are this installation's game.

Run: /usr/bin/python3 -I -m unittest discover -s tests
"""
import contextlib
import importlib.util
import io
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parent.parent
GAME_PROCESS = REPO / "scripts" / "game_process.py"


class GameProcessTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.home = self.tmp / "Games" / "ProjectReclaimer"
        (self.home / "game").mkdir(parents=True)
        # (a version no real game has, so a game running on this Mac can't make a test pass)
        self.env = dict(os.environ, RECLAIMER_GAME_PROCESS=r"project-reclaimer-v9\.9\.99\.exe game-client")

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def load(self):
        patcher = mock.patch.dict(os.environ, self.env)
        patcher.start()
        self.addCleanup(patcher.stop)
        spec = importlib.util.spec_from_file_location("game_process", GAME_PROCESS)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod

    def process(self, *args, folder):
        p = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)", *args], cwd=folder)

        def stop():
            if p.poll() is None:
                p.kill()
            p.wait()
        self.addCleanup(stop)
        return p

    def test_a_process_counts_when_its_working_directory_is_inside_the_installation(self):
        gp = self.load()
        self.assertFalse(gp.running(self.home))
        mine = self.process("project-reclaimer-v9.9.99.exe game-client", folder=self.home / "game")
        self.process("project-reclaimer-v9.9.99.exe game-client", folder=self.tmp)  # (another installation's)
        time.sleep(0.2)
        self.assertEqual(gp.pids(self.home), [str(mine.pid)])
        self.assertTrue(gp.running(self.home))

    def test_a_match_outside_the_installation_says_so(self):
        # a working directory nobody expected must not read as "the game is stopped": one line per rejected pid
        gp = self.load()
        theirs = self.process("project-reclaimer-v9.9.99.exe game-client", folder=self.tmp)
        time.sleep(0.2)
        said = io.StringIO()
        with contextlib.redirect_stderr(said):
            self.assertEqual(gp.pids(self.home), [])
        self.assertIn(f"game process outside the install: {theirs.pid} {self.tmp.resolve()}", said.getvalue())
        self.assertEqual(len(said.getvalue().splitlines()), 1, said.getvalue())

    def test_nothing_is_said_when_no_process_matched(self):
        gp = self.load()
        said = io.StringIO()
        with contextlib.redirect_stderr(said):
            self.assertEqual(gp.pids(self.home), [])
        self.assertEqual(said.getvalue(), "")

    def test_nothing_is_said_when_the_match_is_this_installations(self):
        gp = self.load()
        self.process("project-reclaimer-v9.9.99.exe game-client", folder=self.home / "game")
        time.sleep(0.2)
        said = io.StringIO()
        with contextlib.redirect_stderr(said):
            self.assertTrue(gp.running(self.home))
        self.assertEqual(said.getvalue(), "")

    def test_only_the_first_field_of_a_pgrep_line_is_read_as_a_pid(self):
        # pgrep prints "<pid>" here and "<pid> <command line>" where it reports the command line. Read as one word
        # list, every argument of a matching command line went to lsof as a pid, so a number there could name a
        # live process of this installation and force-quit then killed it.
        gp = self.load()
        decoy = self.process("project-reclaimer-v9.9.99.exe game-client", folder=self.tmp)  # (not ours)
        inside = self.process(folder=self.home / "game")  # (a live pid inside the install, but not the game)
        time.sleep(0.2)
        reported = f"{decoy.pid} {sys.executable} -c pass project-reclaimer-v9.9.99.exe game-client {inside.pid}\n"
        real_run = subprocess.run

        def run(cmd, *args, **kwargs):
            return mock.Mock(stdout=reported) if cmd[0] == "pgrep" else real_run(cmd, *args, **kwargs)
        with mock.patch.object(gp.subprocess, "run", side_effect=run):
            self.assertEqual(gp.pids(self.home), [])


if __name__ == "__main__":
    unittest.main()
