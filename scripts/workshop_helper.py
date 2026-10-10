#!/usr/bin/env python3
"""Fetch Steam Workshop mods for Project Reclaimer under Wine, without the Steam client.

Watches Reclaimer's client log for mods it can't get from Steam Workshop (there is no Steam client under Wine):
"Mod <title> not downloaded: ... Workshop" (Workshop-only mods), and "Workshop for <title> unavailable ... using the
server" (the game falls back to downloading from the game servers, which cap mod sharing at ~2.5 MB/s each).
Resolves the Workshop item ID, downloads it with DepotDownloader (saved Steam login, Steam's CDN) into Steam's
Workshop folder inside the Wine prefix, records it in Steam's Workshop manifest (appworkshop_976730.acf, which the
game checks and only the Steam client normally writes), and posts a macOS notification. The player then presses
Try Again, or leaves and rejoins to stop the slower server download. Mods updated on Workshop are downloaded again.
Each mod's progress goes to logs/mods/<id>.json, which the launcher window shows.

Steam sign-in (used by the launcher before the game starts; prints one result line for it to read):
  login-check   "ok <account>", "need-login" or "offline": does the saved Steam login still work?
  login-qr      QR sign-in: "qr-begin", "qr: <row>"..., "qr-end" for each code DepotDownloader shows, then
                "ok <account>" (saved to steam-account) or "error: <reason>"

Usage: workshop_helper.py watch | get [--in-game] <workshop id or title>... | login-check | login-qr
"""
import fcntl
import json
import os
import re
import subprocess
import queue
import signal
import sys
import tempfile
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
STATUS_DIR = BASE / "logs" / "mods"
DEPOT = BASE / "tools" / "DepotDownloader"
WORKSHOP = (BASE / "prefix-wine" / "drive_c" / "Program Files (x86)" / "Steam" / "steamapps" / "workshop"
            / "content" / "976730")
# Reclaimer's profile lives in the prefix (the installer unlinks Documents from ~/Documents)
PROFILES = [d / "Documents" / "My Games" / "Project Reclaimer"
            for d in (BASE / "prefix-wine" / "drive_c" / "users").glob("*")]
GAME_PROCESS = r"project-reclaimer-v[0-9.]+\.exe game-client"
GAME_GRACE = 60  # seconds the game must be gone before the watching helper stops
APP_ID = "976730"
FAILED = re.compile(r"^Mod (.+?) not downloaded: .*Workshop")
FALLBACK = re.compile(r"^Workshop for (.+?) unavailable: .*using the server")
PROGRESS = re.compile(r"^\s*(\d+(?:\.\d+)?)% ")
# a small MCC Workshop item: fetching only its manifest is a quick test that the saved login works
CHECK_ITEM = "2984061723"
# DepotDownloader output when the saved login is missing (it asks for a password), expired or rejected
LOGIN_NEEDED = re.compile(r"Enter account password|Access token was rejected|InvalidPassword|AccountLogonDenied|"
                          r"TwoFactor|LogOn requires|authentication code", re.I)
OFFLINE = re.compile(r"Could not connect to Steam|Connection to Steam failed|ServiceUnavailable|TryAnotherCM", re.I)
QR_START = "Use the Steam Mobile App to sign in with this QR code:"
QR_SUCCESS = re.compile(r"login with -username (\S+) -remember-password")
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
    """Steam account name saved by login-qr (DepotDownloader keeps the login under exactly this name)."""
    try:
        return ACCOUNT_FILE.read_text().strip() or None
    except OSError:
        return None


def write_status(wid, **fields):
    """Merge fields into logs/mods/<wid>.json, the launcher window's view of this mod."""
    STATUS_DIR.mkdir(parents=True, exist_ok=True)
    path = STATUS_DIR / f"{wid}.json"
    try:
        status = json.loads(path.read_text())
    except (OSError, ValueError):
        status = {"id": wid}
    status.update(fields, time=time.time())
    # a temp file of our own, renamed over: the launcher never reads a half-written file, and the in-game helper
    # and a launcher download can both write without tripping over each other's temp file
    with tempfile.NamedTemporaryFile("w", dir=STATUS_DIR, prefix=f".{wid}.", suffix=".tmp", delete=False) as f:
        f.write(json.dumps(status))
    os.replace(f.name, path)


