#!/usr/bin/env python3
"""The launcher window's Tools menu and automatic fixes, one command per action.

  net-check          "ok" or "missing": are the local network addresses Reclaimer needs on lo0?
  net-fix            reinstall + restart the network startup task (one macOS password prompt)
  controller-check   "stuck" if macOS's game controller service is stuck (no app sees controllers until a restart)
  audio-check        where the Mac's sound goes, tab-separated: "ok <output>", "muted <output>", "virtual <output>"
                     or "headset <headphones> <output>" (the game keeps the output it starts with)
  crash-check        "crash: <plain explanation>" if the last game log shows a crash, else "ok"
  force-quit         stop the game, Wine and wineserver for this install (frozen windows Force Quit can't close)
  mods               JSON: downloaded Workshop mods with titles and sizes, plus free disk space
  remove-mod <id>    delete one downloaded mod (not while the game runs)
  report             zip the logs and versions (no Steam account name) to the Desktop: "ok <path>"
  reset-graphics     put back the tuned graphics settings
  forget-steam       forget the saved Steam account (the window then shows a QR code)
  games              JSON: Halo 3 and Halo 3: ODST (installed or not, size, folder), MCC's size and free disk space
  add-game <id>...   download games (halo3, odst) from the player's Steam copy (QR codes and progress as
                     workshop_helper game-download)
  repair-game <id>   re-check one installed game's files against Steam, the same way
  repair             the same for every installed game
  remove-game <id>   delete one game's files (MCC's shared files stay)
  uninstall          remove the app, the install folder and the network startup task
  server-version <host:port>   "<version> <name>" of the Project Reclaimer a server runs, or "unreachable"
  join <host:port>   join a server in the running game (hands it a join link, as a link in a browser would)

Each prints "ok" (or its result) last, or "error: <plain reason>". RECLAIMER_TOOLS_DRYRUN=1 prints admin commands
("dry-run admin: ...") instead of asking for the password, for tests.
"""
import importlib.util
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
import zipfile
from pathlib import Path

HOME = Path.home()
BASE = Path(os.environ.get("RECLAIMER_HOME", HOME / "Games" / "ProjectReclaimer"))
GAME = BASE / "game"
LOGS = BASE / "logs"
STEAMAPPS = BASE / "prefix-wine" / "drive_c" / "Program Files (x86)" / "Steam" / "steamapps"
WORKSHOP = STEAMAPPS / "workshop" / "content" / "976730"
MCC_DIR = STEAMAPPS / "common" / "Halo The Master Chief Collection"
APP = Path(os.environ.get("RECLAIMER_APP_PATH")
           or Path(os.environ.get("RECLAIMER_APPS_DIR", HOME / "Applications")) / "Project Reclaimer.app")
DESKTOP = Path(os.environ.get("RECLAIMER_DESKTOP", HOME / "Desktop"))
CLIENT_EXE = re.compile(r"^project-reclaimer-v[0-9.]+\.exe$")
GAME_PROCESS = os.environ.get("RECLAIMER_GAME_PROCESS", r"project-reclaimer-v[0-9.]+\.exe game-client")
DAEMON = "local.projectreclaimer.loopback"
DAEMON_PLIST = f"/Library/LaunchDaemons/{DAEMON}.plist"
INSTALLED_PLIST = Path(os.environ.get("RECLAIMER_TEST_DAEMON_PLIST", DAEMON_PLIST))  # (tests point it elsewhere)
DAEMON_DIR = "/Library/Application Support/ProjectReclaimer"
DRYRUN = os.environ.get("RECLAIMER_TOOLS_DRYRUN", "")  # "1": print admin commands; "cancel": as if cancelled


