#!/usr/bin/env bash
# Read-only facts about the head unit, plus the one-time snapshot that undo depends on.
# Changes nothing on the unit.
# Usage: scripts/preflight.sh [--dry-run]
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run|-y|--yes) common_flag "$1"; shift ;;
    -h|--help)
      printf 'usage: scripts/preflight.sh [--dry-run]\n'
      exit 0 ;;
    *) die "unknown flag: $1" ;;
  esac
done

need_device
load_device_facts

manufacturer=$(dev1 getprop ro.product.manufacturer)
model=$(dev1 getprop ro.product.model)
board=$(dev1 getprop ro.product.board)
platform=$(dev1 getprop ro.board.platform)
hardware=$(dev1 getprop ro.hardware)
build_id=$(dev1 getprop ro.build.display.id)
release=$(dev1 getprop ro.build.version.release)
abi=$(dev1 getprop ro.product.cpu.abi)
adb_secure=$(dev1 getprop ro.adb.secure)
debuggable=$(dev1 getprop ro.debuggable)

meminfo=$(dev 'cat /proc/meminfo')
memtotal=$(printf '%s\n' "$meminfo" | awk '/^MemTotal:/ {print $2; exit}')
memavail=$(printf '%s\n' "$meminfo" | awk '/^MemAvailable:/ {print $2; exit}')
if [[ -z $memavail ]]; then
  memavail=$(printf '%s\n' "$meminfo" | awk '/^MemFree:|^Buffers:|^Cached:/ {s+=$2} END {print s+0}')
fi
case $memtotal in ''|*[!0-9]*) memtotal=0 ;; esac
case $memavail in ''|*[!0-9]*) memavail=0 ;; esac

claimed_ram=$(dev1 getprop ro.config.ram)
case $claimed_ram in ''|*[!0-9]*) claimed_ram=$(dev1 getprop ro.product.ram) ;; esac
case $claimed_ram in ''|*[!0-9]*) claimed_ram="" ;; esac

df_line=$(dev 'df /data' | sed '/^[[:space:]]*$/d' | tail -n 1)
total_kb=$(printf '%s\n' "$df_line" | awk '{print $2}')
avail_kb=$(printf '%s\n' "$df_line" | awk '{print $4}')
case $total_kb in ''|*[!0-9]*) total_kb=0 ;; esac
case $avail_kb in ''|*[!0-9]*) avail_kb=0 ;; esac

cores=$(dev 'cat /proc/cpuinfo' | awk '/^processor/ {n++} END {print n+0}')

size_out=$(dev 'wm size')
size_phys=$(printf '%s\n' "$size_out" | sed -n 's/^Physical size: *//p' | head -n 1)
size_over=$(printf '%s\n' "$size_out" | sed -n 's/^Override size: *//p' | head -n 1)
density_out=$(dev 'wm density')
density_phys=$(printf '%s\n' "$density_out" | sed -n 's/^Physical density: *//p' | head -n 1)
density_over=$(printf '%s\n' "$density_out" | sed -n 's/^Override density: *//p' | head -n 1)

installed=$(installed_set)
disabled=$(disabled_set)
third=$(third_set)
[[ -n $installed ]] || die "could not read the package list from $SERIAL"
n_installed=$(printf '%s\n' "$installed" | grep -c .)
n_disabled=$(printf '%s\n' "$disabled" | grep -c .)
n_third=$(printf '%s\n' "$third" | grep -c .)
home_comp=$(home_component)

# Claimed Android release -> API levels the framework actually implements.
api_for_release() {
  case ${1%%.*} in
    6)  printf '23' ;;
    7)  printf '24 25' ;;
    8)  printf '26 27' ;;
    9)  printf '28' ;;
    10) printf '29' ;;
    11) printf '30' ;;
    12) printf '31 32' ;;
    13) printf '33' ;;
    14) printf '34' ;;
    15) printf '35' ;;
    *)  printf '' ;;
  esac
}
mismatch=""
want=$(api_for_release "$release")
if [[ -n $want ]]; then
  case " $want " in
    *" $SDK "*) ;;
    *) mismatch="   <- MISMATCH" ;;
  esac
fi

ram_flag=""
if [[ -n $claimed_ram && $memtotal -gt 0 ]]; then
  real_mb=$((memtotal / 1024))
  if [[ $((real_mb * 100)) -lt $((claimed_ram * 80)) ]]; then
    ram_flag="   <- smaller than claimed"
  fi
fi

gb() { awk -v kb="$1" 'BEGIN { if (kb <= 0) print "unknown"; else printf "%.1f GB", kb / 1048576 }'; }
display_size="unknown"
if [[ -n $size_over && $size_over != "$size_phys" ]]; then
  display_size="$size_phys -> $size_over"
elif [[ -n $size_phys ]]; then
  display_size=$size_phys