def stop_with_parent(proc):
    """Kill proc and exit once the process that started us (the launcher window) is gone, e.g. force-quit."""
    parent = os.getppid()

    def watch_parent():
        while os.getppid() == parent:
            time.sleep(1)
        proc.kill()
        os._exit(1)
    threading.Thread(target=watch_parent, daemon=True).start()


def login_check():
    """Log in with the saved login and stop as soon as Steam accepts it (a few seconds)."""
    name = account()
    if not name:
        return "need-login"
    cmd = [str(DEPOT), "-app", APP_ID, "-pubfile", CHECK_ITEM, "-manifest-only", "-username", name,
           "-remember-password", "-dir", str(BASE / "logs" / "login-check")]
    out = []
    # stdin closed: with no saved login DepotDownloader would otherwise wait for a password
    p = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    stop_with_parent(p)
    # DepotDownloader retries Steam's servers for minutes when it can't reach them; the window shouldn't wait that long
    timer = threading.Timer(float(os.environ.get("RECLAIMER_LOGIN_TIMEOUT", 45)), p.kill)
    timer.daemon = True
    timer.start()
    try:
        for line in p.stdout:
            out.append(line)
            if re.match(r"Got \d+ licenses", line):
                p.terminate()
                return f"ok {name}"
        p.wait(timeout=60)
    finally:
        timer.cancel()
        if p.poll() is None:
            p.kill()
    text = "".join(out)
    if p.returncode == 0:
        return f"ok {name}"
    if LOGIN_NEEDED.search(text):
        return "need-login"
    # unreachable, timed out, rate limited or crashed: a warning, not a reason to make a working login sign in again
    sys.stderr.write(text[-4000:])
    return "offline"


def login_qr():
    """QR sign-in, relaying each QR code DepotDownloader draws; saves the account name Steam reports."""
    cmd = [str(DEPOT), "-app", APP_ID, "-pubfile", CHECK_ITEM, "-manifest-only", "-qr", "-remember-password",
           "-dir", str(BASE / "logs" / "login-check")]
    p = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    stop_with_parent(p)
    qr, name, tail = None, None, []  # qr: rows of the code being relayed, None outside a code
    try:
        for raw in p.stdout:
            line = raw.rstrip("\n")
            # QRCoder rows: "██" per dark module, two spaces per light one, quiet zone included. The code is square,
            # so it ends after as many rows as it has modules: DepotDownloader then prints nothing until the scan
            if line and set(line) <= {"█", " "}:
                if qr is None:
                    qr = []
                    print("qr-begin", flush=True)
                qr.append(line)
                print("qr: " + line, flush=True)
                if len(qr) >= len(qr[0]) // 2:
                    print("qr-end", flush=True)
                    qr = None
                continue
            if qr is not None:  # a shorter code than expected; end it anyway
                print("qr-end", flush=True)
                qr = None
            if line.strip() and line != QR_START and "QR code has changed" not in line:
                tail = (tail + [line])[-20:]
            m = QR_SUCCESS.search(line)
            if m:
                name = m.group(1)
                ACCOUNT_FILE.write_text(name + "\n")
            if name and re.match(r"Got \d+ licenses", line):
                p.terminate()
                break
        if qr is not None:
            print("qr-end", flush=True)
        p.wait(timeout=60)
    finally:
        if p.poll() is None:
            p.kill()
    if name:
        return f"ok {name}"
    reason = tail[-1].strip() if tail else "sign-in did not finish"
    reason = re.sub(r"^Unhandled exception\. [\w.]+: ", "", reason)
    return "error: " + reason


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


# written only after DepotDownloader finishes the whole item; holds the Workshop version that was downloaded
DONE = ".reclaimer-complete"


def installed_version(wid):
    """{"timeupdated", "manifest"} of the downloaded copy, or None when the item isn't fully downloaded."""
    marker = WORKSHOP / wid / DONE
    if not marker.exists():
        return None
    try:
        v = json.loads(marker.read_text())
        if isinstance(v, dict) and "timeupdated" in v:
            return v
    except ValueError:
        pass
    return {}  # finished before versions were recorded


def record_version(wid, details):
    v = {"timeupdated": int(details.get("time_updated", 0)), "manifest": str(details.get("hcontent_file", "0"))}
    (WORKSHOP / wid / DONE).write_text(json.dumps(v) + "\n")
    return v


