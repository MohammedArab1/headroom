#!/usr/bin/env bash
# Prove the unit is healthy. Automatic checks are read-only. --manual asks a person
# at the car the questions in data/common/car-checks.txt and unlocks the next batch.
# Usage: scripts/verify.sh [--manual [--answers "id=y id=s ..."]] [--acc-test] [--dry-run]
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MANUAL=0
ANSWERS=""
ACC_TEST=0
ACC_ONLY=0
SLEEP_DELAY=60
HOME_WAIT=${HOME_WAIT:-2}

while [[ $# -gt 0 ]]; do
  case $1 in
    --manual) MANUAL=1; shift ;;
    --answers) [[ $# -ge 2 ]] || die "--answers needs a value"; ANSWERS=$2; MANUAL=1; shift 2 ;;
    --acc-test) ACC_TEST=1; MANUAL=1; ACC_ONLY=1; shift ;;
    --sleep-delay) [[ $# -ge 2 ]] || die "--sleep-delay needs seconds"; SLEEP_DELAY=$2; shift 2 ;;
    --dry-run|-y|--yes) common_flag "$1"; shift ;;
    -h|--help)
      printf 'usage: scripts/verify.sh [--manual [--answers "id=y id=s ..."]] [--acc-test] [--dry-run]\n'
      exit 0 ;;
    *) die "unknown flag: $1" ;;
  esac
done
case $SLEEP_DELAY in ''|*[!0-9]*) die "--sleep-delay must be seconds" ;; esac

need_device
load_conf
load_device_facts
installed=$(installed_set)
disabled=$(disabled_set)
[[ -n $installed ]] || die "could not read the package list from $SERIAL"

FAILED=0
row() { printf '%-12s %-5s %s\n' "$1" "$2" "$3"; }
fail() { FAILED=1; row "$1" FAIL "$2"; }
matches_any() {
  local re
  while IFS= read -r re; do
    [[ -n $re && $1 =~ $re ]] && return 0
  done <<EOF
$2
EOF
  return 1
}

# never: nothing on a never list may be disabled.
bad=""
for p in $disabled; do
  is_never "$p" && bad="$bad $p"
done
if [[ -n $bad ]]; then
  fail never "disabled never-list package(s):$bad. Run scripts/restore.sh --package <pkg>"
else
  row never ok "no never-list package is disabled"
fi

# batches: what headroom disabled must still be disabled.
journal_disabled=""
if [[ -f $STATE/journal.tsv ]]; then
  journal_disabled=$(awk -F '\t' '$4 == "disabled" {print $3}' "$STATE/journal.tsv")
fi
bad=""
while IFS= read -r b; do
  [[ -n $b ]] || continue
  [[ -e $STATE/batches/$b.restored ]] && continue
  [[ -f $STATE/batches/$b.tsv ]] || continue
  while IFS=$'\t' read -r p before; do
    [[ $before == enabled ]] || continue
    in_lines "$p" "$journal_disabled" || continue
    in_lines "$p" "$disabled" || bad="$bad $p"
  done < "$STATE/batches/$b.tsv"
done <<EOF
$(batches_newest_first)
EOF
if [[ -n $bad ]]; then
  fail batches "came back:$bad. Run scripts/drift.sh"
else
  row batches ok "headroom's disabled packages are still disabled"
fi

# keyboard: without it, Wi-Fi passwords and destinations cannot be typed.
if [[ -z $IME_PKG ]]; then
  row keyboard warn "could not read the current keyboard"
elif in_lines "$IME_PKG" "$disabled"; then
  fail keyboard "keyboard $IME_PKG is disabled. Run scripts/restore.sh --package $IME_PKG"
else
  row keyboard ok "$IME_PKG is enabled"
fi

# home: the recorded HOME must answer, and the HOME key must land there.
HOME_OK=0
expected_home=""
if [[ -f $STATE/launcher-installed ]]; then
  expected_home=$SELF_PKG
