# Car safety

The scripts change software in a car. Treat the car, not the unit, as the
primary risk.

## When and where

- **Parked, parking brake on.** Never run a destructive step while driving.
- **Engine only outdoors.** Never in a closed garage: carbon monoxide. For long
  sessions, use a battery charger or maintainer instead of idling.
- **One device at a time.** If two units are connected, `need_device` stops and
  asks for `ADB_SERIAL`.
- **ADB is a shell.** At the end of the session, run `scripts/close-adb.sh
  <hu-ip>` and turn debugging off on the unit. On a unit that shares its own
  hotspot, an open port is a shell for passengers.

## Why the car checks exist

A head unit is wired to the car through the MCU. A package that looks like an
unused vendor app can host the reverse-camera trigger, the steering-wheel
buttons, or the sleep timer. The checks in `data/common/car-checks.txt` are the
things a person must see with their own eyes after every batch:

| Check | Why it matters |
|---|---|
| `reverse` | the camera must appear within about 2 seconds |
| `guides` | parking lines or sensor overlay may be a separate package |
| `swc` | steering-wheel volume, track and call buttons |
| `radio` | tuner and audio path |
| `bt-pair`, `bt-call`, `bt-audio`, `mic` | hands-free calling is a safety feature |
| `usb-media` | USB audio path |
| `nav` | GPS fix and the navigation app |
| `projection` | CarPlay / Android Auto |
| `canbus` | door, climate, fuel and parking-sensor displays |
| `dimming` | screen dimming with the headlights |
| `acc-sleep`, `acc-wake` | a unit that never sleeps drains the battery |
| `clock` | the clock after waking |
| `keyboard` | typing Wi-Fi passwords and destinations |

A failed check after a batch means something in that batch was load-bearing:
`scripts/restore.sh --last`, check again, then `scripts/bisect.sh`.

## The ignition cycle

After a launcher change, and at the end of a pass, a person reboots once and
then runs the guided ignition test:

```sh
scripts/verify.sh --acc-test
```

It waits for the unit to sleep with the ignition off, then asks the person to
turn the ignition on. A new boot id means a cold boot; the same id means a wake
from sleep. Record the boot id in the launcher soak only after the home and car
checks pass.

## Driver distraction

The launcher is built for a car: black background, high contrast, 76 dp minimum
targets, no motion except press feedback, and a dock of six apps plus All apps.
The app grid is meant for use when parked. Do not add widgets, video, or
animations to the home screen.
