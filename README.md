# Project Reclaimer for Mac

Play Halo 3 through [Project Reclaimer](https://projectreclaimer.dev) (community servers, Forge, Workshop mods) on an
Apple Silicon Mac. Project Reclaimer is Windows-only; this sets it up under Wine with everything tuned for macOS.

Two versions get installed side by side and share the same game files and mods:

| App | How it draws | Defaults | Menu, measured on an M2 Max |
|---|---|---|---|
| **Project Reclaimer** | Wine 11.18 + DXVK-macOS (DirectX 11 → Vulkan → MoltenVK → Metal) | windowed at your screen's best fit, Low quality, 60 fps cap | 60 fps, ~250% CPU, ~53% GPU |
| **Project Reclaimer Metal** | CrossOver 24 Wine + Apple D3DMetal (DirectX 11 → Metal) | full screen, High quality, 60 fps cap | 60 fps, ~190% CPU, ~54% GPU |

Try both and keep whichever plays smoother on your Mac. The Metal one uses Apple software under Apple's license
(you're asked before it's installed).

## Requirements

- Apple Silicon Mac (M1 or newer), macOS 14 Sonoma or newer, 16 GB RAM recommended
- **Halo: The Master Chief Collection on Steam**, plus the Steam app on your phone (to sign in with a QR code)
- ~45 GB free disk space
- Your Mac's admin password once

## Install

Open **Terminal** (Spotlight → "Terminal"), paste this line, press Return, and follow the prompts:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/mattromano/reclaimer-mac/main/install.sh)"
```

What it does, in order:

1. Installs Rosetta 2 if needed.
2. Downloads Wine, DXVK-macOS, Mesa, DepotDownloader and the latest Project Reclaimer, checking every file
   against a known SHA-256 checksum.
3. Shows a **QR code**: open the Steam app on your phone and scan it. Only Halo 3 is downloaded from your own
   Steam account (~35 GB), so this part takes a while. Nothing is shared from anyone else's copy.
4. Asks for your **Mac password** once to install a small startup task that enables the local network addresses
   Reclaimer uses (`127.0.0.x`, `127.0.1.x`, `127.3.1.x`; macOS only enables `127.0.0.1` by default).
5. Asks whether to also install the **Metal** version.
6. Puts **Project Reclaimer** (and **Project Reclaimer Metal**) in `~/Applications`, so they show up in Spotlight
   and Launchpad.

If anything fails, run the same command again; finished steps are skipped and the Steam download resumes.

## Playing

- Open **Project Reclaimer** from Spotlight or Launchpad. The first launch asks for your Steam account name (used to
  download Workshop mods) and spends about a minute building a Forge cache.
- **Workshop mods download themselves.** If a server needs a Workshop-only mod, the game shows a "Start Steam…" error.
  A helper running next to the game downloads that mod and posts a notification when it's ready; then press
  **Try Again**. Mods are 1–2 GB each.
- Settings live in the game's own Settings menu. To get the tuned defaults back, re-run the installer.

## Troubleshooting

| Problem | Fix |
|---|---|
| Game won't start after a reboot | The network startup task re-adds the addresses at boot; give it a few seconds after login, or re-run the installer. |
| "Steam login expired" notification | Terminal opens with a QR code; scan it with the Steam app. |
| Low frame rate in big maps | In Settings, lower the render resolution, or try the other app (Wine vs. Metal). |
| Something else | Logs are in `~/Games/ProjectReclaimer/logs/` (`client-wine.log`, `client-metal.log`, `workshop-helper.log`). |

## Uninstall

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/mattromano/reclaimer-mac/main/uninstall.sh)"
```

## How it works (and why)

These are the problems found while getting it running, and what the scripts do about each:

| Problem | Fix |
|---|---|
| Wine's built-in DirectX 11 can't create a device on MoltenVK, so the engine crashes on start | DXVK-macOS `d3d11`/`d3d10core` (Wine version) or D3DMetal (Metal version) |
| Reclaimer's menu (egui/glutin) needs OpenGL 3.0+, but Wine on macOS only gives 2.1 to apps that don't request a core profile | Mesa's `opengl32.dll` (llvmpipe) next to the game, with `LP_NUM_THREADS=0` (its worker threads each used a full core) |
| Crash mid-match in `xaudio2_9.dll`, and poor audio | MCC's `xaudio2_9redist.dll` hands off to Wine's FAudio on "Windows 10"; `xaudio2_9=d` keeps Microsoft's own mixer |
| Joining fails / engine crashes binding `127.x.y.z` | A LaunchDaemon aliases `127.0.0.x`, `127.0.1.x`, `127.3.1.x` on `lo0` at boot |
| DXVK rebuilt its swapchain every frame (a 1080p swapchain in a differently sized full-screen window), idling the GPU each time | Wine version runs windowed at exactly its render size: ~95 → ~120 fps uncapped |
| Apple's GPTK Wine 7.7 lacks the AFD socket polling Reclaimer's networking (tokio) needs, so the server browser dies | Metal version uses CrossOver 24 (Wine 9) through CrossOver's D3DMetal hook instead |
| No Steam client under Wine (its UI renders black) | DepotDownloader for game files and Workshop mods, using Steam's QR sign-in |
| Multi-GB mod downloads landing in iCloud-synced `~/Documents` | Each Wine prefix gets its own Documents folder |

Performance numbers are from the main menu with the 60 fps cap (the uncapped menu runs at 120–135 fps on both
versions). Busy matches are heavier; if a map dips below 60, lower Settings → Graphics → render resolution.

## Credits

[Project Reclaimer](https://projectreclaimer.dev) · [Wine](https://www.winehq.org) builds by
[Gcenx](https://github.com/Gcenx) · [DXVK-macOS](https://github.com/Gcenx/DXVK-macOS) ·
[Mesa for Windows](https://github.com/pal1000/mesa-dist-win) · [DepotDownloader](https://github.com/SteamRE/DepotDownloader) ·
[Sikarugir](https://github.com/Sikarugir-App) (CrossOver 24 engine and wrapper) · Apple D3DMetal ·
[MoltenVK](https://github.com/KhronosGroup/MoltenVK). Halo is a Microsoft/343 Industries game; you need your own copy.
