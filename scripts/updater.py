#!/usr/bin/env python3
"""Update the Mac port and Project Reclaimer before the game starts (run by the launcher window).

  updater.py run    the Mac port (when GitHub has a newer VERSION, re-run its installer in update mode), then the game
  updater.py game   only the game: install the latest Project Reclaimer release if it isn't installed yet

Project Reclaimer's own in-game updater is turned off (run.sh sets RECLAIMER_UPDATE_URL=off): it overwrites its exe
in place and restarts itself outside the launcher. This installs each release as its own checksum-verified file
instead, and removes the older ones.

Prints one line per event for the launcher: "status: <text>", "progress: <0-100>", "relaunch" (the launcher itself
was replaced), and last "done: up to date|updated", "offline: <reason>" or "error: <reason>". Offline or failed
updates never stop the game from starting.
"""
import fcntl
import hashlib
import os
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from pathlib import Path

BASE = Path(os.environ.get("RECLAIMER_HOME", Path.home() / "Games" / "ProjectReclaimer"))
REPO = "mattromano/project-reclaimer-mac-port"
REPO_RAW = os.environ.get("RECLAIMER_REPO_RAW", f"https://raw.githubusercontent.com/{REPO}/main")
RELEASES = os.environ.get("RECLAIMER_RELEASES",
                          "https://github.com/ProjectReclaimer/project-reclaimer-releases/releases/latest/download")
GAME = BASE / "game"
CLIENT_EXE = re.compile(r"^project-reclaimer-v[0-9.]+\.exe$")
# the running game itself (as workshop_helper.py matches it), not any command that merely names the file
GAME_PROCESS = os.environ.get("RECLAIMER_GAME_PROCESS", r"project-reclaimer-v[0-9.]+\.exe game-client")  # (tests)
UA = {"User-Agent": "project-reclaimer-mac-port"}


class Offline(Exception):
    pass


def say(line):
    print(line, flush=True)


def fetch(url, timeout=20):
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=timeout) as r:
            return r.read()
    except (urllib.error.URLError, OSError) as e:
        raise Offline(str(getattr(e, "reason", e))) from e


def version_tuple(text):
    return tuple(int(x) for x in re.findall(r"\d+", text or "0")[:3]) or (0,)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def game_running():
    return subprocess.run(["pgrep", "-a", "-f", GAME_PROCESS], capture_output=True).returncode == 0  # (-a: see helper)


# ---------------------------------------------------------------------------------------------------------------
def pinned_repo_raw():
    """REPO_RAW at main's current commit, so VERSION, install.sh, the launcher and the scripts all come from one
    commit (GitHub caches raw files on main for minutes, so files fetched separately could mix two versions)."""
    if "RECLAIMER_REPO_RAW" in os.environ:
        return REPO_RAW
    try:
        req = urllib.request.Request(f"https://api.github.com/repos/{REPO}/commits/main",
                                     headers={**UA, "Accept": "application/vnd.github.sha"})
        with urllib.request.urlopen(req, timeout=15) as r:
            sha = r.read().decode().strip()
        if re.fullmatch(r"[0-9a-f]{40}", sha):
            return f"https://raw.githubusercontent.com/{REPO}/{sha}"
    except (urllib.error.URLError, OSError):
        pass  # (e.g. API rate limit) main is nearly always fine
    return REPO_RAW


def installed_port_version():
    try:
        return (BASE / "version").read_text().strip()
    except OSError:
        return "0"  # installed before versions were recorded