elif [[ -f $STATE/home-before.txt ]]; then
  hb=$(head -n 1 "$STATE/home-before.txt")
  expected_home=${hb%%/*}
fi
if [[ -z $expected_home || $expected_home == android ]]; then
  row home skip "no recorded launcher (or the chooser answered); run preflight.sh or set HOME by hand"
else
  now_home=$(home_package)
  if [[ $now_home != "$expected_home" ]]; then
    fail home "HOME is $now_home, expected $expected_home"
  else
    dev_ok input keyevent KEYCODE_HOME >/dev/null
    if [[ $HOME_WAIT -gt 0 ]]; then sleep "$HOME_WAIT"; fi
    fg=$(resumed_activity)
    fg_pkg=${fg%%/*}
    if [[ $fg_pkg == "$expected_home" ]]; then
      row home ok "$expected_home"
      HOME_OK=1
    else
      fail home "HOME key landed on ${fg:-nothing}, expected $expected_home"
    fi
  fi
fi

# crashes: a crash in a never-list or car-name package is a FAIL; others are warnings.
crash_log=$(dev_ok 'logcat -b crash -d')
if [[ -z $crash_log ]]; then
  row crashes ok "no crash entries"
else
  bad=""; warned=""
  while read -r count pkg; do
    [[ -n $pkg ]] || continue
    sensitive=0
    is_never "$pkg" && sensitive=1
    matches_any "$(lower "$pkg")" "$SENSITIVE_RE" && sensitive=1
    [[ $pkg == "$HOME_NOW" || $pkg == "$IME_PKG" ]] && sensitive=1
    if [[ $sensitive == 1 ]]; then bad="$bad $pkg($count)"; else warned="$warned $pkg($count)"; fi
  done <<EOF
$(printf '%s\n' "$crash_log" | sed -n 's/.*Process: \([A-Za-z0-9_.]*\),.*/\1/p' | sort | uniq -c)
EOF
  if [[ -n $bad ]]; then
    fail crashes "sensitive crash(es):$bad"
  elif [[ -n $warned ]]; then
    row crashes warn "crash(es) in other apps:$warned"
  else
    row crashes ok "no crash entries"
  fi
fi

# tweaks: only check settings headroom recorded as changed.
if [[ ! -f $STATE/tweaks.tsv ]]; then
  row tweaks skip "no tweaks recorded"
else
  bad=""; unknown=""
  while IFS=$'\t' read -r kind a b _old; do
    [[ -n $kind ]] || continue
    case $kind in
      setting)
        case $b in
          window_animation_scale|transition_animation_scale|animator_duration_scale) want=$ANIM_SCALE ;;
          wifi_scan_always_enabled|ble_scan_always_enabled) want=0 ;;
          private_dns_mode) want=hostname ;;
          private_dns_specifier) want=$PRIVATE_DNS_HOST ;;
          *) unknown="$unknown $a/$b"; continue ;;
        esac
        got=$(dev1 settings get "$a" "$b")
        [[ $got == "$want" ]] || bad="$bad $a/$b(want $want, got ${got:-empty})"
        ;;
      appop)
        got=$(dev "cmd appops get $a $b" | sed -n 's/.*: *\([a-z][a-z]*\).*/\1/p' | head -n 1)
        [[ $got == ignore ]] || bad="$bad appop:$a/$b(want ignore, got ${got:-empty})"
        ;;
      *) unknown="$unknown $kind" ;;
    esac
  done < "$STATE/tweaks.tsv"
  if [[ -n $bad ]]; then
    row tweaks warn "changed:$bad. Re-run scripts/tune.sh"
  elif [[ -n $unknown ]]; then
    row tweaks warn "could not interpret:$unknown"
  else
    row tweaks ok "recorded tweaks still have their values"
  fi
fi

# dns: only when Private DNS was chosen.
if [[ $PRIVATE_DNS != 1 ]]; then
  row dns skip "Private DNS is off"
else
  mode=$(dev1 settings get global private_dns_mode)
  ping_line=$(dev_ok 'ping -c 1 -W 3 connectivitycheck.gstatic.com')
  case $ping_line in
    PING*)
      if [[ $mode == hostname ]]; then
        row dns ok "mode=hostname, resolver answers"
      else
        fail dns "private_dns_mode is ${mode:-empty}, expected hostname"
      fi ;;
    *)
      fail dns "the resolver did not answer; run scripts/restore.sh --all --no-home" ;;
  esac
fi

# adb: an open, unauthenticated ADB port is a shell for anyone on the network.
adb_secure=$(dev1 getprop ro.adb.secure)
case $adb_secure in
  1) row adb ok "ro.adb.secure=1" ;;
  0) row adb warn "ro.adb.secure=0: anyone on this network gets a shell; run close-adb.sh when done" ;;
  *) row adb warn "could not read ro.adb.secure" ;;
esac

if [[ $FAILED == 1 ]]; then
  note "automatic checks failed; car questions are not asked and no batch is unlocked"
  exit 1
fi
if [[ $MANUAL == 0 || $DRY_RUN == 1 ]]; then
  [[ $DRY_RUN == 1 ]] && note "[dry-run] automatic checks only; no questions and no files written"
  exit 0
fi

checks_file_src=$(cfile car-checks.txt)
[[ -f $checks_file_src ]] || die "missing $checks_file_src"
if [[ -z $ANSWERS ]] && [[ ! -t 0 ]]; then
  die "a person at the car must answer the checks: ask the person each question, then pass their answers with --answers"
