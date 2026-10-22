# Why not root?

Some units are rooted, or have an unlockable bootloader. This project still
stays on the shell user.

- **Reversible.** `pm disable-user` and `settings put` have supported undo
  commands. A modified system partition does not.
- **Survives updates.** After a firmware update, run `scripts/drift.sh --fix`;
  the same records re-apply. A custom system image is overwritten, or worse,
  leaves the unit half-updated.
- **Cannot corrupt `/system` or the MCU link.** Nothing here remounts a
  partition or writes firmware. The vendor's CAN-bus handling and the
  steering-wheel learning stay untouched.
- **No exploit required.** If Developer options cannot be reached, the answer is
  "this unit is not supported", not "find a hole". See `docs/CONNECTING.md`.
- **A person can undo it without the laptop.** Settings > Apps > Enable, or
  Settings > Apps > headroom home > Clear defaults.

A custom ROM is a different project with different risks. It is not a shortcut
for this one.