def loopback_prefixes():
    """The address ranges the installed reclaimer-loopback.sh adds (e.g. 127.0.2), so a new range is checked too."""
    try:
        text = (GAME / "reclaimer-loopback.sh").read_text()
        m = re.search(r"for p in ([0-9. ]+); do", text)
        if m:
            return m.group(1).split()
    except OSError:
        pass
    return ["127.0.0", "127.0.1", "127.0.2", "127.0.3", "127.3.1", "127.3.2", "127.3.3"]


# one sample address per range (127.0.0.1 is always there, so 127.0.0.2 stands for its range)
EXPECTED_ALIASES = [p + (".2" if p == "127.0.0" else ".1") for p in loopback_prefixes()]


def say(line):
    print(line, flush=True)


def as_admin(command, prompt):
    """Run a shell command as root behind macOS's own password dialog."""
    if DRYRUN:
        say("dry-run admin: " + command)
        return DRYRUN != "cancel"
    script = 'do shell script {} with prompt {} with administrator privileges'.format(
        json.dumps(command), json.dumps(prompt))
    return subprocess.run(["/usr/bin/osascript", "-e", script], capture_output=True).returncode == 0


def game_running():
    return subprocess.run(["pgrep", "-a", "-f", GAME_PROCESS], capture_output=True).returncode == 0


def helper():
    """workshop_helper.py from this install, for its Steam and Workshop functions."""
    if "workshop_helper" not in sys.modules:
        spec = importlib.util.spec_from_file_location("workshop_helper", GAME / "workshop_helper.py")
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        sys.modules["workshop_helper"] = mod
    return sys.modules["workshop_helper"]


def quoted(path):
    return "'" + str(path).replace("'", "'\\''") + "'"


# ---------------------------------------------------------------------------------------------------------------
def lo0():
    return subprocess.run(["/sbin/ifconfig", "lo0"], capture_output=True, text=True).stdout


def net_check():
    have = set(re.findall(r"inet (127\.\d+\.\d+\.\d+)", lo0()))
    return "ok" if all(a in have for a in EXPECTED_ALIASES) else "missing"


def net_fix():
    """Install the startup task's files again and restart it, which re-adds every address (as install.sh does)."""
    script, plist = GAME / "reclaimer-loopback.sh", GAME / f"{DAEMON}.plist"
    if not script.exists() or not plist.exists():
        return "error: This install is missing its network files. Open Project Reclaimer again to update it."
    command = (f"mkdir -p {quoted(DAEMON_DIR)} && "
               f"install -o root -g wheel -m 755 {quoted(script)} {quoted(DAEMON_DIR + '/reclaimer-loopback.sh')} && "
               f"install -o root -g wheel -m 644 {quoted(plist)} {DAEMON_PLIST} && "
               f"{{ launchctl bootout system/{DAEMON} 2>/dev/null; true; }} && "
               f"launchctl bootstrap system {DAEMON_PLIST}")
    if not as_admin(command, "Project Reclaimer is fixing its network settings."):
        return "error: The network setup wasn't fixed (the password box was cancelled)."
    if DRYRUN:
        return "ok"
    for _ in range(20):  # the task adds ~1,300 addresses; give it a moment
        if net_check() == "ok":
            return "ok"
        time.sleep(1)
    return "error: The network setup is still incomplete. Restart your Mac, then open Project Reclaimer again."


def gamecontrollerd_state():
    """The process state of macOS's game controller service (e.g. "Ss"), or None when it isn't running."""
    ps = subprocess.run(["/bin/ps", "-axo", "stat=,comm="], capture_output=True, text=True).stdout
    for line in ps.splitlines():
        state, _, command = line.strip().partition(" ")
        if command.strip() == "/usr/libexec/gamecontrollerd":
            return state
    return None


def controller_check():
    """macOS's gamecontrollerd can get stuck in the kernel (state U, for good). Every app that looks for controllers
    then hangs, Wine's included, so the game never sees one although Bluetooth shows it connected. Only a restart
    clears it. A moment of waiting is normal, so it counts only if the service is stuck on every look."""
    for i in range(4):
        if i:
            time.sleep(0.5)
        if "U" not in (gamecontrollerd_state() or ""):
            return "ok"
    return "stuck"