fi
CHECK_IDS=$(awk '{print $1}' "$checks_file_src")
ANSWERS_MAP=""
if [[ -n $ANSWERS ]]; then
  for pair in $ANSWERS; do
    id=${pair%%=*}; ans=${pair#*=}
    case $id in ''|*[!A-Za-z0-9_-]*) die "bad check id in --answers: $pair" ;; esac
    case $ans in y|n|s) ;; *) die "answer for $id must be y, n or s" ;; esac
    in_lines "$id" "$CHECK_IDS" || die "unknown car-check id: $id"
    ANSWERS_MAP="$ANSWERS_MAP$id"$'\t'"$ans"$'\n'
  done
fi
answer_for() { printf '%s' "$ANSWERS_MAP" | awk -F '\t' -v id="$1" '$1 == id {print $2; exit}'; }

acc_test_sequence() {
  [[ -t 0 ]] || die "the ignition test needs a person at the terminal"
  local before after step limit waited dev_state ans
  step=${ACC_POLL:-5}
  case $step in ''|*[!0-9]*|0) step=5 ;; esac
  limit=${ACC_TIMEOUT:-$((SLEEP_DELAY + 60))}
  case $limit in ''|*[!0-9]*) limit=$((SLEEP_DELAY + 60)) ;; esac
  before=$(dev1 cat /proc/sys/kernel/random/boot_id)
  note "Turn the ignition off now."
  waited=0; dev_state=device
  while [[ $waited -lt $limit ]]; do
    dev_state=$("$ADB" -s "$SERIAL" get-state 2>/dev/null)
    [[ $dev_state != device ]] && break
    sleep "$step"
    waited=$((waited + step))
  done
  if [[ $dev_state == device ]]; then
    warn "the unit still answers over ADB after ${limit}s, so it is probably not asleep (battery drain risk)"
    warn "check the screen, any fan and the backlight before driving off"
  else
    note "ADB stopped answering; the unit went to sleep"
  fi
  note "Turn the ignition on now."
  for _ in $(seq 1 60); do
    reconnect_quietly
    [[ $(dev1 getprop sys.boot_completed) == 1 ]] && break
    sleep "$step"
  done
  after=$(dev1 cat /proc/sys/kernel/random/boot_id)
  if [[ $before == "$after" ]]; then
    note "same boot id: the unit woke from sleep"
  else
    note "new boot id: the unit cold-booted"
  fi
}

if [[ $ACC_TEST == 1 ]]; then
  acc_test_sequence
fi

mkdir -p "$STATE/checks"
checks_file="$STATE/checks/$(date +%Y%m%d-%H%M%S).tsv"
: > "$checks_file"
batch=$(unchecked_batches | head -n 1)
[[ -n $batch ]] || batch="-"
ANY_NO=0

while IFS=' ' read -r id question; do
  [[ -n $id ]] || continue
  if [[ $ACC_ONLY == 1 ]]; then
    case $id in acc-sleep|acc-wake|clock) ;; *) continue ;; esac
  fi
  if [[ -n $ANSWERS ]]; then
    ans=$(answer_for "$id")
    [[ -n $ans ]] || die "missing answer for $id: ask the person, then pass it in --answers"
  else
    while :; do
      printf '%s [y/n/s] ' "$question" >/dev/tty
      read -r ans </dev/tty
      case $ans in y|n|s) break ;; *) printf 'answer y, n or s\n' >/dev/tty ;; esac
    done
  fi
  printf '%s\t%s\t%s\n' "$id" "$ans" "$batch" >> "$checks_file"
  printf '%-12s %s\n' "$id" "$ans"
  [[ $ans == n ]] && ANY_NO=1
done < "$checks_file_src"

if [[ $ANY_NO == 1 ]]; then
  note "a car check failed. Recovery: scripts/restore.sh --last, check again, then scripts/bisect.sh"
  exit 1
fi

if [[ $LAUNCHER == 1 && $HOME_OK == 1 ]]; then
  acc_wake=$(answer_for acc-wake)
  if [[ $acc_wake == y ]]; then
    reconnect_quietly
    boot_id=$(dev1 cat /proc/sys/kernel/random/boot_id)
    if [[ $boot_id =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
      if [[ -f $STATE/launcher-soak.txt ]] && in_lines "$boot_id" "$(cat "$STATE/launcher-soak.txt")"; then
        note "boot id already in the launcher soak record"
      else
        printf '%s\n' "$boot_id" >> "$STATE/launcher-soak.txt"
        note "launcher soak: recorded boot id"
      fi
    else
      warn "could not read a UUID boot id; launcher soak not recorded"
    fi
  fi
fi

if [[ $ACC_ONLY == 1 ]]; then
  note "ignition checks recorded. Run scripts/verify.sh --manual for the full set."
  exit 0
fi

while IFS= read -r b; do
  [[ -n $b ]] || continue
  : > "$STATE/batches/$b.checked"
done <<EOF
$(unchecked_batches)
EOF
note "all car checks passed; the next batch is unlocked"
