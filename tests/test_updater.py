"""Tests for scripts/updater.py against local file:// stand-ins for GitHub.

Run: /usr/bin/python3 -I -m unittest discover -s tests
"""
import hashlib
import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parent.parent
UPDATER = REPO / "scripts" / "updater.py"
NEW_EXE = b"MZ new reclaimer 0.9.12"

FAKE_INSTALL = """#!/bin/bash
# stand-in for install.sh: records how it was called, then behaves like a successful update
set -e
echo "env RECLAIMER_UPDATE=$RECLAIMER_UPDATE RECLAIMER_HOME=$RECLAIMER_HOME EXPECT=$RECLAIMER_EXPECT_VERSION" > "$RECLAIMER_HOME/install-called"
printf '\\n\\033[1m==> Wine\\033[0m\\n'
echo "    ok"
printf '\\n\\033[1m==> Apps\\033[0m\\n'
[ -n "$FAIL_INSTALL" ] && { echo "Error: something broke" >&2; exit 1; }
# like install.sh: install the game through the updater (timeout: a deadlock fails the test instead of hanging it)
[ -n "$NESTED_UPDATER" ] && { "$PYTHON" -c 'import subprocess, sys; sys.exit(subprocess.run(sys.argv[1:], timeout=10).returncode)' \\
  "$PYTHON" -I "$NESTED_UPDATER" game || exit 1; }
# like install.sh: record the version the updater asked for (VERSION.new stands in for a stale CDN copy if present)
if [ -f "${RECLAIMER_REPO_RAW#file://}/VERSION.new" ]; then cp "${RECLAIMER_REPO_RAW#file://}/VERSION.new" "$RECLAIMER_HOME/version"
else echo "$RECLAIMER_EXPECT_VERSION" > "$RECLAIMER_HOME/version"; fi
"""


def sha(b):
    return hashlib.sha256(b).hexdigest()


class UpdaterTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.home = self.tmp / "home"
        (self.home / "game").mkdir(parents=True)
        self.raw = self.tmp / "raw"
        self.raw.mkdir()
        self.rel = self.tmp / "releases"
        self.rel.mkdir()
        (self.raw / "VERSION").write_text("1.1.0\n")
        (self.raw / "install.sh").write_text(FAKE_INSTALL)
        (self.home / "version").write_text("1.1.0\n")
        # latest game release
        (self.rel / "project-reclaimer-v0.9.12.exe").write_bytes(NEW_EXE)
        (self.rel / "SHA256SUMS.txt").write_text(
            f"{sha(b'ded')}  project-reclaimer-dedicated-v0.9.12.exe\r\n"
            f"{sha(NEW_EXE)} *project-reclaimer-v0.9.12.exe\r\n")
        # a game version no real install has, so a game running on this Mac doesn't affect the tests
        self.env = dict(os.environ, RECLAIMER_HOME=str(self.home), RECLAIMER_REPO_RAW=self.raw.as_uri(),
                        RECLAIMER_RELEASES=self.rel.as_uri(),
                        RECLAIMER_GAME_PROCESS=r"project-reclaimer-v9\.9\.(98|99)\.exe game-client")

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def run_updater(self, *args, **env):
        p = subprocess.run([sys.executable, "-I", str(UPDATER), *args], env=dict(self.env, **env),
                           capture_output=True, text=True, timeout=60)
        return p.returncode, p.stdout.splitlines()

    def game_files(self):
        return sorted(p.name for p in (self.home / "game").glob("*.exe"))

    def test_up_to_date_changes_nothing(self):
        (self.home / "game" / "project-reclaimer-v0.9.12.exe").write_bytes(NEW_EXE)
        rc, out = self.run_updater("run")
        self.assertEqual(rc, 0)
        self.assertEqual(out[-1], "done: up to date")
        self.assertFalse((self.home / "install-called").exists())
        self.assertNotIn("relaunch", out)

    def test_new_game_release_replaces_old_and_mislabeled_exes(self):
        game = self.home / "game"
        (game / "project-reclaimer-v0.9.8.exe").write_bytes(b"old")
        (game / "project-reclaimer-v0.9.7.exe").write_bytes(b"self-updated in place, wrong name")
        (game / "project-reclaimer-dedicated-v0.9.8.exe").write_bytes(b"server")
        rc, out = self.run_updater("run")
        self.assertEqual(rc, 0, out)
        self.assertIn("status: Updating Project Reclaimer to 0.9.12…", out)
        self.assertTrue(any(l.startswith("progress: ") for l in out))
        self.assertEqual(self.game_files(), ["project-reclaimer-dedicated-v0.9.8.exe", "project-reclaimer-v0.9.12.exe"])
        self.assertEqual((game / "project-reclaimer-v0.9.12.exe").read_bytes(), NEW_EXE)
        self.assertEqual(out[-1], "done: updated")

    def test_corrupt_game_exe_is_downloaded_again(self):
        (self.home / "game" / "project-reclaimer-v0.9.12.exe").write_bytes(b"truncated")
        rc, out = self.run_updater("game")
        self.assertEqual((self.home / "game" / "project-reclaimer-v0.9.12.exe").read_bytes(), NEW_EXE)

    def test_checksum_mismatch_keeps_old_game(self):
        (self.rel / "project-reclaimer-v0.9.12.exe").write_bytes(b"tampered")
        (self.home / "game" / "project-reclaimer-v0.9.8.exe").write_bytes(b"old")
        rc, out = self.run_updater("run")
        self.assertNotEqual(rc, 0)
        self.assertTrue(out[-1].startswith("error: "), out)
        self.assertEqual(self.game_files(), ["project-reclaimer-v0.9.8.exe"])
        self.assertEqual(list((self.home / "game").glob("*.part")), [])

    def test_newer_port_version_runs_installer_in_update_mode_and_relaunches(self):
        (self.home / "game" / "project-reclaimer-v0.9.12.exe").write_bytes(NEW_EXE)
        (self.raw / "VERSION").write_text("1.2.0\n")
        (self.raw / "VERSION.new").write_text("1.2.0\n")
        rc, out = self.run_updater("run")
        self.assertEqual(rc, 0, out)
        called = (self.home / "install-called").read_text()
        self.assertIn("RECLAIMER_UPDATE=1", called)
        self.assertIn(f"RECLAIMER_HOME={self.home}", called)
        self.assertIn("status: Updating the Mac port to 1.2.0…", out)
        self.assertIn("relaunch", out)
        self.assertEqual((self.home / "version").read_text().strip(), "1.2.0")

    def test_installer_is_told_which_version_it_installs(self):
        (self.home / "game" / "project-reclaimer-v0.9.12.exe").write_bytes(NEW_EXE)
        (self.raw / "VERSION").write_text("1.2.0\n")
        rc, out = self.run_updater("run")
        self.assertIn("EXPECT=1.2.0", (self.home / "install-called").read_text())
        self.assertIn("relaunch", out)

    def test_no_relaunch_when_the_installed_version_did_not_change(self):
        # e.g. GitHub's cache served an older install.sh: relaunching would only run the same update again
        (self.home / "game" / "project-reclaimer-v0.9.12.exe").write_bytes(NEW_EXE)
        (self.raw / "VERSION").write_text("1.2.0\n")
        (self.raw / "VERSION.new").write_text("1.1.0\n")
        rc, out = self.run_updater("run")
        self.assertNotIn("relaunch", out)
        self.assertTrue(out[-1].startswith("error: "), out)

    def test_installer_updating_the_game_inside_a_port_update_does_not_deadlock(self):
        (self.raw / "VERSION").write_text("1.2.0\n")
        rc, out = self.run_updater("run", NESTED_UPDATER=str(UPDATER), PYTHON=sys.executable)
        self.assertIn("relaunch", out, out)
        self.assertIn("project-reclaimer-v0.9.12.exe", self.game_files())

    def test_one_update_at_a_time(self):
        import fcntl
        (self.home / "game" / "project-reclaimer-v0.9.12.exe").write_bytes(NEW_EXE)
        lock = open(self.home / ".update.lock", "w")
        fcntl.flock(lock, fcntl.LOCK_EX)
        p = subprocess.Popen([sys.executable, "-I", str(UPDATER), "run"], env=self.env, stdout=subprocess.PIPE,
                             text=True)
        try:
            first = p.stdout.readline().strip()
            self.assertEqual(first, "status: Waiting for another update to finish…")
            self.assertIsNone(p.poll())
        finally:
            lock.close()  # the other update finishes
        out = p.communicate(timeout=30)[0].splitlines()
        self.assertEqual(out[-1], "done: up to date")

    def test_up_to_date_game_still_removes_other_client_exes(self):
        game = self.home / "game"
        (game / "project-reclaimer-v0.9.12.exe").write_bytes(NEW_EXE)
        (game / "project-reclaimer-v0.9.13.exe").write_bytes(b"newer name, e.g. after a release was rolled back")
        self.run_updater("game")
        self.assertEqual(self.game_files(), ["project-reclaimer-v0.9.12.exe"])

    def test_install_without_version_file_counts_as_old(self):
        (self.home / "version").unlink()
        (self.home / "game" / "project-reclaimer-v0.9.12.exe").write_bytes(NEW_EXE)
        (self.raw / "VERSION.new").write_text("1.1.0\n")
        rc, out = self.run_updater("run")
        self.assertTrue((self.home / "install-called").exists())

    def test_version_compare_is_numeric(self):
        (self.home / "version").write_text("1.10.0\n")
        (self.raw / "VERSION").write_text("1.9.0\n")
        (self.home / "game" / "project-reclaimer-v0.9.12.exe").write_bytes(NEW_EXE)
        self.run_updater("run")
        self.assertFalse((self.home / "install-called").exists())

    def test_failed_port_update_still_updates_game_and_reports_error(self):
        (self.raw / "VERSION").write_text("1.2.0\n")
        rc, out = self.run_updater("run", FAIL_INSTALL="1")
        self.assertNotIn("relaunch", out)
        self.assertEqual((self.home / "version").read_text().strip(), "1.1.0")
        self.assertIn("project-reclaimer-v0.9.12.exe", self.game_files())
        self.assertTrue(any(l.startswith("error: ") and "something broke" in l for l in out), out)

    def test_offline_lets_the_game_start(self):
        (self.home / "game" / "project-reclaimer-v0.9.8.exe").write_bytes(b"old")
        rc, out = self.run_updater("run", RECLAIMER_REPO_RAW="http://127.0.0.1:9/nothing",
                                   RECLAIMER_RELEASES="http://127.0.0.1:9/nothing")
        self.assertEqual(rc, 0)
        self.assertTrue(out[-1].startswith("offline: "), out)
        self.assertEqual(self.game_files(), ["project-reclaimer-v0.9.8.exe"])

    def test_other_processes_naming_the_exe_dont_count_as_the_game(self):
        (self.home / "game" / "project-reclaimer-v0.9.8.exe").write_bytes(b"old")
        # e.g. a Terminal command that mentions the file; only the running game (".exe game-client") counts
        bystander = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)",
                                      "rm", "project-reclaimer-v9.9.99.exe"])
        try:
            rc, out = self.run_updater("game")
        finally:
            bystander.kill()
        self.assertIn("project-reclaimer-v0.9.12.exe", self.game_files())

    def test_skipped_while_running_is_not_reported_as_up_to_date(self):
        (self.home / "game" / "project-reclaimer-v0.9.8.exe").write_bytes(b"old")
        game = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)",
                                 r"C:\game\project-reclaimer-v9.9.99.exe game-client --mcc-path x"])
        try:
            rc, out = self.run_updater("run")
        finally:
            game.kill()
        self.assertEqual(out[-1], "done: skipped while the game is running")
        self.assertEqual(self.game_files(), ["project-reclaimer-v0.9.8.exe"])

    def test_game_running_skips_game_update(self):
        (self.home / "game" / "project-reclaimer-v0.9.8.exe").write_bytes(b"old")
        with mock.patch.dict(os.environ, self.env):
            spec = importlib.util.spec_from_file_location("updater", UPDATER)
            u = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(u)
        with mock.patch.object(u, "game_running", return_value=True):
            self.assertEqual(u.update_game(), "running")
        self.assertEqual(self.game_files(), ["project-reclaimer-v0.9.8.exe"])


if __name__ == "__main__":
    unittest.main()
