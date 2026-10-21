# Guardrails and navigation for the Mac port

## Problem Statement

Nothing checks a change to this port automatically: there is no CI and no hook. The only verification is three
commands written inside test-module docstrings, and the README does not name them. Two tests were already failing on
the default branch when this work began, and nobody noticed until a contributor ran the suite by hand.

Two smaller costs compound it. The suite's idea of "the game is running" is a system-wide process match, so two
suites running at once see each other's fake game and fail — a contributor with two checkouts, or a CI job beside
anything else. And an agent arriving in the repository re-derives a layout spanning shell, Python and Swift, then
hits two traps that no configuration records: the helper scripts run isolated, so a sibling import fails with no
obvious cause, and a shell shim can inject an ARM-only library into Wine's x86_64 process and kill it.

## Solution

Every pull request runs the three checks automatically and fails visibly when one breaks. The repository carries a
short navigation file that points at the architecture, names the verification commands, and records the two traps.
The suite's process matching is scoped to the installation under test, so two runs can no longer mistake each
other's fake game for the real one.

## User Stories

1. As a maintainer, I want every pull request to run the test suite, so that a red change cannot merge unnoticed.
2. As a maintainer, I want the type-check and the launcher tests to run on every pull request, so that Swift breakage is caught before review.
3. As a contributor, I want one documented command per check, so that I do not have to read test docstrings to find them.
4. As a contributor, I want continuous integration to run on macOS with the same interpreter and toolchain as a real Mac, so that green means something.
5. As a contributor with two checkouts, I want one checkout's fake game not to affect the other's tests, so that concurrent work is trustworthy.
6. As an agent arriving in the repository, I want a pointer to the architecture, so that I do not re-derive three languages from scratch.
7. As an agent, I want the isolated-interpreter rule written down, so that a sibling import failure is not a debugging cycle.
8. As an agent, I want the injected-library trap written down, so that I unset it before invoking x86_64 tools.
9. As a maintainer, I want the navigation file to stay pointer-only, so that it does not become a second README.
10. As a contributor, I want the process match to identify this installation specifically, so that the check reflects reality.
11. As a maintainer, I want the isolation fix covered by the existing fake-process tests, so that no new test infrastructure is needed.
12. As a contributor, I want the checks to be fast enough to wait for, so that they are not bypassed.
13. As a contributor, I want a failing run to name which check failed, so that the fix is obvious.
14. As a maintainer, I want the checks to be the same commands a human runs, so that there is one source of truth.
15. As an agent, I want the spec and ticket locations named, so that I can find the plan behind a change.

## Implementation Decisions

**Continuous integration runs three checks** on pull requests and on the default branch: the Python suite, a Swift
type-check of the launcher, and the launcher's own tests. A failing check fails the run, and the run names which one.

**CI runs on a macOS image.** The product and every check are macOS-only; testing on Linux would verify something
else. The runner image is pinned so the interpreter does not drift silently.

**The three commands are documented once.** The README stays user-facing; the commands live with the navigation
material and are referenced, not restated, from anywhere else.

**A short, pointer-only navigation file** names the architecture, the checks, and the two traps. It carries
pointers, not explanations, so it stays cheap in every agent's context.

**Process matching is scoped to the installation.** A process counts as this installation's game only if it belongs
to this installation — its working directory lies inside the install, or it carries a marker this install sets.
The Tools check and the updater share the same rule so they cannot disagree.

**The rule stays permissive enough for the real game**, which is started from its own folder, and for the older
release a player may have chosen.

**No new test seam.** The existing fake-process tests exercise the match directly.

## Testing Decisions

A good test asserts observable behaviour: given a fake game process belonging to this installation, the check
reports running; given one belonging to another installation, it reports not running. Tests must not assert on how
the match is implemented.

**Modules under test:** the Tools game check and the updater's game check.

**Prior art:** the existing tests that spawn a process whose command line names the game executable.

**The concurrency case is the regression test.** Two suites running at once, one holding a fake game process, must
both pass. That is the failure this change exists to prevent, so it is proven directly rather than inferred.

**CI is verified by its first run**, and by a deliberately failing change observed once before it is relied upon;
it is not unit-tested.

## Out of Scope

- Rebuilding the injected shell library as a universal binary. That is the machine's environment, not this repository.
- Installing or repairing the skills setup command, and the tracker labels it would configure.
- Tool-economy habits for agents (preferring targeted scans, avoiding profilers on emulated processes).
- The Forge startup work, which has its own spec.
- Windows and Linux, and the game's own behaviour on them.

## Further Notes

**Evidence.** Two tests failed on unmodified `main` until the maintainer fixed them. Two implementers independently
observed the system-wide process match flaking their suites when run concurrently, each mistaking the other's fake
game for the real one.

**CI environment risk.** The Python suite assumes the stock macOS interpreter and macOS paths. If the runner's
interpreter differs, the run should fail loudly rather than silently skip work.

**Navigation file discipline.** It is the only always-loaded material in the repository. Its pointers should
front-load the triggering word and name only distinct branches; depth belongs in the documents they point at.

**Publishing.** This spec lives in the repository because the upstream tracker does not grant this contributor label
rights. Mirror it to an issue with the agent-ready label once the tracker is configured.
