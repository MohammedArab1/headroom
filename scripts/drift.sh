#!/usr/bin/env bash
# Show what a firmware update (or a vendor "repair") undid, and optionally re-apply it.
# Usage: scripts/drift.sh [--fix] [--dry-run] [-y]
# Exit:  0 in sync, 1 drift (or a guard kept a package enabled during --fix), 2 usage error.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FIX=0
usage_die() {
  printf 'error: %s\n' "$*" >&2
  printf 'usage: scripts/drift.sh [--fix] [--dry-run] [-y]\n' >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --fix) FIX=1; shift ;;
    --dry-run|-y|--yes) common_flag "$1"; shift ;;
    -h|--help)
      printf 'usage: scripts/drift.sh [--fix] [--dry-run] [-y]\n'
      exit 0 ;;
    *) usage_die "unknown flag: $1" ;;
  esac
done

need_device
load_conf
need_snapshot
# shellcheck disable=SC2153  # STATE is set by need_device in lib.sh
TWEAKS="$STATE/tweaks.tsv"

BACK_ON=""
TWEAK_DRIFT=""
NEW_PKGS=""
EXPECTED_HOME=""
BUILD_CHANGED=0
HOME_DRIFT=0
DRIFT=0
CHANGED=0
KEPT=0
REMAINING=0
BATCH=""

want_setting() {  # ns key, prints the value headroom set; fails for a key it does not know
  case $2 in
    window_animation_scale|transition_animation_scale|animator_duration_scale)
      printf '%s' "$ANIM_SCALE" ;;
    wifi_scan_always_enabled|ble_scan_always_enabled)
      printf '0' ;;
    private_dns_mode)
      printf 'hostname' ;;
    private_dns_specifier)
      printf '%s' "$PRIVATE_DNS_HOST" ;;
    *) return 1 ;;
  esac
}

journal_result() {  # batch pkg
  [[ -f $STATE/journal.tsv ]] || return 0
  awk -F '\t' -v b="$1" -v p="$2" \
    '$2 == b && $3 == p {result = $4} END {print result}' "$STATE/journal.tsv"
}

INSTALLED_NOW=$(installed_set)
DISABLED_NOW=$(disabled_set)
[[ -n $INSTALLED_NOW ]] || die "could not read the package list from $SERIAL"

step "drift"

# Packages headroom disabled (the plan is not restored and the journal says the
# disable succeeded) that are enabled again.
if [[ -f $STATE/journal.tsv ]]; then
  while read -r b; do
    [[ -n $b && -f "$STATE/batches/$b.tsv" ]] || continue
    [[ -e "$STATE/batches/$b.restored" ]] && continue
    while IFS=$'\t' read -r p before; do
      [[ -n $p && $before == enabled ]] || continue
      [[ $(journal_result "$b" "$p") == disabled ]] || continue
      in_lines "$p" "$DISABLED_NOW" || BACK_ON="${BACK_ON:+$BACK_ON }$p"
    done < "$STATE/batches/$b.tsv"
  done <<EOF
$(batches_newest_first)
EOF
  if [[ -n $BACK_ON ]]; then
    BACK_ON=$(printf '%s\n' "$BACK_ON" | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' ' | sed 's/ $//')
  fi
fi
if [[ -n $BACK_ON ]]; then
  DRIFT=1
  for p in $BACK_ON; do printf '  back on: %s\n' "$p"; done
fi

if [[ $LAUNCHER == 1 && -f $STATE/launcher-installed ]] && present "$SELF_PKG"; then
  EXPECTED_HOME=$SELF_PKG
  NOW_HOME=$(home_package)
  if [[ $NOW_HOME != "$EXPECTED_HOME" ]]; then
    HOME_DRIFT=1
    DRIFT=1
    printf '  HOME: expected %s, found %s\n' "$EXPECTED_HOME" "${NOW_HOME:-unknown}"
  fi
fi

if [[ -f $TWEAKS ]]; then
  while IFS=$'\t' read -r kind a b _old; do
    [[ -n $kind ]] || continue
    case $kind in
      setting)
        if want=$(want_setting "$a" "$b"); then
          got=$(dev1 settings get "$a" "$b")
          [[ $got == "$want" ]] \
            || TWEAK_DRIFT="$TWEAK_DRIFT; $a/$b (want $want, got ${got:-empty})"
        fi ;;
      appop)
        got=$(dev "cmd appops get $a $b" | sed -n 's/.*: *\([a-z][a-z]*\).*/\1/p' | head -n 1)
        [[ $got == ignore ]] || TWEAK_DRIFT="$TWEAK_DRIFT; appop $a/$b (want ignore, got ${got:-empty})" ;;
    esac
  done < "$TWEAKS"
  if [[ -n $TWEAK_DRIFT ]]; then
    DRIFT=1
    printf '  tweaks: %s\n' "${TWEAK_DRIFT#; }"
  fi
fi

