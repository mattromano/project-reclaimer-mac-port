"""scripts/sandboxed.sh + wine-sandbox.sb: everything Wine runs is kept to its own folders.

The game (and anything a bad release or a server exploit runs inside it) can read the install's Wine, game and
Windows folders and write only the Windows folder: never the person's own files, and never the scripts that later run
outside the sandbox. The test install sits under the home folder (the sandbox closes /Users), in a throwaway folder.
Run: /usr/bin/python3 -I -m unittest discover -s tests
"""
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent


class SandboxTest(unittest.TestCase):
    def setUp(self):
        caches = Path.home() / "Library" / "Caches"
        caches.mkdir(parents=True, exist_ok=True)
        self.tmp = Path(tempfile.mkdtemp(prefix="reclaimer-sandbox-test-", dir=caches)).resolve()
        self.home = self.tmp / "Games" / "ProjectReclaimer"
        for d in ("game", "wine", "prefix-wine", "logs"):
            (self.home / d).mkdir(parents=True)
        for f in ("sandboxed.sh", "wine-sandbox.sb"):
            shutil.copy(REPO / "scripts" / f, self.home / "game" / f)
        (self.home / "game" / "sandboxed.sh").chmod(0o755)
        self.secret = self.tmp / "Documents" / "secret.txt"  # stands in for the person's own files
        self.secret.parent.mkdir()
        self.secret.write_text("private")
        (self.home / "game" / "run.sh").write_text("echo hi\n")
        (self.home / "prefix-wine" / "user.reg").write_text("reg\n")
        (self.home / "steam-account").write_text("someone\n")

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def sandboxed(self, *cmd, **env):
        return subprocess.run([str(self.home / "game" / "sandboxed.sh"), *cmd], capture_output=True, text=True,
                              env=dict(os.environ, RECLAIMER_HOME=str(self.home), **env), timeout=30)

    def test_cant_read_the_persons_files(self):
        p = self.sandboxed("/bin/cat", str(self.secret))
        self.assertNotEqual(p.returncode, 0)
        self.assertNotIn("private", p.stdout)
        self.assertNotEqual(self.sandboxed("/bin/ls", str(Path.home())).returncode, 0)

    def test_cant_read_the_steam_account_or_other_install_files(self):
        self.assertNotEqual(self.sandboxed("/bin/cat", str(self.home / "steam-account")).returncode, 0)

    def test_reads_its_own_folders(self):
        self.assertEqual(self.sandboxed("/bin/cat", str(self.home / "game" / "run.sh")).stdout, "echo hi\n")
        self.assertEqual(self.sandboxed("/bin/cat", str(self.home / "prefix-wine" / "user.reg")).stdout, "reg\n")
        self.assertEqual(self.sandboxed("/bin/ls", str(self.home / "wine")).returncode, 0)

    def test_writes_only_the_windows_folder(self):
        ok = self.home / "prefix-wine" / "drive_c.txt"
        self.assertEqual(self.sandboxed("/usr/bin/touch", str(ok)).returncode, 0)
        self.assertTrue(ok.exists())
        # the scripts in game/ run later outside the sandbox: changing them would be a way out
        for path in (self.home / "game" / "run.sh", self.home / "game" / "new.sh", self.home / "wine" / "x",
                     self.tmp / "Documents" / "planted.txt", self.home / "steam-account"):
            self.sandboxed("/bin/sh", "-c", f'echo planted > "{path}"')
            self.assertFalse(path.exists() and "planted" in path.read_text(), path)

    def test_cant_start_things_outside_the_sandbox(self):
        # (open and osascript hand work to processes the sandbox doesn't cover)
        for cmd in ("/usr/bin/open -h", "/usr/bin/osascript -e 'return 1'"):  # (harmless even if they ran)
            p = self.sandboxed("/bin/sh", "-c", cmd)
            self.assertNotEqual(p.returncode, 0, cmd)
            self.assertIn("not permitted", p.stderr, cmd)

    def test_temporary_files_work(self):
        self.assertEqual(self.sandboxed("/bin/sh", "-c", 'f=$(mktemp) && echo x > "$f" && rm "$f"').returncode, 0)

    def test_passes_arguments_and_exit_code_through(self):
        p = self.sandboxed("/bin/sh", "-c", 'echo "$1|$2"; exit 3', "sh", "a b", "c")
        self.assertEqual((p.returncode, p.stdout), (3, "a b|c\n"))

    def test_says_whether_it_is_on(self):
        self.assertIn("sandbox: on", self.sandboxed("/usr/bin/true").stderr)
        p = self.sandboxed("/bin/cat", str(self.secret), RECLAIMER_NO_SANDBOX="1")  # (troubleshooting only)
        self.assertIn("sandbox: off", p.stderr)
        self.assertEqual(p.stdout, "private")

    def test_rumble_bridge_injected_only_for_wine_when_x86_64(self):
        wine_bin = self.home / "wine" / "wine"
        wineserver = self.home / "wine" / "wineserver"
        wine_c = (
            '#include <stdio.h>\n'
            '#include <stdlib.h>\n'
            'int main() { printf("insert=%s\\n", getenv("DYLD_INSERT_LIBRARIES") ? getenv("DYLD_INSERT_LIBRARIES") : ""); return 0; }\n'
        )
        subprocess.run(["clang", "-arch", "x86_64", "-x", "c", "-", "-o", str(wine_bin)], input=wine_c, text=True, check=True)
        subprocess.run(["clang", "-arch", "x86_64", "-x", "c", "-", "-o", str(wineserver)], input=wine_c, text=True, check=True)

        lib_dir = self.home / "wine" / "Wine Staging.app" / "Contents" / "Resources" / "wine" / "lib"
        lib_dir.mkdir(parents=True, exist_ok=True)
        bridge = lib_dir / "librumble_bridge.dylib"
        sdl_lib = lib_dir / "libSDL2-2.0.0.dylib"

        # 1. Without dylib: no insertion (both no-sandbox and sandbox)
        p = self.sandboxed(str(wine_bin), RECLAIMER_NO_SANDBOX="1")
        self.assertEqual(p.stdout.strip(), "insert=")
        p = self.sandboxed(str(wine_bin))
        self.assertEqual(p.stdout.strip(), "insert=")

        # 2. With matching architecture (x86_64) but missing SDL2 library: not inserted
        subprocess.run(["clang", "-arch", "x86_64", "-dynamiclib", "-x", "c", "/dev/null", "-o", str(bridge)], check=True)
        p = self.sandboxed(str(wine_bin), RECLAIMER_NO_SANDBOX="1")
        self.assertEqual(p.stdout.strip(), "insert=")
        p = self.sandboxed(str(wine_bin))
        self.assertEqual(p.stdout.strip(), "insert=")

        # Create SDL2 library next to bridge
        sdl_lib.touch()

        # 3. With wrong architecture (arm64): not inserted (prevents dyld abort)
        subprocess.run(["clang", "-arch", "arm64", "-dynamiclib", "-x", "c", "/dev/null", "-o", str(bridge)], check=True)
        p = self.sandboxed(str(wine_bin), RECLAIMER_NO_SANDBOX="1")
        self.assertEqual(p.stdout.strip(), "insert=")
        p = self.sandboxed(str(wine_bin))
        self.assertEqual(p.stdout.strip(), "insert=")

        # 4. With matching architecture (x86_64) and SDL2 library present: inserted for wine
        subprocess.run(["clang", "-arch", "x86_64", "-dynamiclib", "-x", "c", "/dev/null", "-o", str(bridge)], check=True)
        p = self.sandboxed(str(wine_bin), RECLAIMER_NO_SANDBOX="1")
        self.assertEqual(p.stdout.strip(), f"insert={bridge}")
        p = self.sandboxed(str(wine_bin))
        self.assertEqual(p.stdout.strip(), f"insert={bridge}")

        # 5. Not injected when binary is wineserver (even with x86_64 bridge)
        p = self.sandboxed(str(wineserver), RECLAIMER_NO_SANDBOX="1")
        self.assertEqual(p.stdout.strip(), "insert=")
        p = self.sandboxed(str(wineserver))
        self.assertEqual(p.stdout.strip(), "insert=")

        # 6. Caller has an arm64 dylib in environment (simulating ~/.zshenv): stripped by unset, only x86_64 bridge is injected
        shim = self.home / "arm64_shim.dylib"
        subprocess.run(["clang", "-arch", "arm64", "-dynamiclib", "-x", "c", "/dev/null", "-o", str(shim)], check=True)
        p = self.sandboxed(str(wine_bin), RECLAIMER_NO_SANDBOX="1", DYLD_INSERT_LIBRARIES=str(shim))
        self.assertEqual(p.stdout.strip(), f"insert={bridge}")
        p = self.sandboxed(str(wine_bin), DYLD_INSERT_LIBRARIES=str(shim))
        self.assertEqual(p.stdout.strip(), f"insert={bridge}")


if __name__ == "__main__":
    unittest.main()
