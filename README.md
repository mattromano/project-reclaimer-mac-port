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
- ~45 GB free disk space
- Your Mac's admin password once

## Install

Easiest: open **Terminal** (Spotlight → "Terminal"), paste this line, press Return, and follow the prompts:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/mattromano/project-reclaimer-mac-port/main/install.sh)"
```

What it does, in order:

1. Installs Rosetta 2 if needed.
2. Downloads Wine, DXVK-macOS, MoltenVK, Mesa, DepotDownloader and the latest Project Reclaimer, checking every
   file against a known SHA-256 checksum.
3. Shows a **QR code**: open the Steam app on your phone and scan it. Only Halo 3 is downloaded from your own
   Steam account (~35 GB), so this part takes a while. Nothing is shared from anyone else's copy.
4. Asks for your **Mac password** once to install a small startup task that enables the local network addresses
   Reclaimer uses (`127.0.0.x`–`127.0.3.x`, `127.3.1.x`; macOS only enables `127.0.0.1` by default).
5. Puts **Project Reclaimer** in `~/Applications`, so it shows up in Spotlight and Launchpad.

If anything fails, run the same command again: finished steps are skipped and the Steam download resumes.

**Prefer double-clicking?** Download
[Project-Reclaimer-Mac-Port.dmg](https://github.com/mattromano/project-reclaimer-mac-port/releases/latest/download/Project-Reclaimer-Mac-Port.dmg),
open it and double-click **Install Project Reclaimer**: it opens Terminal and runs the same command. It isn't signed
by Apple, so the first time macOS refuses it: click Done, then System Settings → Privacy & Security → **Open Anyway**.
(`scripts/make_dmg.sh` builds the disk image.)

## Playing

- Open **Project Reclaimer** from Spotlight or Launchpad. The first launch asks for your Steam account name (used to
  download Workshop mods) and spends about a minute building a Forge cache.
- **Workshop mods download themselves.** Without the Steam client, the game downloads mods from the game servers,
  which cap sharing at ~2.5 MB/s each, or shows a "Start Steam…" error for Workshop-only mods. A helper running next
  to the game fetches the same mods from Steam's CDN instead (~40 MB/s measured: 1.6 GB in 37 s) and posts a
  notification when each is ready: press **Try Again**, or leave and rejoin if the game was still downloading it
  from the server. Mods are 1–9 GB each. The helper signs in to Steam with the QR login saved at install; when
  that expires, a Terminal window shows a new QR code to scan.
- Change graphics in the game's own Settings. To restore the tuned defaults, re-run the installer.

## Troubleshooting

| Problem | Fix |
|---|---|
| "Could not join that server" on every server, especially after a Reclaimer update | A new release may use new local addresses. Re-run the installer, then **quit and reopen** the game. |
| Game won't start right after a reboot | The startup task re-adds the network addresses at boot; wait a few seconds after logging in. |
| Stuck on "Synchronizing players" for minutes | Usually the server (its clock is stuck for everyone). Try another server. |
| "Steam login expired" notification | Terminal opens with a QR code; scan it with the Steam app. |
| "Graphics card stopped responding" | A GPU fault in the DirectX → Metal translation, mostly on heavy modded maps. Relaunch; lower Settings → render resolution if it repeats. |
| Something else | Logs are in `~/Games/ProjectReclaimer/logs/` (`client-wine.log`, `workshop-helper.log`). Each launch overwrites the game log, so copy it before relaunching. |

## Uninstall

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/mattromano/project-reclaimer-mac-port/main/uninstall.sh)"
```

Removes the app, `~/Games/ProjectReclaimer` (game files, Wine, mods) and the network startup task.

## How it works (and why)

The problems found while porting it, and what the scripts do about each:

| Problem | Fix |
|---|---|
| Wine's built-in DirectX 11 can't create a device on MoltenVK, so the engine crashes on start | DXVK-macOS `d3d11`/`d3d10core` in the Wine prefix's `system32` |
| Reclaimer's menu (egui/glutin) needs OpenGL 3.0+, but Wine on macOS only gives 2.1 to apps that don't request a core profile | Mesa's `opengl32.dll` (llvmpipe) next to the game, with `LP_NUM_THREADS=0` (its worker threads each used a full core) |
| Crash mid-match in `xaudio2_9.dll`, and poor audio | MCC's `xaudio2_9redist.dll` hands off to Wine's FAudio on "Windows 10"; `xaudio2_9=d` keeps Microsoft's own mixer |
| Joins refused / engine crashes binding `127.x.y.z` | A LaunchDaemon aliases `127.0.0.x`–`127.0.3.x` and `127.3.1.x` on `lo0` at boot (0.9.8 added `127.0.2.x`); re-running the installer updates it |
| Uncapped frame rate kept the Mac maxed out even at the menu | 60 fps cap |
| Halo 3's engine thread polls the clock ~40,000 times a second between frames: one full CPU core under Rosetta, menu and match alike | `spinfix`: a small `d3d11.dll` in front of DXVK that makes halo3.dll's clock polling sleep 1 ms once it reads the clock 8+ times within a millisecond. Menu ~2.4 → ~1.5 cores, match ~1.75 → ~0.9, same 60 fps. Source in `spinfix/`; set `RECLAIMER_SPINFIX_US=0` to turn it off |
| DXVK rebuilt its swapchain every frame (a 1080p swapchain in a differently sized full-screen window), stalling the GPU each time | Windowed at exactly the render size: ~95 → ~120 fps uncapped |
| GPU address fault ("graphics card stopped responding") on heavy modded maps | MoltenVK 1.4.2 (device-loss and argument-buffer fixes) instead of Wine's bundled 1.4.0 |
| No Steam client under Wine (its UI renders black) | DepotDownloader for game files and Workshop mods, using Steam's QR sign-in |
| Without Steam, the game downloads Workshop mods from game servers (capped ~2.5 MB/s each) or refuses Workshop-only mods ("Start Steam…") | The Workshop helper fetches them from Steam's CDN instead (~40–110 MB/s measured) |
| Downloaded mods still showed "Start Steam…": the game only counts a mod as installed when Steam's `appworkshop_976730.acf` lists its current version, and only the Steam client writes that file | The helper writes it for every downloaded mod, with versions from Steam's public Workshop API, and downloads mods again when they update |
| Multi-GB mod downloads landing in iCloud-synced `~/Documents` | The Wine prefix gets its own Documents folder |

## Credits

[Project Reclaimer](https://projectreclaimer.dev) · [Wine](https://www.winehq.org) builds by
[Gcenx](https://github.com/Gcenx) · [DXVK-macOS](https://github.com/Gcenx/DXVK-macOS) ·
[MoltenVK](https://github.com/KhronosGroup/MoltenVK) · [Mesa for Windows](https://github.com/pal1000/mesa-dist-win) ·
[DepotDownloader](https://github.com/SteamRE/DepotDownloader). Halo is a Microsoft/343 Industries game; you need your
own copy. Not affiliated with Project Reclaimer, Microsoft or Valve.