def up_to_date(wid, details):
    v = installed_version(wid)
    if v == {}:  # older marker: assume the copy matches what Steam has now, and remember that
        v = record_version(wid, details)
    return v is not None and v["timeupdated"] >= int(details.get("time_updated", 0))


ACF = WORKSHOP.parent.parent / f"appworkshop_{APP_ID}.acf"


def vdf(d, indent=0):
    tab = "\t" * indent
    out = ""
    for k, v in d.items():
        if isinstance(v, dict):
            out += f'{tab}"{k}"\n{tab}{{\n{vdf(v, indent + 1)}{tab}}}\n'
        else:
            out += f'{tab}"{k}"\t\t"{v}"\n'
    return out


def write_manifest():
    """Record every finished item in steamapps/workshop/appworkshop_976730.acf, as the Steam client would.

    Reclaimer only treats a Workshop mod as installed and current when this manifest lists it with the downloaded
    version (time updated, content manifest) matching Steam's latest; without the Steam client nothing writes it.
    An outdated copy is listed as such, so the game asks for it again and the helper downloads the update."""
    wids = sorted(d.name for d in WORKSHOP.iterdir() if d.is_dir() and (d / DONE).exists()) if WORKSHOP.exists() else []
    if not wids:
        return
    details = {f["publishedfileid"]: f for f in workshop_details(wids) if f.get("result") == 1}
    now = int(time.time())
    installed_items, item_details, total = {}, {}, 0
    for wid in wids:
        f = details.get(wid)
        if not f:
            continue
        size = sum(p.stat().st_size for p in (WORKSHOP / wid).rglob("*") if p.is_file() and ".DepotDownloader" not in p.parts and p.name != DONE)
        total += size
        latest_manifest, latest_updated = f.get("hcontent_file", "0"), f.get("time_updated", 0)
        v = installed_version(wid) or record_version(wid, f)
        manifest, updated = v["manifest"], v["timeupdated"]
        installed_items[wid] = {"size": size, "timeupdated": updated, "manifest": manifest}
        item_details[wid] = {"manifest": manifest, "timeupdated": updated, "timetouched": now, "subscribedby": "0",
                             "latest_timeupdated": latest_updated, "latest_manifest": latest_manifest}
    outdated = int(any(d["timeupdated"] < d["latest_timeupdated"] for d in item_details.values()))
    acf = {"AppWorkshop": {"appid": APP_ID, "SizeOnDisk": total, "NeedsUpdate": outdated, "NeedsDownload": 0,
                           "TimeLastUpdated": now, "TimeLastAppRan": now,
                           "WorkshopItemsInstalled": installed_items, "WorkshopItemDetails": item_details}}
    ACF.write_text(vdf(acf))


def download(wid, label, details, ready_hint="Press Try Again in the game."):
    """Download one item, with its status ending as ready, failed or login_needed whatever happens."""
    finished = False
    try:
        finished = _download(wid, label, details, ready_hint)
        return finished
    finally:
        try:
            state = json.loads((STATUS_DIR / f"{wid}.json").read_text()).get("state")
        except (OSError, ValueError):
            state = None
        if state == "downloading":  # an unexpected error: the window must not show it downloading forever
            write_status(wid, state="failed")


def _download(wid, label, details, ready_hint):
    size = int(details.get("file_size") or 0)
    write_status(wid, title=label, state="downloading", percent=0.0, bytes_total=size, hint=ready_hint)
    name = account()
    if not name:
        # the launcher window shows the QR sign-in when it sees this
        write_status(wid, state="login_needed")
        notify(f"Sign in to Steam in the Project Reclaimer window to download {label}.")
        return False
    dest = WORKSHOP / wid
    dest.mkdir(parents=True, exist_ok=True)
    (dest / DONE).unlink(missing_ok=True)  # an update in progress is not a finished copy
    notify(f"Downloading {label} from Steam Workshop...")
    cmd = [str(DEPOT), "-app", APP_ID, "-pubfile", wid, "-username", name,
           "-remember-password", "-dir", str(dest)]
    # stdin closed: if the saved login expired DepotDownloader fails instead of waiting for a password
    p = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    stop_on_exit(p)
    out, last = [], 0.0
    for line in p.stdout:
        out = (out + [line])[-200:]
        m = PROGRESS.match(line)
        if m and time.time() - last >= 1:  # DepotDownloader prints a line per file; the window polls every second
            write_status(wid, percent=min(float(m.group(1)), 100.0))
            last = time.time()
    p.wait()
    text = "".join(out)
    if p.returncode == 0 and (dest / "ModInfo.json").exists():
        record_version(wid, details)
        write_manifest()
        write_status(wid, state="ready", percent=100.0)
        notify(f"{label} is ready. {ready_hint}")
        return True
    sys.stderr.write(text[-4000:])
    if LOGIN_NEEDED.search(text):
        write_status(wid, state="login_needed")
        notify(f"Steam sign-in needed: open the Project Reclaimer window to download {label}.")
    else:
        write_status(wid, state="failed")
        notify(f"Could not download {label}. See ~/Games/ProjectReclaimer/logs/workshop-helper.log")
    return False


