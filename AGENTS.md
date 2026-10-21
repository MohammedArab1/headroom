# AGENTS.md

You are about to change the software in someone's car. Read this whole file,
then interview the person before touching anything. The scripts are written so
an agent that follows this order never has to improvise.

## Scope

This project supports Android head units that expose a shell over ADB. If ADB
cannot be reached (no Developer options, a locked factory menu, a carrier-locked
unit), say so plainly. Do not look for exploits. Point at
`docs/CONNECTING.md`.

It is not for Android Automotive OS built into a car, and not for CarPlay-only
units.

## Hard rules

1. **Never while driving.** Car parked, parking brake on. Run the engine only
   outdoors, never in a closed garage. For long sessions, use a battery charger
   or maintainer instead.
2. **Never touch `/system`.** No root, no remount, no `su`, even if the unit is
   pre-rooted. No script contains these commands and CI greps for them.
3. **Never factory-reset the unit.** It can erase the CAN-bus profile and the
   steering-wheel key learning.
4. **Never launch factory, engineering or test apps, and never change a factory
   setting.** On some boards, merely opening one flips a mode flag. If the
   person already knows how to reach their factory settings screen, they may
   photograph it before starting, without changing anything.
5. **Never disable anything on a never-disable list**, or anything that is the
   current HOME, the current keyboard, or a device admin. These are hard blocks
   with no override.
6. **Never uninstall.** Disable only, with `pm disable-user --user 0`.
7. **Do not invent package names.** Every candidate comes from that unit's own
   `pm list packages`. Absent packages are skipped.
8. **Ask before the first destructive step.** `confirm()` stops unless a person
   said yes, or `-y` was passed after they did.
9. **One batch at a time. Car checks between batches.** `debloat.sh` refuses to
   start while an earlier batch has not passed `verify.sh --manual`.
10. **Only a person at the car answers car checks.** Relay the questions word
    for word and pass the person's answers with `--answers`. Never answer them
    yourself, never skip one because it seems unlikely to be affected, and
    never pass `s` unless the person said it does not apply.
11. **Guard overrides need evidence.** A package goes into `ALLOW_RISKY` only
    after a person has read `dumpsys package <pkg>` and agreed, and the reason
    is written into the profile's `packages.txt` comment.
12. **Never remove an app the person said they use.** If you are unsure which
    package an app is, ask.
13. **Keep identifiers out of the repo and out of public posts.** That means IP
    and MAC addresses, serial numbers, VIN, number plate, Wi-Fi names, account
    emails, phone numbers, contacts and GPS coordinates. `report/` and
    `headroom.conf` are git-ignored; recovery records live outside the repo.
14. **Never read personal data.** No `content query`, and no reading contacts,
    call logs, messages or location.
15. **One device at a time.** If more than one is connected, `need_device`
    stops and asks for `ADB_SERIAL`.
16. **Close ADB at the end of a session.** If the unit shares its own hotspot
    with passengers, an open ADB port is a shell for anyone in the car.

## Current implementation

Phases 0 to 14 are implemented (the launcher is written but has not been built
here: this machine had no JDK or Android SDK):

```sh
scripts/connect.sh <hu-ip>
scripts/preflight.sh
scripts/discover.sh
scripts/configure.sh ...
scripts/benchmark.sh --label before --runs 5
scripts/verify.sh
scripts/debloat.sh --tier 1 --dry-run
scripts/debloat.sh --tier 1 -y
scripts/restore.sh --last
scripts/bisect.sh --batch <id> --answers "y n ..."
scripts/tune.sh -y
scripts/launcher.sh -y
scripts/stock-launcher.sh --disable          # optional, after the 2-boot soak
scripts/verify.sh                            # after a firmware update: drift.sh
scripts/drift.sh
scripts/close-adb.sh <hu-ip>
```

`preflight.sh` is read-only. It writes the first snapshot, which is the record
undo will depend on, and never overwrites an existing one. `discover.sh` is
read-only: it writes `report/discover-<date>.txt` and suggests a profile, but
it never disables anything. `configure.sh` writes only `headroom.conf` (mode
600, git-ignored); it never changes the unit. `connect.sh` never scans the
network: the IP comes from the person.

`debloat.sh` is the first destructive script. It refuses to start without a
snapshot, a non-empty verified profile, and every earlier batch checked. It
writes the undo plan before the first disable, never uninstalls, and reboots.
`restore.sh` replays those plans, restores tweaks in reverse and puts HOME back.
`bisect.sh` narrows a bad batch to one package with a person's answers.
`tune.sh` records every value it changes before the first change, refuses to
background-restrict kept, docked or guarded apps, self-tests Private DNS and
reverts both keys if the resolver does not answer.

Phase 12 is the launcher in `launcher/`. Its pure-Java logic (`App`,
`ConfigCodec`, `DockModel`, `GridMath`, `AppOrder`) has JUnit tests; the Android
glue and resources are written. `tests/test_launcher_static.py` enforces zero
permissions, no background components, no runtime dependencies and the SDK
floor. To build it, follow `launcher/README.md`; the Gradle wrapper has not been
generated yet.

