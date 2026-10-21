# headroom

**Declutter and speed up an Android car head unit over ADB. No root, nothing
uninstalled, every step reversible.**

Work in progress. The implementation follows `headroom-plan.md`. See
`AGENTS.md` before running anything against a real head unit.

## Status

Implemented and covered by offline tests:

- Phase 0: repository scaffold
- Phase 1: `scripts/lib.sh`, the fake head unit, and the safety-guard tests
- Phase 2: `scripts/connect.sh`, `tools/pyadb`, `scripts/close-adb.sh`
- Phase 3: `scripts/preflight.sh` and the one-time snapshot
- Phase 5 data files: `data/common/`, the generic profile, and the fixture profile

Not built yet: `discover.sh`, `configure.sh`, `benchmark.sh`, `debloat.sh`,
`tune.sh`, `restore.sh`, `verify.sh`, the launcher, and the catalog tooling.
Until `debloat.sh` exists, nothing in this repository can disable a package.

## Safety

- Never while driving. Parked, parking brake on. Run the engine only outdoors.
- Never root, remount, flash, or touch `/system`.
- Never factory-reset, and never open factory or engineering menus.
- Disable only (`pm disable-user`); never uninstall.
- A person at the car answers the car checks. No script or agent may answer
  them on that person's behalf.

## Quickstart (read-only, once connected)

```sh
scripts/connect.sh <hu-ip>          # or --pair ... for Android 11+
scripts/preflight.sh                # facts + the one-time snapshot
scripts/close-adb.sh <hu-ip>        # end the session
```

The snapshot is written to `~/.headroom/<device-id>/snapshot/`, outside the
repository. It is the record undo will depend on, so the first run wins and
later runs never overwrite it.

## Tests

No head unit is needed:

```sh
python3 -m unittest discover -s tests -v
bash -n scripts/*.sh
shellcheck scripts/*.sh
```

The tests run every script against `tests/fake_adb.py`, which keeps state in
JSON and exits 92 on any command it does not explicitly support.

## Connecting

See `docs/CONNECTING.md` for hotspot setup, Android 11 wireless pairing,
macOS Local Network privacy, the `tools/pyadb` fallback, and closing ADB at the
end of a session.