def stop_on_exit(proc):
    """If this helper is stopped (SIGTERM), stop its DepotDownloader too rather than leaving it running."""
    if threading.current_thread() is threading.main_thread():  # (only the main thread may set signal handlers)
        signal.signal(signal.SIGTERM, lambda *_: (proc.kill(), sys.exit(1)))


def fetch(item, ready_hint="Press Try Again in the game."):
    wid = resolve(item)
    if not wid:
        notify(f"Could not find {item} on Steam Workshop.")
        return False
    # one download per item: the in-game helper and a pasted link in the window may ask for the same mod
    STATUS_DIR.mkdir(parents=True, exist_ok=True)
    with open(STATUS_DIR / f".{wid}.lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)  # waits for the other download, then finds the item up to date
        return _fetch(wid, item, ready_hint)


def _fetch(wid, item, ready_hint):
    details = next(iter(workshop_details([wid])), {})
    title = details.get("title") or item
    if up_to_date(wid, details):
        write_manifest()
        write_status(wid, title=title, state="ready", percent=100.0, bytes_total=int(details.get("file_size") or 0),
                     hint=ready_hint)
        return True
    if installed_version(wid) is not None:
        log(f"{title} has an update on Steam Workshop")
    return download(wid, title, details, ready_hint)


def fetcher(jobs):
    """One download at a time (DepotDownloader shares one saved login), off the log-watching loop."""
    while True:
        item, hint = jobs.get()
        try:
            fetch(item, hint)
        except Exception as e:  # keep going after network or parse errors
            notify(f"Could not download {item}: {e}")
        finally:
            jobs.task_done()


def game_running():
    return subprocess.run(["pgrep", "-f", GAME_PROCESS], capture_output=True).returncode == 0


def watch():
    """Rescan the client log every 2 s until the game exits; fetch each failed Workshop mod once."""
    others = subprocess.run(["pgrep", "-f", "workshop_helper.py watch"], capture_output=True, text=True).stdout.split()
    if [p for p in others if p != str(os.getpid())]:
        log("another helper is already watching; exiting")
        return
    log("watching " + str(LOG))
    try:
        write_manifest()  # mods downloaded before the helper wrote Steam's manifest
    except Exception as e:
        log(f"could not update the Workshop manifest: {e}")
    seen, pos, last_seen = set(), 0, time.time()
    jobs = queue.Queue()
    threading.Thread(target=fetcher, args=(jobs,), daemon=True).start()
    # keep going until the game has been gone for 60 s straight: one missed check (or Reclaimer restarting itself
    # after an update) used to stop the helper while the game was still running
    while time.time() - last_seen < GAME_GRACE:
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
        time.sleep(min(2, GAME_GRACE))
    if jobs.unfinished_tasks:
        log("game exited; finishing mod downloads first")
    jobs.join()  # a download started in the game finishes, so the mod is ready next time
    log("game exited; helper stopping")


def main(argv):
    if len(argv) < 2 or argv[1] not in ("watch", "get", "login-check", "login-qr"):
        print(__doc__)
        return 2
    if argv[1] in ("login-check", "login-qr"):
        # the launcher stops a sign-in it no longer needs: exit through login_qr's cleanup, which stops DepotDownloader
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(1))
        result = login_check() if argv[1] == "login-check" else login_qr()
        print(result, flush=True)
        return 0 if result.startswith("ok ") or result == "need-login" or result == "offline" else 1
    if argv[1] == "get":
        in_game = "--in-game" in argv
        hint = "Ready: press Try Again in the game." if in_game else "Downloaded and ready to play."
        return 0 if all([fetch(x, hint) for x in argv[2:] if x != "--in-game"]) else 1
    watch()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
