#!/usr/bin/env bash
# Speed settings, each recorded so restore.sh can put the original value back.
# Usage: scripts/tune.sh [-y] [--dry-run]
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run|-y|--yes) common_flag "$1"; shift ;;
    -h|--help)
      printf 'usage: scripts/tune.sh [-y] [--dry-run]\n'
      exit 0 ;;
    *) die "unknown flag: $1" ;;
  esac
done

need_device
need_snapshot
load_conf
require_checked
load_device_facts
installed=$(installed_set)
[[ -n $installed ]] || die "could not read the package list from $SERIAL"
TWEAKS="$STATE/tweaks.tsv"
FAILED=0

case $ANIM_SCALE in 0|0.5|1) ;; *) die "ANIM_SCALE must be 0, 0.5 or 1 in headroom.conf" ;; esac
if [[ $PRIVATE_DNS == 1 ]]; then
  [[ -n $PRIVATE_DNS_HOST ]] || die "PRIVATE_DNS=1 but PRIVATE_DNS_HOST is empty; re-run configure.sh"
fi

record_setting() {  # ns key
  if grep -F "$(printf 'setting\t%s\t%s\t' "$1" "$2")" "$TWEAKS" >/dev/null 2>&1; then
    return 0
  fi
  printf 'setting\t%s\t%s\t%s\n' "$1" "$2" "$(dev1 settings get "$1" "$2")" >> "$TWEAKS"
}
put_setting() {     # ns key value
  if [[ $DRY_RUN == 1 ]]; then
    note "[dry-run] settings put $1 $2 $3"
    return 0
  fi
  record_setting "$1" "$2"
  acmd settings put "$1" "$2" "$3" >/dev/null
  printf '  %-44s %s\n' "$1/$2" "$3"
}
record_appop() {    # pkg op
  if grep -F "$(printf 'appop\t%s\t%s\t' "$1" "$2")" "$TWEAKS" >/dev/null 2>&1; then
    return 0
  fi
  local mode
  mode=$(dev "cmd appops get $1 $2" | sed -n 's/.*: *\([a-z][a-z]*\).*/\1/p' | head -n 1)
  printf 'appop\t%s\t%s\t%s\n' "$1" "$2" "${mode:-default}" >> "$TWEAKS"
}
put_appop() {       # pkg op
  if [[ $DRY_RUN == 1 ]]; then
    note "[dry-run] cmd appops set $1 $2 ignore"
    return 0
  fi
  record_appop "$1" "$2"
  acmd cmd appops set "$1" "$2" ignore >/dev/null
  printf '  %-44s ignore\n' "appop $1/$2"
}
recorded_old() {    # ns key
  awk -F '\t' -v ns="$1" -v k="$2" \
    '$1 == "setting" && $2 == ns && $3 == k {print $4; exit}' "$TWEAKS"
}
revert_setting() {  # ns key
  local old
  old=$(recorded_old "$1" "$2")
  if [[ -z $old ]]; then
    warn "no recorded value for $1/$2; leaving it as it is"
    return 0
  fi
  if [[ $old == null ]]; then
    acmd settings delete "$1" "$2" >/dev/null
  else
    acmd settings put "$1" "$2" "$old" >/dev/null
  fi
  note "reverted $1/$2"
}

# Plan first, so --dry-run and the confirmation show exactly what will change.
step "plan"
LAUNCHER_PRESENT=0
present "$SELF_PKG" && LAUNCHER_PRESENT=1
[[ $ANIM_SCALE != 1 ]] && note "animations: $ANIM_SCALE"
[[ $SCAN_OFF == 1 ]] && note "always-on Wi-Fi and Bluetooth scanning: off"
[[ -n $BG_RESTRICT ]] && note "background restriction: $BG_RESTRICT"
[[ $TRIM_CACHES == 1 ]] && note "cache trim if /data is over 85% used"
[[ $PRIVATE_DNS == 1 ]] && note "Private DNS: $PRIVATE_DNS_HOST (with a self-test and revert)"
[[ $DEXOPT == 1 ]] && note "ahead-of-time compile (5 to 30 minutes)"
[[ $LAUNCHER_PRESENT == 1 ]] && note "compile $SELF_PKG for speed"

