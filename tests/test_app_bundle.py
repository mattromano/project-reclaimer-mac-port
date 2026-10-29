"""The installed app bundle (scripts/make_app.sh) and the network task's address ranges.

make_app.sh builds into a throwaway apps folder (RECLAIMER_APPS_DIR), never ~/Applications.
Run: /usr/bin/python3 -I -m unittest discover -s tests
"""
import os
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
LSREGISTER = ("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/"
              "lsregister")


class AppBundleTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        (self.tmp / "home" / "tools").mkdir(parents=True)
        shutil.copy(REPO / "launcher" / "ProjectReclaimer", self.tmp / "home" / "tools" / "ProjectReclaimer")
        self.app = self.tmp / "apps" / "Project Reclaimer.app"

    def tearDown(self):
        subprocess.run([LSREGISTER, "-u", str(self.app)], capture_output=True)
        shutil.rmtree(self.tmp)

    def test_app_asks_for_the_microphone_for_voice_chat(self):
        # without a usage description macOS never prompts: the game (started by the app) silently gets silence
        env = dict(os.environ, RECLAIMER_HOME=str(self.tmp / "home"), RECLAIMER_APPS_DIR=str(self.tmp / "apps"))
        env.pop("RECLAIMER_APP_PATH", None)
        subprocess.run(["/bin/bash", str(REPO / "scripts" / "make_app.sh"), "Project Reclaimer", "9.9.9"], env=env,
                       check=True, capture_output=True, timeout=60)
        info = plistlib.loads((self.app / "Contents" / "Info.plist").read_bytes())
        self.assertIn("voice chat", info.get("NSMicrophoneUsageDescription", ""))
        self.assertEqual(subprocess.run(["codesign", "-v", str(self.app)], capture_output=True).returncode, 0)


class LoopbackRangesTest(unittest.TestCase):
    def test_network_task_covers_the_ranges_releases_bind(self):
        # 127.0.1.N/127.0.2.N: the client's slot N ("Local client slot N: transport 127.0.1.N, native bind 127.0.2.N",
        # 0.9.8 to 0.9.23). 127.3.1.x/127.3.2.x: the native UDP bind, which moves between releases; 0.9.13 bound
        # 127.3.2.124 and every join was refused until that range was added (GitHub issue #3). No release from 0.9.8
        # on binds anything in 127.0.0.x but 127.0.0.1, which macOS has, so that range's 253 aliases are gone.
        text = (REPO / "scripts" / "reclaimer-loopback.sh").read_text()
        prefixes = text.split("for p in ", 1)[1].split("; do", 1)[0].split()
        self.assertEqual(prefixes, ["127.0.1", "127.0.2", "127.3.1", "127.3.2"])


if __name__ == "__main__":
    unittest.main()
