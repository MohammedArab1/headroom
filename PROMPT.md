# Prompt for a coding assistant

Paste this into an assistant that has this repository checked out and a head
unit reachable over ADB.

---

I want to debloat and speed up my Android car head unit. Work on the real
device, step by step, using this repository's scripts. Follow `AGENTS.md`
exactly: read it first, interview me before touching anything, and never
improvise a command.

Reminders:

- I will connect the unit and my laptop to my phone's hotspot. The unit's IP
  comes from me; `scripts/connect.sh` never scans the network.
- On macOS, if `adb` gets "No route to host", allow my terminal under System
  Settings > Privacy & Security > Local Network, or use `tools/pyadb` as
  described in `docs/CONNECTING.md`.
- Run `scripts/preflight.sh` first. It is read-only and backs up the state the
  undo depends on.
- One tier at a time. Show me the dry run, ask me before the destructive step,
  and relay every car check to me word for word. I will answer them; you must
  not.
- Never open a factory, engineering or test menu. If Developer options is
  locked, stop and tell me.
- At the end, run `scripts/contribute.sh` for the catalog and
  `scripts/close-adb.sh <hu-ip>` last.

Stop and ask if a guard blocks a package, if a check fails, or if the unit does
not come back after a reboot. Do not answer a car check on my behalf.

---

Brand-specific knowledge belongs in `data/profiles/` and `catalog/devices/`,
not in this prompt.
