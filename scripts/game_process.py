#!/usr/bin/env python3
"""Which running processes are this installation's game.

A bare `pgrep -f <game command line>` is system-wide: another checkout, another test run or another player's copy
matches it too, so two suites running at once each saw the other's fake game. The launcher starts the game from the
install's game folder (run.sh cds to game/, or game/versions/ for an older release, then execs Wine), so a process
belongs to this installation when its working directory is inside it.

tools.py and updater.py both load this file by its exact path (they run as `/usr/bin/python3 -I`, which leaves their
own folder off sys.path), so the rule cannot drift between them.
"""
import subprocess
from pathlib import Path


def pids(pattern, root):
    """This installation's game processes whose command line matches `pattern` (a pgrep -f pattern)."""
    # -a: include the caller's ancestors, which pgrep leaves out by default (a game the caller was started by)
    found = subprocess.run(["pgrep", "-a", "-f", pattern], capture_output=True, text=True).stdout.split()
    root = Path(root).resolve()
    return [pid for pid in found if _inside(_cwd(pid), root)]


def running(pattern, root):
    """Whether this installation's game is running."""
    return bool(pids(pattern, root))


def _cwd(pid):
    """The process's working directory, or None if it has exited meanwhile (or isn't this user's to inspect)."""
    out = subprocess.run(["/usr/sbin/lsof", "-a", "-p", pid, "-d", "cwd", "-Fn"],
                         capture_output=True, text=True).stdout
    for line in out.splitlines():
        if line.startswith("n"):  # (lsof prints "p<pid>", "fcwd", "n<path>")
            return Path(line[1:]).resolve()
    return None


def _inside(cwd, root):
    return cwd is not None and (cwd == root or root in cwd.parents)
