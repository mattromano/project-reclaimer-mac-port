#!/usr/bin/env python3
"""Fetch Steam Workshop mods for Project Reclaimer under Wine, without the Steam client.

Watches Reclaimer's client log for mods it can't get from Steam Workshop (there is no Steam client under Wine):
"Mod <title> not downloaded: ... Workshop" (Workshop-only mods), and "Workshop for <title> unavailable ... using the
server" (the game falls back to downloading from the game servers, which cap mod sharing at ~2.5 MB/s each).
Resolves the Workshop item ID, downloads it with DepotDownloader (saved Steam login, Steam's CDN) into Steam's
Workshop folder inside the Wine prefix, and posts a macOS notification. The player then presses Try Again, or
leaves and rejoins to stop the slower server download.

Usage: workshop_helper.py watch | get <workshop id or title>... | setup
"""
import json
import os
import re
import subprocess
import queue
import sys
import threading
import time
import urllib.parse
import urllib.request
from difflib import SequenceMatcher
from pathlib import Path

HOME = Path.home()
BASE = Path(os.environ.get("RECLAIMER_HOME", HOME / "Games" / "ProjectReclaimer"))
LOG = Path(os.environ.get("RECLAIMER_LOG", BASE / "logs" / "client.log"))
ACCOUNT_FILE = BASE / "steam-account"
DEPOT = BASE / "tools" / "DepotDownloader"
WORKSHOP = (BASE / "prefix-wine" / "drive_c" / "Program Files (x86)" / "Steam" / "steamapps" / "workshop"
            / "content" / "976730")
# each variant's Reclaimer profile lives in its own prefix (the installer unlinks Documents from ~/Documents)
PROFILES = [d / "Documents" / "My Games" / "Project Reclaimer"
            for d in (BASE / "prefix-wine" / "drive_c" / "users").glob("*")] + [
            d / "Documents" / "My Games" / "Project Reclaimer"
            for d in (BASE / "prefix-metal" / "drive_c" / "users").glob("*")]
GAME_PROCESS = r"project-reclaimer-v[0-9.]+\.exe game-client"
APP_ID = "976730"
FAILED = re.compile(r"^Mod (.+?) not downloaded: .*Workshop")
FALLBACK = re.compile(r"^Workshop for (.+?) unavailable: .*using the server")
UA = {"User-Agent": "Mozilla/5.0"}


def log(msg):
    print(time.strftime("%Y-%m-%d %H:%M:%S"), msg, flush=True)


def applescript_str(text):
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def notify(text, title="Project Reclaimer mods"):
    log(text)
    script = f"display notification {applescript_str(text)} with title {applescript_str(title)}"
    subprocess.run(["osascript", "-e", script], check=False)


def account():
    if ACCOUNT_FILE.exists():
        name = ACCOUNT_FILE.read_text().strip()
        if name:
            return name
    return setup()


def setup():
    script = ('text returned of (display dialog "Steam account name (the one you sign in with) '
              'for downloading Workshop mods:" default answer "" with title "Project Reclaimer")')
    out = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    name = out.stdout.strip()
    if not re.fullmatch(r"[A-Za-z0-9_]{2,64}", name):
        return None
    ACCOUNT_FILE.write_text(name + "\n")
    return name


def workshop_details(ids):
    data = {"itemcount": str(len(ids))}
    data.update({f"publishedfileids[{i}]": str(x) for i, x in enumerate(ids)})
    req = urllib.request.Request(
        "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/",
        data=urllib.parse.urlencode(data).encode(), headers=UA)
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)["response"].get("publishedfiledetails", [])


def id_from_modinfo(title):
    """Workshop ID from a ModInfo.json Reclaimer already fetched for this title, if any."""
    for info in (i for p in PROFILES for i in (p / "Mods").glob("**/ModInfo.json")):
        try:
            d = json.loads(info.read_text(encoding="utf-8-sig"))
        except (OSError, ValueError):
            continue
        if d.get("Title", {}).get("Neutral", "").strip().lower() == title.lower():
            wid = d.get("ModIdentifier", {}).get("HostedModIds", {}).get("SteamWorkshopId")
            if wid:
                return str(wid)
    return None


def id_from_search(title):
    """Best Workshop title match for MCC; tolerates suffixes like ' - Beta'."""
    base = re.sub(r"\s*[-(\[].*$", "", title).strip() or title
    url = ("https://steamcommunity.com/workshop/browse/?appid=" + APP_ID
           + "&searchtext=" + urllib.parse.quote(base) + "&browsesort=textsearch")
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=30) as r:
        ids = sorted(set(re.findall(r"filedetails/\?id=(\d+)", r.read().decode("utf-8", "replace"))))
    if not ids:
        return None
    best, score = None, 0.0
    for f in workshop_details(ids[:20]):
        t = (f.get("title") or "").strip()
        s = max(SequenceMatcher(None, t.lower(), title.lower()).ratio(),
                SequenceMatcher(None, t.lower(), base.lower()).ratio())
        if s > score:
            best, score = f["publishedfileid"], s
    return best if score >= 0.6 else None


