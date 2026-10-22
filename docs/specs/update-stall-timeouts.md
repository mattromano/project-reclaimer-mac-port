# An update that stalls should fail fast and resume

## Problem Statement

An update can hang for a long time and then be abandoned. On the machine that prompted this, the launcher logged
"Updating the Mac port to 1.4.5…" and, **1 h 45 min later**, "The update took too long and was stopped. You can still
play." The scripts had been written partway through; the version marker had not, so the install reported one version
and ran another until the next attempt.

The detail matters more than the headline, because the obvious diagnoses are already wrong:

- **Transfers are not unbounded in general.** `install.sh` already passes `--connect-timeout 20 --speed-limit 1024
  --speed-time 60`, and the updater's `urlopen` calls use 15/20/30 s timeouts. What is missing is an **overall cap**,
  so a transfer that trickles just above 1 KB/s can run indefinitely.
- **`VERSION` is already written last**, deliberately, so a half-applied update is retried on the next launch. That
  part is working as designed.
- **Completed downloads are already reused**, by a sha-checked cache with `.part` files.

What actually failed is the **watchdog**, and it failed in a way that is measurable in the code: it compares the age of
an *in-flight update* against the age of the **launcher process**, not against when the update started. An update
started ten minutes into a session is therefore killed on the next tick; a long update gets at most ten minutes from
launch. And because the check lives on a 1 s `Timer` with no activity assertion, macOS sleep or App Nap can stop it
firing entirely — which is the only way to explain a 1 h 45 min gap when the timer was supposed to fire at ten minutes.

## Solution

Bound each transfer with a total time limit, apply the script files atomically, name the step that got stuck, and make
the watchdog measure the thing it claims to measure — the update — while keeping the app awake for the duration.

## User Stories

1. As a player updating the port, I want a transfer that stalls to fail within a bounded total time, so that I am not left waiting without knowing why.
2. As a player, I want the failure to name the step that timed out, so that I know whether it was the network, the disk, or something else.
3. As a player, I want to try again and have completed downloads reused, so that a slow connection does not restart from zero.
4. As a player, I want an interrupted update to leave the previous install usable and truthfully labelled, so that I can still play.
5. As a player, I want the version marker to stay accurate, so that support and bug reports are not misled.
6. As a player, I want the update to apply all-or-nothing, so that I never run a mix of old and new scripts.
7. As a player, I want the launcher to keep me informed while it works, so that a long update looks like progress rather than a hang.
8. As a player, I want the update to be safe to re-run, so that a failed attempt does not require a reinstall.
9. As a player who left the launcher open for a while, I want an update started later in the session to get its full time budget, so that app uptime does not decide whether it is killed.
10. As a player who let the Mac sleep, I want the update to survive and either finish or fail cleanly on wake, so that I do not come back to a stopped update.
11. As a maintainer, I want the total cap in one place beside the other curl limits, so that tuning it is one edit.
12. As a maintainer, I want the watchdog's decision to be a pure function of update age, so that it can be tested without waiting ten minutes.
13. As a maintainer, I want the launcher to hold an activity assertion while updating, so that App Nap cannot starve the watchdog.
14. As a maintainer, I want the failure path exercised by tests, so that a future change cannot quietly remove the bound.
15. As a support volunteer, I want the log to record which step timed out and after how long, so that I can tell a slow server from a broken install.

## Implementation Decisions

**A total time limit per transfer.** Add `--max-time` to the installer's existing curl limits; keep the connect and
speed limits as they are, since they catch different failures. The value lives beside them, in one place.

**Stage, then swap.** The installer currently writes script files one by one into the live install. Stage the new set and
swap it in at the end of that step, so a killed update cannot leave a mixed set of scripts. `VERSION` stays last: that
behaviour is already correct and is what makes an interrupted update retry.

**Name the stuck step.** The installer already tracks its current step for the window's error message; include that name
and the elapsed time in the timeout failure, and in the log.

**The watchdog measures the update, not the app.** Record when the update starts and compare against that. The decision
belongs in the launcher's pure core, taking two dates, so it is testable without waiting.

**Keep the app awake while updating.** Hold an activity assertion for the lifetime of the update, so App Nap and display
sleep cannot suspend the timer that enforces the bound.

**Do not re-litigate what already works.** The existing connect/speed limits, the `urlopen` timeouts, the sha-checked
download cache with `.part` files, and writing `VERSION` last all stay. The spec points at the total cap and the
watchdog, not at replacing the transfer layer.

## Testing Decisions

A good test asserts observable behaviour: given a transfer that never completes, the installer fails within the cap,
names the step, and leaves the previous install intact. Given an update that has run longer than the cap, the launcher
reports a warning; given one that has run for less, it does not.

**Modules under test:** the installer's transfer step (timeout, failure message, staging), and the launcher core's
watchdog decision as a pure function of update age.

**Prior art:** the installer's GUI tests already fake `curl`, `tar` and `uname`, which is the seam needed to simulate a
hanging transfer. The launcher core is tested through pure functions.

**Cases that must be covered:** a hanging transfer times out and names itself; a truncated download is not treated as
complete; a completed download is reused rather than fetched again; a killed apply leaves the marker unchanged; the
watchdog fires on update age, not app age; an update started late in a session still gets its full budget.

## Out of Scope

- Replacing curl or the download cache, either of which already does its job.
- Changing when `VERSION` is written; it is written last on purpose.
- Parallelising downloads, or changing where they come from.
- The updater's version-selection logic.
- Reworking the launcher's progress UI beyond naming the failed step.

## Further Notes

**Measured.** The launcher began a port update and logged a stop 1 h 45 min later. The scripts were written about an hour
in; the version marker never was. The install then reported 1.4.2 while running 1.4.5 scripts.

**Why the lock file is not the bug.** An earlier diagnosis blamed the leftover `.update.lock`. It is an advisory
`flock` released by the kernel when the process dies; nothing reads the file's existence. Recording that here so it is
not chased again.

**Why the 1 h 45 min gap is the interesting number.** A 1 s timer with a ten-minute threshold should have fired at ten
minutes. It did not, which points at the timer being suspended — by system sleep or App Nap — rather than at the
threshold being wrong. Both the clock the watchdog reads and the assertion it holds need fixing; changing the number
alone would hide the problem.
