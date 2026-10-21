# A multiplayer-only content profile for constrained Macs

## Problem Statement

On a Mac with less RAM than the recommended 16 GB, the game starts and reaches its main menu, but the Forge asset
library it builds during startup never finishes. The build walks every installed map and collects its Forge objects,
which on an 8 GB machine outgrows the memory available — the engine sizes its pool at half of RAM and adds roughly
2.6 GB of GPU-visible memory, and the machine ends up moving hundreds of megabytes a second through swap while the
cache stays empty.

The port offers no supported way to reduce what that build must collect. A player who only wants multiplayer either
waits indefinitely, or starts moving game files around by hand with no way to tell whether it helped and no way to
put them back.

## Solution

A reversible **multiplayer-only content profile**. The port can move the campaign content aside, leaving the shared
cache and every multiplayer map in place, so the build collects objects from far fewer maps. A Tools action turns
the profile on and off, restoring exactly what was moved. The existing startup report then says whether the build
finished or stalled, so the player can tell whether the profile helped instead of guessing.

The profile is honest about being a mitigation: it reduces demand, it does not guarantee the build fits, and it
trades away campaign play while it is on.

## User Stories

1. As a player on an 8 GB Mac, I want a supported way to reduce what the Forge build collects, so that the game has a chance of finishing startup.
2. As a player who only wants multiplayer, I want to set aside content I am not using, so that I am not carrying campaign data through a build that cannot fit.
3. As a player, I want the port to move those files rather than delete them, so that nothing is lost.
4. As a player, I want one action to put everything back, so that the change is reversible without reinstalling.
5. As a player, I want the port to refuse to move files while the game is running, so that a running game is not corrupted mid-session.
6. As a player, I want to see whether the profile is on, so that I know what content I currently have.
7. As a player, I want the state to be derived from what is actually on disk, so that it cannot disagree with reality.
8. As a player, I want startup to tell me whether the build finished after I turn the profile on, so that I know whether it helped.
9. As a player, I want the port to say the profile may help rather than promise it will, so that I am not misled if it still fails.
10. As a player, I want the trade-off stated plainly — campaign stops working while it is on — so that the choice is informed.
11. As a player, I want restoring to report anything that could not be put back, so that a partial restore is visible rather than silent.
12. As a player who ran a Steam repair, I want the profile to notice that the campaign files returned, so that its state stays truthful.
13. As a maintainer, I want the profile to touch only campaign content, so that multiplayer and the shared cache are never at risk.
14. As a maintainer, I want the operation to follow the existing Tools command conventions, so that it behaves like every other action.
15. As a maintainer, I want the profile's state in the bug report, so that a player reporting a stall tells us which content they had.
16. As a maintainer, I want the change to leave the game's launch path untouched, so that diagnosing a failure is not compounded by launch differences.

## Implementation Decisions

**A content profile with two states: full and multiplayer-only.** The default is full. The profile is a description
of which installed content the game is given, not a game mode and not a graphics setting.

**The profile moves campaign content only.** Campaign missions and the campaign cache are set aside; the shared
cache and every multiplayer and custom map stay. The campaign cache is included because the campaign missions are
useless without it, and leaving it behind would keep part of the cost without the benefit.

**Move, never delete.** Content goes to a store inside the port's own install area, outside the game's install
folder, with its names and relative structure preserved so the reverse is exact. The store's location never depends
on a game file being present.

**State is derived, not stored.** Whether the profile is on is computed from which content is present on disk. There
is no flag to drift out of sync, and a Steam repair that restores the campaign files automatically reports the
profile as off.

**One action turns it on, one turns it off.** Turning it on is refused while the game is running, matching the other
content operations. Turning it off restores every recorded file and reports any file it could not put back, naming
how many.

**Restore is idempotent and safe.** Running restore with nothing set aside reports success; a partially restored
state is reported rather than hidden.

**The profile is offered where the tier says it matters.** On a constrained machine the window can point at it; it
is always reachable from Tools regardless of tier, because the tier is a heuristic about memory and the player may
know better.

**Success is observed, not asserted.** After the profile is applied, whether the build completes is read from the
existing startup report. The window and the docs say the profile *may* let the build finish.

**The launch path is untouched.** No new launch flags, no changes to how the game is started; the profile only
changes which files are present.

**The profile's state joins the bug report**, so a stall can be interpreted with the content that was installed.

## Testing Decisions

A good test asserts observable behaviour: given a fake install with known files, what is present after turning the
profile on, what is present after turning it off, and what the command reports. Tests must not depend on the real
game or a multi-gigabyte install.

**Modules under test:** the profile command (apply, restore, state, and the running-game refusal), and the derived
state used by Tools and the report.

**Prior art:** the Tools commands are tested by running them as subprocesses against a throwaway home, with a fake
game process standing in for a running game; the report tests show how to assert on the zip's contents.

**Cases that must be covered:** apply moves exactly the campaign content and nothing else; apply twice is harmless;
restore returns every file and leaves nothing behind; restore with nothing set aside succeeds; restore with a
missing file reports it; apply is refused while a fake game process is running; a Steam-repair-style restore of the
campaign files flips the reported state back to full without any stored flag.

**What cannot be unit-tested.** Whether the build actually completes is an integration observation, and the spec
says so: the acceptance bar is that after applying the profile on the affected machine, the startup report reaches
either ready or a named stall — an honest outcome either way, not a test that can be faked.

## Out of Scope

- Importing a completed Forge cache from another machine. Plausible, untested, and it needs hardware we do not have.
- Pinning an older game release that predates the cross-map Forge library. Depends on the servers a player wants.
- Buying more RAM, or changing the recommendation.
- Changing the engine's memory pool, which the game sizes itself and exposes no control over.
- Reducing the render target below 720p, which the game does not offer.
- Making campaign content work while the profile is on. It is the trade-off, not a bug.
- Supporting Windows or Linux, where this problem does not arise.

## Further Notes

**Measured on the affected machine.** 8 GB M1 Air. Campaign plus its cache is 4.4 GB across 12 files; multiplayer and
custom maps are 5.3 GB across 28. The engine pool was 4095 MB, GPU-visible memory about 2.6 GB, and swap traffic
about 600 MB/s while the cache stayed at zero bytes for over 25 minutes.

**The shared cache stays.** It alone is roughly 893 MB and every multiplayer map depends on it, so it is never moved.
That bounds how much this can help, and is the main reason the profile is a mitigation rather than a fix.

**Detection must survive a repair.** A Steam repair re-downloads missing files, which turns the profile off in
practice. Deriving state from disk is what keeps the port truthful when that happens, instead of reporting a profile
that is no longer applied.

**Wording discipline.** Every player-facing mention says the profile *may* let the build finish and names what it
costs. Promising a fix that the next start disproves is worse than saying nothing.

**Publishing.** This spec lives in the repository because the upstream tracker does not grant this contributor label
rights. Mirror it to an issue with the agent-ready label once the tracker is configured.