def resolve(item):
    if item.isdigit():
        return item
    return id_from_modinfo(item) or id_from_search(item)


DONE = ".reclaimer-complete"  # written only after DepotDownloader finishes the whole item


def installed(wid):
    return (WORKSHOP / wid / DONE).exists()


def download(wid, label, ready_hint="Press Try Again in the game."):
    name = account()
    if not name:
        notify("No Steam account name set; mod download skipped.")
        return False
    dest = WORKSHOP / wid
    dest.mkdir(parents=True, exist_ok=True)
    notify(f"Downloading {label} from Steam Workshop...")
    cmd = [str(DEPOT), "-app", APP_ID, "-pubfile", wid, "-username", name,
           "-remember-password", "-dir", str(dest)]
    # stdin closed: if the saved login expired DepotDownloader fails instead of waiting for a password
    p = subprocess.run(cmd, stdin=subprocess.DEVNULL, capture_output=True, text=True)
    if p.returncode == 0 and (dest / "ModInfo.json").exists():
        (dest / DONE).write_text(time.strftime("%Y-%m-%d %H:%M:%S\n"))
        notify(f"{label} is ready. {ready_hint}")
        return True
    if re.search(r"password|login|logon|auth", p.stdout + p.stderr, re.I):
        notify("Steam login expired. Opening Terminal to sign in with a QR code.")
        relogin(name)
    else:
        notify(f"Could not download {label}. See ~/Games/ProjectReclaimer/logs/workshop-helper.log")
    sys.stderr.write(p.stdout[-4000:] + p.stderr[-4000:])
    return False


def relogin(name):
    # no -username: DepotDownloader refuses it with -qr, and saves the QR login under the account's name anyway
    cmd = (f"{DEPOT} -app {APP_ID} -pubfile 2984061723 -manifest-only -qr -remember-password "
           f"-dir /tmp/reclaimer-login-check; exit")
    subprocess.run(["osascript", "-e", f'tell application "Terminal" to do script {json.dumps(cmd)}',
                    "-e", 'tell application "Terminal" to activate'], check=False)


def fetch(item, ready_hint="Press Try Again in the game."):
    wid = resolve(item)
    if not wid:
        notify(f"Could not find {item} on Steam Workshop.")
        return False
    if installed(wid):
        return True
    title = next((f.get("title") for f in workshop_details([wid]) if f.get("title")), item)
    return download(wid, title, ready_hint)


def fetcher(jobs):
    """One download at a time (DepotDownloader shares one saved login), off the log-watching loop."""
    while True:
        item, hint = jobs.get()
        try:
            fetch(item, hint)
        except Exception as e:  # keep going after network or parse errors
            notify(f"Could not download {item}: {e}")


def game_running():
    return subprocess.run(["pgrep", "-f", GAME_PROCESS], capture_output=True).returncode == 0


def watch():
    """Rescan the client log every 2 s until the game exits; fetch each failed Workshop mod once."""
    others = subprocess.run(["pgrep", "-f", "workshop_helper.py watch"], capture_output=True, text=True).stdout.split()
    if [p for p in others if p != str(os.getpid())]:
        log("another helper is already watching; exiting")
        return
    log("watching " + str(LOG))
    seen, pos, last_seen = set(), 0, time.time()
    jobs = queue.Queue()
    threading.Thread(target=fetcher, args=(jobs,), daemon=True).start()
    # keep going until the game has been gone for 60 s straight: one missed check (or Reclaimer restarting itself
    # after an update) used to stop the helper while the game was still running
    while time.time() - last_seen < 60:
        if game_running():
            last_seen = time.time()
        try:
            size = LOG.stat().st_size
            if size < pos:  # log was truncated by a new game launch
                pos = 0
            with LOG.open("rb") as f:
                f.seek(pos)
                chunk = f.read()
            pos += len(chunk) - len(chunk.rsplit(b"\n", 1)[-1])  # keep any partial last line for next pass
        except OSError:
            chunk = b""
        for line in chunk.decode("utf-8", "replace").splitlines():
            line = line.strip()
            m = FAILED.match(line)
            if m and m.group(1) not in seen:
                seen.add(m.group(1))
                log("game could not download Workshop mod: " + m.group(1))
                jobs.put((m.group(1), "Press Try Again in the game."))
                continue
            m = FALLBACK.match(line)
            if m and m.group(1) not in seen:
                seen.add(m.group(1))
                log("game is downloading Workshop mod from servers instead: " + m.group(1))
                jobs.put((m.group(1), "If the game is still downloading it, leave and rejoin to use this copy."))
        time.sleep(2)
    log("game exited; helper stopping")


def main(argv):
    if len(argv) < 2 or argv[1] not in ("watch", "get", "setup"):
        print(__doc__)
        return 2
    if argv[1] == "setup":
        return 0 if setup() else 1
    if argv[1] == "get":
        return 0 if all([fetch(x) for x in argv[2:]]) else 1
    watch()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