Phase 13 is the handover: `launcher/install.sh` (also reachable as
`scripts/launcher.sh`) builds or takes `--apk`, pushes and runs `pm install -r`,
starts the launcher **before** touching HOME, and rolls back with
`report/launcher-rollback.txt` and `STATE/set-home-ignored` when the firmware
ignores `set-home-activity`. `scripts/stock-launcher.sh` disables the vendor
launcher only after a 2-boot soak, applies every non-HOME guard (with
`IGNORE_HOME_GUARD` for the HOME ones), and re-enables it if HOME does not stay.
`drift.sh` reports packages that came back, HOME, tweaks, new preloads and a
changed build; `--fix` re-applies the packages through fresh guards, re-applies
the recorded tweaks with the Private DNS self-test, and re-takes HOME with the
install rollback logic. The next phase is `all.sh` (Phase 15).

## Order of operations (once the full tool exists)

```sh
scripts/connect.sh <hu-ip>
scripts/preflight.sh
scripts/configure.sh ...                       # answers from the interview
scripts/benchmark.sh --label before --runs 5
scripts/debloat.sh --tier 1 --dry-run          # show the person the plan
scripts/debloat.sh --tier 1 -y                 # only after they said yes
scripts/verify.sh && scripts/verify.sh --manual --answers "..."   # answers come from the PERSON
# repeat for --tier 2 and --tier 3
scripts/tune.sh -y
scripts/launcher.sh -y
# person: reboot once; then the guided ignition cycle:
scripts/verify.sh --acc-test
scripts/verify.sh && scripts/verify.sh --manual --answers "..."
scripts/benchmark.sh --label after --runs 5
tools/bench_compare.py report/bench-before-*.json report/bench-after-*.json
scripts/contribute.sh
scripts/close-adb.sh <hu-ip>                    # always, last
```

## Reading the output

| Word in output    | Meaning                                                                                                            |
| ----------------- | ------------------------------------------------------------------------------------------------------------------ |
| `disabled`        | `pm disable-user` succeeded                                                                                        |
| `refused`         | the firmware refused (protected package). Expected for some vendor packages: add them to the profile's `README.md` |
| `suspect: <text>` | unexpected output. Stop and have a person read it                                                                  |
| `SKIP (...)`      | intentionally not touched, with the reason                                                                         |
| `GUARD`           | a safety guard blocked it. The reasons are listed underneath                                                       |
| `absent`          | not installed on this unit                                                                                         |

Exit codes: 0 did what was asked; 1 a check failed or the person said no;
2 usage error or the unit could not be read.

## Overriding a guard

Only when the person wants a guarded package disabled. Show them
`dumpsys package <pkg>` (activities, services, receivers, permissions). If they
agree, write the evidence into the profile's `packages.txt` comment, then run
`configure.sh --allow-risky "<pkg>"`. Never override a `hard:` reason.

## Recovery

| Symptom                                             | Likely cause                                         | Fix                                                                                                                |
| --------------------------------------------------- | ---------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| A car check fails after a batch                     | something in that batch was load-bearing             | `scripts/restore.sh --last`, check again, then `scripts/bisect.sh`                                                 |
| Black screen or no home after boot                  | HOME lost its target                                 | `launcher/install.sh --undo`, or `scripts/stock-launcher.sh --enable --make-home`                                  |
| HOME lands on a setup wizard or FallbackHome        | vendor launcher disabled, another claimant took HOME | `scripts/stock-launcher.sh --enable --make-home`                                                                   |
| ADB lost after reboot                               | Wireless debugging changed port                      | `scripts/connect.sh` again (pairing persists)                                                                      |
| Keyboard missing                                    | the IME package is disabled                          | `scripts/restore.sh --package <ime>`; `verify.sh` names it                                                         |
| No internet after `tune.sh`                         | Private DNS resolver unreachable                     | `scripts/restore.sh --all --no-home`                                                                               |
| Unit does not sleep with ignition off               | a power/ACC package is disabled                      | `scripts/restore.sh --last`; fix before driving off                                                                |
| Everything is back after a firmware update          | the update re-enabled packages                       | `scripts/drift.sh`, then `scripts/drift.sh --fix`                                                                  |
| ADB will not come back and a car function is broken | ADB off after the reboot                             | on the unit: Settings > Apps (show system apps) > enable each app in `report/manual-undo-<batch>.txt`, then reboot |
| HOME is wrong and no laptop is at hand              | launcher handover                                    | on the unit: Settings > Apps > headroom home > Open by default > Clear defaults (or Disable)                       |
| Start over                                          |                                                      | `scripts/restore.sh --all`                                                                                         |

## Reporting

Never paste `report/` or `~/.headroom/` anywhere public. Summarise the verify
table, the batch counts and the benchmark comparison instead.
