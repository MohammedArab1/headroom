---
name: headunit-debloat
description: Debloat and speed up an Android car head unit over ADB without root, with a person at the car answering the safety checks. Not for Android Automotive OS built into cars, and not for CarPlay-only units.
---

# headunit-debloat

Use this skill when someone wants to disable unused preloaded apps, shorten
animations, or replace the launcher on an Android head unit that exposes a shell
over ADB.

## Read first

`AGENTS.md` is the contract. This skill is a short index; if they disagree,
`AGENTS.md` wins.

## Preconditions

- The car is parked with the parking brake on. The engine runs only outdoors, or
  a charger is connected.
- `scripts/connect.sh <hu-ip>` succeeds and `adb devices` shows `device`.
  `unauthorized` means a person taps Allow; do not retry in a loop.
- `scripts/preflight.sh` has written the snapshot.

## Order

1. Interview the person (the 15 questions in `AGENTS.md`, Step 0) and record the
   answers with `scripts/configure.sh`.
2. `scripts/benchmark.sh --label before --runs 5`.
3. For tier 1, 2, then 3: `scripts/debloat.sh --tier N --dry-run`, show the
   plan, get a yes, run with `-y`, then `scripts/verify.sh` and
   `scripts/verify.sh --manual`.
4. `scripts/tune.sh -y`, then `scripts/launcher.sh -y` if the person wants the
   launcher.
5. A person reboots once and cycles the ignition; then
   `scripts/verify.sh --acc-test` and `scripts/verify.sh --manual`.
6. `scripts/benchmark.sh --label after --runs 5` and
   `tools/bench_compare.py` on the two reports.
7. `scripts/contribute.sh`, then `scripts/close-adb.sh <hu-ip>`.

## Report back

Summarise the verify table, the batch counts, the benchmark comparison and any
`SKIP`/`GUARD` lines with their reasons. Never paste `report/` or
`~/.headroom/`. Never include an IP, MAC, serial, VIN, plate, e-mail, phone
number or coordinates.

## Guardrails

- Never root, remount, flash or touch `/system`.
- Never factory-reset or open factory/engineering menus.
- Never uninstall; `pm disable-user` only.
- Never answer a car check. Relay the question word for word and pass the
  person's answer.
- Never override a `hard:` guard. A `risk:` guard needs the person's agreement
  and the evidence in the profile, then `configure.sh --allow-risky`.

## Recovery

The table in `AGENTS.md` > Recovery is the short version. The most common cases:

- a failed check after a batch: `scripts/restore.sh --last`, check again, then
  `scripts/bisect.sh`;
- no home screen after a boot: `launcher/install.sh --undo`, or
  `scripts/stock-launcher.sh --enable --make-home`;
- everything back after a firmware update: `scripts/drift.sh`, then
  `scripts/drift.sh --fix`;
- ADB gone and a car function broken: on the unit, Settings > Apps (show system
  apps), enable the apps in `report/manual-undo-<batch>.txt`, then reboot.