SNAPSHOT_ALL=$(sed -n 's/^package://p' "$STATE/snapshot/packages-all.txt")
for p in $INSTALLED_NOW; do
  in_lines "$p" "$SNAPSHOT_ALL" || NEW_PKGS="${NEW_PKGS:+$NEW_PKGS }$p"
done
if [[ -n $NEW_PKGS ]]; then
  NEW_PKGS=$(printf '%s\n' "$NEW_PKGS" | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' ' | sed 's/ $//')
  DRIFT=1
  printf '  new since snapshot: %s\n' "$NEW_PKGS"
  printf '  (run scripts/discover.sh before trusting the profile for these)\n'
fi

SNAP_BUILD=$(sed -n 's/^\[ro\.build\.display\.id\]: \[\(.*\)\]$/\1/p' \
  "$STATE/snapshot/props.txt" | head -n 1)
NOW_BUILD=$(dev1 getprop ro.build.display.id)
if [[ -n $SNAP_BUILD && -n $NOW_BUILD && $SNAP_BUILD != "$NOW_BUILD" ]]; then
  BUILD_CHANGED=1
  DRIFT=1
  printf '  build changed: %s -> %s\n' "$SNAP_BUILD" "$NOW_BUILD"
  printf '  the profile may no longer match; re-run scripts/discover.sh before --fix\n'
fi

if [[ $DRIFT == 0 ]]; then
  printf '  in sync with the snapshot and the recorded changes\n'
fi

if [[ $FIX == 0 ]]; then
  [[ $DRIFT == 0 ]] && exit 0
  printf '\n  scripts/drift.sh --fix re-applies the above through fresh guards\n'
  exit 1
fi

if [[ $DRIFT == 0 ]]; then
  exit 0
fi
if [[ $DRY_RUN == 1 ]]; then
  note "dry-run: nothing changed"
  exit 1
fi

require_checked
load_device_facts
if [[ $BUILD_CHANGED == 1 ]]; then
  confirm "The firmware build changed ($SNAP_BUILD -> $NOW_BUILD). Re-apply the drift anyway?" \
    || die "cancelled"
else
  confirm "Re-apply the drift on $SERIAL?" || die "cancelled"
fi

fix_packages() {
  [[ -n $BACK_ON ]] || return 0
  local p state why r todo="" n_ok=0
  for p in $BACK_ON; do
    state=$(pkg_state "$p" "$INSTALLED_NOW" "$DISABLED_NOW")
    [[ $state == enabled ]] || continue
    why=$(blocking_reasons "$p")
    if [[ -n $why ]]; then
      warn "$p came back but a guard now protects it; leaving it enabled:"
      printf '%s\n' "$why" | sed 's/^/    /' >&2
      KEPT=$((KEPT + 1))
      continue
    fi
    todo="$todo $p"
  done
  [[ -n $todo ]] || return 0

  step "re-disable"
  BATCH=$(new_batch_id drift)
  for p in $todo; do printf '%s\tenabled\n' "$p"; done | write_plan "$BATCH"
  for p in $todo; do
    r=$(disable_one "$p")
    [[ -n $r ]] || die "no answer from $SERIAL while disabling $p. The batch is recorded: reconnect, then scripts/restore.sh --batch $BATCH"
    journal "$BATCH" "$p" "$r"
    printf '  %-50s %s\n' "$p" "$r"
    case $r in
      disabled) n_ok=$((n_ok + 1)); CHANGED=1 ;;
      refused) KEPT=$((KEPT + 1)) ;;
      *) warn "suspect: $r"; KEPT=$((KEPT + 1)) ;;
    esac
  done
  if [[ $n_ok == 0 ]]; then
    : > "$STATE/batches/$BATCH.restored"
    note "nothing changed; batch $BATCH marked restored"
  fi
}

put_old() {  # ns key old
  case $3 in
    '') warn "no recorded value for $1/$2; leaving it as it is" ;;
    null) acmd settings delete "$1" "$2" >/dev/null ;;
    *) acmd settings put "$1" "$2" "$3" >/dev/null ;;
  esac
}

