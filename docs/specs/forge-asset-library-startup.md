# Surface a stalled Forge asset-library build

## Problem Statement

On a Mac with less RAM than the recommended 16 GB, pressing Play can leave the player on a
**Building Asset Library** screen that spins for half an hour or more without finishing. The window gives
no indication whether anything is happening, no explanation of what is being built, and no way to tell a
slow start from a stuck one. Closing it looks like a crash; waiting feels endless. Nothing in the window
or its logs says why, or what would help.

## Solution

While a game is starting, the launcher reports what startup is doing instead of showing an undifferentiated
spinner. It tells **building** from **stalled** by watching whether the Forge asset library is being written,
and when the build stops progressing it says so in plain words, names the likely cause — the build needs more
memory than this Mac has free — and offers the two actions that help: quit other apps and try again, or
force-quit a build that will not finish. On a constrained Mac the window also sets that expectation before
Play.

The port does not change the game's behaviour. It cannot make the game skip the library; it can only report
honestly and help the player decide.

## User Stories

1. As a player on an 8 GB Mac, I want to know that startup is building the Forge asset library, so that I do not think the game has crashed.
2. As a player, I want to be told when startup has stopped progressing, so that I do not wait indefinitely.
3. As a player, I want the message to name the likely cause in plain words, so that I know it is a memory problem rather than a broken install.
4. As a player, I want to be told to quit other apps and try again, so that I have an action that might work.
5. As a player, I want a way to stop a build that will not finish, so that I am not left with a spinning window.
6. As a player on a 16 GB Mac, I want no memory warning at all, so that I am not alarmed about a problem I do not have.
7. As a player, I want the building state to show how long it has been building, so that I can judge whether to keep waiting.
8. As a player, I want the window to stop saying "building" once the game is actually up, so that I stop waiting for something already finished.
9. As a player, I want readiness to come from the game's own signal, so that the window never guesses.
10. As a player, I want the explanation in the same place I press Play, so that I do not have to find a log file.
11. As a player on a constrained Mac, I want to be told before Play that the first build may take a long time, so that the wait is expected.
12. As a player, I want the window to distinguish "slow" from "stuck", so that I do not give up on a build that is working.
13. As a player, I want Force Quit to stay available during a stalled start, so that I can recover without Terminal.
14. As a player, I want a stalled build to be recoverable by trying again after freeing memory, so that a failure is not permanent.
15. As a player, I want the message to avoid jargon, so that I understand what to do next.
16. As a maintainer, I want the launcher's view of startup to come from one command, so that the window and Tools cannot disagree.
17. As a maintainer, I want the display decision to be a pure function, so that it can be tested without launching a game.
18. As a maintainer, I want the stall threshold to be configurable, so that slower machines can be given more patience without a code change.
19. As a maintainer, I want an unreadable state to fall back to existing behaviour, so that a broken probe never invents a verdict.
20. As a maintainer, I want the evidence for a stall to be available to a bug report, so that this can be fixed upstream.

## Implementation Decisions

**One source of truth for startup.** The startup-state command already added to the launcher's Tools interface
is the only thing that decides what startup is doing. The window must not infer progress from process liveness,
log growth, or CPU use.

**State vocabulary.** `starting`, `building`, `ready`, `stalled`, `stopped`.

**Stalled means "the build started, and has written nothing since this start".** Concretely: the build marker
is present, the game has been running at least the stall threshold, and the Forge cache's newest write predates
the game's start time. Comparing against the start time is what stops a cache left by an earlier run counting as
progress.

**Threshold.** Default 180 seconds; overridable by environment so a slow machine can be given more patience
without a rebuild. The evidence behind 180: the first build takes about a minute on the hardware the port was
tuned for.

**A pure display mapping in the launcher core.** A function maps `(state, elapsed, threshold)` to what the window
shows: a title, a detail line, and whether it is a warning. No I/O, no dates, no process access — so it is
testable on its own.

**Polling, not blocking.** While a game runs, the window polls the startup state on a timer off the main thread
and cancels on exit. Play must never be blocked by a stall; Force Quit stays enabled throughout.

**Never claim ready without the game's own completion marker.** Absence of a stall is not readiness.

**The tier sets expectations, not gates.** The existing machine-fit tier (constrained below 16 GB) decides
whether the window mentions memory at all. It never blocks Play or installation.

**Failure is not a verdict.** If the command cannot run or returns something unrecognised, the window keeps its
current behaviour rather than showing a state it did not observe.

**No changes to how the game is launched.** This is reporting only: no new launch flags, no changes to the
launch scripts, no attempt to influence the game's cache.

## Testing Decisions

A good test here asserts observable behaviour: given a home with a log and a cache in a known state, what startup
state is reported; given a state, what the window would display. Tests must not reach into helper functions or
assert on formatting internals.

**Modules under test**

- the startup-state command (its JSON verdict, including the failure and unknown cases)
- the launcher's pure display mapping (one assertion per state, plus the fallback)

**Prior art**

- The Tools commands are tested by running the command as a subprocess against a throwaway home, with a fake game
  process standing in for the real one.
- The launcher core is tested through pure functions for developer-tools state and installed-version selection.

**Timing**

`ps` reports elapsed time in whole seconds, so any test that depends on "written before the start" versus
"written after it" must make that ordering explicit rather than rely on sub-second file times.

## Out of Scope

- Making the game skip, defer, or shrink the Forge asset library. The game is closed source; this port cannot.
- Reporting the underlying defect upstream, and tracking any fix that comes from it.
- Changing the graphics preset, resolution floor, or fit-tier thresholds — already decided and shipped.
- Reducing the build's memory footprint, or auto-retrying with different settings.
- Windows and Linux, and the game's own launcher behaviour on them.

## Further Notes

**Evidence from the machine that motivated this.** An 8 GB M1 MacBook Air reached the main menu behind the
overlay (`map_loaded: true`, menu music cycling) while the Forge cache stayed at 0 bytes for over 25 minutes.
The engine sized its memory pool at 4095 MB and held roughly 2.6 GB of GPU-visible memory, and the machine moved
about 600 MB/s through swap. The build's map sweep returned to earlier maps rather than completing. Nothing was
logged as an error.

**720p is the floor.** The game accepts only 720p, 900p, 1080p and 1440p render targets, so no tier or setting can
shrink the render target further. Any future attempt to make the build fit has to come from memory, not resolution.

**Vocabulary introduced here.** *startup state*, *stall threshold*, *constrained tier*. The repository has no
domain glossary or ADR directory yet; these terms should move there if one is added.

**Publishing.** This spec lives in the repository because the upstream tracker does not grant this contributor
label rights. It should be mirrored to an issue with the agent-ready label once the tracker is configured.