def update_port():
    """Returns "current", "updated" (installer ran; the launcher was rebuilt) or raises."""
    raw = pinned_repo_raw()
    latest = fetch(f"{raw}/VERSION").decode().strip()
    if version_tuple(latest) <= version_tuple(installed_port_version()):
        return "current"
    say(f"status: Updating the Mac port to {latest}…")
    with tempfile.TemporaryDirectory() as tmp:
        script = Path(tmp) / "install.sh"
        script.write_bytes(fetch(f"{raw}/install.sh"))
        env = dict(os.environ, RECLAIMER_HOME=str(BASE), RECLAIMER_REPO_RAW=raw, RECLAIMER_UPDATE="1",
                   RECLAIMER_EXPECT_VERSION=latest,
                   RECLAIMER_UPDATE_LOCKED="1")  # install.sh runs `updater.py game` under this run's lock
        p = subprocess.Popen(["/bin/bash", str(script)], env=env, stdin=subprocess.DEVNULL,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        tail = []
        steps = 0
        for line in p.stdout:
            line = re.sub(r"\x1b\[[0-9;]*m", "", line).rstrip()
            tail = (tail + [line])[-30:]
            if line.startswith("==> "):
                steps += 1
                say(f"progress: {min(95, steps * 7)}")  # the installer has ~13 steps
        p.wait()
    if p.returncode != 0:
        err = next((l for l in reversed(tail) if l.strip()), "installer failed")
        raise RuntimeError(re.sub(r"^Error: ", "", err.strip()))
    if installed_port_version() != latest:  # relaunching would only start the same update again
        raise RuntimeError(f"the update to {latest} didn't install; it will be tried again next time")
    return "updated"


def latest_release():
    sums = fetch(f"{RELEASES}/SHA256SUMS.txt").decode().replace("\r", "")
    for line in sums.splitlines():
        parts = line.split()
        if len(parts) == 2:
            name = parts[1].lstrip("*")
            if CLIENT_EXE.match(name):
                return name, parts[0].lower()
    raise RuntimeError("the latest Project Reclaimer release has no game client")


def update_game():
    """Returns "current", "updated" or "running" (left alone while the game runs), or raises."""
    exe, expected = latest_release()
    target = GAME / exe
    if target.exists() and sha256(target) == expected:
        remove_other_clients(exe)
        return "current"
    if game_running():
        return "running"
    version = re.search(r"v([0-9.]+)\.exe$", exe).group(1)
    say(f"status: Updating Project Reclaimer to {version}…")
    part = target.with_name(target.name + ".part")
    try:
        req = urllib.request.Request(f"{RELEASES}/{exe}", headers=UA)
        try:
            r = urllib.request.urlopen(req, timeout=30)
        except (urllib.error.URLError, OSError) as e:
            raise Offline(str(getattr(e, "reason", e))) from e
        with r, open(part, "wb") as f:
            total = int(r.headers.get("Content-Length") or 0)
            done, shown = 0, -1
            for block in iter(lambda: r.read(1 << 18), b""):
                f.write(block)
                done += len(block)
                pct = done * 100 // total if total else 0
                if pct != shown:
                    say(f"progress: {pct}")
                    shown = pct
        if sha256(part) != expected:
            raise RuntimeError("the Project Reclaimer download didn't match its checksum; kept the current version")
        part.replace(target)
    finally:
        part.unlink(missing_ok=True)
    remove_other_clients(exe)
    return "updated"


def remove_other_clients(exe):
    """run.sh starts the newest-named client, so only the verified one may stay (the dedicated server stays too)."""
    for old in GAME.glob("project-reclaimer-v*.exe"):
        if old.name != exe and CLIENT_EXE.match(old.name):
            old.unlink()


def main(argv):
    if len(argv) != 2 or argv[1] not in ("run", "game"):
        print(__doc__)
        return 2
    BASE.mkdir(parents=True, exist_ok=True)
    lock = open(BASE / ".update.lock", "w")  # one update at a time (e.g. the app opened twice)
    if not os.environ.get("RECLAIMER_UPDATE_LOCKED"):  # (set when run by install.sh inside a port update)
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            say("status: Waiting for another update to finish…")
            fcntl.flock(lock, fcntl.LOCK_EX)
    say("status: Checking for updates…")
    results, errors, offline = {}, [], None
    steps = [update_game] if argv[1] == "game" else [update_port, update_game]
    for step in steps:
        try:
            results[step.__name__] = step()
            sys.stderr.write(f"updater: {step.__name__}: {results[step.__name__]}\n")
        except Offline as e:
            sys.stderr.write(f"updater: {step.__name__}: can't connect: {e}\n")
            offline = offline or str(e)
        except Exception as e:  # report and carry on: a failed update never blocks the game
            sys.stderr.write(f"updater: {step.__name__}: {e}\n")
            errors.append(str(e))
    if results.get("update_port") == "updated":
        say("relaunch")
    results = list(results.values())
    if errors:
        say(f"error: {errors[0]}")
        return 1
    if offline and "updated" not in results:  # (checks that could connect found nothing to do)
        say(f"offline: {offline}")
        return 0
    if "updated" in results:
        say("done: updated")
    elif "running" in results:
        say("done: skipped while the game is running")
    else:
        say("done: up to date")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