fix_tweaks() {
  [[ -f $TWEAKS ]] || return 0
  local kind a b old got want line ok waited wait_for step_s
  local dns=0 dns_spec_old="" dns_mode_old=""
  step "tweaks"
  while IFS=$'\t' read -r kind a b old; do
    [[ -n $kind ]] || continue
    case $kind in
      setting)
        case $b in
          private_dns_specifier) dns=1; dns_spec_old=$old; continue ;;
          private_dns_mode) dns=1; dns_mode_old=$old; continue ;;
        esac
        if want=$(want_setting "$a" "$b"); then
          got=$(dev1 settings get "$a" "$b")
          [[ $got == "$want" ]] && continue
          acmd settings put "$a" "$b" "$want" >/dev/null
          note "re-applied $a/$b = $want (was ${got:-empty})"
          CHANGED=1
        fi ;;
      appop)
        got=$(dev "cmd appops get $a $b" | sed -n 's/.*: *\([a-z][a-z]*\).*/\1/p' | head -n 1)
        [[ $got == ignore ]] && continue
        acmd cmd appops set "$a" "$b" ignore >/dev/null
        note "re-applied appop $a/$b = ignore (was ${got:-empty})"
        CHANGED=1 ;;
    esac
  done < "$TWEAKS"

  if [[ $dns == 1 && $SDK -ge 28 ]]; then
    got_spec=$(dev1 settings get global private_dns_specifier)
    got_mode=$(dev1 settings get global private_dns_mode)
    if [[ $got_spec != "$PRIVATE_DNS_HOST" || $got_mode != hostname ]]; then
      note "Private DNS does not block YouTube ads, and the resolver sees every lookup this unit makes"
      acmd settings put global private_dns_specifier "$PRIVATE_DNS_HOST" >/dev/null
      acmd settings put global private_dns_mode hostname >/dev/null
      note "re-applied Private DNS: $PRIVATE_DNS_HOST (was ${got_spec:-empty})"
      CHANGED=1
      ok=0; waited=0
      wait_for=${PRIVATE_DNS_WAIT:-30}
      step_s=${PRIVATE_DNS_STEP:-5}
      case $wait_for in ''|*[!0-9]*) wait_for=30 ;; esac
      case $step_s in ''|*[!0-9]*|0) step_s=5 ;; esac
      while :; do
        line=$(dev 'ping -c 1 -W 3 connectivitycheck.gstatic.com')
        case $line in PING*) ok=1; break ;; esac
        [[ $waited -ge $wait_for ]] && break
        sleep "$step_s"
        waited=$((waited + step_s))
      done
      if [[ $ok == 1 ]]; then
        note "Private DNS resolver answers"
      else
        warn "Private DNS did not resolve; reverting both settings immediately"
        put_old global private_dns_specifier "$dns_spec_old"
        put_old global private_dns_mode "$dns_mode_old"
        REMAINING=1
      fi
    fi
  fi
}

fix_home() {
  [[ $HOME_DRIFT == 1 && $EXPECTED_HOME == "$SELF_PKG" ]] || return 0
  local out now before=""
  step "home"
  [[ -f $STATE/home-before.txt ]] && before=$(head -n 1 "$STATE/home-before.txt")
  out=$(dev am start -W -n "$SELF_PKG/.HomeActivity")
  if printf '%s\n' "$out" | grep -E '(^Error|Error:)' >/dev/null; then
    warn "$SELF_PKG did not start; HOME is unchanged. Run scripts/launcher.sh"
    REMAINING=1
    return 0
  fi
  case $out in
    *"Status: ok"*) ;;
    *) warn "$SELF_PKG did not start; HOME is unchanged"; REMAINING=1; return 0 ;;
  esac
  acmd cmd package set-home-activity --user 0 "$SELF_PKG/.HomeActivity" >/dev/null
  now=$(home_package)
  if [[ $now != "$SELF_PKG" ]]; then
    if [[ -n $before && $before != android/* ]]; then
      acmd cmd package set-home-activity --user 0 "$before" >/dev/null
      acmd am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null
    fi
    {
      echo "headroom home did not become HOME again: this firmware ignores set-home-activity."
      echo
      echo "Run these by hand over ADB:"
      if [[ -n $before && $before != android/* ]]; then
        echo "  adb -s $SERIAL shell cmd package set-home-activity --user 0 $before"
      fi
      echo "  adb -s $SERIAL shell am start -a android.intent.action.MAIN -c android.intent.category.HOME"
      echo
      echo "On the unit: Settings > Apps > headroom home > Open by default > Clear defaults."
    } > "$REPORT/launcher-rollback.txt"
    : > "$STATE/set-home-ignored"
    note "the recovery commands are in report/launcher-rollback.txt"
    die "this firmware ignores set-home-activity; HOME is back on ${before%%/*}"
  fi
  : > "$STATE/launcher-installed"
  note "HOME is $SELF_PKG again"
  CHANGED=1
}

fix_packages
fix_tweaks
fix_home

if [[ $CHANGED == 1 ]]; then
  step "reboot"
  reboot_wait
  if [[ $EXPECTED_HOME == "$SELF_PKG" ]]; then
    NOW_HOME=$(home_package)
    if [[ $NOW_HOME != "$SELF_PKG" ]]; then
      warn "after the reboot HOME is ${NOW_HOME:-unknown}, not $SELF_PKG"
      REMAINING=1
    fi
  fi
fi

step "next"
if [[ $KEPT -gt 0 ]]; then
  warn "$KEPT package(s) stayed enabled because a guard protects them"
fi
if [[ $REMAINING -gt 0 ]]; then
  warn "some drift could not be re-applied; read the warnings above"
fi
note "a person at the car runs scripts/verify.sh --manual"
[[ $KEPT == 0 && $REMAINING == 0 ]] || exit 1
exit 0
