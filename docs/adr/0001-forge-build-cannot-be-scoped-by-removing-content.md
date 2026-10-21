# ADR 0001: The Forge asset-library build cannot be scoped by removing content

**Status:** Accepted

## Context

On a Mac with 8 GB of RAM, Project Reclaimer starts and reaches its main menu, but the Forge asset library it builds
during startup never finishes. The build walks every installed map and collects its Forge objects; the engine sizes
its memory pool at half of physical RAM and adds roughly 2.6 GB of GPU-visible memory, so the machine swaps heavily
while the cache stays empty.

The instinctive fix is to reduce what the build collects: keep multiplayer, set campaign aside. Campaign plus its
cache is 4.3 GB across 13 files, and multiplayer and custom maps are 5.3 GB across 27, so the trim looks substantial.

That instinct is wrong, and the reason is worth recording so it is not attempted again.

## Decision

**Do not attempt to make startup fit by removing or moving installed Halo 3 content.** No content profile, no
"multiplayer only" mode, no trimming of campaign maps.

The client validates its required content at startup and refuses to run when any of it is missing.

## Evidence

The experiment was run on the affected machine: the 13 campaign files were moved aside and the game launched. It
exited before the engine started, with:

```
Error: The MCC installation in C:\Program Files (x86)\Steam\steamapps\common\Halo The Master Chief Collection is missing required Halo 3 content.

Project Reclaimer requires Halo: The Master Chief Collection with BOTH Halo 3 Campaign and Halo 3 Multiplayer installed.

Missing files:
Halo 3 Campaign: halo3\maps lacks campaign.map, 040_voi.map, 130_epilogue.map.
```

The files were restored immediately; all 40 maps were present again.

The wording that suggested otherwise — "Halo 3's campaign is not installed in …, so its campaign.map and 040_voi.map
were not copied" — belongs to the dedicated server's content-copy path, which can build a server folder without
campaign. It says nothing about the client's requirements.

## Consequences

- The build's scope is fixed by the game, not by the port. There is no content lever.
- The engine's memory pool is auto-sized and exposes no control, and the game accepts no render target below 720p.
- Remaining levers are environmental, not architectural: more RAM, more free disk so macOS can grow swap, importing
  a completed cache from a machine with more memory (plausible but unverified), or pinning an older game release
  that predates the cross-map Forge library (server-version dependent).
- The port's honest role is to report the stall and help the player decide, which is what the startup-state work
  does. It cannot make the build fit.
