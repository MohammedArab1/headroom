#!/usr/bin/env bash
# Measure the unit the same way before and after. Never disables or enables a package.
# Usage: scripts/benchmark.sh --label before --runs 5 [--boot] [--settle 90] [-y] [--dry-run]
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LABEL=run
RUNS=3
SETTLE=${SETTLE:-90}
HOME_WAIT=${HOME_WAIT:-2}
COLD_SLEEP=${COLD_SLEEP:-3}
BOOT=0

while [[ $# -gt 0 ]]; do
  case $1 in
    --label) [[ $# -ge 2 ]] || die "--label needs a value"; LABEL=$2; shift 2 ;;
    --runs) [[ $# -ge 2 ]] || die "--runs needs a value"; RUNS=$2; shift 2 ;;
    --settle) [[ $# -ge 2 ]] || die "--settle needs a value"; SETTLE=$2; shift 2 ;;
    --boot) BOOT=1; shift ;;
    --dry-run|-y|--yes) common_flag "$1"; shift ;;
    -h|--help)
      printf 'usage: scripts/benchmark.sh --label before --runs 5 [--boot] [--settle 90] [-y] [--dry-run]\n'
      exit 0 ;;
    *) die "unknown flag: $1" ;;
  esac
done

case $LABEL in ''|*[!A-Za-z0-9._-]*) die "--label must be letters, digits, dot, dash or underscore" ;; esac
case $RUNS in ''|*[!0-9]*|0) die "--runs must be a positive number" ;; esac
case $SETTLE in ''|*[!0-9]*) die "--settle must be seconds, 0 or more" ;; esac
[[ $RUNS -le 10 ]] || die "--runs is capped at 10; this is a car, not a lab"

need_device
load_conf
installed=$(installed_set)
third=$(third_set)
[[ -n $installed ]] || die "could not read the package list from $SERIAL"

BENCH_LIST=""
if [[ -n $BENCH_APPS ]]; then
  load_device_facts
  for p in $BENCH_APPS; do
    if ! in_lines "$p" "$installed"; then warn "$p is not installed; skipping"; continue; fi
    if ! in_lines "$p" "$third"; then warn "$p is not third-party; benchmark.sh refuses vendor apps"; continue; fi
    why=$(blocking_reasons "$p")
    if [[ -n $why ]]; then
      warn "$p is guarded, so it will not be force-stopped:"
      printf '%s\n' "$why" | sed 's/^/    /' >&2
      continue
    fi
    BENCH_LIST="$BENCH_LIST $p"
  done
fi

note "conditions: engine outdoors or a charger connected; same Wi-Fi, Bluetooth and apps as last time"
note "settle ${SETTLE}s on the home screen before measuring; $RUNS run(s) per timed metric"
if [[ $BOOT == 1 ]]; then note "boot mode: the unit will reboot once"; fi

if [[ $DRY_RUN == 1 ]]; then
  note "[dry-run] would measure home_ms and ${BENCH_LIST:-no bench apps}; boot=$BOOT; no files written"
  exit 0
fi

if [[ $LABEL == before ]]; then
  existing=""
  for f in "$REPORT"/bench-before-*.json; do
    [[ -e $f ]] && existing=$f
  done
  if [[ -n $existing ]]; then
    note "a before benchmark already exists: $existing"
    confirm "Run another before benchmark and keep both?" || die "cancelled"
  fi
fi
if [[ $BOOT == 1 ]]; then
  confirm "Reboot the unit now to measure boot time? (engine outdoors, or a charger connected)" || die "cancelled"
fi

if [[ $SETTLE -gt 0 ]]; then sleep "$SETTLE"; fi

median() {
  sed -n '/^[0-9][0-9]*$/p' | sort -n \
    | awk '{a[NR]=$1} END{ if(!NR){print "null"} else if(NR%2){print a[(NR+1)/2]} else {print int((a[NR/2]+a[NR/2+1])/2)} }'
}
total_time() { sed -n 's/^TotalTime: *\([0-9][0-9]*\).*/\1/p' | head -n 1; }
json_num() {
  if [[ ${1:-} =~ ^[0-9]+(\.[0-9]+)?$ ]]; then printf '%s' "$1"; else printf 'null'; fi
}

