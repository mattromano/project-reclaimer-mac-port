#!/usr/bin/env python3
"""Update the Mac port and Project Reclaimer before the game starts (run by the launcher window).

  updater.py run    the Mac port (when GitHub has a newer VERSION, re-run its installer in update mode), then the game
  updater.py game   only the game: install the latest Project Reclaimer release if it isn't installed yet
  updater.py versions        JSON: recent Project Reclaimer releases, which are downloaded, and the chosen one
  updater.py use <version>   play an older release (for servers that haven't updated yet): download and verify it
                             into game/versions/, and pause game updates; "use newest" goes back to the latest

Project Reclaimer's own in-game updater is turned off (run.sh sets RECLAIMER_UPDATE_URL=off): it overwrites its exe
in place and restarts itself outside the launcher. This installs each release as its own checksum-verified file
instead, and removes the older ones.

Prints one line per event for the launcher: "status: <text>", "progress: <0-100>", "relaunch" (the launcher itself
was replaced), and last "done: up to date|updated", "offline: <reason>" or "error: <reason>". Offline or failed
updates never stop the game from starting.
"""
import fcntl
import hashlib
import importlib.util
import json
import os
import re
import shutil
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
VERSIONS = GAME / "versions"          # older releases a player chose, each kept for switching back and forth
CHOSEN = GAME / "chosen-version"      # the older release to start instead of the newest (run.sh reads it)
RELEASES_API = os.environ.get("RECLAIMER_RELEASES_API", "https://api.github.com/repos/ProjectReclaimer/"
                              "project-reclaimer-releases/releases?per_page=12")
RELEASE_DOWNLOADS = os.environ.get("RECLAIMER_RELEASE_DOWNLOADS", "https://github.com/ProjectReclaimer/"
                                   "project-reclaimer-releases/releases/download")
MENU_DLLS = ("opengl32.dll", "libgallium_wgl.dll")  # Mesa, loaded from the exe's own folder
CLIENT_EXE = re.compile(r"^project-reclaimer-v[0-9.]+\.exe$")  # the game as installed here
# the game as a release names it: project-reclaimer-v0.9.17.exe, project-reclaimer-client-v0.9.18.exe from 0.9.18 on
RELEASE_CLIENT = re.compile(r"^project-reclaimer-(?:client-)?v([0-9.]+)\.exe$")
UA = {"User-Agent": "project-reclaimer-mac-port"}


class Offline(Exception):
    pass


def say(line):
    try:
        print(line, flush=True)
    except BrokenPipeError:
        # the window closed: finish the update anyway (stopping halfway left a half-updated install), quietly
        devnull = os.open(os.devnull, os.O_WRONLY)
        os.dup2(devnull, sys.stdout.fileno())
        os.close(devnull)


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


# game_process.py from this install: the one rule for which running processes are this installation's game.
# (game_process.py owns that rule and says why it is loaded by exact path.)
_spec = importlib.util.spec_from_file_location("game_process", Path(__file__).resolve().parent / "game_process.py")
game_process = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(game_process)


def game_running():
    return game_process.running(BASE)


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


def client_in(sums_url):
    """(download name, sha256, installed name) of the game client listed in a release's SHA256SUMS.txt. It's always
    installed as project-reclaimer-v<version>.exe, the name run.sh, Tools, the window and the mod helper know."""
    sums = fetch(sums_url).decode().replace("\r", "")
    for line in sums.splitlines():
        parts = line.split()
        if len(parts) == 2:
            name = parts[1].lstrip("*")
            m = RELEASE_CLIENT.match(name)
            if m:
                return name, parts[0].lower(), f"project-reclaimer-v{m.group(1)}.exe"
    raise RuntimeError("that Project Reclaimer release has no game client")


def latest_release():
    return client_in(f"{RELEASES}/SHA256SUMS.txt")


def download_verified(url, target, expected):
    """Download to target with progress lines, keeping it only if its SHA-256 matches."""
    part = target.with_name(target.name + ".part")
    try:
        try:
            r = urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=30)
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


