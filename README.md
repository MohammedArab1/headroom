# headroom

**Declutter and speed up an Android car head unit over ADB. No root, nothing
uninstalled, every step reversible.**

Work in progress. The implementation follows `headroom-plan.md`. Read
`AGENTS.md` before running anything against a real head unit.

## Status

Implemented and covered by offline tests:

- Phase 0: repository scaffold
- Phase 1: `scripts/lib.sh`, the fake head unit, and the safety-guard tests
- Phase 2: `scripts/connect.sh`, `tools/pyadb`, `scripts/close-adb.sh`
- Phase 3: `scripts/preflight.sh` and the one-time snapshot
- Phase 4: `scripts/discover.sh` (read-only inventory and suggestions)
- Phase 5 data files: `data/common/`, the generic profile, and the fixture profile
- Phase 6: `scripts/configure.sh` (the interview and `headroom.conf`)
- Phase 7: `scripts/benchmark.sh` and `tools/bench_compare.py`
- Phase 8: `scripts/debloat.sh` (one tier, one recorded batch)
- Phase 9: `scripts/tune.sh` (recorded settings, background restriction, cache trim,
  Private DNS self-test, ahead-of-time compile)
- Phase 10: `scripts/restore.sh` and `scripts/bisect.sh`
- Phase 11: `scripts/verify.sh` (automatic checks, manual gate, ignition test)
- Phase 12: the `launcher/` app (headroom home) — built, unit-tested and
  linted in Docker: 24 KB release APK, zero permissions, no lint issues;
  emulator and real-unit checks still pending
- Phase 13: `launcher/install.sh`, `scripts/launcher.sh` and
  `scripts/stock-launcher.sh` (handover, 2-boot soak gate, rollback)
- Phase 14: `scripts/drift.sh` (what a firmware update undid, with `--fix`
  through fresh guards)
- Phase 15: `scripts/all.sh` (the whole pass, stopping at every gate)
- Phase 16: `catalog/schema.json`, `catalog/validate.py` and
  `scripts/contribute.sh` (identifier-free catalog entries)
- Phase 17: `PROMPT.md`, `llms.txt`, the `skills/headunit-debloat` skill, and
  `docs/` (how it works, gotchas, car safety, adding a unit, why not root, FAQ)
- Phase 18: `.github/workflows/ci.yml` (scripts on Ubuntu and macOS, the real
  launcher build, APK budgets), the PR template and the unit-report issue form

All 18 phases are implemented. The launcher was built and linted in Docker
(`launcher/docker-build.sh`): unit tests and `lintRelease` pass, the release APK
is 24 KB with zero permissions, no background components and no runtime
dependencies. The emulator checks and everything that needs a car still remain:
nothing has been tested on a real head unit yet.

## What it changes

| Area        | What headroom does                                                                                                 | Reversible?                                        |
| ----------- | ------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------- |
| Packages    | disables tier 1 (telemetry, ads, promo), tier 2 (unused system leftovers) and the tier-3 apps the owner said no to | yes: `pm enable`, `restore.sh`, or Settings > Apps |
| Animations  | window, transition and animator scales to 0.5 or 0                                                                 | yes: the old values are recorded                   |
| Scanning    | always-on Wi-Fi and Bluetooth scanning off                                                                         | yes: the old values are recorded                   |
| Background  | chosen apps cannot run in the background (`appops`)                                                                | yes: the old mode is recorded                      |
| Storage     | optional cache trim when `/data` is over 85% full                                                                  | caches rebuild themselves                          |
| Private DNS | optional filtering resolver, with a self-test and automatic revert                                                 | yes: both keys are recorded                        |
| Compilation | ahead-of-time compile of apps and the launcher                                                                     | not needed: Android redoes it                      |
| HOME        | optional replacement launcher with no permissions and no internet                                                  | yes: `launcher/install.sh --undo`                  |
| Measurement | before/after RAM, processes, HOME and app cold-start times                                                         | n/a                                                |

## What it will not do

- root the unit, remount or write `/system`, or flash firmware
- change MCU or CAN-bus settings
- open factory, engineering or test menus
- factory-reset the unit (it can erase the CAN profile and steering-wheel keys)
- uninstall anything (`pm disable-user` only)
- read contacts, call logs, messages, navigation history or location
- run while the car is moving

## Quickstart (read-only, once connected)

```sh
scripts/connect.sh <hu-ip>          # or --pair ... for Android 11+
scripts/preflight.sh                # facts + the one-time snapshot
scripts/discover.sh --labels --screens  # read-only inventory, app names and a screenshot
scripts/configure.sh --keep ...     # the interview -> headroom.conf
scripts/benchmark.sh --label before --runs 5
scripts/verify.sh                   # automatic health checks
scripts/debloat.sh --tier 1 --dry-run
scripts/debloat.sh --tier 1 -y      # only after the person agrees
scripts/verify.sh --manual          # a person answers the car checks
scripts/close-adb.sh <hu-ip>        # end the session
```

The full order is in `AGENTS.md`. The snapshot is written to
`~/.headroom/<device-id>/snapshot/`, outside the repository. It is the record
undo depends on, so the first run wins and later runs never overwrite it.

## Reversibility

