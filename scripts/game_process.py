#!/usr/bin/env python3
"""Which running processes are this installation's game.

A bare `pgrep -f <game command line>` is system-wide: another checkout, another test run or another player's copy
matches it too, so two suites running at once each saw the other's fake game. The launcher starts the game from the
install's game folder (run.sh cds to game/, or game/versions/ for an older release, then execs Wine), so a process
belongs to this installation when its working directory is inside it. The install's identity is that folder - the
decision, not an implementation detail: a marker would have to be carried by the game itself.

The match pattern lives here too, with its RECLAIMER_GAME_PROCESS override, so every caller passes only the install:
tools.py (the check and Force Quit), updater.py (skip the update while playing) and workshop_helper.py (stop
watching once the game exits). The launcher window applies the same rule in Swift (launcher/LauncherCore.swift).

A match this installation will not claim is reported on stderr, one line per pid: the callers otherwise see only
"not running", and a working directory nobody expected would look like the game having stopped.

Those three load this file by its exact path, because they run as `/usr/bin/python3 -I`, which leaves their own
folder off sys.path (and adding it would let a file beside them stand in for a stdlib module; see presets.py).
"""
import os
import subprocess
import sys
from pathlib import Path

GAME_PROCESS = os.environ.get("RECLAIMER_GAME_PROCESS", r"project-reclaimer-v[0-9.]+\.exe game-client")  # (tests)


def pids(root):
    """This installation's game processes."""
    # -a: include the caller's ancestors, which pgrep leaves out by default (a game the caller was started by)
    out = subprocess.run(["pgrep", "-a", "-f", GAME_PROCESS], capture_output=True, text=True).stdout
    # A line is "<pid>" where pgrep prints only pids (BSD) and "<pid> <command line>" where it reports the command
    # line. Only the first field of each line is a pid: split() over the whole output made every argument of a
    # matching command line an lsof -p argument, so a number there could name another process of this installation.
    found = [parts[0] for parts in map(str.split, out.splitlines()) if parts]
    root = Path(root).resolve()
    mine = []
    for pid in found:
        cwd = _cwd(pid)
        if _inside(cwd, root):
            mine.append(pid)
        elif cwd is not None:
            # A match this installation will not claim: say so, because the caller only sees "not running" (the
            # updater would skip no update and the window would call the game ended) while the real cause is a
            # working directory nobody expected. Not for a process that exited between the match and the check.
            print(f"game process outside the install: {pid} {cwd}", file=sys.stderr)
    return mine


def running(root):
    """Whether this installation's game is running."""
    return bool(pids(root))


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
