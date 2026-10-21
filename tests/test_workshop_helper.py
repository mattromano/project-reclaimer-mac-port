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
        self.env = dict(os.environ, RECLAIMER_HOME=str(self.home), FAKE_DEPOT=str(self.spec),
                        RECLAIMER_GAME_PROCESS=r"project-reclaimer-v9\.9\.99\.exe game-client")

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

    def test_qr_code_expiring_is_said_plainly(self):
        # what DepotDownloader 3.4.0 prints when nobody scans for ~2 minutes
        self.fake([*QR, "", "The QR code has changed:", *QR, "Error: InitializeSteam failed"], rc=1)
        self.assertEqual(self.run_helper_env({"RECLAIMER_QR_ATTEMPTS": "2"}, "login-qr")[1][-1],
                         "error: The QR code expired before it was scanned. Press Try Again for a new one.")

    def test_an_expired_qr_code_is_replaced_by_itself(self):
        # finding the Steam app can take a while: a new code appears without pressing Try Again
        self.depot_seq([([*QR, "Error: InitializeSteam failed"], 1),
                        ([*QR, SUCCESS, "Got 1 licenses for account!"], 0)])
        rc, out = self.run_helper("login-qr")
        self.assertEqual(out[-1], "ok RealName_1", out)
        self.assertEqual(out.count("qr-begin"), 2)

    def test_game_download_replaces_an_expired_qr_code_by_itself(self):
        self.depot_seq([([*QR, "Error: InitializeSteam failed"], 1),
                        ([*QR, SUCCESS, "Got 1 licenses for account!", "100.00% halo3/halo3.dll"], 0)])
        rc, out = self.run_helper("game-download", str(self.home / "mcc"))
        self.assertEqual(out[-1], "ok", out)

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

    def search(self, h, title, found):
        """id_from_search(title) when the Workshop search page lists `found` ({id: title})."""
        page = " ".join(f'<a href="https://steamcommunity.com/sharedfiles/filedetails/?id={i}">' for i in found)
        response = mock.MagicMock()
        response.__enter__.return_value.read.return_value = page.encode()
        details = [{"publishedfileid": i, "title": t} for i, t in found.items()]
        with mock.patch.object(h.urllib.request, "urlopen", return_value=response), \
                mock.patch.object(h, "workshop_details", return_value=details):
            return h.id_from_search(title)

    def test_search_never_settles_for_a_different_mod(self):
        # "Halo 2 Spartan (characters)" (a character pack a server made) once fetched the 3 GB campaign mod
        # "Halo 2 But Everyone is a Spartan": close enough for a loose similarity score, but the wrong mod
        h = self.load()
        self.assertIsNone(self.search(h, "Halo 2 Spartan", {"3010133477": "Halo 2 But Everyone is a Spartan"}))
        self.assertEqual(self.search(h, "Halo 3 Foundation", {"1": "Halo 3 Foundations", "2": "Halo 3 Foundation"}),
                         "2")
        self.assertEqual(self.search(h, "Warlock - Beta", {"7": "Warlock"}), "7")  # (a server's suffix)
        self.assertEqual(self.search(h, "Ultimate Forge 2.0", {"9": "ULTIMATE FORGE 2.0"}), "9")

    def test_character_packs_are_left_to_the_server(self):
        # since 0.9.18 servers share packs of their character mods, named "<mod> (characters)"; they aren't
        # Workshop items, so the helper doesn't search Steam for them (the game gets them from the server)
        log = self.home / "logs" / "client.log"  # (the helper's log when RECLAIMER_LOG isn't set)
        log.write_text("Mod Halo 2 Spartan (characters) not downloaded: Start Steam and sign in with an account "
                       "that owns MCC to use Workshop\n"
                       "Workshop for CE Spartan (characters) unavailable: no Steam; using the server\n"
                       "Mod Warlock not downloaded: Start Steam and sign in with an account that owns MCC to use "
                       "Workshop\n")
        h = self.load()
        with mock.patch.object(h, "GAME_GRACE", 0.1), mock.patch.object(h, "fetch") as fetch, \
                mock.patch.object(h, "game_running", return_value=False):
            h.watch()
        self.assertEqual([c.args[0] for c in fetch.call_args_list], ["Warlock"])  # (an ordinary mod still is)

    def test_workshop_ids_are_digits_only(self):
        # a ModInfo.json from a server names its own SteamWorkshopId; "123/../../x" went into folder paths
        # (security review, M2). Steam's API even accepts it, reading only the leading digits.
        mods = self.home / "prefix-wine" / "drive_c" / "users" / "p" / "Documents" / "My Games" / "Project Reclaimer" / "Mods" / "x"
        mods.mkdir(parents=True)
        (mods / "ModInfo.json").write_text(json.dumps({"Title": {"Neutral": "Evil"}, "ModIdentifier": {
            "HostedModIds": {"SteamWorkshopId": "2984061723/../../../../Library/LaunchAgents"}}}))
        h = self.load()
        with mock.patch.object(h, "id_from_search", return_value=None):
            self.assertIsNone(h.resolve("Evil"))
        self.assertEqual(h.resolve("2984061723"), "2984061723")
        for bad in ("/etc/x", "12/../3", "١٢٣", ""):  # (Arabic-Indic digits pass str.isdigit)
            self.assertFalse(h.valid_workshop_id(bad), bad)
        with mock.patch.object(h, "notify"):
            self.assertFalse(h.fetch("/tmp/evil"))
        self.assertFalse(any(Path("/tmp").glob("evil*.lock")))

    def test_steam_account_file_is_private(self):
        h = self.load()
        h.save_account("RealName_1")
        self.assertEqual(oct((self.home / "steam-account").stat().st_mode & 0o777), "0o600")
        self.assertEqual((self.home / "steam-account").read_text(), "RealName_1\n")

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

    def test_game_counts_as_running_when_it_is_the_helpers_parent(self):
        # launch.sh starts the helper, then exec's into the game: the game is the helper's parent process, and
        # macOS pgrep skips a caller's ancestors unless told otherwise, so the helper stopped mid-game after 60 s
        game = subprocess.run([sys.executable, "-c", (
            "import subprocess, sys\n"
            "child = ('import importlib.util; s = importlib.util.spec_from_file_location(\"h\", sys.argv[1]); '\n"
            "         'h = importlib.util.module_from_spec(s); s.loader.exec_module(h); '\n"
            "         'print(h.game_running())')\n"
            "print(subprocess.run([sys.executable, '-I', '-c', 'import sys; ' + child, sys.argv[1]],\n"
            "                     capture_output=True, text=True).stdout.strip())\n"),
            # (a version no real game has, so a game running on this Mac can't make the test pass)
            str(HELPER), "project-reclaimer-v9.9.99.exe game-client"], env=self.env, capture_output=True, text=True)
        self.assertEqual(game.stdout.strip(), "True", game.stderr)

    def test_launcher_posts_the_notifications_when_it_is_running(self):
        # the launcher's own notifications say "Project Reclaimer"; the helper's osascript ones say "Script Editor"
        self.env["RECLAIMER_LAUNCHER_NOTIFIES"] = "1"
        h = self.load()
        with mock.patch.object(h.subprocess, "run") as run:
            h.notify("Warlock is ready.")
        self.assertFalse(run.called)

    def test_only_one_watching_helper_and_nothing_else_fools_it(self):
        # a process that merely mentions the helper (e.g. a shell command) must not count as a running helper
        bystander = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)", "workshop_helper.py watch"])
        log = self.home / "logs" / "client.log"
        log.write_text("")
        env = dict(self.env, RECLAIMER_LOG=str(log))
        try:
            first = subprocess.Popen([sys.executable, "-I", str(HELPER), "watch"], env=env,
                                     stdout=subprocess.PIPE, text=True)
            self.assertRegex(first.stdout.readline(), r"\d\d:\d\d:\d\d watching ")  # (not "already watching")
            second = subprocess.run([sys.executable, "-I", str(HELPER), "watch"], env=env, capture_output=True,
                                    text=True, timeout=20)
            self.assertIn("already watching", second.stdout)
        finally:
            bystander.kill()
            first.kill()
            first.wait()

    # ---- game-download (first install, and Repair game files) -------------------------------------------------
    def depot_seq(self, runs):
        """A fake DepotDownloader that behaves differently on each run (for "saved login fails, then QR")."""
        script = self.home / "tools" / "DepotDownloader"
        specs = []
        for i, (lines, rc) in enumerate(runs):
            spec = self.home / f"run{i}.json"
            spec.write_text(json.dumps({"lines": lines, "rc": rc, "args_log": str(self.args_log)}))
            specs.append(str(spec))
        counter = self.home / "runs"
        counter.write_text("0")
        real = script.read_text()
        script.write_text(real.replace('spec = json.loads(Path(os.environ["FAKE_DEPOT"]).read_text())', (
            'n = int(Path(%r).read_text()); Path(%r).write_text(str(n + 1))\n'
            'spec = json.loads(Path(%r[n]).read_text())') % (str(counter), str(counter), specs)))

    def test_game_download_first_install_signs_in_with_qr(self):
        dest = self.home / "mcc"
        self.fake(["Connecting to Steam3... Done!", *QR, SUCCESS, " Done!", "Got 442 licenses for account!",
                   "  5.00% halo3/maps/a.map", " 50.00% halo3/maps/b.map", "100.00% halo3/halo3.dll",
                   "Total downloaded: 35000000000 bytes"])
        rc, out = self.run_helper("game-download", str(dest))
        self.assertEqual(rc, 0, out)
        self.assertIn("qr-begin", out)
        self.assertIn("qr-end", out)
        self.assertTrue(any(l.startswith("progress: ") for l in out), out)
        self.assertEqual(out[-1], "ok")
        self.assertEqual((self.home / "steam-account").read_text().strip(), "RealName_1")  # mods won't ask again
        # the window takes the code away as soon as Steam accepts the scan, before the first progress line
        signed = out.index("status: Signed in to Steam. Getting the file list…")
        self.assertLess(out.index("qr-end"), signed)
        self.assertLess(signed, next(i for i, l in enumerate(out) if l.startswith("progress: ")))
        run = self.depot_runs()[0]
        for a in ["-qr", "-validate", "-remember-password", "976731", "976738", "976739", str(dest)]:
            self.assertIn(a, run)

    def test_game_download_adds_odst_when_asked_or_installed(self):
        (self.home / "steam-account").write_text("RealName_1\n")
        self.fake(["Logging 'RealName_1' into Steam3...", " Done!", "100.00% halo3/halo3.dll"])
        dest = self.home / "mcc"
        self.run_helper("game-download", str(dest))
        self.assertNotIn("1064222", self.depot_runs()[-1])  # Halo 3 only, unless the player asks
        self.run_helper("game-download", str(dest), "--odst")
        self.assertIn("1064222", self.depot_runs()[-1])
        self.assertIn("976738", self.depot_runs()[-1])
        (dest / "halo3odst").mkdir()
        (dest / "halo3odst" / "halo3odst.dll").write_bytes(b"MZ")
        self.run_helper("game-download", str(dest))  # Repair checks ODST too once it's installed
        self.assertIn("1064222", self.depot_runs()[-1])

    def test_game_download_uses_the_saved_login(self):
        (self.home / "steam-account").write_text("RealName_1\n")
        self.fake(["Logging 'RealName_1' into Steam3...", " Done!", "100.00% halo3/halo3.dll"])
        rc, out = self.run_helper("game-download", str(self.home / "mcc"))
        self.assertEqual(out[-1], "ok")
        self.assertNotIn("qr-begin", out)
        run = self.depot_runs()[0]
        self.assertEqual(run[run.index("-username") + 1], "RealName_1")

    def test_game_download_falls_back_to_qr_when_the_saved_login_expired(self):
        (self.home / "steam-account").write_text("RealName_1\n")
        self.depot_seq([(["Access token was rejected (AccessDenied)."], 1),
                        ([*QR, SUCCESS, "Got 1 licenses for account!", "100.00% halo3/halo3.dll"], 0)])
        rc, out = self.run_helper("game-download", str(self.home / "mcc"))
        self.assertEqual(out[-1], "ok", out)
        self.assertIn("qr-begin", out)
        self.assertEqual(len(self.depot_runs()), 2)
        self.assertIn("-qr", self.depot_runs()[1])

    def test_game_download_without_mcc_says_so_plainly(self):
        self.fake([*QR, SUCCESS, "Got 3 licenses for account!", "App 976730 (Halo) is not available from this account."],
                  rc=1)
        rc, out = self.run_helper("game-download", str(self.home / "mcc"))
        self.assertNotEqual(rc, 0)
        self.assertEqual(out[-1], "error: This Steam account doesn't own Halo: The Master Chief Collection.")

    def test_game_download_connection_failure(self):
        self.fake(["Connecting to Steam3...", "Could not connect to Steam after 10 tries"], rc=1)
        rc, out = self.run_helper("game-download", str(self.home / "mcc"))
        self.assertEqual(out[-1], "error: Couldn't reach Steam. Check your internet connection and try again.")

    # ---- failed joins (the window offers to switch versions and rejoin) -----------------------------------------
    def watch_log(self, lines):
        h = self.load()
        log = self.home / "logs" / "client.log"
        log.write_text("\n".join(lines) + "\n")
        with mock.patch.object(h, "LOG", log), mock.patch.object(h, "notify"), \
                mock.patch.object(h, "game_running", return_value=False), mock.patch.object(h, "GAME_GRACE", 0.5):
            h.watch()
        path = self.home / "logs" / "join-problem.json"
        return json.loads(path.read_text()) if path.exists() else None

    def test_join_refused_for_version_is_recorded_with_the_servers_version(self):
        p = self.watch_log(["A join link asks to join 72.222.230.115:49176.",
                            "Joining 72.222.230.115:49176 from a join link.",
                            "Joining server failed: This server runs Project Reclaimer 0.9.7, older than your 0.9.13: "
                            "its host needs to update it."])
        self.assertEqual((p["address"], p["server_version"], p["mine"], p["kind"]),
                         ("72.222.230.115:49176", "0.9.7", "0.9.13", "version"))

    def test_join_timeout_is_recorded_without_a_version(self):
        p = self.watch_log(["Joining 75.98.127.226:49241 from the server browser.",
                            "Public join timed out; check the server address and forwarded ports"])
        self.assertEqual((p["address"], p["server_version"], p["kind"]), ("75.98.127.226:49241", None, "no-answer"))

    def test_a_good_join_records_nothing(self):
        self.assertIsNone(self.watch_log(["Joining 1.2.3.4:5 from a join link.",
                                          "Joining the game in progress: the map is ready after 5.0 s."]))

    def test_no_setup_command(self):
        rc, out = self.run_helper("setup")
        self.assertNotEqual(rc, 0)


if __name__ == "__main__":
    unittest.main()