elif [[ -n $size_over ]]; then
  display_size=$size_over
fi
display_density="unknown"
if [[ -n $density_over && $density_over != "$density_phys" ]]; then
  display_density="$density_phys -> $density_over"
elif [[ -n $density_phys ]]; then
  display_density=$density_phys
elif [[ -n $density_over ]]; then
  display_density=$density_over
fi

transport=local
case $SERIAL in *:*) transport=tcp ;; esac

printf 'device\n'
printf '  serial         <redacted> (local id %s)\n' "$(basename "$STATE")"
printf '  manufacturer   %s\n' "${manufacturer:-unknown}"
printf '  model          %s\n' "${model:-unknown}"
printf '  board          %s\n' "${board:-unknown}"
printf '  platform       %s\n' "${platform:-unknown}"
printf '  hardware       %s\n' "${hardware:-unknown}"
printf '  build          %s\n' "${build_id:-unknown}"
printf '  android        claimed %s (ro.build.version.release) | real API %s%s\n' \
  "${release:-unknown}" "$SDK" "$mismatch"
if [[ -n $claimed_ram ]]; then
  printf '  ram            claimed %s MB | real MemTotal %s (%s kB)%s\n' \
    "$claimed_ram" "$(gb "$memtotal")" "$memtotal" "$ram_flag"
else
  printf '  ram            claimed not advertised | real MemTotal %s (%s kB)\n' \
    "$(gb "$memtotal")" "$memtotal"
fi
printf '  storage /data  %s free of %s\n' "$(gb "$avail_kb")" "$(gb "$total_kb")"
printf '  cpu            %s cores, abi %s\n' "$cores" "${abi:-unknown}"
printf '  screen         %s @ %s dpi\n' "$display_size" "$display_density"
printf '  adb            ro.adb.secure=%s | ro.debuggable=%s | transport %s\n' \
  "${adb_secure:-unknown}" "${debuggable:-unknown}" "$transport"
profile_note=""
[[ $PROFILE == generic ]] && profile_note=" (fallback: no profile match.txt matched)"
printf '  profile        %s%s\n' "$PROFILE" "$profile_note"
printf '\ncurrent state\n'
printf '  packages       %s installed | %s disabled | %s third-party\n' \
  "$n_installed" "$n_disabled" "$n_third"
printf '  home           %s\n' "${home_comp:-unknown}"
printf '  keyboard       %s\n' "${IME:-unknown}"
printf '  free RAM now   MemAvailable %s MB\n' "$((memavail / 1024))"
printf '\nnot touched, ever\n'
printf '  /system, firmware, MCU/CAN settings, factory menus, contacts/calls/messages/location\n'
printf '\nbefore you continue (a person does these)\n'
printf '  [ ] if you know how to reach them: photograph the factory-settings screens (change nothing)\n'
printf '  [ ] the car is parked, brake on; engine only outdoors, or a charger connected\n'
printf '  [ ] you know which apps you actually use (configure.sh will ask)\n'

snapshot_dir="$STATE/snapshot"
if [[ -f $snapshot_dir/meta.txt ]]; then
  printf '\n  snapshot       already exists from %s, keeping the original\n' \
    "$(sed -n 's/^date=//p' "$snapshot_dir/meta.txt" | head -n 1)"
elif [[ -e $snapshot_dir ]]; then
  die "$snapshot_dir exists but has no meta.txt. Inspect it by hand; refusing to overwrite."
elif [[ $DRY_RUN == 1 ]]; then
  printf '\n  snapshot       [dry-run] would write %s\n' "$snapshot_dir"
else
  tmp="$STATE/snapshot.tmp"
  rm -rf "$tmp"
  mkdir -p "$tmp"
  chmod 700 "$tmp"
  dev_ok getprop                       > "$tmp/props.txt"
  dev_ok settings list system          > "$tmp/settings-system.txt"
  dev_ok settings list secure          > "$tmp/settings-secure.txt"
  dev_ok settings list global          > "$tmp/settings-global.txt"
  dev_ok pm list packages              > "$tmp/packages-all.txt"
  dev_ok pm list packages -d           > "$tmp/packages-disabled.txt"
  dev_ok pm list packages -3           > "$tmp/packages-third.txt"
  dev_ok pm list packages -f           > "$tmp/packages-paths.txt"
  home_component                       > "$tmp/home.txt"
  printf 'date=%s\nversion=%s\ndevice_id=%s\nsdk=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$HEADROOM_VERSION" "$(basename "$STATE")" "$SDK" \
    > "$tmp/meta.txt"
  mv "$tmp" "$snapshot_dir"
  printf '\n  snapshot       written to %s (first run wins; later runs keep it)\n' "$snapshot_dir"
fi

if [[ ! -f $STATE/home-before.txt && $DRY_RUN == 0 ]]; then
  home_component > "$STATE/home-before.txt"
fi
