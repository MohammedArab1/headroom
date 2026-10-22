#!/usr/bin/env bash
# Manage the vendor launcher after headroom home has taken HOME.
# Usage: scripts/stock-launcher.sh [--disable | --handover | --enable [--make-home]]
#                                  [--dry-run] [-y]
# --disable  needs a soak of 2 boots and every batch checked.
# --handover only for units that ignored set-home-activity (STATE/set-home-ignored).
# --enable   brings the vendor launcher back; --make-home also gives it HOME again.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MODE=""
MAKE_HOME=0

usage() {
  cat <<'EOF'
usage: scripts/stock-launcher.sh [--disable | --handover | --enable [--make-home]]
                                 [--dry-run] [-y]

  --disable    disable the vendor launcher (stays installed); needs a 2-boot soak
  --handover   disable it on a unit whose firmware ignored set-home-activity
  --enable     enable the vendor launcher again
  --make-home  with --enable: give HOME back to the vendor launcher
EOF
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --disable) [[ -n $MODE ]] && die "pick one of --disable, --handover or --enable"; MODE=disable; shift ;;
    --handover) [[ -n $MODE ]] && die "pick one of --disable, --handover or --enable"; MODE=handover; shift ;;
    --enable) [[ -n $MODE ]] && die "pick one of --disable, --handover or --enable"; MODE=enable; shift ;;
    --make-home) MAKE_HOME=1; shift ;;
    --dry-run|-y|--yes) common_flag "$1"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown flag: $1" ;;
  esac
done
[[ -n $MODE ]] || die "pick one of --disable, --handover or --enable"
[[ $MAKE_HOME == 1 && $MODE != enable ]] && die "--make-home only makes sense with --enable"

