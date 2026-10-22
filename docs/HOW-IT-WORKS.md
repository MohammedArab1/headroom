# How it works

Everything runs as the Android shell user (uid 2000) over ADB. Nothing here
needs root, and nothing writes outside the app and settings databases.

## The levers

| Lever | Command | What it changes | Undo |
|---|---|---|---|
| Package state | `pm disable-user --user 0 <pkg>` | the package cannot start, is absent from launchers, and keeps its data | `pm enable --user 0 <pkg>`; a person can do it in Settings > Apps |
| Global settings | `settings put global <key> <value>` | animation scales, always-on scanning, Private DNS | the value recorded before the first change |
| Compile state | `cmd package bg-dexopt-job`, `cmd package compile -m speed -f <pkg>` | apps run from ahead-of-time compiled code instead of JIT | not needed: Android redoes this by itself when idle |
| App-ops | `cmd appops set <pkg> RUN_IN_BACKGROUND ignore` | the app cannot keep a background process | the mode recorded before the change |
| Private DNS | `private_dns_specifier` + `private_dns_mode hostname` | every lookup goes to the chosen resolver | both values are recorded, and both are reverted automatically if the resolver does not answer |
| HOME | `cmd package set-home-activity --user 0 app.headroom.home/.HomeActivity` | which launcher answers the HOME key | `launcher/install.sh --undo`, or Settings > Apps > headroom home > Clear defaults |

These are enough because each one is a supported API that survives a reboot and
can be reversed with another supported API. None of them touches `/system`,
firmware, the MCU or the CAN bus.

## The records

`preflight.sh` writes one snapshot per unit under `~/.headroom/<device-id>/`,
outside the repository, and never overwrites it. `debloat.sh` writes a batch
plan **before** the first disable; `restore.sh` replays it. `tune.sh` records
the old value of every setting and app-op before it changes it. `verify.sh`
writes one checks file per manual session. `drift.sh` reads all of these to
notice what a firmware update undid.

`report/` holds human-readable output (manual-undo lists, rollback commands,
benchmarks). It is git-ignored.

## Guards

The guards are code, not advice (see `risk_reasons` and `blocking_reasons` in
`scripts/lib.sh`).

**Hard blocks, no override:**

- a package on the common or profile never-disable list
- `app.headroom.home` itself
- the current keyboard (`default_input_method`)
- the current HOME app, or any package that answers HOME
- a package named by device policy (a device admin)

**Risk blocks, overridable only with recorded evidence:**

- an enabled accessibility service
- a shared core uid below 10000 (system, phone, Bluetooth and friends)
- `pkgFlags=[... PERSISTENT ...]` (it is always running)
- a sensitive permission (microphone, camera, location, telephony, SMS...)
- a name that matches a sensitive pattern (CAN bus, MCU, radio, Bluetooth,
  phone, camera, reverse, steering wheel, audio, TPMS, GPS, navigation,
  CarPlay/Android Auto, factory/settings, Wi-Fi, power/ACC...)

Overriding a risk block means a person reads `dumpsys package <pkg>` and agrees;
the reason goes into the profile's `packages.txt` comment, then
`configure.sh --allow-risky "<pkg>"`. The hard blocks cannot be overridden.

`tune.sh` additionally refuses to background-restrict an app in `KEEP_APPS`, a
docked app, or anything a guard blocks. A package that is not installed is
skipped, never invented.

## What is not used, and why

- **`pm uninstall`** — irreversible for preloaded apps on older Android, even
  with `--user 0`; the APK can be gone from the user and hard to restore.
- **`pm hide`** — the shell user lacks `MANAGE_USERS`.
- **`pm suspend`** — a suspended app shows a dialog when opened, and Settings >
  Apps does not show the state as plainly as "disabled", which matters for an
  undo by hand.
- **Root or remounting `/system`** — rule 2. It also breaks firmware updates and
  can corrupt the MCU link.
- **A hosts file** — it lives on `/system`.
- **"RAM booster" apps** — they kill processes the OS will restart, and cost
  more than they save.
- **Developer-option background process limits** — they reset at reboot and
  kill navigation and music in the background.
- **Changing MCU or CAN-bus settings** — out of scope, and a factory reset can
  erase the steering-wheel learning.