def output_devices():
    """macOS's sound output devices: [(name, is the default output, transport)], or [] when it can't tell."""
    try:
        out = subprocess.run(["/usr/sbin/system_profiler", "SPAudioDataType", "-json"], capture_output=True,
                             text=True, timeout=20).stdout
        items = [d for group in json.loads(out).get("SPAudioDataType", []) for d in group.get("_items", [])]
    except (OSError, ValueError, subprocess.SubprocessError):
        return []
    return [(" ".join(str(d.get("_name", "")).split()), d.get("coreaudio_default_audio_output_device") == "spaudio_yes",
             d.get("coreaudio_device_transport", ""))
            for d in items if d.get("coreaudio_device_output")]


def output_muted():
    """Whether the Mac's sound output is muted, or None when it can't tell."""
    try:
        out = subprocess.run(["/usr/bin/osascript", "-e", "output muted of (get volume settings)"],
                             capture_output=True, text=True, timeout=20).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return None
    return {"true": True, "false": False}.get(out)


def audio_check():
    """Where the Mac's sound goes. The game (Wine's CoreAudio driver) keeps the output device it starts with, so
    headphones picked afterwards stay silent, and so does an output that is muted. Tab-separated, since device
    names have spaces: "ok <output>", "muted <output>", "virtual <output>" (a virtual device such as a meeting
    app's, with no speaker behind it) or "headset <headphones> <output>" (Bluetooth headphones connected but not
    the output). Plain "ok" when macOS can't tell: never keeps anyone from playing."""
    devices = output_devices()
    output = next((name for name, is_default, _ in devices if is_default), None)
    if not output:
        return "ok"
    if output_muted():
        return f"muted\t{output}"
    transport = next(t for name, is_default, t in devices if is_default)
    if "virtual" in transport:
        return f"virtual\t{output}"
    headset = next((name for name, is_default, t in devices if not is_default and "bluetooth" in t), None)
    if headset:
        return f"headset\t{headset}\t{output}"
    return f"ok\t{output}"


CRASHES = [
    ("stopped responding, so the game had to close",
     "The graphics card stopped responding, so the game closed. This happens now and then on heavy modded maps. "
     "Press Play to start again; if it keeps happening, lower Settings > Render resolution in the game."),
    ("device lost",
     "The graphics card stopped responding, so the game closed. Press Play to start again."),
    (" panicked at ",
     "Project Reclaimer hit an error and closed. Press Play to start again. If it keeps happening, use "
     "Tools > Send a report."),
]


def crash_check():
    try:
        text = (LOGS / "client-wine.log").read_text(errors="replace")[-200000:]
    except OSError:
        return "ok"
    for marker, message in CRASHES:
        if marker in text:
            return "crash: " + message
    return "ok"


def force_quit():
    # the game first, by force: a frozen game often comes with a stuck wineserver, which must not stop this
    subprocess.run(["pkill", "-9", "-a", "-f", GAME_PROCESS], capture_output=True)
    env = dict(os.environ, WINEPREFIX=str(BASE / "prefix-wine"))
    wineserver = BASE / "wine" / "Wine Staging.app" / "Contents" / "Resources" / "wine" / "bin" / "wineserver"
    if wineserver.exists():
        try:
            subprocess.run([str(wineserver), "-k"], env=env, capture_output=True, timeout=10)
        except subprocess.TimeoutExpired:
            pass
    subprocess.run(["pkill", "-9", "-f", str(BASE / "wine") + "/"], capture_output=True)
    for _ in range(10):
        if not game_running():
            return "ok"
        time.sleep(0.5)
    return "error: The game didn't stop. Restart your Mac (Apple menu > Restart) to close it."


def folder_size(path):
    return sum(f.stat().st_size for f in path.rglob("*") if f.is_file() and not f.is_symlink())


