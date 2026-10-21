#!/usr/bin/env bash
# Undo: enable what headroom disabled, newest batch first. Never uninstalls anything.
# Usage: scripts/restore.sh [--all | --last | --batch ID | --package PKG]
#                          [--no-tweaks] [--no-home] [--from-snapshot] [--dry-run] [-y]
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MODE=all
MODE_SET=0
BATCH=""
PACKAGE=""
NO_TWEAKS=0
NO_HOME=0
FROM_SNAPSHOT=0

while [[ $# -gt 0 ]]; do
  case $1 in
    --all) [[ $MODE_SET == 1 ]] && die "pick one of --all, --last, --batch or --package"; MODE='all'; MODE_SET=1; shift ;;
    --last) [[ $MODE_SET == 1 ]] && die "pick one of --all, --last, --batch or --package"; MODE='last'; MODE_SET=1; shift ;;
    --batch) [[ $MODE_SET == 1 ]] && die "pick one of --all, --last, --batch or --package"; [[ $# -ge 2 ]] || die "--batch needs an id"; MODE='batch'; BATCH=$2; MODE_SET=1; shift 2 ;;
    --package) [[ $MODE_SET == 1 ]] && die "pick one of --all, --last, --batch or --package"; [[ $# -ge 2 ]] || die "--package needs a package"; MODE='package'; PACKAGE=$2; MODE_SET=1; shift 2 ;;
    --no-tweaks) NO_TWEAKS=1; shift ;;
    --no-home) NO_HOME=1; shift ;;
    --from-snapshot) FROM_SNAPSHOT=1; shift ;;
    --dry-run|-y|--yes) common_flag "$1"; shift ;;
    -h|--help)
      printf 'usage: scripts/restore.sh [--all | --last | --batch ID | --package PKG] [--no-tweaks] [--no-home] [--from-snapshot] [--dry-run] [-y]\n'
      exit 0 ;;
    *) die "unknown flag: $1" ;;
  esac
done
[[ $FROM_SNAPSHOT == 1 && $MODE != all ]] && die "--from-snapshot can only be used with --all"
case $PACKAGE in
  ''|*[!A-Za-z0-9_.]*) [[ $MODE == package ]] && die "--package needs a valid package name" ;;
esac
case $BATCH in
  ''|*[!A-Za-z0-9._-]*) [[ $MODE == batch ]] && die "--batch needs a valid batch id" ;;
esac

need_device
TWEAKS="$STATE/tweaks.tsv"

batches_to_restore() {
  local b
  batches_newest_first | while read -r b; do
    [[ -f "$STATE/batches/$b.tsv" ]] || continue
    [[ -e "$STATE/batches/$b.restored" ]] && continue
    printf '%s\n' "$b"
  done
}

