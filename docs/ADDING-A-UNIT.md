# Adding a new unit

The goal is a profile and a catalog entry the next person with the same
firmware can trust. An agent may do the reading and drafting; **a person
verifies every package** before it is used to disable anything.

## 1. Collect the read-only report

With the unit connected:

```sh
scripts/preflight.sh
scripts/discover.sh
```

`report/discover-<date>.txt` lists packages by tier, app labels, the real API
level and claimed release, RAM, screen, launcher claimants and suggestions. It
never changes the unit.

## 2. Propose a profile

Create `data/profiles/<id>/` with:

- `README.md` — the unit, the build, what was verified, and what was not.
- `packages.txt` — `pkg<TAB>tier<TAB># evidence`. Tier 1 is telemetry/ads/promo,
  tier 2 is unused system leftovers, tier 3 is preinstalled apps the person may
  use. The evidence comment says what the package is, not just its name.
- `never-disable.txt` — packages this firmware needs that the common list does
  not cover.
- `match.txt` — lines `prop <name>=<glob>` or `pkg <package>`. Every line must
  hold for the profile to be detected. Never match only on `ro.product.model`
  if two vendors use the same model string.

Start from `data/profiles/generic/` and add only what the unit proves.

## 3. Verify each package by hand

For every candidate, read:

```sh
adb -s <serial> shell dumpsys package <pkg>
```

Look at activities, services, receivers, requested permissions and `pkgFlags`.
A package that owns a HOME activity, is `PERSISTENT`, runs as a shared core uid,
or requests microphone/camera/location/telephony belongs on the never list or
in `ALLOW_RISKY` only after the person agrees and the evidence is written in
the profile comment. The guard list is in `docs/HOW-IT-WORKS.md`.

A name is not evidence. Map app labels from `data/common/apps.txt` and the
unit's own `pm list packages -3`; never guess a package from a name.

## 4. Test against the fake first

Copy the profile into `tests/fixtures/data/profiles/` when a guard or parser
needs it, and add a test that exercises the risky case. The offline suite must
pass before the profile meets a car.

## 5. Run one tier at a time

On the real unit, follow the order in `AGENTS.md`: dry run, the person's yes,
one tier, automatic checks, then the manual car checks. Do not skip a check
because it seems unrelated.

## 6. Write the catalog entry

At the end of a successful session:

```sh
scripts/contribute.sh
```

It fills the facts the scripts recorded, asks only what a robot cannot know,
refuses IP/MAC/VIN/e-mail/phone/coordinate-shaped answers, and validates the
YAML. A `status: tested` entry needs at least one car check and every check
`pass` or `n/a`.

The long field runbook is in `headroom-plan.md` (Field runbook).