def mod_title(folder):
    try:
        info = json.loads((folder / "ModInfo.json").read_text(encoding="utf-8-sig"))
        return info.get("Title", {}).get("Neutral", "").strip() or folder.name
    except (OSError, ValueError, AttributeError):
        return folder.name


def mods():
    items = []
    if WORKSHOP.exists():
        for d in WORKSHOP.iterdir():
            if d.is_dir() and d.name.isdigit():
                items.append({"id": d.name, "title": mod_title(d), "bytes": folder_size(d)})
    items.sort(key=lambda m: -m["bytes"])
    return json.dumps({"free_bytes": shutil.disk_usage(BASE).free, "mods": items})


def remove_mod(wid):
    if not wid.isdigit():
        return "error: That isn't a Workshop item."
    if game_running():
        return "error: Quit the game first."
    folder = WORKSHOP / wid
    if not folder.is_dir():
        return "error: That mod isn't downloaded."
    shutil.rmtree(folder)
    (LOGS / "mods" / f"{wid}.json").unlink(missing_ok=True)
    try:
        helper().write_manifest()  # the game checks Steam's manifest to know what's installed
    except Exception as e:  # (offline: the manifest is rewritten on the next game)
        sys.stderr.write(f"could not update the Workshop manifest: {e}\n")
    return "ok"


def report():
    account = ""
    try:
        account = (BASE / "steam-account").read_text().strip()
    except OSError:
        pass

    def scrub(text):
        return text.replace(account, "<steam account>") if account else text
    summary = [f"Project Reclaimer Mac Port report, {time.strftime('%Y-%m-%d %H:%M')}"]
    for label, cmd in [("macOS", ["sw_vers", "-productVersion"]), ("Mac", ["sysctl", "-n", "machdep.cpu.brand_string"]),
                       ("Memory", ["sysctl", "-n", "hw.memsize"])]:
        value = subprocess.run(cmd, capture_output=True, text=True).stdout.strip()
        summary.append(f"{label}: " + (f"{int(value) / 2**30:.0f} GB" if label == "Memory" and value.isdigit() else value))
    try:
        summary.append("Mac port version: " + (BASE / "version").read_text().strip())
    except OSError:
        summary.append("Mac port version: 1.0 or older")
    summary.append("Game: " + ", ".join(sorted(p.name for p in GAME.glob("project-reclaimer-v*.exe"))))
    summary.append(f"Free disk space: {shutil.disk_usage(BASE).free / 1e9:.0f} GB")
    summary.append("Network addresses: " + net_check())
    summary.append("Workshop mods: " + ", ".join(m["title"] for m in json.loads(mods())["mods"]))
    DESKTOP.mkdir(parents=True, exist_ok=True)
    path = DESKTOP / f"Project Reclaimer report {time.strftime('%Y-%m-%d %H.%M')}.zip"
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("summary.txt", scrub("\n".join(summary) + "\n"))
        for log in sorted(LOGS.glob("*.log")):
            z.writestr(f"logs/{log.name}", scrub(log.read_text(errors="replace")[-2_000_000:]))
    return f"ok {path}"


def reset_graphics():
    if game_running():  # (the game writes its settings when it quits)
        return "error: Quit the game first."
    p = subprocess.run([sys.executable, "-I", str(GAME / "presets.py"), "wine"], capture_output=True, text=True,
                       env=dict(os.environ, RECLAIMER_HOME=str(BASE)))
    return "ok" if p.returncode == 0 else "error: The graphics settings couldn't be changed."


def forget_steam():
    (BASE / "steam-account").unlink(missing_ok=True)
    return "ok"


# id: (title, folder in MCC_DIR, its depots). Each game's depots write only into its folder; MCC's shared files
# (BASE_DEPOT: MCC/, Data/, Engine/) come with either and stay when one is removed.
GAMES = {"halo3": ("Halo 3", "halo3", ["976738", "976739"]),  # Halo 3, its multiplayer
         "odst": ("Halo 3: ODST", "halo3odst", ["1064222"])}