has_plan() {
  local f
  for f in "$STATE"/batches/*.tsv; do
    [[ -f $f ]] && return 0
  done
  return 1
}

restore_batch() {
  local b=$1 p before r bad=0
  step "batch $b"
  while IFS=$'\t' read -r p before; do
    [[ -n $p ]] || continue
    if [[ $before != enabled ]]; then
      printf '  %-50s left %s (as it was)\n' "$p" "$before"
      continue
    fi
    r=$(enable_one "$p")
    [[ -n $r ]] || die "no answer from $SERIAL while enabling $p. Reconnect and run restore again (it is safe to repeat)."
    [[ $DRY_RUN == 1 ]] || journal "restore:$b" "$p" "$r"
    printf '  %-50s %s\n' "$p" "$r"
    case $r in enabled|dry-run) ;; *) bad=$((bad+1)) ;; esac
  done < "$STATE/batches/$b.tsv"
  [[ $DRY_RUN == 1 ]] && return 0
  if [[ $bad -gt 0 ]]; then
    warn "$bad package(s) in $b did not come back; the batch stays open"
    return 1
  fi
  : > "$STATE/batches/$b.restored"
}

restore_tweaks() {
  [[ $NO_TWEAKS == 1 ]] && return 0
  if [[ ! -f $TWEAKS ]]; then
    note "no tweaks recorded"
    return 0
  fi
  step "tweaks (reverse order)"
  local rows kind a b old
  rows=$(sed '1!G;h;$!d' "$TWEAKS")
  while IFS=$'\t' read -r kind a b old; do
    [[ -n $kind ]] || continue
    case $kind in
      setting)
        if [[ $old == null ]]; then
          acmd settings delete "$a" "$b" >/dev/null
          note "$a/$b deleted (was unset)"
        else
          acmd settings put "$a" "$b" "$old" >/dev/null
          note "$a/$b = $old"
        fi ;;
      appop)
        acmd cmd appops set "$a" "$b" "$old" >/dev/null
        note "appop $a/$b = $old" ;;
      *) warn "unknown tweak kind '$kind'; left alone" ;;
    esac
  done <<EOF
$rows
EOF
}

restore_home() {
  [[ $NO_HOME == 1 ]] && return 0
  if [[ ! -f $STATE/home-before.txt ]]; then
    note "no home-before.txt; leaving HOME alone"
    return 0
  fi
  local hb now
  hb=$(head -n 1 "$STATE/home-before.txt")
  case $hb in
    ''|android/*)
      note "HOME was the system chooser; leaving it alone"
      return 0 ;;
  esac
  step "home"
  acmd cmd package set-home-activity --user 0 "$hb" >/dev/null
  acmd am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null
  if [[ $DRY_RUN == 0 ]]; then
    now=$(home_package)
    if [[ $now == "${hb%%/*}" ]]; then
      note "HOME is back on ${hb%%/*}"
    else
      warn "HOME is $now, expected ${hb%%/*}; use scripts/stock-launcher.sh --enable --make-home"
    fi
    rm -f "$STATE/launcher-installed"
  fi
  note "headroom home stays installed. To remove it by hand: adb uninstall app.headroom.home"
}

restore_from_snapshot() {
  need_snapshot
  local snapshot_disabled current to_enable p r bad=0
  snapshot_disabled=""
  if [[ -f $STATE/snapshot/packages-disabled.txt ]]; then
    snapshot_disabled=$(sed -n 's/^package://p' "$STATE/snapshot/packages-disabled.txt")
  fi
  current=$(disabled_set)
  to_enable=""
  for p in $current; do
    in_lines "$p" "$snapshot_disabled" || to_enable="$to_enable $p"
  done
  if [[ -z $to_enable ]]; then
    note "nothing is disabled that was not already disabled in the snapshot"
    return 0
  fi
  note "packages disabled after the snapshot:$to_enable"
  if [[ $DRY_RUN == 0 ]]; then
    confirm "Enable these packages?" || die "cancelled"
  fi
  for p in $to_enable; do
    r=$(enable_one "$p")
    [[ -n $r ]] || die "no answer from $SERIAL while enabling $p. Reconnect and run restore again."
    [[ $DRY_RUN == 1 ]] || journal "restore:from-snapshot" "$p" "$r"
    printf '  %-50s %s\n' "$p" "$r"
    case $r in enabled|dry-run) ;; *) bad=$((bad+1)) ;; esac
  done
  [[ $bad -gt 0 ]] && return 1
  return 0
}

if [[ $MODE == package ]]; then
  found=0
  for f in "$STATE"/batches/*.tsv; do
    [[ -f $f ]] || continue
    if awk -F '\t' -v p="$PACKAGE" '$1 == p && $2 == "enabled" {found=1} END {exit(found ? 0 : 1)}' "$f"; then
      found=1
      break
    fi
  done
  [[ $found == 1 ]] || die "headroom never disabled $PACKAGE; use Settings > Apps"
  r=$(enable_one "$PACKAGE")
  [[ -n $r ]] || die "no answer from $SERIAL while enabling $PACKAGE."
  [[ $DRY_RUN == 1 ]] || journal "restore:package" "$PACKAGE" "$r"
  printf '  %-50s %s\n' "$PACKAGE" "$r"
  case $r in enabled|dry-run) exit 0 ;; *) exit 1 ;; esac
fi

if [[ $MODE == batch ]]; then
  [[ -f $STATE/batches/$BATCH.tsv ]] || die "no batch '$BATCH' in $STATE/batches"
  if [[ -e $STATE/batches/$BATCH.restored ]]; then
    note "batch $BATCH is already restored"
    exit 0
  fi
  restore_batch "$BATCH" || exit 1
  exit 0
fi

if [[ $FROM_SNAPSHOT == 0 ]] && ! has_plan; then
  die "no batch records in $STATE/batches. If the records were deleted, run scripts/restore.sh --all --from-snapshot, or use Settings > Apps."
fi

bad=0
if [[ $FROM_SNAPSHOT == 1 ]]; then
  restore_from_snapshot || bad=1
elif [[ $MODE == last ]]; then
  b=$(batches_to_restore | head -n 1)
  if [[ -z $b ]]; then
    note "no batch is waiting to be restored"
    exit 0
  fi
  restore_batch "$b" || bad=1
else
  while IFS= read -r b; do
    [[ -n $b ]] || continue
    restore_batch "$b" || bad=1
  done <<EOF
$(batches_to_restore)
EOF
fi

if [[ $MODE == all ]]; then
  restore_tweaks
  restore_home
  [[ $DRY_RUN == 1 ]] || reboot_wait
elif [[ $MODE == last ]]; then
  [[ $DRY_RUN == 1 ]] || reboot_wait
fi
[[ $bad == 0 ]] || exit 1
exit 0
