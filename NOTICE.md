# Notice

`headroom` is an independent implementation. Its design draws on lessons from
two MIT-licensed projects:

- **dumbtv** — the agent contract, read-only preflight and discovery, the
  never-disable lists, the offline fake-ADB test harness, the device catalog
  and its validator.
- **cleanyourtv** — disable-instead-of-uninstall, recovery records written
  before the first change, guarded batches, the launcher handover, drift
  checks, the pure-Python ADB client, and closing ADB at the end of a session.

If code is copied from either project in future, its MIT copyright notice must
be reproduced here.

The catalog data under `catalog/` is licensed CC BY-SA 4.0. See
`catalog/LICENSE`.
