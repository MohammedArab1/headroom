#!/usr/bin/env bash
# Find the one package in a batch that broke a car check. Disables half the suspects at a
# time, asks a person whether the problem came back, and records every round as a batch.
# Usage: scripts/bisect.sh [--batch ID] [--reboot-each] [--answers "y n ..."] [-y] [--dry-run]
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BATCH=""
REBOOT_EACH=0
ANSWERS=""
ANSWERS_LEFT=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --batch) [[ $# -ge 2 ]] || die "--batch needs an id"; BATCH=$2; shift 2 ;;
    --reboot-each) REBOOT_EACH=1; shift ;;
    --answers) [[ $# -ge 2 ]] || die "--answers needs a value"; ANSWERS=$2; shift 2 ;;
    --dry-run|-y|--yes) common_flag "$1"; shift ;;
    -h|--help)
      printf 'usage: scripts/bisect.sh [--batch ID] [--reboot-each] [--answers "y n ..."] [-y] [--dry-run]\n'
      exit 0 ;;
    *) die "unknown flag: $1" ;;
  esac
done
for a in $ANSWERS; do
  case $a in y|n) ;; *) die "--answers takes y or n values, not '$a'" ;; esac
done
ANSWERS_LEFT=$ANSWERS

need_device
load_conf
load_device_facts
installed=$(installed_set)
disabled=$(disabled_set)
[[ -n $installed ]] || die "could not read the package list from $SERIAL"

if [[ -z $BATCH ]]; then
  BATCH=$(batches_newest_first | head -n 1)
  [[ -n $BATCH ]] || die "no batch to bisect. Run scripts/debloat.sh first, then restore its batch."
fi
case $BATCH in ''|*[!A-Za-z0-9._-]*) die "bad batch id: $BATCH" ;; esac
PLAN="$STATE/batches/$BATCH.tsv"
[[ -f $PLAN ]] || die "no plan for batch '$BATCH' in $STATE/batches"

suspects=$(awk -F '\t' '$2 == "enabled" {print $1}' "$PLAN")
[[ -n $suspects ]] || die "batch $BATCH has no packages that headroom enabled"
for p in $suspects; do
  if in_lines "$p" "$disabled"; then
    die "$p is still disabled. Run scripts/restore.sh --last first, check that the problem is gone, then bisect."
  fi
done

n=$(printf '%s\n' "$suspects" | grep -c .)
if [[ $n -eq 1 ]]; then
  culprit=$(printf '%s\n' "$suspects" | head -n 1)
  note "the culprit is $culprit"
  if [[ $DRY_RUN == 1 ]]; then exit 0; fi
else
  half_n=$((n / 2))
  [[ $half_n -lt 1 ]] && half_n=1
  first_half=$(printf '%s\n' "$suspects" | head -n "$half_n")
  if [[ $DRY_RUN == 1 ]]; then
    note "[dry-run] would disable: $(printf '%s' "$first_half" | tr '\n' ' ')"
    exit 0
  fi
  if [[ -z $ANSWERS && ! -t 0 ]]; then
    die "a person at the car must answer whether the problem came back; pass their answers with --answers \"y n ...\""
  fi
fi

next_answer() {
  if [[ -n $ANSWERS_LEFT ]]; then
    ANS=${ANSWERS_LEFT%% *}
    case $ANSWERS_LEFT in
      *" "*) ANSWERS_LEFT=${ANSWERS_LEFT#* } ;;
      *) ANSWERS_LEFT="" ;;
    esac
    return 0
  fi
  [[ -t 0 ]] || die "no answers left: ask the person whether the problem came back, then pass more in --answers"
  printf 'Is the problem back? [y/N] ' >&2
  read -r reply
  case $reply in y|Y) ANS=y ;; *) ANS=n ;; esac
}

round=1
while [[ $n -gt 1 ]]; do
  half_n=$((n / 2))
  [[ $half_n -lt 1 ]] && half_n=1
  half=$(printf '%s\n' "$suspects" | head -n "$half_n")
  rest=$(printf '%s\n' "$suspects" | tail -n +$((half_n + 1)))
  BATCH_ID="$(new_batch_id bisect)-r$round"

  plan=""
  for p in $half; do
    why=$(blocking_reasons "$p")
    if [[ -n $why ]]; then
      printf 'GUARD %s\n' "$p" >&2
      printf '%s\n' "$why" | sed 's/^/    /' >&2
      die "a guard now blocks $p; refusing to disable it. Fix it by hand and re-run."
    fi
    plan="$plan$p"$'\t'"enabled"$'\n'
  done

  printf '%s' "$plan" | write_plan "$BATCH_ID"
  step "round $round · batch $BATCH_ID"
  for p in $half; do
    r=$(disable_one "$p")
    [[ -n $r ]] || die "no answer from $SERIAL while disabling $p. The round is recorded: reconnect, then scripts/restore.sh --last"
    journal "$BATCH_ID" "$p" "$r"
    printf '  %-50s %s\n' "$p" "$r"
    case $r in
      disabled) ;;
      *) die "could not disable $p ($r). The round is recorded; run scripts/restore.sh --last." ;;
    esac
  done

  if [[ $REBOOT_EACH == 1 ]]; then
    reboot_wait
  fi

  next_answer
  ans=$ANS
  case $ans in
    y)
      bad=0
      for p in $half; do
        r=$(enable_one "$p")
        [[ -n $r ]] || die "no answer from $SERIAL while enabling $p. Run scripts/restore.sh --last."
        journal "bisect-restore:$BATCH_ID" "$p" "$r"
        printf '  %-50s %s\n' "$p" "$r"
        case $r in enabled|dry-run) ;; *) bad=$((bad + 1)) ;; esac
      done
      if [[ $bad -gt 0 ]]; then
        die "could not re-enable the whole half. Run scripts/restore.sh --last."
      fi
      : > "$STATE/batches/$BATCH_ID.restored"
      suspects=$half
      note "problem returned: the culprit is in this half"
      ;;
    n)
      suspects=$rest
      note "problem stayed away: this half is safe, the culprit is in the other half"
      ;;
  esac
  n=$(printf '%s\n' "$suspects" | grep -c .)
  round=$((round + 1))
done

culprit=$(printf '%s\n' "$suspects" | head -n 1)
step "result"
note "the culprit is $culprit"
note "move it to data/profiles/$PROFILE/never-disable.txt with evidence from dumpsys package $culprit"

keep_list=${KEEP_APPS:+$KEEP_APPS }$culprit
add=0
if [[ $ASSUME_YES == 1 ]]; then
  add=1
elif [[ -t 0 ]]; then
  printf 'Add %s to the keep list? [y/N] ' "$culprit" >&2
  read -r reply
  case $reply in y|Y) add=1 ;; esac
else
  note "to keep it: scripts/configure.sh --keep \"$keep_list\" -y"
fi
if [[ $add == 1 ]]; then
  if "$ROOT/scripts/configure.sh" --keep "$keep_list" -y >/dev/null 2>&1; then
    note "added $culprit to KEEP_APPS in headroom.conf"
  else
    warn "could not update headroom.conf; run scripts/configure.sh --keep \"$keep_list\" -y"
  fi
fi