GAME_DLL = {"halo3": "halo3/halo3.dll", "odst": "halo3odst/halo3odst.dll"}
BASE_DEPOT = "976731"
HALO3_REMOVED = BASE / "halo3-removed"  # (Halo 3 was removed in Tools on purpose: updates leave it be)


def game_installed(gid):
    return (MCC_DIR / GAME_DLL[gid]).is_file()


def download_games(ids):
    if game_running():
        return "error: Quit the game first."
    depots = [BASE_DEPOT] + [d for gid in ids for d in GAMES[gid][2]]
    return helper().game_download(str(MCC_DIR), depots)


def repair():
    """Check every installed game against Steam (Halo 3's depots when nothing is installed)."""
    return download_games([gid for gid in GAMES if game_installed(gid)] or ["halo3"])


def repair_game(gid):
    if gid not in GAMES:
        return "error: That isn't a game Project Reclaimer plays."
    if game_running():
        return "error: Quit the game first."
    if not game_installed(gid):
        return f"error: {GAMES[gid][0]} isn't installed. Add it first."
    return download_games([gid])


def add_games(ids):
    if not ids or any(gid not in GAMES for gid in ids):
        return "error: That isn't a game Project Reclaimer plays."
    result = download_games(ids)
    if result == "ok" and "halo3" in ids:
        HALO3_REMOVED.unlink(missing_ok=True)
    return result


def games():
    items = []
    for gid, (title, folder, _) in GAMES.items():
        path = MCC_DIR / folder
        items.append({"id": gid, "title": title, "installed": game_installed(gid), "path": str(path),
                      "bytes": folder_size(path) if path.is_dir() else 0})  # (what Remove frees)
    return json.dumps({"free_bytes": shutil.disk_usage(BASE).free, "games": items,
                       "mcc_bytes": folder_size(MCC_DIR) if MCC_DIR.is_dir() else 0})


def remove_game(gid):
    if gid not in GAMES:
        return "error: That isn't a game Project Reclaimer plays."
    title, folder, depots = GAMES[gid]
    if game_running():
        return "error: Quit the game first."
    if not (MCC_DIR / folder).is_dir():
        return f"error: {title} isn't installed."
    if gid == "halo3":
        HALO3_REMOVED.write_text("")
    shutil.rmtree(MCC_DIR / folder)
    # DepotDownloader's record of the depots, so adding the game again downloads it all
    for depot in depots:
        for f in (MCC_DIR / ".DepotDownloader").glob(depot + "_*.manifest*"):
            f.unlink(missing_ok=True)
    return "ok"


ADDRESS = re.compile(r"[A-Za-z0-9.-]+:\d{1,5}")


def game_env():
    """Wine settings as run.sh uses them, for asking the game something without opening it."""
    return dict(os.environ, WINEPREFIX=str(BASE / "prefix-wine"), WINEDEBUG="-all", MVK_CONFIG_LOG_LEVEL="0",
                WINEDLLOVERRIDES="opengl32=n,b;xaudio2_9=d;d3d11,d3d10core=n,b")


WINE = BASE / "wine" / "Wine Staging.app" / "Contents" / "Resources" / "wine" / "bin" / "wine"


def game_exe():
    """(folder, exe name) the game starts from: the chosen older version, else the newest (as run.sh decides)."""
    try:
        chosen = (GAME / "chosen-version").read_text().strip()
    except OSError:
        chosen = ""
    if chosen and (GAME / "versions" / f"project-reclaimer-v{chosen}.exe").exists():
        return GAME / "versions", f"project-reclaimer-v{chosen}.exe"
    exes = [e for e in GAME.glob("project-reclaimer-v*.exe") if CLIENT_EXE.match(e.name)]
    if not exes:
        return None, None
    newest = max(exes, key=lambda p: [int(x) for x in re.findall(r"\d+", p.name)])
    return GAME, newest.name


