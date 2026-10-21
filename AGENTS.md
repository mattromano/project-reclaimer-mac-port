# AGENTS.md

Pointers for contributors and coding agents. The README is for players; this file is for changing the port.

## Layout
- `install.sh`: installs and updates everything (also re-run by the app on every Mac port update).
- `scripts/`: what lands in `~/Games/ProjectReclaimer/game/`: `run.sh` (starts the game under Wine), `updater.py`, `tools.py` (Tools menu and auto-fixes), `workshop_helper.py` (Steam sign-in, game and mod downloads), `presets.py` + `fit.py` (graphics settings per Mac).
- `launcher/*.swift`: the app window (SwiftUI). Pure, tested logic lives in `LauncherCore.swift`; tests in `launcher/Tests/main.swift`.
- `docs/specs/` (plans), `docs/adr/` (decisions, including things that don't work).

## Checks (CI runs the same: `.github/workflows/checks.yml`)
- `/usr/bin/python3 -I -m unittest discover -s tests`
- `swiftc -typecheck -target arm64-apple-macos14.0 -swift-version 5 -parse-as-library launcher/*.swift`
- `scripts/make_launcher.sh test`

## Rules
- **Don't commit `launcher/ProjectReclaimer` or change `LAUNCHER_SHA` in a PR.** The maintainer rebuilds the launcher from source at release time (`scripts/make_launcher.sh` builds it and pins its checksum). Same for any other prebuilt binary: commit its source and build script.
- Players get a change only when `VERSION` on main goes up; the maintainer bumps it.
- Tests and experiments never touch a real install (`~/Games/ProjectReclaimer`, `~/Applications`): use a throwaway `RECLAIMER_HOME` / `RECLAIMER_APPS_DIR`.
- Process matches (`pgrep`/`pkill`) name this install or a test path, never a bare script or app name.

## Traps
- The helper scripts run as `/usr/bin/python3 -I`: their own folder isn't on `sys.path`, so importing a sibling script needs `sys.path.insert(0, <its folder>)` (see `presets.py`).
- Wine is x86_64 (Rosetta). An arm64 library in `DYLD_INSERT_LIBRARIES` (e.g. from `~/.zshenv`) kills it at launch: `run.sh` and `tools.py` unset it.
- Wine reads `SDL_*` controller variables only when its device process starts: a Wine process started earlier without them (e.g. by `tools.py`) keeps the old setting until Wine restarts.