`scripts/restore.sh --all` re-enables every package headroom disabled, restores
every recorded setting and app-op in reverse order, and puts HOME back.

It is honest about what it does not cover:

- **Ahead-of-time compilation is not undone.** Android redoes it when idle
  anyway; there is nothing to restore.
- **Packages disabled outside headroom are untouched.** Only headroom's own
  batch records are replayed.
- **A removed APK cannot be restored.** That is why nothing is uninstalled.
- **A vendor launcher can be re-enabled**, but if HOME does not stay,
  `scripts/stock-launcher.sh --enable --make-home` is the recovery.

## Scripts

| Script                      | What it does                                         | Reboots?                   |
| --------------------------- | ---------------------------------------------------- | -------------------------- |
| `scripts/connect.sh`        | connect over ADB; never scans the network            | no                         |
| `scripts/close-adb.sh`      | turn debugging off and prove the port closed         | no                         |
| `scripts/preflight.sh`      | facts and the first snapshot; read-only              | no                         |
| `scripts/discover.sh`       | package inventory and profile suggestions; read-only | no                         |
| `scripts/configure.sh`      | the interview; writes `headroom.conf` only           | no                         |
| `scripts/benchmark.sh`      | before/after metrics                                 | only with `--boot`         |
| `scripts/debloat.sh`        | disable one tier and record the batch                | yes                        |
| `scripts/verify.sh`         | automatic checks and the manual gate                 | `--acc-test` waits for one |
| `scripts/restore.sh`        | enable packages, restore tweaks and HOME             | yes                        |
| `scripts/bisect.sh`         | narrow a bad batch to one package                    | only with `--reboot-each`  |
| `scripts/tune.sh`           | recorded speed settings and compile                  | no                         |
| `scripts/launcher.sh`       | install and hand over headroom home                  | no; a person reboots after |
| `scripts/stock-launcher.sh` | disable the vendor launcher after a soak             | yes                        |
| `scripts/drift.sh`          | report firmware drift; `--fix` re-applies it         | no; `--fix` yes            |
| `scripts/all.sh`            | the whole pass, stopping at every gate               | yes                        |
| `scripts/contribute.sh`     | write and validate a catalog entry                   | no                         |

## The launcher

`headroom home` is a small home screen: clock, date, up to six dock apps, an app
grid and options. The release build is 24 KB with zero permissions and no lint
issues. Its acceptance budget:

| Property                | Target                             |
| ----------------------- | ---------------------------------- |
| permissions             | zero                               |
| runtime dependencies    | none                               |
| release APK             | under 150 KB                       |
| RAM with home on screen | under 40 MB PSS                    |
| touch target            | at least 76 dp                     |
| motion                  | no animation except press feedback |
| background components   | none                               |
| Android                 | minSdk 26, targetSdk 34            |

`tests/test_launcher_static.py` enforces the parts that need no build. See
`launcher/README.md` for the build steps and the emulator checks.

## Development

The offline suite uses PyYAML for the catalog validator:

```sh
python3 -m venv tools/venv
tools/venv/bin/pip install -r requirements-dev.txt
tools/venv/bin/python -m unittest discover -s tests -v
```

`tools/venv/` is git-ignored. The tests run every script against
`tests/fake_adb.py`, which keeps state in JSON and exits 92 on any command it
does not explicitly support. No head unit is needed.

Syntax and shell checks:

```sh
bash -n scripts/*.sh
shellcheck scripts/*.sh
python3 catalog/validate.py
```

The launcher build needs a JDK and the Android SDK; see `launcher/README.md`.
Or run the whole build in Docker, with no local SDK:

```sh
launcher/docker-build.sh
```

Docker on macOS cannot run a hardware-accelerated Android emulator, so the
visual/emulator checks still need a real device, a head unit, or a local SDK
emulator.

## Safety

- Never while driving. Parked, parking brake on. Run the engine only outdoors.
- Never root, remount, flash, or touch `/system`.
- Never factory-reset, and never open factory or engineering menus.
- Disable only (`pm disable-user`); never uninstall.
- A person at the car answers the car checks. No script or agent may answer
  them on that person's behalf.
- Close ADB at the end of every session.

Details: `docs/CAR-SAFETY.md`.

## For AI agents

Start with `AGENTS.md`. `PROMPT.md` is a paste-ready block for a coding
assistant; `CLAUDE.md` is the short form; `llms.txt` indexes the docs;
`skills/headunit-debloat/SKILL.md` packages the same workflow as a skill.
`docs/ADDING-A-UNIT.md` covers turning a discovery report into a reviewed
profile.

## Connecting

See `docs/CONNECTING.md` for hotspot setup, Android 11 wireless pairing, macOS
Local Network privacy, the `tools/pyadb` fallback, and closing ADB at the end of
a session.

## Credits and licences

The design draws on **dumbtv** (agent contract, read-only preflight/discovery,
never-disable lists, fake-ADB tests, catalog) and **cleanyourtv**
(disable-not-uninstall, recovery records, guarded batches, launcher handover,
drift, the pure-Python ADB client, closing ADB). See `NOTICE.md`.

Code is MIT (`LICENSE`). Catalog data under `catalog/devices/` is CC BY-SA 4.0
(`catalog/LICENSE`).
