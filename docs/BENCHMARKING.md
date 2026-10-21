# Benchmarking

The goal is to show whether headroom helped, not to claim it did. Measure the
same way before and after, and report whatever the numbers say, including “no
change”.

## Method rules

- Same conditions every time: engine running outdoors (or a charger connected),
  same Wi-Fi, phone connected over Bluetooth or not exactly as last time, and
  the same apps installed.
- After any reboot, wait on the home screen for `--settle` seconds (default 90)
  before measuring.
- Run `--label before` **before** any change. If a before report already exists,
  the script asks before making another one.
- `benchmark.sh` never disables or enables a package. It only force-stops the
  apps being timed (harmless) and changes which app is in the foreground.
- Use `--runs 5` for the real before and after. Each timed metric stores the
  **median**, not the mean.

## What is measured

| Key | Better | How |
|---|---|---|
| `mem_available_kb` | higher | `MemAvailable` after settling on the home screen |
| `app_processes` | lower | `ps -A -o USER`, counting `u0_` users; falls back to `ps` on old toolbox |
| `loadavg_1m` | lower | `/proc/loadavg` |
| `home_ms` | lower | leave home, wait, press HOME, read `TotalTime:` |
| `apps.<pkg>_cold_ms` | lower | force-stop a third-party app, wait, start it, read `TotalTime:` |
| `boot_enable_screen_ms` | lower | `--boot`: reboot, then the last `boot_progress_enable_screen:` event |
| `data_free_kb` | higher | `df /data` |
| `disabled_packages` | context | `pm list packages -d` |

Only third-party apps with no guard reasons are timed. `benchmark.sh` refuses
to force-stop a vendor radio, phone, camera or other guarded app.

## Commands

```sh
scripts/benchmark.sh --label before --runs 5
scripts/benchmark.sh --label before-boot --boot --runs 1 -y
# ... run the rest of the pass, then:
scripts/benchmark.sh --label after --runs 5
tools/bench_compare.py report/bench-before-*.json report/bench-after-*.json
```

Reports are written to `report/bench-<label>-<yyyymmdd-HHMM>.json` and copied
to `~/.headroom/<device-id>/bench/` so they survive a re-clone. `report/` is
git-ignored: never paste it anywhere public.
