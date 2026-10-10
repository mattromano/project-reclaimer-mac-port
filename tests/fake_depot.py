#!/usr/bin/python3 -I
"""Stand-in for DepotDownloader in tests: replays the script in $FAKE_DEPOT (JSON).

{"lines": [...], "rc": 0, "modinfo": true, "delay": 0.0, "sleep_after": 0.0, "args_log": "<file>"}
Lines are printed one by one (with "delay" seconds between them). With "modinfo", a ModInfo.json is created in the
-dir folder, as a finished Workshop download has. Each run's arguments are appended to "args_log" as JSON.
"""
import json
import os
import sys
import time
from pathlib import Path

spec = json.loads(Path(os.environ["FAKE_DEPOT"]).read_text())
args = sys.argv[1:]
if spec.get("args_log"):
    with open(spec["args_log"], "a") as f:
        f.write(json.dumps(args) + "\n")
for line in spec.get("lines", []):
    print(line, flush=True)
    time.sleep(spec.get("delay", 0))
if spec.get("modinfo") and "-dir" in args:
    d = Path(args[args.index("-dir") + 1])
    d.mkdir(parents=True, exist_ok=True)
    (d / "ModInfo.json").write_text("{}")
time.sleep(spec.get("sleep_after", 0))  # e.g. waiting for a QR scan
sys.exit(spec.get("rc", 0))
