"""install.sh in the launcher window's GUI mode: every failure must reach the window as an "error:" line.

Runs install.sh against a throwaway RECLAIMER_HOME with fake commands first on PATH (it fails early, so nothing is
installed or downloaded). Run: /usr/bin/python3 -I -m unittest discover -s tests
"""
import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent


class InstallGuiTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.bin = self.tmp / "bin"
        self.bin.mkdir()

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def fake(self, name, script):
        f = self.bin / name
        f.write_text("#!/bin/sh\n" + script + "\n")
        f.chmod(0o755)

    def run_install(self, **extra):
        env = dict(os.environ, RECLAIMER_GUI="1", RECLAIMER_HOME=str(self.tmp / "home"),
                   RECLAIMER_APPS_DIR=str(self.tmp / "apps"), PATH=f"{self.bin}:{os.environ['PATH']}",
                   RECLAIMER_MCC_FROM=str(self.tmp))  # (skips the free-space check; the test fails earlier anyway)
        env.update(extra)
        p = subprocess.run(["/bin/bash", str(REPO / "install.sh")], env=env, stdin=subprocess.DEVNULL,
                           capture_output=True, text=True, timeout=120)
        return p.returncode, [l for l in p.stdout.splitlines() if l.startswith("error: ")]

    def test_root_never_reads_a_file_the_game_can_write(self):
        # the sandboxed game may write the user's temp folder; root's staged copies live in game/, which it can't
        text = (REPO / "install.sh").read_text()
        block = text[text.index('script_file scripts/reclaimer-loopback.sh') - 200:text.index('rm -rf "$T"')]
        self.assertIn('T=$(mktemp -d "$BASE/game/', block)
        self.assertIn("/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin", text[text.index("as_admin() {"):])

    def network_step(self):
        text = (REPO / "install.sh").read_text()
        return text[text.index('bold "Local network addresses'):text.index('bold "Tuned graphics settings"')]

    def test_network_step_leaves_a_task_the_player_turned_off_alone(self):
        # (the #37 workaround, `launchctl disable`: launchd refuses to load the task, so trying to install it again
        # failed every update, and asked for a password each time first)
        step = self.network_step()
        check = step.index("launchctl print-disabled system")
        self.assertLess(check, step.index("as_admin"))
        self.assertLess(check, step.index("mktemp"))
        # (read whole: under pipefail an early-exiting grep -q SIGPIPEs launchctl, and the match is missed)
        self.assertNotIn("launchctl print-disabled system 2>/dev/null | grep", step)

    def test_network_step_gives_the_request_folder_to_the_player_alone(self):
        step = self.network_step()
        self.assertIn("chown $(id -u) '$LB_DIR/request' && chmod 700 '$LB_DIR/request'", step)
        self.assertIn("chown root:wheel '$LB_DIR' && chmod 755 '$LB_DIR'", step)
        self.assertIn('[ ! -O "$LB_DIR/request" ]', step)  # (reinstalled when it isn't the player's alone)
        self.assertIn('[ "$(stat -f %Lp "$LB_DIR/request")" != 700 ]', step)
        self.assertIn("cmp -s \"$T/local.projectreclaimer.loopback.plist\"", step)  # (the old boot-time plist goes)

    def test_every_wine_start_is_sandboxed(self):
        # (an unsandboxed wineboot would run DLLs the sandboxed game could have changed)
        text = (REPO / "install.sh").read_text()
        starts = [l for l in text.splitlines() if re.search(r'"\$WINE_BIN/wine(server)?"', l)]
        self.assertGreaterEqual(len(starts), 4)
        for line in starts:
            self.assertIn('"$BASE/game/sandboxed.sh" "$WINE_BIN/', line)
        copied = re.search(r"for f in (.*?); do script_file", text, re.S).group(1)
        self.assertIn("sandboxed.sh", copied)
        self.assertIn("wine-sandbox.sb", copied)

    def test_top_level_failure_reaches_the_window(self):
        self.fake("uname", "echo x86_64")
        rc, errors = self.run_install()
        self.assertNotEqual(rc, 0)
        self.assertEqual(errors, ["error: This needs an Apple Silicon Mac (M1 or newer)."])

    def test_odst_needs_more_free_space(self):
        self.fake("df", 'echo "Filesystem 1G-blocks Used Available"; echo "/dev/disk3 900 850 50"')
        self.fake("curl", "exit 6")  # (past the free-space check, the install stops at its first download)
        rc, errors = self.run_install(RECLAIMER_MCC_FROM="")
        self.assertNotIn("free disk space", " ".join(errors))  # Halo 3 alone fits in 50 GB
        rc, errors = self.run_install(RECLAIMER_MCC_FROM="", RECLAIMER_ODST="1")
        self.assertNotEqual(rc, 0)
        self.assertEqual(errors, ["error: Need about 54 GB free disk space (have 50 GB)."])

    def test_unaccepted_xcode_license_says_so(self):
        # /usr/bin/python3 refuses to run until Xcode's license is accepted; the install then failed much later
        # with "check your internet connection" (GitHub #10)
        self.fake("python3", "echo \"You have not agreed to the Xcode license agreements. Please run 'sudo xcodebuild "
                  "-license' from within a Terminal window.\" >&2; exit 69")
        self.fake("curl", "exit 6")  # (so nothing downloads should the check let it through)
        rc, errors = self.run_install(RECLAIMER_TEST_PYTHON=str(self.bin / "python3"))
        self.assertNotEqual(rc, 0)
        self.assertEqual(len(errors), 1, errors)
        self.assertIn("Xcode's license", errors[0])
        self.assertIn("sudo xcodebuild -license accept", errors[0])

    def test_download_failure_inside_a_helper_reaches_the_window(self):
        # fetch runs inside $(...): its error line used to be swallowed, leaving only "the install stopped"
        self.fake("curl", "exit 6")
        rc, errors = self.run_install()
        self.assertNotEqual(rc, 0)
        self.assertTrue(errors, "no error line")
        self.assertIn("internet connection", errors[0])

    def test_unexpected_failure_still_says_something(self):
        # a command failing without die (here: tar) must not end the install silently
        self.fake("tar", "exit 1")
        cache = self.tmp / "home" / "downloads"
        cache.mkdir(parents=True)
        # a cached Wine archive with the right checksum would be needed to reach tar; instead make curl "succeed"
        self.fake("curl", 'for a; do o=$a; done; while [ $# -gt 0 ]; do [ "$1" = -o ] && touch "$2"; shift; done')
        rc, errors = self.run_install()
        self.assertNotEqual(rc, 0)
        self.assertTrue(errors, "the install ended without an error line")



class UninstallTest(unittest.TestCase):
    def test_refuses_a_folder_that_isnt_an_install(self):
        # uninstall.sh deletes RECLAIMER_HOME with rm -rf: RECLAIMER_HOME=~ (or a typo) must not delete a home folder.
        # (It stops before its pkill lines, so nothing else on this Mac is touched.)
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp, True)
        (tmp / "notes.txt").write_text("keep me")
        env = dict(os.environ, RECLAIMER_HOME=str(tmp), RECLAIMER_APPS_DIR=str(tmp / "apps"), RECLAIMER_YES="1",
                   RECLAIMER_KEEP_NETWORK="1")
        p = subprocess.run(["/bin/bash", str(REPO / "uninstall.sh")], env=env, stdin=subprocess.DEVNULL,
                           capture_output=True, text=True, timeout=30)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("doesn't look like a Project Reclaimer install", p.stderr)
        self.assertEqual((tmp / "notes.txt").read_text(), "keep me")

    def test_downloads_stay_on_https(self):
        text = (REPO / "install.sh").read_text()
        self.assertIn("--proto =https --proto-redir =https", text)
        self.assertIn("chmod 700", text)


if __name__ == "__main__":
    unittest.main()
