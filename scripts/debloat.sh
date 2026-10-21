#!/usr/bin/env bash
# Disable (never uninstall) one tier of this unit's verified package list, as one recorded batch.
# Usage: scripts/debloat.sh --tier 1|2|3 [--dry-run] [-y]
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TIER=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --tier) [[ $# -ge 2 ]] || die "--tier needs 1, 2 or 3"; TIER=$2; shift 2 ;;
    --dry-run|-y|--yes) common_flag "$1"; shift ;;
    -h|--help)
      printf 'usage: scripts/debloat.sh --tier 1|2|3 [--dry-run] [-y]\n'
      exit 0 ;;
    *) die "unknown flag: $1" ;;
  esac
done
case $TIER in 1|2|3) ;; *) die "pick a tier: --tier 1, 2 or 3" ;; esac

need_device
need_snapshot
load_conf
require_checked
LIST=$(pfile packages.txt)
[[ -n $(list_of "$LIST") ]] || die "profile '$PROFILE' has no verified list. Run scripts/discover.sh, then follow docs/ADDING-A-UNIT.md."
# shellcheck disable=SC2153  # TIER1/TIER2 are assigned by load_conf
[[ $TIER == 1 && $TIER1 == 0 ]] && { note "TIER1=0 in headroom.conf: nothing to do"; exit 0; }
# shellcheck disable=SC2153
[[ $TIER == 2 && $TIER2 == 0 ]] && { note "TIER2=0 in headroom.conf: nothing to do"; exit 0; }
load_device_facts
installed=$(installed_set)
disabled=$(disabled_set)
[[ -n $installed ]] || die "could not read the package list from $SERIAL"
UPDATER_RE='(^|[._])f?ota([._]|$)|update|upgrade'

step "plan · profile $PROFILE · tier $TIER"
todo=""; plan=""
while read -r p t _; do
  [[ $t == "$TIER" ]] || continue
  case $(pkg_state "$p" "$installed" "$disabled") in
    absent)   printf '  %-50s absent\n' "$p"; continue ;;
    disabled) printf '  %-50s already disabled (left alone, also by restore)\n' "$p"; continue ;;
  esac
  if in_words "$p" "$KEEP_APPS"; then printf '  %-50s SKIP (keep list)\n' "$p"; continue; fi
  if [[ $TIER == 3 ]] && ! in_words "$p" "$REMOVE_APPS"; then
    printf '  %-50s SKIP (not chosen in configure.sh)\n' "$p"; continue
  fi
  if [[ $UPDATER_KEEP == 1 && $(lower "$p") =~ $UPDATER_RE ]]; then
    printf '  %-50s SKIP (UPDATER_KEEP=1)\n' "$p"; continue
  fi
  why=$(blocking_reasons "$p")
  if [[ -n $why ]]; then
    printf '  %-50s GUARD\n' "$p"; printf '%s\n' "$why" | sed 's/^/        /'; continue
  fi
  printf '  %-50s will be disabled\n' "$p"
  todo="$todo $p"; plan="$plan$p"$'\t'"enabled"$'\n'
done < <(list_of "$LIST")

[[ -n $todo ]] || { note "nothing to do in tier $TIER"; exit 0; }
[[ $DRY_RUN == 1 ]] && { note "dry-run: nothing changed"; exit 0; }
note "these are DISABLED, not uninstalled: Settings > Apps can turn each back on, so can scripts/restore.sh"
confirm "Disable $(printf '%s' "$todo" | wc -w | tr -d ' ') packages (tier $TIER) on $SERIAL?" || die "cancelled"

BATCH=$(new_batch_id "t$TIER")
printf '%s' "$plan" | write_plan "$BATCH"          # the undo record exists before the first change
step "batch $BATCH"
n_ok=0; n_ref=0; n_sus=0
for p in $todo; do
  r=$(disable_one "$p")
  [[ -n $r ]] || die "no answer from $SERIAL while disabling $p. The batch is recorded: reconnect, then scripts/restore.sh --last"
  journal "$BATCH" "$p" "$r"
  printf '  %-50s %s\n' "$p" "$r"
  case $r in disabled) n_ok=$((n_ok+1)) ;; refused) n_ref=$((n_ref+1)) ;; *) n_sus=$((n_sus+1)) ;; esac
done

step "read back"
now=$(disabled_set)
for p in $todo; do in_lines "$p" "$now" || warn "$p is not in pm list packages -d"; done

write_manual_undo "$BATCH"
reboot_wait
step "after reboot"
now=$(disabled_set); back=""
for p in $todo; do in_lines "$p" "$now" || back="$back $p"; done
if [[ -n $back ]]; then
  warn "the firmware re-enabled at boot:$back"
  warn "do not loop on these. Note them in data/profiles/$PROFILE/README.md"
fi
note "foreground now: $(resumed_activity)"

step "summary"
note "disabled $n_ok · refused $n_ref · suspect $n_sus · batch $BATCH"
[[ $n_sus -gt 0 ]] && warn "SUSPECT results: a person reads them before anything else runs"
note "NEXT: a person at the car runs scripts/verify.sh --manual"
note "if anything is wrong: scripts/restore.sh --last, then scripts/bisect.sh to find the one package"