need_device
load_conf
[[ -f $STATE/home-before.txt ]] || die "no recorded previous HOME for this unit; run scripts/launcher.sh first"
VENDOR=$(head -n 1 "$STATE/home-before.txt")
VENDOR_PKG=${VENDOR%%/*}
case $VENDOR in
  ''|android/*) die "HOME was the system chooser before headroom, so there is no vendor launcher to manage" ;;
esac
[[ $VENDOR_PKG != "$SELF_PKG" ]] || die "home-before.txt names headroom home itself; nothing to disable"

soak_boots() {
  [[ -f $STATE/launcher-soak.txt ]] || return 0
  sed '/^[[:space:]]*$/d' "$STATE/launcher-soak.txt" | sort -u
}

vendor_reasons() {
  IGNORE_HOME_GUARD="$VENDOR_PKG" blocking_reasons "$VENDOR_PKG"
}

require_vendor_guards_clear() {
  local why
  why=$(vendor_reasons)
  if [[ -n $why ]]; then
    warn "$VENDOR_PKG still has guards the HOME override does not cover:"
    printf '%s\n' "$why" | sed 's/^/    /' >&2
    die "refusing to disable $VENDOR_PKG. Evidence goes into the profile, then configure.sh --allow-risky (AGENTS.md)."
  fi
}

require_headroom_answers_home() {
  in_lines "$SELF_PKG" "$(home_claimants)" \
    || die "$SELF_PKG does not answer HOME. Reinstall it with scripts/launcher.sh first."
}

mark_batches_restored() {
  local f n=0
  for f in "$STATE"/batches/stock-launcher-*.tsv; do
    [[ -f $f ]] || continue
    if grep -F "$VENDOR_PKG" "$f" >/dev/null; then
      : > "${f%.tsv}.restored"
      n=$((n + 1))
    fi
  done
  note "marked $n stock-launcher batch(es) restored"
}

rollback_vendor() {
  local reason=$1 r
  r=$(enable_one "$VENDOR_PKG")
  [[ -n $r ]] || die "no answer from $SERIAL while re-enabling $VENDOR_PKG. Run scripts/stock-launcher.sh --enable by hand."
  acmd cmd package set-home-activity --user 0 "$VENDOR" >/dev/null
  acmd am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null
  [[ -z ${BATCH:-} ]] || : > "$STATE/batches/$BATCH.restored"
  die "$reason. $VENDOR_PKG is enabled again."
}

if [[ $MODE == enable ]]; then
  step "enable $VENDOR_PKG"
  if [[ $DRY_RUN == 1 ]]; then
    if [[ $MAKE_HOME == 1 ]]; then
      note "[dry-run] would enable $VENDOR_PKG and make it HOME"
    else
      note "[dry-run] would enable $VENDOR_PKG"
    fi
    note "dry-run: nothing changed"
    exit 0
  fi
  r=$(enable_one "$VENDOR_PKG")
  [[ -n $r ]] || die "no answer from $SERIAL while enabling $VENDOR_PKG"
  case $r in enabled|dry-run) ;; *) die "suspect: $r. Enable it by hand in Settings > Apps." ;; esac
  mark_batches_restored
  if [[ $MAKE_HOME == 1 ]]; then
    acmd cmd package set-home-activity --user 0 "$VENDOR" >/dev/null
    acmd am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null
    rm -f "$STATE/launcher-installed"
    note "HOME is back on $VENDOR_PKG"
  fi
  note "NEXT: scripts/verify.sh --manual if the person wants the car checks again"
  exit 0
fi

# Both remaining modes disable the vendor package.
if [[ $MODE == disable ]]; then
  require_checked
  NOW_HOME=$(home_package)
  [[ $NOW_HOME == "$SELF_PKG" ]] \
    || die "HOME is $NOW_HOME, not $SELF_PKG. Run scripts/launcher.sh first."
  [[ -f $STATE/launcher-installed ]] \
    || die "headroom home is not recorded as installed (STATE/launcher-installed is missing)"
  boots=$(soak_boots | grep -c .)
  [[ $boots -ge 2 ]] \
    || die "the launcher soak has $boots boot id(s); it needs 2. Drive normally, run verify.sh --manual after each boot, then retry."
else
  require_checked
  [[ -f $STATE/set-home-ignored ]] \
    || die "this unit did not ignore set-home-activity; use --disable after the soak"
  present "$SELF_PKG" || die "$SELF_PKG is not installed; run scripts/launcher.sh first"
  out=$(dev am start -W -n "$SELF_PKG/.HomeActivity")
  if printf '%s\n' "$out" | grep -E '(^Error|Error:)' >/dev/null; then
    die "$SELF_PKG does not start: $out"
  fi
  case $out in *"Status: ok"*) ;; *) die "$SELF_PKG does not start: $out" ;; esac
fi
load_device_facts
require_vendor_guards_clear
require_headroom_answers_home

step "plan"
note "disable $VENDOR_PKG (it stays installed; --enable brings it back)"
note "HOME must stay on $SELF_PKG, before and after a reboot"
[[ $MODE == handover ]] && note "handover: the firmware ignored set-home-activity, so the vendor launcher must go"
[[ $DRY_RUN == 1 ]] && { note "dry-run: nothing changed"; exit 0; }
confirm "Disable $VENDOR_PKG? It stays installed and can be re-enabled." || die "cancelled"

BATCH=$(new_batch_id stock-launcher)
printf '%s\tenabled\n' "$VENDOR_PKG" | write_plan "$BATCH"
step "disable"
r=$(disable_one "$VENDOR_PKG")
[[ -n $r ]] || die "no answer from $SERIAL while disabling $VENDOR_PKG. Reconnect and run scripts/restore.sh --batch $BATCH"
case $r in
  disabled) ;;
  refused)
    : > "$STATE/batches/$BATCH.restored"
    die "the firmware refused to disable $VENDOR_PKG; nothing changed" ;;
  *) die "suspect: $r. Run scripts/restore.sh --batch $BATCH" ;;
esac
write_manual_undo "$BATCH"

step "home"
acmd cmd package set-home-activity --user 0 "$SELF_PKG/.HomeActivity" >/dev/null
WAIT=${HOME_WAIT:-5}
waited=0
while :; do
  NOW_HOME=$(home_package)
  [[ $NOW_HOME == "$SELF_PKG" ]] && break
  [[ $waited -ge $WAIT ]] && break
  sleep 1
  waited=$((waited + 1))
done
[[ $NOW_HOME == "$SELF_PKG" ]] \
  || rollback_vendor "HOME did not stay on $SELF_PKG after disabling $VENDOR_PKG"

step "reboot check"
reboot_wait
NOW_HOME=$(home_package)
[[ $NOW_HOME == "$SELF_PKG" ]] \
  || rollback_vendor "after the reboot HOME is $NOW_HOME, not $SELF_PKG"

if ! in_lines "$VENDOR_PKG" "$(disabled_set)"; then
  : > "$STATE/batches/$BATCH.restored"
  warn "$VENDOR_PKG came back at boot and is enabled again; HOME is still $SELF_PKG."
  warn "record this in data/profiles/$PROFILE/README.md: this firmware will not keep it disabled."
  exit 1
fi

if [[ $MODE == handover ]]; then
  rm -f "$STATE/set-home-ignored"
  : > "$STATE/launcher-installed"
fi
note "HOME is $SELF_PKG; $VENDOR_PKG is disabled but still installed"
step "next"
note "a person at the car runs scripts/verify.sh --manual"
exit 0