measure_home() {
  local i out v vals=""
  for i in $(seq 1 "$RUNS"); do
    acmd 'am start -W -a android.settings.SETTINGS' >/dev/null
    sleep "$HOME_WAIT"
    out=$(acmd 'am start -W -a android.intent.action.MAIN -c android.intent.category.HOME')
    v=$(printf '%s\n' "$out" | total_time)
    [[ -n $v ]] && vals="$vals$v"$'\n'
  done
  printf '%s' "$vals" | median
}
measure_app() {  # package, component
  local p=$1 comp=$2 i out v vals=""
  for i in $(seq 1 "$RUNS"); do
    acmd "am force-stop $p" >/dev/null
    sleep "$COLD_SLEEP"
    out=$(acmd "am start -W -n $comp")
    v=$(printf '%s\n' "$out" | total_time)
    [[ -n $v ]] && vals="$vals$v"$'\n'
    acmd 'input keyevent KEYCODE_HOME' >/dev/null
    sleep "$HOME_WAIT"
  done
  printf '%s' "$vals" | median
}

mem_available=$(dev_ok 'cat /proc/meminfo' | awk '/^MemAvailable:/ {print $2; exit}')
ps_out=$(dev_ok 'ps -A -o USER')
case $ps_out in
  *"bad pid"*|'') ps_out=$(dev_ok ps) ;;
esac
app_processes=$(printf '%s\n' "$ps_out" | awk '$1 ~ /^u0_/ {n++} END {print n+0}')
loadavg=$(dev_ok 'cat /proc/loadavg' | awk '{print $1; exit}')
df_line=$(dev_ok 'df /data' | sed '/^[[:space:]]*$/d' | tail -n 1)
data_free=$(printf '%s\n' "$df_line" | awk '{print $4}')
disabled=$(disabled_set)
n_disabled=$(printf '%s\n' "$disabled" | grep -c .)

home_ms=$(measure_home)

APP_JSON=""
for p in $BENCH_LIST; do
  comp=$(dev_ok "cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.LAUNCHER $p" | tail -n 1)
  case $comp in
    */*) ;;
    *) warn "no launcher activity for $p; skipping its cold start"; continue ;;
  esac
  med=$(measure_app "$p" "$comp")
  APP_JSON="$APP_JSON  \"apps.${p}_cold_ms\": $(json_num "$med"),"$'\n'
  note "apps.${p}_cold_ms = $med"
done

boot_ms=""
if [[ $BOOT == 1 ]]; then
  reboot_wait
  boot_ms=$(dev_ok 'logcat -b events -d' \
    | sed -n 's/.*boot_progress_enable_screen: *\([0-9][0-9]*\).*/\1/p' | tail -n 1)
fi

report_file="$REPORT/bench-$LABEL-$(date +%Y%m%d-%H%M).json"
mkdir -p "$REPORT" "$STATE/bench"
{
  printf '{\n'
  printf '  "label": "%s",\n' "$LABEL"
  printf '  "date": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '  "runs": %s,\n' "$RUNS"
  printf '  "sdk": %s,\n' "$SDK"
  printf '  "mem_available_kb": %s,\n' "$(json_num "$mem_available")"
  printf '  "app_processes": %s,\n' "$(json_num "$app_processes")"
  printf '  "loadavg_1m": %s,\n' "$(json_num "$loadavg")"
  printf '  "home_ms": %s,\n' "$(json_num "$home_ms")"
  printf '%s' "$APP_JSON"
  if [[ $BOOT == 1 ]]; then
    printf '  "boot_enable_screen_ms": %s,\n' "$(json_num "$boot_ms")"
  else
    printf '  "boot_enable_screen_ms": null,\n'
  fi
  printf '  "data_free_kb": %s,\n' "$(json_num "$data_free")"
  printf '  "disabled_packages": %s\n' "$(json_num "$n_disabled")"
  printf '}\n'
} > "$report_file"
cp "$report_file" "$STATE/bench/"
note "home_ms = $home_ms"
printf '%s\n' "$report_file"
