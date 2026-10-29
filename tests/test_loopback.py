"""scripts/reclaimer-loopback.sh and its plist, the root network task: gentle on macOS's network service (#37).

Adding ~1,800 lo0 aliases in one burst at every boot stalled configd on Macs with VPNs and kernel-panicked them. The
task now runs only when the launcher asks (never at boot), adds only the addresses lo0 doesn't have, 25 at a time,
times configd's answer after each batch and takes its addresses back when configd stops answering. It runs as root,
so it takes no input of any kind. The tests run a copy whose ifconfig, sleep, scutil and sysctl are stand-ins that
only record. Run: /usr/bin/python3 -I -m unittest discover -s tests
"""
import plistlib
import re
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SCRIPT = REPO / "scripts" / "reclaimer-loopback.sh"
PLIST = REPO / "scripts" / "local.projectreclaimer.loopback.plist"
ROOT_DIR = "/Library/Application Support/ProjectReclaimer"
RANGES = ["127.0.1", "127.0.2", "127.3.1", "127.3.2"]  # what current and older clients bind
EVERY = [f"{p}.{i}" for p in RANGES for i in range(1, 255)]


class LoopbackTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.log = self.tmp / "log"
        self.present = self.tmp / "present"  # what `ifconfig lo0` reports
        self.present.write_text("inet 127.0.0.1 netmask 0xff000000\n")
        self.boot = self.tmp / "boot"  # when the Mac booted, for sysctl kern.boottime
        self.boot.write_text("1000000000")
        self.ticks = self.tmp / "ticks"
        self.answers = self.tmp / "answers"  # how configd answers each query in turn: fast (default), slow, none
        self.root = self.tmp / "root"  # stands in for root's own folder
        self.root.mkdir()
        fakes = {
            "ifconfig": f'if [ "$#" -eq 1 ]; then cat "{self.present}"; '
                        f'elif [ "$2" = alias ]; then echo "add $3" >> "{self.log}"; '
                        f'else echo "remove $3" >> "{self.log}"; fi',
            # (a tenth-of-a-second tick while timing configd is counted, not logged: "slow" answers after 40 ticks,
            # 4 s in the script's terms, whatever the machine's speed)
            "sleep": f'[ "$1" = 0.1 ] && {{ echo >> "{self.ticks}"; exec /bin/sleep 0.005; }}; '
                     f'echo "pause $1" >> "{self.log}"',
            "scutil": f'echo check >> "{self.log}"; n=$(grep -c "^check$" "{self.log}"); '
                      f'a=$(sed -n "${{n}}p" "{self.answers}" 2>/dev/null); '
                      f'ticks() {{ wc -l < "{self.ticks}" 2>/dev/null || echo 0; }}; '
                      f'if [ "$a" = slow ]; then s=$(ticks); '
                      f'while [ $(($(ticks) - s)) -lt 40 ]; do /bin/sleep 0.005; done; fi; '
                      f'[ "$a" = none ] && exec /bin/sleep 30; exit 0',
            "sysctl": f'echo "{{ sec = $(cat "{self.boot}"), usec = 0 }} Thu Jan  1 00:00:00 1970"',
        }
        text = SCRIPT.read_text()
        for name, body in fakes.items():
            f = self.tmp / name
            f.write_text("#!/bin/sh\n" + body + "\n")
            f.chmod(0o755)
        for real, name in (("/sbin/ifconfig", "ifconfig"), ("/bin/sleep", "sleep"), ("/usr/sbin/scutil", "scutil"),
                           ("/usr/sbin/sysctl", "sysctl"), (ROOT_DIR, "root")):
            self.assertIn(real, text)
            text = text.replace(real, str(self.tmp / name))
        self.copy = self.tmp / "loopback.sh"
        self.copy.write_text(text)

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def run_script(self, expect_rc=0):
        p = subprocess.run(["/bin/sh", str(self.copy)], capture_output=True, text=True, timeout=120)
        self.assertEqual(p.returncode, expect_rc, p.stdout + p.stderr)
        return self.log.read_text().splitlines() if self.log.exists() else []

    def have(self, addresses):
        self.present.write_text("".join(f"\tinet {a} netmask 0xffffffff\n" for a in ["127.0.0.1"] + addresses))

    def added(self, log):
        return [l.split()[1] for l in log if l.startswith("add ")]

    def removed(self, log):
        return [l.split()[1] for l in log if l.startswith("remove ")]

    def status(self):
        return (self.root / "loopback.status").read_text().strip()

    def test_adds_every_host_of_the_ranges_clients_bind(self):
        self.assertEqual(sorted(self.added(self.run_script())), sorted(EVERY))
        self.assertEqual(self.status(), f"ok {len(EVERY)}")

    def test_times_configd_after_every_batch_of_25(self):
        # (one burst of interface changes is what stalled configd: never more than 25 without asking configd)
        log = self.run_script()
        run = 0
        for line in log:
            run = 0 if line == "check" else run + (line.startswith("add "))
            self.assertLessEqual(run, 25)
        self.assertGreaterEqual(log.count("check"), len(self.added(log)) // 25)

    def test_adds_only_what_is_missing(self):
        have = [f"127.0.1.{i}" for i in range(1, 255)] + ["127.3.1.7"]
        self.have(have)
        added = self.added(self.run_script())
        self.assertFalse(set(added) & set(have))
        self.assertIn("127.3.1.8", added)
        self.assertIn("127.0.2.1", added)

    def test_nothing_missing_means_no_changes_at_all(self):
        self.have(EVERY)
        log = self.run_script()
        self.assertFalse([l for l in log if l.startswith(("add ", "remove "))], log)
        self.assertEqual(self.status(), "ok 0")

    def test_configd_not_answering_stops_and_takes_back_what_this_run_added(self):
        before = [f"127.0.1.{i}" for i in range(1, 11)]  # (someone else's, or an earlier run's: they stay)
        self.have(before)
        self.answers.write_text("fast\nfast\nnone\nnone\nfast\n")  # the third batch gets no answer, then twice more
        log = self.run_script(expect_rc=1)
        added = self.added(log)
        self.assertEqual(len(added), 75)
        self.assertEqual(sorted(self.removed(log)), sorted(added))
        first_removal = next(i for i, l in enumerate(log) if l.startswith("remove "))
        self.assertFalse([l for l in log[first_removal:] if l.startswith("add ")], "added after giving up")
        run = 0
        for line in log[first_removal:]:  # (paced and checked like adding: removing is interface changes too)
            run = 0 if line == "check" else run + (line.startswith("remove "))
            self.assertLessEqual(run, 25)
        self.assertEqual(self.status(), "taken-back")

    def test_configd_that_doesnt_recover_means_changing_nothing_more(self):
        # (a burst of removals into a stalled configd is the #37 pattern again: leaving the aliases is harmless)
        self.answers.write_text("fast\n" + "none\n" * 20)
        log = self.run_script(expect_rc=1)
        self.assertEqual(len(self.added(log)), 50)
        self.assertFalse(self.removed(log))
        self.assertEqual(self.status(), "stopped")

    def test_configd_answering_slowly_means_waiting_for_it(self):
        self.answers.write_text("slow\nslow\nfast\n")  # (over 2 s, in 20 ms ticks; under 8 s)
        log = self.run_script()
        self.assertEqual(log[:log.index("check") + 6].count("pause 3"), 2, log[:40])
        self.assertEqual(sorted(self.added(log)), sorted(EVERY))
        self.assertFalse(self.removed(log))

    def test_waits_out_the_first_two_minutes_after_a_boot(self):
        self.boot.write_text(str(int(time.time()) - 30))
        log = self.run_script()
        first = log[0].split()
        self.assertEqual(first[0], "pause")
        self.assertTrue(85 <= int(first[1]) <= 90, log[0])

    def test_runs_as_root_so_takes_no_input(self):
        text = SCRIPT.read_text()
        self.assertIsNone(re.search(r"\$[0-9@*#]|\$\{?[A-Z]", text.replace("$PATH", "")),
                          "the root script must not read arguments or environment variables")
        self.assertIn("PATH=/usr/bin:/bin:/usr/sbin:/sbin", text)
        # the request folder is the player's: root must never read, write or follow anything in it
        self.assertNotIn("request", text)


class LoopbackPlistTest(unittest.TestCase):
    def setUp(self):
        self.plist = plistlib.loads(PLIST.read_bytes())

    def test_never_runs_at_boot_or_on_a_timer(self):
        for key in ("RunAtLoad", "KeepAlive", "StartInterval", "StartCalendarInterval", "StartOnMount", "QueueDirectories"):
            self.assertNotIn(key, self.plist)

    def test_runs_when_the_players_request_folder_changes_at_most_every_five_minutes(self):
        self.assertEqual(self.plist["WatchPaths"], [ROOT_DIR + "/request"])
        self.assertGreaterEqual(self.plist["ThrottleInterval"], 300)

    def test_runs_the_root_owned_script_with_no_arguments(self):
        self.assertEqual(self.plist["ProgramArguments"], [ROOT_DIR + "/reclaimer-loopback.sh"])
        self.assertNotIn("EnvironmentVariables", self.plist)


if __name__ == "__main__":
    unittest.main()