def server_version(address):
    if not ADDRESS.fullmatch(address):
        return "error: That isn't a server address."
    folder, exe = game_exe()
    if not exe:
        return "error: Project Reclaimer isn't installed."
    try:
        p = subprocess.run([str(WINE), exe, "server-status", address], cwd=folder, env=game_env(),
                           capture_output=True, text=True, timeout=40)
    except subprocess.TimeoutExpired:
        return "unreachable"
    text = p.stdout
    start = text.find("{")
    try:
        info = json.loads(text[start:text.rindex("}") + 1]) if start >= 0 else {}
    except ValueError:
        info = {}
    version = str(info.get("version") or "")
    if not re.fullmatch(r"\d+(\.\d+){1,3}", version):
        return "unreachable"
    return f"{version} {info.get('name') or address}".strip()


def join(address):
    if not ADDRESS.fullmatch(address):
        return "error: That isn't a server address."
    folder, exe = game_exe()
    if not exe:
        return "error: Project Reclaimer isn't installed."
    # a second start with only the link hands it to the running game and exits (other arguments make it ignore it)
    subprocess.Popen([str(WINE), exe, f"reclaimer://join?server={address}"], cwd=folder, env=game_env(),
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     start_new_session=True)
    return "ok"


def uninstall():
    if not (BASE / "game").is_dir() or not (BASE / "prefix-wine").is_dir():
        return f"error: {BASE} doesn't look like a Project Reclaimer install, so nothing was removed."
    stopped = force_quit()
    if stopped != "ok":
        return stopped  # (nothing deleted while the game still runs)
    subprocess.run(["pkill", "-f", str(GAME / "workshop_helper.py")], capture_output=True)  # (only this install's)
    shutil.rmtree(APP, ignore_errors=True)
    shutil.rmtree(APP.with_name("Project Reclaimer Metal.app"), ignore_errors=True)  # (from early versions)
    shutil.rmtree(BASE, ignore_errors=True)
    if not os.environ.get("RECLAIMER_KEEP_NETWORK") and INSTALLED_PLIST.exists():
        removed = as_admin(f"launchctl bootout system/{DAEMON} 2>/dev/null; rm -f {DAEMON_PLIST}; "
                           f"rm -rf {quoted(DAEMON_DIR)}", "Project Reclaimer is removing its network setting.")
        if not removed:
            return "ok network-kept"  # (harmless: extra local addresses that nothing else uses)
    return "ok"


COMMANDS = {"net-check": net_check, "net-fix": net_fix, "controller-check": controller_check,
            "audio-check": audio_check, "crash-check": crash_check, "force-quit": force_quit, "mods": mods,
            "report": report, "reset-graphics": reset_graphics, "forget-steam": forget_steam, "repair": repair,
            "games": games, "uninstall": uninstall}


def main(argv):
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(1))
    if len(argv) == 3 and argv[1] == "remove-mod":
        result = remove_mod(argv[2])
    elif len(argv) == 3 and argv[1] == "remove-game":
        result = remove_game(argv[2])
    elif len(argv) == 3 and argv[1] == "repair-game":
        result = repair_game(argv[2])
    elif len(argv) >= 3 and argv[1] == "add-game":
        result = add_games(argv[2:])
    elif len(argv) == 3 and argv[1] == "server-version":
        result = server_version(argv[2])
    elif len(argv) == 3 and argv[1] == "join":
        result = join(argv[2])
    elif len(argv) == 2 and argv[1] == "net-check":
        result = net_check()
        for _ in range(8):  # right after login the startup task may still be adding its ~1,300 addresses
            if result == "ok":
                break
            time.sleep(1)
            result = net_check()
    elif len(argv) == 2 and argv[1] in COMMANDS:
        result = COMMANDS[argv[1]]()
    else:
        print(__doc__)
        return 2
    say(result)
    return 1 if result.startswith("error: ") else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
