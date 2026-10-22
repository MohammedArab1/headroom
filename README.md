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
- Phase 4: `scripts/discover.sh` (read-only inventory and suggestions)
- Phase 5 data files: `data/common/`, the generic profile, and the fixture profile
- Phase 6: `scripts/configure.sh` (the interview and `headroom.conf`)
- Phase 7: `scripts/benchmark.sh` and `tools/bench_compare.py`
- Phase 8: `scripts/debloat.sh` (one tier, one recorded batch)
- Phase 9: `scripts/tune.sh` (recorded settings, background restriction, cache trim,
  Private DNS self-test, ahead-of-time compile)
- Phase 10: `scripts/restore.sh` and `scripts/bisect.sh`
- Phase 11: `scripts/verify.sh` (automatic checks, manual gate, ignition test)
- Phase 12: the `launcher/` app (headroom home) — source and static acceptance
  checks; it has not been compiled or run here (no JDK or Android SDK on this
  machine yet)
- Phase 13: `launcher/install.sh`, `scripts/launcher.sh` and
  `scripts/stock-launcher.sh` (handover, 2-boot soak gate, rollback)
- Phase 14: `scripts/drift.sh` (what a firmware update undid, with `--fix`
  through fresh guards)
- Phase 15: `scripts/all.sh` (the whole pass, stopping at every gate)
- Phase 16: `catalog/schema.json`, `catalog/validate.py` and
  `scripts/contribute.sh` (identifier-free catalog entries)

Not built yet: the remaining user docs and CI.

## Development

The offline suite uses PyYAML for the catalog validator:

```sh
python3 -m venv tools/venv
tools/venv/bin/pip install -r requirements-dev.txt
tools/venv/bin/python -m unittest discover -s tests -v
```

`tools/venv/` is git-ignored. The launcher build needs a JDK and the Android
SDK; see `launcher/README.md`.

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
scripts/discover.sh                 # read-only inventory -> report/discover-*.txt
scripts/configure.sh --keep ...      # the interview -> headroom.conf
scripts/benchmark.sh --label before --runs 5
scripts/verify.sh                   # automatic health checks
scripts/debloat.sh --tier 1 --dry-run
scripts/debloat.sh --tier 1 -y      # only after the person agrees
scripts/verify.sh --manual          # a person answers the car checks
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
