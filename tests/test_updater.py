"""Tests for scripts/updater.py against local file:// stand-ins for GitHub.

Run: /usr/bin/python3 -I -m unittest discover -s tests
"""
import hashlib
import json
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
OLD_EXE = b"MZ older reclaimer 0.9.11"

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
        # an older release, where GitHub keeps it: releases/download/<tag>/
        self.tags = self.tmp / "tags"
        (self.tags / "v0.9.11").mkdir(parents=True)
        (self.tags / "v0.9.11" / "project-reclaimer-v0.9.11.exe").write_bytes(OLD_EXE)
        (self.tags / "v0.9.11" / "SHA256SUMS.txt").write_text(f"{sha(OLD_EXE)}  project-reclaimer-v0.9.11.exe\n")
        (self.home / "game" / "opengl32.dll").write_bytes(b"mesa")
        (self.home / "game" / "libgallium_wgl.dll").write_bytes(b"gallium")
        listing = self.tmp / "releases.json"
        listing.write_text(json.dumps([
            {"tag_name": "v0.9.12", "published_at": "2026-10-10T13:20:51Z", "prerelease": False, "draft": False},
            {"tag_name": "v0.9.11", "published_at": "2026-10-09T22:35:00Z", "prerelease": False, "draft": False},
            {"tag_name": "v0.9.11-rc1", "published_at": "2026-10-09T20:00:00Z", "prerelease": True, "draft": False},
        ]))
        self.env = dict(os.environ, RECLAIMER_HOME=str(self.home), RECLAIMER_REPO_RAW=self.raw.as_uri(),
                        RECLAIMER_RELEASES=self.rel.as_uri(), RECLAIMER_RELEASES_API=listing.as_uri(),
                        RECLAIMER_RELEASE_DOWNLOADS=self.tags.as_uri(),
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

    def rename_release_to_client(self):
        """Since 0.9.18 releases name the game project-reclaimer-client-v<version>.exe (the server stays -dedicated-)."""
        (self.rel / "project-reclaimer-v0.9.12.exe").rename(self.rel / "project-reclaimer-client-v0.9.12.exe")
        (self.rel / "SHA256SUMS.txt").write_text(
            f"{sha(NEW_EXE)}  project-reclaimer-client-v0.9.12.exe\n"
            f"{sha(b'ded')}  project-reclaimer-dedicated-v0.9.12.exe\n")

    def test_release_with_renamed_client_installs_under_the_usual_name(self):
        # the whole Mac port (run.sh, Tools, the window, the mod helper) knows the game as project-reclaimer-v*.exe
        self.rename_release_to_client()
        (self.home / "game" / "project-reclaimer-v0.9.8.exe").write_bytes(b"old")
        rc, out = self.run_updater("game")
        self.assertEqual(rc, 0, out)
        self.assertIn("status: Updating Project Reclaimer to 0.9.12…", out)
        self.assertEqual(self.game_files(), ["project-reclaimer-v0.9.12.exe"])
        self.assertEqual((self.home / "game" / "project-reclaimer-v0.9.12.exe").read_bytes(), NEW_EXE)
        rc, out = self.run_updater("game")
        self.assertEqual(out[-1], "done: up to date")

    def test_older_release_with_renamed_client_can_be_chosen(self):
        d = self.tags / "v0.9.11"
        (d / "project-reclaimer-v0.9.11.exe").rename(d / "project-reclaimer-client-v0.9.11.exe")
        (d / "SHA256SUMS.txt").write_text(f"{sha(OLD_EXE)}  project-reclaimer-client-v0.9.11.exe\n")
        rc, out = self.run_updater("use", "0.9.11")
        self.assertEqual(rc, 0, out)
        self.assertEqual((self.home / "game" / "versions" / "project-reclaimer-v0.9.11.exe").read_bytes(), OLD_EXE)

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

    def test_port_update_finishes_when_the_window_closes(self):
        # 1.3.1's update died halfway with BrokenPipeError when the window was closed a second after it started
        (self.home / "game" / "project-reclaimer-v0.9.12.exe").write_bytes(NEW_EXE)
        (self.raw / "VERSION").write_text("1.2.0\n")
        (self.raw / "VERSION.new").write_text("1.2.0\n")
        p = subprocess.Popen([sys.executable, "-I", str(UPDATER), "run"], env=self.env, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, text=True)
        self.assertEqual(p.stdout.readline().strip(), "status: Checking for updates…")
        p.stdout.close()  # the window quits
        _, err = p.communicate(timeout=60)
        self.assertEqual(p.returncode, 0, err)
        self.assertNotIn("Traceback", err)
        self.assertEqual((self.home / "version").read_text().strip(), "1.2.0")

    def test_after_a_port_update_the_new_installer_owns_the_game_update(self):
        # the new install.sh updates the game with the new updater.py; this (old) process must not try again with
        # its old code: in 1.2.1 that printed "no game client" for 0.9.18 just after the fix had installed it
        (self.raw / "VERSION").write_text("1.2.0\n")
        (self.raw / "VERSION.new").write_text("1.2.0\n")
        (self.rel / "SHA256SUMS.txt").write_text("0" * 64 + "  some-future-name-v0.9.12.exe\n")
        rc, out = self.run_updater("run")
        self.assertEqual(rc, 0, out)
        self.assertIn("relaunch", out)
        self.assertFalse(any(l.startswith("error: ") for l in out), out)

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
                                 r"C:\game\project-reclaimer-v9.9.99.exe game-client --mcc-path x"],
                                cwd=self.home / "game")  # (the launcher starts the game from here)
        try:
            rc, out = self.run_updater("run")
        finally:
            game.kill()
        self.assertEqual(out[-1], "done: skipped while the game is running")
        self.assertEqual(self.game_files(), ["project-reclaimer-v0.9.8.exe"])

    def test_a_game_from_another_installation_doesnt_stop_the_update(self):
        (self.home / "game" / "project-reclaimer-v0.9.8.exe").write_bytes(b"old")
        other = self.tmp / "other" / "game"
        other.mkdir(parents=True)
        game = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)",
                                 "project-reclaimer-v9.9.99.exe game-client"], cwd=other)  # (another checkout)
        try:
            rc, out = self.run_updater("game")
        finally:
            game.kill()
            game.wait()  # (reap it: otherwise Python warns about a still-running child)
        self.assertEqual(out[-1], "done: updated", out)
        self.assertEqual(self.game_files(), ["project-reclaimer-v0.9.12.exe"])

    # ---- choosing an older version (servers that haven't updated yet) ------------------------------------------
    def test_versions_lists_recent_releases_without_prereleases(self):
        (self.home / "game" / "project-reclaimer-v0.9.12.exe").write_bytes(NEW_EXE)
        rc, out = self.run_updater("versions")
        listing = json.loads(out[-1])
        self.assertEqual([v["version"] for v in listing["versions"]], ["0.9.12", "0.9.11"])
        self.assertEqual(listing["chosen"], None)
        self.assertEqual(listing["versions"][0]["date"], "2026-10-10")

    def test_use_an_older_version_downloads_verifies_and_pins_it(self):
        (self.home / "game" / "project-reclaimer-v0.9.12.exe").write_bytes(NEW_EXE)
        rc, out = self.run_updater("use", "0.9.11")
        self.assertEqual(out[-1], "done: using 0.9.11", out)
        versions = self.home / "game" / "versions"
        self.assertEqual((versions / "project-reclaimer-v0.9.11.exe").read_bytes(), OLD_EXE)
        # the menu's graphics library loads from the exe's own folder
        self.assertEqual((versions / "opengl32.dll").read_bytes(), b"mesa")
        self.assertTrue((versions / "libgallium_wgl.dll").exists())
        self.assertEqual((self.home / "game" / "chosen-version").read_text().strip(), "0.9.11")
        self.assertIn("project-reclaimer-v0.9.12.exe", self.game_files())  # the newest stays for later

    def test_a_chosen_version_is_not_updated_away(self):
        (self.home / "game" / "project-reclaimer-v0.9.8.exe").write_bytes(b"old")
        self.run_updater("use", "0.9.11")
        rc, out = self.run_updater("game")
        self.assertEqual(out[-1], "done: using 0.9.11", out)
        self.assertEqual(self.game_files(), ["project-reclaimer-v0.9.8.exe"])  # no game update while chosen
        listing = json.loads(self.run_updater("versions")[1][-1])
        self.assertEqual(listing["chosen"], "0.9.11")
        self.assertTrue(next(v for v in listing["versions"] if v["version"] == "0.9.11")["downloaded"])

    def test_an_older_version_lasts_until_the_app_is_opened_again(self):
        # friends shouldn't stay stuck on an old version: the launcher's start-up run goes back to the newest
        self.run_updater("use", "0.9.11")
        rc, out = self.run_updater("run")
        self.assertFalse((self.home / "game" / "chosen-version").exists())
        self.assertIn("project-reclaimer-v0.9.12.exe", self.game_files())

    def test_back_to_the_newest(self):
        self.run_updater("use", "0.9.11")
        rc, out = self.run_updater("use", "newest")
        self.assertFalse((self.home / "game" / "chosen-version").exists())
        self.assertIn("project-reclaimer-v0.9.12.exe", self.game_files())  # installed right away
        self.assertEqual(out[-1], "done: updated")

    def test_damaged_older_download_is_refused(self):
        (self.tags / "v0.9.11" / "project-reclaimer-v0.9.11.exe").write_bytes(b"tampered")
        rc, out = self.run_updater("use", "0.9.11")
        self.assertTrue(out[-1].startswith("error: "), out)
        self.assertFalse((self.home / "game" / "chosen-version").exists())
        self.assertFalse((self.home / "game" / "versions" / "project-reclaimer-v0.9.11.exe").exists())

    def test_use_rejects_odd_versions(self):
        rc, out = self.run_updater("use", "../../x")
        self.assertTrue(out[-1].startswith("error: "))

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
