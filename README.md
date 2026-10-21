# Project Reclaimer Mac Port

Play Halo 3 through [Project Reclaimer](https://projectreclaimer.dev) (community servers, Forge, Workshop mods) on an
Apple Silicon Mac. Project Reclaimer is Windows-only; this installs it under Wine with everything tuned for macOS,
and adds a **Project Reclaimer** app to your Mac.

- **Graphics:** Wine 11.18 + DXVK-macOS + MoltenVK 1.4.2 (DirectX 11 → Vulkan → Metal)
- **Defaults:** windowed at the largest size that fits your screen (1920×1080 on most Macs), Low quality, 60 fps cap
- **Measured on an M2 Max:** steady 60 fps; ~1.5 CPU cores and ~16% of the GPU's capacity at the menu, ~0.9 cores
  and ~24% of the GPU in a Slayer match on Valhalla; Big Team Battle on Hugegrass (40+ players, modded) playable

## Requirements

- Apple Silicon Mac (M1 or newer), macOS 14 Sonoma or newer, 16 GB RAM recommended
- **Halo: The Master Chief Collection on Steam**, plus the Steam app on your phone (to sign in with a QR code)
- ~45 GB free disk space (~54 GB with Halo 3: ODST)
- Your Mac's admin password once

## Install

1. Download [Project-Reclaimer-Mac-Port.dmg](https://github.com/mattromano/project-reclaimer-mac-port/releases/latest/download/Project-Reclaimer-Mac-Port.dmg)
   and open it.
2. Double-click **Project Reclaimer**. It isn't from the App Store or signed by a paid Apple developer account, so
   the first time macOS blocks it: click **Done**, open System Settings → Privacy & Security, and click
   **Open Anyway** (the disk image has a picture of this). You only do this once.
3. The window checks your Mac (Apple Silicon, macOS 14+, ~45 GB free, Apple's developer tools, which it helps you
   install if they're missing) and shows **Install**, with a checkbox to **also download Halo 3: ODST** (about 9 GB
   more; see [Halo 3: ODST](#halo-3-odst)). Then it:
   - downloads Wine, DXVK-macOS, MoltenVK, Mesa, DepotDownloader and the latest Project Reclaimer, checking every
     file against a known SHA-256 checksum;
   - shows a **QR code**: scan it with the Steam app on your phone. Only Halo 3 is downloaded, from your own Steam
     account (~35 GB), with a progress bar and the time left. Nothing is shared from anyone else's copy;
   - asks for your **Mac password** once, for a small startup task that enables the local network addresses
     Reclaimer uses (`127.0.0.x`–`127.0.3.x`, `127.3.1.x`–`127.3.3.x`; macOS only enables `127.0.0.1` by default);
   - puts **Project Reclaimer** in `~/Applications` and opens it. You can eject and delete the disk image.

If something fails, the window says what happened; **Try Again** picks up where it stopped. After this, the app keeps
itself, Project Reclaimer and your Workshop mods up to date every time you open it.

**Prefer Terminal?** This does the same install:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/mattromano/project-reclaimer-mac-port/main/install.sh)"
```

(`scripts/make_dmg.sh` builds the disk image; `scripts/make_launcher.sh` builds the app from `launcher/`.)

## Upgrading from 1.0

Had the first version (the one that asked for your Steam account name)? Quit the game, then open **Project
Reclaimer** from the new disk image: it offers a one-time **Upgrade** that keeps your Halo 3 files, mods and graphics
settings (no big download, a minute or two). From then on the app updates itself. If the window shows a QR code, scan
it with the Steam app: the old account-name login is gone. (Running the Terminal line above again works too.)

If you had moved the old app out of your home folder's Applications folder, delete that copy: the new one is in
`~/Applications`, and Spotlight finds it there.

## Playing

Open **Project Reclaimer** from Spotlight or Launchpad. A small window gets everything ready, then you press **Play**:

1. **Updates.** It installs any new version of this Mac port and of Project Reclaimer (each checksum-verified), then
   carries on. Offline? It skips this and you can still play. The game's own in-game updater is turned off: it
   replaced the game file in place and restarted the game outside the launcher, which broke things under Wine.
2. **Steam sign-in, for Workshop mods.** It checks that the saved Steam login still works. If it doesn't, a QR code
   appears right in the window: open the Steam app on your phone, tap the shield (Steam Guard), then
   **Scan a QR code**. The window moves on by itself. You can skip this, but mods then download slowly or not at all.
3. **Play.** While you play, the window lists Workshop mods being downloaded, with progress, and a notification
   tells you when each is ready: press **Try Again** in the game, or leave and rejoin if the game was still
   downloading it from the server. The game itself keeps saying "not downloaded… Start Steam" for these mods; the
   window explains that this is expected.

The window's **Problems joining or playing?** section explains the game messages players hit most (a server on an
older version, a server with an outdated mod, and so on) and has a **Show logs** button for sending you the logs.

Before Play, the window also checks the local network addresses the game needs (they can go missing after a restart
or a macOS update) and fixes them with one password prompt. If the game crashes, the window says what happened in
plain words and stays open for **Play again**.

**Tools** (the gear button) handles the rest without Terminal: **Force Quit** a frozen game; under **Installed
games**, add or remove Halo 3 and Halo 3: ODST, **Repair** either one's files against Steam, or open its folder; see **Mods and disk space** and remove mods, **Restore** the recommended graphics settings,
**Switch** Steam accounts, **Make Report** (a zip of the logs and what startup is doing on your Desktop, without
your Steam account name), and **Uninstall**.

**A server on an older Project Reclaimer?** Releases come out about twice a day, and a server only a day behind can't
be joined with the newest version. When a join fails, the window finds out which version the server runs (the game's
error says so, or the window asks the server) and offers **Switch to 0.9.x and rejoin**: the game restarts on that
version and joins the server by itself. The version downloads once (~45 MB, checksum-verified) and is kept; it lasts
until you close Project Reclaimer, so the next start is back on the newest. Tools → **Game version** does the same by
hand, with a list of recent releases.

Since Project Reclaimer 0.9.20, servers choose the on-foot camera; where they let players choose, **P** switches
between first and third person (bind a controller button in the game's Settings → Controller).

## Halo 3: ODST

Project Reclaimer 0.9.19 and newer play Halo 3: ODST's campaign and Firefight, solo, in co-op and on ODST servers,
once ODST's files are there. It's optional: tick **Halo 3: ODST** in the list of games when installing, or later open Tools
→ **Installed games** → **Add**. Either way, it downloads ODST (about 9 GB) from your own Steam copy of MCC, with the same QR
sign-in. Its **Repair** button checks ODST's files against Steam. Without it, joining an ODST game says to "Enable
Halo 3: ODST in Steam", which on a Mac means Tools → **Installed games** → **Add**. **Remove** there
deletes ODST's files again (about 9 GB back). Halo 3 can be removed the same way (about 13 GB back): Play then
turns into **Install Halo 3…**, which lists both games to download again, with ODST still ticked if it's there
(untick it to remove ODST too). In Terminal, run the install command with
`RECLAIMER_ODST=1 ` in front of it (this also adds ODST to an existing install).

Why mods need Steam: without the Steam client, the game downloads mods from the game servers, which cap sharing at
~2.5 MB/s each, or shows a "Start Steam…" error for Workshop-only mods. A helper next to the game fetches the same
mods from Steam's CDN instead (~40 MB/s measured: 1.6 GB in 37 s). Mods are 1–9 GB each. To get a mod before
joining a server, paste its Steam Workshop link into the window.

The first match builds a Forge cache (about a minute). Change graphics in the game's own Settings; updates keep them.
To put back the tuned defaults, run the install command with `RECLAIMER_RESET_GRAPHICS=1 ` in front of it.

## Troubleshooting

| Problem | Fix |
|---|---|
| "Could not join that server" on every server, especially after a Reclaimer update | A new release may use new local addresses. Quit the game and open Project Reclaimer again: the update installs the fix (it may ask for your Mac password). |
| Mods won't download / "Start Steam…" | Look at the Project Reclaimer window: if it shows a QR code, scan it with the Steam app. If it says a mod couldn't download, press Try Again in the game. |
| Game won't start right after a reboot | The window checks the network addresses before Play and fixes them (asks for your Mac password). |
| "Public join timed out" on one server | That server didn't answer: usually it runs an older Project Reclaimer ("This server runs an older version" on its card) or its port is closed. Pick another server; the server browser's filters can hide servers running another version. If **every** server times out, quit and reopen Project Reclaimer (it checks the network setup). |
| Stuck on "Synchronizing players" for minutes | Usually the server (its clock is stuck for everyone). Try another server. |
| "Graphics card stopped responding" | A GPU fault in the DirectX → Metal translation, mostly on heavy modded maps. Relaunch; lower Settings → render resolution if it repeats. |
| Controller connected in Bluetooth, but the game ignores it | Turn the controller on before pressing Play. If the window shows **Controller: Your Mac's game controller service is stuck**, restart the Mac: macOS's controller service (`gamecontrollerd`) sometimes hangs, and then no app sees a controller until a restart. |
| No sound, or sound from the wrong speakers | The game keeps the sound output your Mac had when you pressed Play (Wine's CoreAudio driver doesn't follow a later switch), so AirPods put in afterwards stay silent, and so does a muted output. The window shows **Sound: (output)** before Play, warns when that output is muted or a virtual device, and mentions Bluetooth headphones that are connected but not chosen. Already playing? Switch the Mac's sound back to the output the game started with (and un-mute it), or quit and press Play again. |
| PlayStation controller: "no gamepad detected" in the game | Fixed in 1.4.4: Wine used to hand the game a raw PlayStation device instead of a gamepad. Open the app so it updates, then start the game with the controller already connected. |
| Voice chat: nobody hears you | The first time the game uses the microphone, macOS asks whether Project Reclaimer may use it: click **Allow**. If you clicked Don't Allow, turn it on in System Settings → Privacy & Security → Microphone. |
| "This game is Halo 3: ODST, which isn't installed" | Tools → **Installed games** → **Add** next to Halo 3: ODST (about 9 GB). |
| "This halo3odst.dll is not the ODST build this release supports" | Tools → **Installed games** → **Repair** next to Halo 3: ODST: it brings its files up to Steam's current version. |
| Game frozen and won't close | Tools → **Force Quit**. |
| Something else | Tools → **Make Report**, and send the zip it puts on your Desktop. Logs are in `~/Games/ProjectReclaimer/logs/`. |

## Uninstall

Tools → **Uninstall** in the app. Or in Terminal:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/mattromano/project-reclaimer-mac-port/main/uninstall.sh)"
```

Removes the app, `~/Games/ProjectReclaimer` (Halo 3 and Halo 3: ODST's files, Wine, mods) and the network startup task.

## How it works (and why)

The problems found while porting it, and what the scripts do about each:

| Problem | Fix |
|---|---|
| Wine's built-in DirectX 11 can't create a device on MoltenVK, so the engine crashes on start | DXVK-macOS `d3d11`/`d3d10core` in the Wine prefix's `system32` |
| Reclaimer's menu (egui/glutin) needs OpenGL 3.0+, but Wine on macOS only gives 2.1 to apps that don't request a core profile | Mesa's `opengl32.dll` (llvmpipe) next to the game, with `LP_NUM_THREADS=0` (its worker threads each used a full core) |
| Crash mid-match in `xaudio2_9.dll`, and poor audio | MCC's `xaudio2_9redist.dll` hands off to Wine's FAudio on "Windows 10"; `xaudio2_9=d` keeps Microsoft's own mixer |
| Joins refused / engine crashes binding `127.x.y.z` | A LaunchDaemon aliases `127.0.0.x`–`127.0.3.x` and `127.3.1.x`–`127.3.3.x` on `lo0` at boot (0.9.8 added `127.0.2.x`, 0.9.13 `127.3.2.x`); the app updates it and re-adds missing ones before Play |
| Uncapped frame rate kept the Mac maxed out even at the menu | 60 fps cap |
| Halo 3's engine thread polls the clock ~40,000 times a second between frames: one full CPU core under Rosetta, menu and match alike | `spinfix`: a small `d3d11.dll` in front of DXVK that makes halo3.dll's clock polling sleep 1 ms once it reads the clock 8+ times within a millisecond. Menu ~2.4 → ~1.5 cores, match ~1.75 → ~0.9, same 60 fps. Source in `spinfix/`; set `RECLAIMER_SPINFIX_US=0` to turn it off |
| DXVK rebuilt its swapchain every frame (a 1080p swapchain in a differently sized full-screen window), stalling the GPU each time | Windowed at exactly the render size: ~95 → ~120 fps uncapped |
| GPU address fault ("graphics card stopped responding") on heavy modded maps | MoltenVK 1.4.2 (device-loss and argument-buffer fixes) instead of Wine's bundled 1.4.0 |
| No Steam client under Wine (its UI renders black) | DepotDownloader for game files and Workshop mods, using Steam's QR sign-in, shown in the launcher window |
| Mod downloads never started for some players: the helper asked for an account name and looked up the saved login under exactly that name, so a display name, email or different capitalization failed every time | No name to type: the launcher saves the account name Steam reports at QR sign-in, checks the login before each game, and shows a new QR code when it has expired |
| Reclaimer's in-game updater replaces its exe in place and restarts the game outside the launcher | `RECLAIMER_UPDATE_URL=off`; the launcher installs each release as its own checksum-verified file before the game starts |
| Fixes only reached players who re-ran the installer | The launcher compares `VERSION` on GitHub with the installed one and re-runs the installer in update mode (`RECLAIMER_UPDATE=1`) when it is newer |
| Without Steam, the game downloads Workshop mods from game servers (capped ~2.5 MB/s each) or refuses Workshop-only mods ("Start Steam…") | The Workshop helper fetches them from Steam's CDN instead (~40–110 MB/s measured) |
| Downloaded mods still showed "Start Steam…": the game only counts a mod as installed when Steam's `appworkshop_976730.acf` lists its current version, and only the Steam client writes that file | The helper writes it for every downloaded mod, with versions from Steam's public Workshop API, and downloads mods again when they update |
| Multi-GB mod downloads landing in iCloud-synced `~/Documents` | The Wine prefix gets its own Documents folder |

## Credits

[Project Reclaimer](https://projectreclaimer.dev) · [Wine](https://www.winehq.org) builds by
[Gcenx](https://github.com/Gcenx) · [DXVK-macOS](https://github.com/Gcenx/DXVK-macOS) ·
[MoltenVK](https://github.com/KhronosGroup/MoltenVK) · [Mesa for Windows](https://github.com/pal1000/mesa-dist-win) ·
[DepotDownloader](https://github.com/SteamRE/DepotDownloader). Halo is a Microsoft/343 Industries game; you need your
own copy. Not affiliated with Project Reclaimer, Microsoft or Valve.