def update_game():
    """Returns "current", "updated", "running" (left alone while the game runs) or "chosen" (the player picked an
    older release), or raises."""
    if CHOSEN.exists():
        return "chosen"
    download, expected, exe = latest_release()
    target = GAME / exe
    if target.exists() and sha256(target) == expected:
        remove_other_clients(exe)
        return "current"
    if game_running():
        return "running"
    version = re.search(r"v([0-9.]+)\.exe$", exe).group(1)
    say(f"status: Updating Project Reclaimer to {version}…")
    download_verified(f"{RELEASES}/{download}", target, expected)
    remove_other_clients(exe)
    return "updated"


def versions():
    """Recent releases for the window's version list (prereleases left out)."""
    try:
        listing = json.loads(fetch(RELEASES_API).decode())
    except ValueError as e:
        raise RuntimeError("the list of Project Reclaimer releases couldn't be read") from e
    chosen = CHOSEN.read_text().strip() if CHOSEN.exists() else None
    items = []
    for r in listing:
        if r.get("prerelease") or r.get("draft"):
            continue
        version = str(r.get("tag_name", "")).lstrip("v")
        if not re.fullmatch(r"\d+(\.\d+){1,3}", version):
            continue
        exe = f"project-reclaimer-v{version}.exe"
        items.append({"version": version, "date": str(r.get("published_at", ""))[:10],
                      "downloaded": (VERSIONS / exe).exists() or (GAME / exe).exists()})
    return json.dumps({"chosen": chosen, "versions": items})


def use(version):
    """Choose the release to play: an older one (downloaded once, then kept), or "newest"."""
    if version == "newest":
        CHOSEN.unlink(missing_ok=True)
        return update_game()
    if not re.fullmatch(r"\d+(\.\d+){1,3}", version):
        raise RuntimeError(f"{version} isn't a Project Reclaimer version")
    download, expected, exe = client_in(f"{RELEASE_DOWNLOADS}/v{version}/SHA256SUMS.txt")
    VERSIONS.mkdir(parents=True, exist_ok=True)
    target = VERSIONS / exe
    if not (target.exists() and sha256(target) == expected):
        say(f"status: Downloading Project Reclaimer {version}…")
        download_verified(f"{RELEASE_DOWNLOADS}/v{version}/{download}", target, expected)
    for dll in MENU_DLLS:  # the menu's graphics library, next to this exe too
        if (GAME / dll).exists() and not (VERSIONS / dll).exists():
            shutil.copy2(GAME / dll, VERSIONS / dll)
    CHOSEN.write_text(version + "\n")
    return "chosen"


def remove_other_clients(exe):
    """run.sh starts the newest-named client, so only the verified one may stay (the dedicated server stays too)."""
    for old in GAME.glob("project-reclaimer-v*.exe"):
        if old.name != exe and CLIENT_EXE.match(old.name):
            old.unlink()


def main(argv):
    if len(argv) == 2 and argv[1] == "versions":
        try:
            say(versions())
            return 0
        except Offline as e:
            say(f"offline: {e}")
            return 1
        except Exception as e:
            say(f"error: {e}")
            return 1
    if len(argv) == 3 and argv[1] == "use":
        try:
            result = use(argv[2])
        except Offline as e:
            say(f"error: Couldn't download it ({e}). Check your internet connection and try again.")
            return 1
        except Exception as e:
            say(f"error: {e}")
            return 1
        if result == "chosen":
            say(f"done: using {argv[2]}")
        else:
            say("done: updated" if result == "updated" else "done: up to date")
        return 0
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
    if argv[1] == "run":
        # an older version is for this session only (Tools, or the window's "switch and rejoin"): opening the app
        # again goes back to the newest, so nobody stays stuck on an old one
        CHOSEN.unlink(missing_ok=True)
    steps = [update_game] if argv[1] == "game" else [update_port, update_game]
    for step in steps:
        if step is update_game and results.get("update_port") == "updated":
            break  # the new install.sh just updated the game with the new updater.py; this one's code is the old one
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
    if "chosen" in results:
        say(f"done: using {CHOSEN.read_text().strip()}")
    elif "updated" in results:
        say("done: updated")
    elif "running" in results:
        say("done: skipped while the game is running")
    else:
        say("done: up to date")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
