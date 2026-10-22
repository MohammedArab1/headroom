## What this changes

One topic only: a profile, **or** a catalog entry, **or** code. Never mixed.

## Checklist

- [ ] package lists come from this unit's own `pm list packages`, and each line
      has evidence in the comment
- [ ] `status` is honest (`tested` means the full pass ran and every car check
      is `pass` or `n/a`)
- [ ] no identifiers anywhere, including screenshots: no IP or MAC address,
      serial number, VIN, number plate, Wi-Fi name, e-mail, phone number,
      contacts or GPS coordinates
- [ ] `bash -n` and `shellcheck` pass, and `python3 -m unittest discover -s
      tests` is green
- [ ] the launcher job passes if `launcher/` changed (unit tests, lint, size,
      zero permissions, no background components)

## Evidence

Paste the `verify.sh` table, the batch counts, and the benchmark comparison
(`tools/bench_compare.py`). Do **not** paste `report/` or `~/.headroom/`.
