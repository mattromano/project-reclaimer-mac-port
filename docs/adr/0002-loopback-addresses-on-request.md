# ADR 0002: Loopback addresses are added on request, after login, never at boot

**Status:** Accepted

## Context

Under Wine, Project Reclaimer binds addresses on `lo0` other than `127.0.0.1`, and macOS has only `127.0.0.1` there.
Until 1.5.1 a LaunchDaemon added every host of seven `/24` ranges (1,778 `ifconfig lo0 alias` calls) at every boot.
On a Mac with several network extensions (Tailscale, PIA, Docker, mDNSResponder all react to each change) that
stalled configd's `IPConfigurationAgent` queue for minutes. The result was userspace-watchdog kernel panics ("no
successful checkins from configd in 180 seconds"), twice in seven minutes, the second one 447 s after the reboot from
the first (#37). #38 paced the same task at 50 a second, but lo0 is empty at every boot, so it still made ~1,270
changes in the busiest window, with no feedback and no rollback.

## Decision

1. **No boot task.** The LaunchDaemon has no `RunAtLoad`. launchd starts it when a folder changes
   (`WatchPaths` on `/Library/Application Support/ProjectReclaimer/request`, `ThrottleInterval` 300). The launcher
   changes it when it opens and finds the addresses missing. People who don't play never pay for it, and the work
   happens after login has settled. The script also waits out the first two minutes after a boot, whatever starts it.
2. **No password after a restart.** The request folder belongs to the player (mode 700) inside root's own folder
   (root:wheel 755). So only the player's account can trigger the task. The sandboxed game can't, since
   `wine-sandbox.sb` denies writes outside `prefix-wine/`, temp and cache. The task never reads, writes or follows
   anything in that folder: launchd only watches it. (Uninstall deletes the folder as root with `rm -rf`, which
   doesn't follow symlinks.) The root script stays constant and input-free (no arguments, no
   environment, `PATH` set inside), and is hash-pinned and checked as root after copying, as before.
3. **Closed-loop pacing.** The task adds 25 aliases at a time. After each batch it times `scutil --nwi`. Slower than
   2 s means wait and ask again, for about a minute; no answer within 8 s means stop. Once configd answers again, it
   takes back what it added, in the same paced and checked batches. If configd doesn't recover, or stalls again
   partway through, it leaves the rest: aliases sitting on lo0 are harmless, and the churn of changing them is what
   hurts. It writes `loopback.status` (`adding`, `ok <n>`, `taken-back`, `stopped`) in root's folder, so the
   launcher can say what happened.
4. **Respect a task the player turned off.** With `launchctl disable system/local.projectreclaimer.loopback` (the #37
   workaround), install.sh and the launcher's network fix leave it alone. They don't install it again (launchd
   refuses to load it, so every update used to fail at this step), and they never ask for a password for it. The
   older version's files stay as they were, and they may be the boot task. So the way back is
   `sudo launchctl enable …` and then opening the app before the next restart, which installs the current task.
   install.sh says so.
5. **Fewer addresses: 1,016 instead of 1,270 (#38) or 1,778 (1.5.1).** Only ranges some release binds are added.

## Evidence

- **A netmask doesn't help.** On macOS, a program can only bind an address added as its own alias. An alias with a
  `/24` (or `127.0.0.1`'s own `/8`) that covers the address isn't enough (tested on an M1 Max, 2026-10-27). So each
  range needs every host.
- **`127.0.1.N`, `127.0.2.N`:** the client's slot, a new one each session. 0.9.23 logs `Local client slot 64:
  transport 127.0.1.64, native bind 127.0.2.64.` The same format strings (`src/local_network.rs`) are in 0.9.8,
  0.9.11, 0.9.13, 0.9.16 and 0.9.23.
- **`127.3.1.x`, `127.3.2.x`:** the native UDP bind (`Native UDP experiment bind 127.3.1.88:0 result=0`; 0.9.23 starts its
  engine worker with `--native-udp`). It is one address per release, worked out at runtime (no literal in the binary),
  and it moves: `127.3.1.64` on 0.9.11, `127.3.2.124` on 0.9.13 (joins were refused until that range was added, #3),
  `127.3.1.88` on 0.9.23. Both ranges stay until the rule behind it is known.
- **`127.0.0.x` is dropped.** No release from 0.9.8 to 0.9.23 has a `127.0.0.` address other than `127.0.0.1` (the
  local server browser, RCON, the master server default), and macOS already has `127.0.0.1`. `127.3.3.x` was a spare
  range nothing binds (already dropped in #38).
- **It works in play:** on an M1 Max (macOS 27.2, with Tailscale, PIA and Docker), multiplayer on 0.9.23 has worked
  over several sessions with no boot task. The addresses were added by hand after login, in batches of 25 with
  configd timed after each batch: every host of `127.0.1.x`, `127.0.2.x` and `127.3.2.x`, but only a few of
  `127.0.0.x` and `127.3.1.x` (`127.3.1.88` among them).

## Consequences

- After every restart, the first launcher open takes ~25 s longer before Play, with no password box. Measured on the
  M1 Max (2026-10-29, the script run by hand as root): 251 addresses in 10 batches took 6 s, and configd answered
  every check within 0.1 s. The full 1,016 is 41 batches. After that, nothing more until the next restart.
- A release whose native bind moves outside `127.3.1.x`/`127.3.2.x`, or a new slot range, needs a new script, so one
  password box on that update (as before).
- If launchd throttles a request (two within five minutes), the launcher says to open it again in a few minutes.
  The task runs once the five minutes are up anyway. launchd's `WatchPaths` can also miss a change (its man page
  warns about this). The script takes nothing from the folder, so a miss only means the launcher says the same thing,
  and the next open asks again.
- There is one request folder, owned by whoever installed last. On a Mac where two accounts each have an install,
  each account's launcher asks for a password when it finds the folder isn't its own, and takes it over.
- Hand-added partial sets read as "missing": the launcher checks the last host of every range.
