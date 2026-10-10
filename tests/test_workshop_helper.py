"""Tests for scripts/workshop_helper.py: Steam sign-in and mod status, against a fake DepotDownloader.

Run: /usr/bin/python3 -I -m unittest discover -s tests
"""
import importlib.util
import json
import queue
import threading
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
HELPER = REPO / "scripts" / "workshop_helper.py"
QR = ["Use the Steam Mobile App to sign in with this QR code:",  # square: 5 rows of 5 modules
      "          ",
      "  ██  ██  ",
      "  ████    ",
      "    ████  ",
      "          "]
SUCCESS = "Success! Next time you can login with -username RealName_1 -remember-password instead of -qr."


class HelperTest(unittest.TestCase):
    def setUp(self):
        self.home = Path(tempfile.mkdtemp())
        (self.home / "tools").mkdir()
        (self.home / "logs").mkdir()
        shutil.copy(REPO / "tests" / "fake_depot.py", self.home / "tools" / "DepotDownloader")
        os.chmod(self.home / "tools" / "DepotDownloader", 0o755)
        self.spec = self.home / "fake.json"
        self.args_log = self.home / "args.log"
        self.env = dict(os.environ, RECLAIMER_HOME=str(self.home), FAKE_DEPOT=str(self.spec))

    def tearDown(self):
        shutil.rmtree(self.home)

    def fake(self, lines, rc=0, modinfo=False, delay=0.0):
        self.spec.write_text(json.dumps({"lines": lines, "rc": rc, "modinfo": modinfo, "delay": delay,
                                         "args_log": str(self.args_log)}))

    def depot_runs(self):
        return [json.loads(l) for l in self.args_log.read_text().splitlines()] if self.args_log.exists() else []

    def run_helper(self, *args):
        return self.run_helper_env({}, *args)

    def run_helper_env(self, extra, *args):
        p = subprocess.run([sys.executable, "-I", str(HELPER), *args], env=dict(self.env, **extra),
                           capture_output=True, text=True, timeout=30)
        return p.returncode, p.stdout.splitlines()

    def load(self):
        """Import the helper with this test's RECLAIMER_HOME (and keep it set for the fake DepotDownloader)."""
        patcher = mock.patch.dict(os.environ, self.env)
        patcher.start()
        self.addCleanup(patcher.stop)
        if True:
            spec = importlib.util.spec_from_file_location("workshop_helper", HELPER)
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
        return mod

    # ---- login-check ----------------------------------------------------------------------------------------
    def test_check_without_account_needs_login_and_never_runs_depot(self):
        self.fake(["should not run"])
        rc, out = self.run_helper("login-check")
        self.assertEqual(out[-1], "need-login")
        self.assertEqual(self.depot_runs(), [])

    def test_check_ok(self):
        (self.home / "steam-account").write_text("RealName_1\n")
        self.fake(["Connecting to Steam3... Done!", "Logging 'RealName_1' into Steam3...", " Done!",
                   "Got 442 licenses for account!"])
        rc, out = self.run_helper("login-check")
        self.assertEqual((rc, out[-1]), (0, "ok RealName_1"))
        run = self.depot_runs()[0]
        self.assertEqual(run[run.index("-username") + 1], "RealName_1")
        self.assertIn("-remember-password", run)

    def test_check_missing_saved_login_needs_login(self):
        # what DepotDownloader 3.4.0 does when there's no saved login for the name (e.g. a mistyped account name)
        (self.home / "steam-account").write_text("display name\n")
        self.fake(['Enter account password for "display name": ', "Connecting to Steam3... Done!",
                   "Unhandled exception. System.ArgumentException: LogOn requires a username and password"], rc=134)
        self.assertEqual(self.run_helper("login-check")[1][-1], "need-login")

    def test_check_rejected_token_needs_login(self):
        (self.home / "steam-account").write_text("RealName_1\n")
        self.fake(["Connecting to Steam3... Done!", "Access token was rejected (AccessDenied)."], rc=1)
        self.assertEqual(self.run_helper("login-check")[1][-1], "need-login")

    def test_check_unrecognized_failure_is_a_warning_not_a_sign_in(self):
        # e.g. Steam rate limiting or a DepotDownloader crash: a working login must not be asked to sign in again
        (self.home / "steam-account").write_text("RealName_1\n")
        self.fake(["Connecting to Steam3... Done!", "Unhandled exception. System.Net.Http.HttpRequestException: 502"],
                  rc=134)
        self.assertEqual(self.run_helper("login-check")[1][-1], "offline")

    def test_check_gives_up_on_a_stalled_connection(self):
        (self.home / "steam-account").write_text("RealName_1\n")
        self.spec.write_text(json.dumps({"lines": ["Connecting to Steam3..."], "sleep_after": 120}))
        start = time.time()
        rc, out = self.run_helper_env({"RECLAIMER_LOGIN_TIMEOUT": "3"}, "login-check")
        self.assertEqual(out[-1], "offline")
        self.assertLess(time.time() - start, 15)

    def test_check_offline(self):
        (self.home / "steam-account").write_text("RealName_1\n")
        self.fake(["Connecting to Steam3...", "Could not connect to Steam after 10 tries"], rc=1)
        self.assertEqual(self.run_helper("login-check")[1][-1], "offline")

    # ---- login-qr -------------------------------------------------------------------------------------------
    def test_qr_relays_code_and_saves_real_account_name(self):
        (self.home / "steam-account").write_text("wrong name\n")
        self.fake(["Connecting to Steam3... Done!", "Logging in with QR code...", *QR, SUCCESS, " Done!",
                   "Got 442 licenses for account!"])
        rc, out = self.run_helper("login-qr")
        self.assertEqual(rc, 0)
        self.assertEqual(out[0], "qr-begin")
        self.assertEqual(out[1:6], ["qr: " + l for l in QR[1:]])
        self.assertEqual(out[6], "qr-end")
        self.assertEqual(out[-1], "ok RealName_1")
        self.assertEqual((self.home / "steam-account").read_text().strip(), "RealName_1")
        run = self.depot_runs()[0]
        self.assertIn("-qr", run)
        self.assertNotIn("-username", run)  # DepotDownloader refuses -username together with -qr

    def test_qr_code_is_complete_while_waiting_for_the_scan(self):
        # DepotDownloader prints the code, then nothing until the phone scans it: the code must end by itself
        self.spec.write_text(json.dumps({"lines": [*QR, SUCCESS], "delay": 0.0}))
        script = json.loads(self.spec.read_text())
        script["lines"] = QR
        script["rc"] = 0
        self.spec.write_text(json.dumps(script))
        wrapper = self.home / "tools" / "DepotDownloader"
        wrapper.write_text(wrapper.read_text().replace("sys.exit(spec.get(\"rc\", 0))",
                                                       "time.sleep(5)\nsys.exit(spec.get(\"rc\", 0))"))
        p = subprocess.Popen([sys.executable, "-I", str(HELPER), "login-qr"], env=self.env, stdout=subprocess.PIPE,
                             text=True)
        lines = queue.Queue()
        threading.Thread(target=lambda: [lines.put(l.rstrip("\n")) for l in p.stdout], daemon=True).start()
        try:
            got, start = [], time.time()
            while "qr-end" not in got and time.time() - start < 3:
                try:
                    got.append(lines.get(timeout=0.2))
                except queue.Empty:
                    pass
            self.assertIn("qr-end", got, "the code only ended when the next line arrived")
        finally:
            p.kill()
            p.wait()

    def test_sign_in_stops_when_the_launcher_is_gone(self):
        # a launcher that crashes or is force-quit must not leave DepotDownloader waiting for a scan for minutes
        self.spec.write_text(json.dumps({"lines": QR, "sleep_after": 60}))
        launcher = subprocess.Popen([sys.executable, "-c", (
            "import subprocess, sys, time\n"
            "p = subprocess.Popen([sys.executable, '-I', sys.argv[1], 'login-qr'], stdout=subprocess.DEVNULL)\n"
            "print(p.pid, flush=True)\n"
            "time.sleep(60)\n"), str(HELPER)], env=self.env, stdout=subprocess.PIPE, text=True)
        helper_pid = int(launcher.stdout.readline())
        time.sleep(1.5)
        fake = subprocess.run(["pgrep", "-f", str(self.home / "tools" / "DepotDownloader")],
                              capture_output=True, text=True).stdout.split()
        self.assertTrue(fake, "fake DepotDownloader should be running")
        launcher.kill()
        launcher.wait()
        deadline = time.time() + 5
        while time.time() < deadline and subprocess.run(["pgrep", "-f", str(self.home / "tools" / "DepotDownloader")],
                                                        capture_output=True).returncode == 0:
            time.sleep(0.2)
        left = subprocess.run(["pgrep", "-f", str(self.home / "tools" / "DepotDownloader")], capture_output=True)
        subprocess.run(["kill", str(helper_pid)] + fake, capture_output=True)
        self.assertNotEqual(left.returncode, 0, "DepotDownloader kept running after the launcher was gone")

    def test_qr_refresh_sends_a_new_code(self):
        self.fake([*QR, "", "The QR code has changed:", *QR, SUCCESS, "Got 1 licenses for account!"])
        out = self.run_helper("login-qr")[1]
        self.assertEqual(out.count("qr-begin"), 2)
        self.assertEqual(out.count("qr-end"), 2)

    def test_qr_failure_reports_error_and_keeps_account(self):
        (self.home / "steam-account").write_text("RealName_1\n")
        self.fake([*QR, "Unhandled exception. SteamKit2.Authentication.AuthenticationException: Authentication "
                        "failed with result Expired"], rc=134)
        rc, out = self.run_helper("login-qr")
        self.assertNotEqual(rc, 0)
        self.assertTrue(out[-1].startswith("error: "), out[-1])
        self.assertIn("Expired", out[-1])
        self.assertEqual((self.home / "steam-account").read_text().strip(), "RealName_1")

    def test_qr_failure_without_explanation_says_so(self):
        self.fake([*QR], rc=1)
        self.assertEqual(self.run_helper("login-qr")[1][-1], "error: sign-in did not finish")

    # ---- downloads and mod status ---------------------------------------------------------------------------
    def details(self, wid="123"):
        return {"publishedfileid": wid, "result": 1, "title": "Warlock", "time_updated": 1700000000,
                "hcontent_file": "999", "file_size": "1600000000"}

    def status(self, h, wid="123"):
        return json.loads((h.STATUS_DIR / f"{wid}.json").read_text())

    def test_download_writes_progress_then_ready(self):
        (self.home / "steam-account").write_text("RealName_1\n")
        self.fake([" 10.00% maps/a.map", " 55.50% maps/b.map", "100.00% ModInfo.json",
                   "Total downloaded: 1600000000 bytes"], modinfo=True, delay=1.05)
        h = self.load()
        seen = []
        real_write = h.write_status

        def spy(wid, **fields):
            real_write(wid, **fields)
            seen.append(dict(self.status(h, wid)))
        with mock.patch.object(h, "workshop_details", return_value=[self.details()]), \
                mock.patch.object(h, "write_status", side_effect=spy), \
                mock.patch.object(h, "notify"), mock.patch.object(h.subprocess, "run", wraps=subprocess.run) as run:
            self.assertTrue(h.download("123", "Warlock", self.details()))
        states = [s["state"] for s in seen]
        self.assertEqual(states[0], "downloading")
        self.assertEqual(states[-1], "ready")
        self.assertIn(55.5, [s.get("percent") for s in seen])
        final = seen[-1]
        self.assertEqual((final["title"], final["percent"], final["bytes_total"]), ("Warlock", 100.0, 1600000000))

    def test_no_account_dialog_or_terminal_left_in_the_helper(self):
        source = HELPER.read_text()
        self.assertNotIn("display dialog", source)
        self.assertNotIn('"Terminal"', source)

    def test_download_without_account_reports_login_needed(self):
        self.fake(["should not run"])
        h = self.load()
        with mock.patch.object(h, "notify"), mock.patch.object(h.subprocess, "run") as run:
            self.assertFalse(h.download("123", "Warlock", self.details()))
        self.assertEqual(self.status(h)["state"], "login_needed")
        self.assertEqual(self.depot_runs(), [])
        self.assertFalse(run.called)  # in particular no account-name dialog

    def test_download_with_expired_login_reports_login_needed_without_terminal(self):
        (self.home / "steam-account").write_text("RealName_1\n")
        self.fake(["Connecting to Steam3... Done!", "Access token was rejected (AccessDenied)."], rc=1)
        h = self.load()
        with mock.patch.object(h, "notify"):
            self.assertFalse(h.download("123", "Warlock", self.details()))
        self.assertEqual(self.status(h)["state"], "login_needed")

    def test_download_failure_reports_failed(self):
        (self.home / "steam-account").write_text("RealName_1\n")
        self.fake(["Connecting to Steam3... Done!", " Done!", "Encountered error downloading depot manifest"], rc=1)
        h = self.load()
        with mock.patch.object(h, "notify"):
            self.assertFalse(h.download("123", "Warlock", self.details()))
        self.assertEqual(self.status(h)["state"], "failed")

    def test_unexpected_error_mid_download_never_leaves_it_downloading(self):
        (self.home / "steam-account").write_text("RealName_1\n")
        self.fake([" 10.00% a", "100.00% b"], modinfo=True)
        h = self.load()
        with mock.patch.object(h, "notify"), mock.patch.object(h, "record_version", side_effect=OSError("disk full")):
            with self.assertRaises(OSError):
                h.download("123", "Warlock", self.details())
        self.assertEqual(self.status(h)["state"], "failed")

    def test_status_writes_from_two_processes_dont_collide(self):
        h = self.load()
        errors = []

        def hammer(n):
            try:
                for i in range(200):
                    h.write_status("123", percent=float(i), writer=n)
            except Exception as e:
                errors.append(e)
        threads = [threading.Thread(target=hammer, args=(n,)) for n in range(4)]
        [t.start() for t in threads]
        [t.join() for t in threads]
        self.assertEqual(errors, [])
        self.assertIn("percent", self.status(h))

    def test_watch_finishes_a_download_after_the_game_exits(self):
        # quitting the game mid-download used to kill the download and leave it "downloading" forever
        (self.home / "steam-account").write_text("RealName_1\n")
        self.fake([" 50.00% a", "100.00% b"], modinfo=True, delay=1.0)
        h = self.load()
        log = self.home / "logs" / "client.log"
        log.write_text("Mod Warlock not downloaded: needs Steam Workshop\n")
        with mock.patch.object(h, "LOG", log), mock.patch.object(h, "notify"), \
                mock.patch.object(h, "game_running", return_value=False), \
                mock.patch.object(h, "GAME_GRACE", 0.5), \
                mock.patch.object(h, "resolve", return_value="123"), \
                mock.patch.object(h, "workshop_details", return_value=[self.details()]):
            h.watch()
        self.assertEqual(self.status(h)["state"], "ready")

    def test_no_setup_command(self):
        rc, out = self.run_helper("setup")
        self.assertNotEqual(rc, 0)


if __name__ == "__main__":
    unittest.main()
