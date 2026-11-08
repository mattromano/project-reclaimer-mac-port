"""scripts/reclaimer-loopback.sh, the root startup task: gentle on macOS's network service (#37).

Adding ~1,800 lo0 aliases in one burst at every boot stalled configd on Macs with VPNs and kernel-panicked them. The
script now adds only the addresses lo0 doesn't have, a batch at a time with a pause between batches. It runs as root,
so it takes no input of any kind. The tests run a copy whose ifconfig and sleep are stand-ins that only record.
Run: /usr/bin/python3 -I -m unittest discover -s tests
"""
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SCRIPT = REPO / "scripts" / "reclaimer-loopback.sh"
RANGES = ["127.0.0", "127.0.1", "127.0.2", "127.3.1", "127.3.2"]  # what current and older clients bind


class LoopbackTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.log = self.tmp / "log"
        self.present = self.tmp / "present"  # what `ifconfig lo0` reports
        self.present.write_text("inet 127.0.0.1 netmask 0xff000000\n")
        fake_ifconfig = self.tmp / "ifconfig"
        fake_ifconfig.write_text(f'#!/bin/sh\nif [ "$#" -eq 1 ]; then cat "{self.present}"; '
                                 f'else echo "add $3" >> "{self.log}"; fi\n')
        fake_sleep = self.tmp / "sleep"
        fake_sleep.write_text(f'#!/bin/sh\necho "pause" >> "{self.log}"\n')
        for f in (fake_ifconfig, fake_sleep):
            f.chmod(0o755)
        text = SCRIPT.read_text()
        self.assertIn("/sbin/ifconfig", text)
        self.assertIn("/bin/sleep", text)
        self.copy = self.tmp / "loopback.sh"
        self.copy.write_text(text.replace("/sbin/ifconfig", str(fake_ifconfig)).replace("/bin/sleep", str(fake_sleep)))

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def run_script(self):
        subprocess.run(["/bin/sh", str(self.copy)], check=True, timeout=60)
        return self.log.read_text().splitlines() if self.log.exists() else []

    def added(self, log):
        return [l.split()[1] for l in log if l.startswith("add ")]

    def test_first_boot_adds_every_address_of_the_ranges_clients_bind(self):
        expected = [f"{p}.{i}" for p in RANGES for i in range(1, 255) if f"{p}.{i}" != "127.0.0.1"]
        self.assertEqual(sorted(self.added(self.run_script())), sorted(expected))

    def test_adds_in_paced_batches(self):
        # (one burst of interface changes is what stalled configd: never more than 50 without a pause)
        log = self.run_script()
        run = 0
        for line in log:
            run = 0 if line == "pause" else run + 1
            self.assertLessEqual(run, 50)
        self.assertGreaterEqual(log.count("pause"), len(self.added(log)) // 50 - 1)

    def test_adds_only_what_is_missing(self):
        have = [f"127.0.1.{i}" for i in range(1, 255)] + ["127.3.1.7"]
        self.present.write_text("".join(f"\tinet {a} netmask 0xffffffff\n" for a in ["127.0.0.1"] + have))
        added = self.added(self.run_script())
        self.assertFalse(set(added) & set(have))
        self.assertIn("127.3.1.8", added)
        self.assertIn("127.0.2.1", added)

    def test_nothing_missing_means_no_changes_at_all(self):
        everything = ["127.0.0.1"] + [f"{p}.{i}" for p in RANGES for i in range(1, 255)]
        self.present.write_text("".join(f"\tinet {a} netmask 0xffffffff\n" for a in everything))
        self.assertEqual(self.run_script(), [])

    def test_runs_as_root_so_takes_no_input(self):
        text = SCRIPT.read_text()
        self.assertIsNone(re.search(r"\$[0-9@*#]|\$\{?[A-Z]", text.replace("$PATH", "")),
                          "the root script must not read arguments or environment variables")
        self.assertIn("PATH=/usr/bin:/bin:/usr/sbin:/sbin", text)


if __name__ == "__main__":
    unittest.main()