if [[ $ANIM_SCALE == 1 && $SCAN_OFF == 0 && -z $BG_RESTRICT && $TRIM_CACHES == 0 && $PRIVATE_DNS == 0 && $DEXOPT == 0 && $LAUNCHER_PRESENT == 0 ]]; then
  note "nothing to do"
  exit 0
fi

[[ $DRY_RUN == 1 ]] && { note "dry-run: nothing changed"; exit 0; }
confirm "Apply these speed settings on $SERIAL?" || die "cancelled"

if [[ $ANIM_SCALE != 1 ]]; then
  put_setting global window_animation_scale "$ANIM_SCALE"
  put_setting global transition_animation_scale "$ANIM_SCALE"
  put_setting global animator_duration_scale "$ANIM_SCALE"
fi

if [[ $SCAN_OFF == 1 ]]; then
  put_setting global wifi_scan_always_enabled 0
  put_setting global ble_scan_always_enabled 0
fi

if [[ -n $BG_RESTRICT ]]; then
  for p in $BG_RESTRICT; do
    if ! in_lines "$p" "$installed"; then warn "$p is not installed; skipping"; continue; fi
    if in_words "$p" "$KEEP_APPS"; then
      note "$p is in KEEP_APPS; refusing to restrict it in the background"
      continue
    fi
    if in_words "$p" "$DOCK_APPS"; then
      note "$p is a dock app; refusing to restrict it in the background"
      continue
    fi
    why=$(blocking_reasons "$p")
    if [[ -n $why ]]; then
      warn "$p is guarded; refusing to restrict it in the background:"
      printf '%s\n' "$why" | sed 's/^/    /' >&2
      continue
    fi
    put_appop "$p" RUN_IN_BACKGROUND
    [[ $SDK -ge 28 ]] && put_appop "$p" RUN_ANY_IN_BACKGROUND
  done
fi

if [[ $TRIM_CACHES == 1 ]]; then
  df_line=$(dev_ok 'df /data' | sed '/^[[:space:]]*$/d' | tail -n 1)
  used=$(printf '%s\n' "$df_line" | awk '{print $3}')
  total=$(printf '%s\n' "$df_line" | awk '{print $2}')
  case $used in ''|*[!0-9]*) used=0 ;; esac
  case $total in ''|*[!0-9]*) total=0 ;; esac
  if [[ $total -gt 0 && $((used * 100 / total)) -gt 85 ]]; then
    acmd pm trim-caches 999G >/dev/null
    note "cache trimmed (storage was over 85% full)"
  else
    note "storage is below 85%; caches left alone"
  fi
fi

if [[ $PRIVATE_DNS == 1 ]]; then
  if [[ $SDK -lt 28 ]]; then
    warn "Private DNS needs API 28 or later; skipping on API $SDK"
  else
    note "Private DNS does not block YouTube ads, and the resolver sees every lookup this unit makes"
    put_setting global private_dns_specifier "$PRIVATE_DNS_HOST"
    put_setting global private_dns_mode hostname
    ok=0; waited=0
    wait_for=${PRIVATE_DNS_WAIT:-30}
    step_s=${PRIVATE_DNS_STEP:-5}
    case $wait_for in ''|*[!0-9]*) wait_for=30 ;; esac
    case $step_s in ''|*[!0-9]*|0) step_s=5 ;; esac
    while :; do
      line=$(dev 'ping -c 1 -W 3 connectivitycheck.gstatic.com')
      case $line in PING*) ok=1; break ;; esac
      [[ $waited -ge $wait_for ]] && break
      sleep "$step_s"; waited=$((waited + step_s))
    done
    if [[ $ok == 1 ]]; then
      note "Private DNS resolver answers"
    else
      warn "Private DNS did not resolve; reverting both settings immediately"
      revert_setting global private_dns_specifier
      revert_setting global private_dns_mode
      FAILED=1
    fi
  fi
fi

if [[ $DEXOPT == 1 ]]; then
  note "compiling apps ahead of time: this takes 5 to 30 minutes; keep the unit on"
  started=$(date +%s)
  acmd cmd package bg-dexopt-job >/dev/null
  elapsed=$(( $(date +%s) - started ))
  note "ahead-of-time compile finished in ${elapsed}s"
fi

if [[ $LAUNCHER_PRESENT == 1 ]]; then
  acmd cmd package compile -m speed -f "$SELF_PKG" >/dev/null
  note "compiled $SELF_PKG for speed"
fi

[[ $FAILED == 0 ]] || exit 1
exit 0
