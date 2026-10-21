#!/usr/bin/env bash
# The interview: ask what this person actually uses, then write headroom.conf.
# Agents pass the answers as flags; they never guess.
# Usage: scripts/configure.sh [answers...] [-y] [--dry-run]
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PKG_RE='^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$'
PUBLIC_DNS_RE='^[a-z0-9.-]+\.[a-z]{2,}$'
FLAGS_SEEN=0
KEEP_RAW=""; KEEP_SET=0
REMOVE_RAW=""; REMOVE_SET=0
DOCK_RAW=""; DOCK_SET=0
BENCH_RAW=""; BENCH_SET=0
BG_RAW=""; BG_SET=0
RISKY_RAW=""; RISKY_SET=0

usage() {
  cat >&2 <<'EOF'
usage: scripts/configure.sh [answers...] [-y] [--dry-run]
  --keep "pkg1,pkg2"          never touch these (packages or names from apps.txt)
  --remove "pkg1,pkg2"        tier-3 apps the person agreed to disable
  --tier1 0|1                 telemetry / ads / promo
  --tier2 0|1                 unused system leftovers
  --sim 0|1                   a SIM card is in the unit
  --updater-keep 0|1          keep the firmware updater
  --anim 0|0.5|1              animation scale
  --dexopt 0|1                compile apps ahead of time
  --scan-off 0|1              turn off always-on Wi-Fi/Bluetooth scanning
  --trim-caches 0|1           clear caches when storage is over 85%
  --bg-restrict "pkg1,..."    keep installed but restrict in the background
  --private-dns HOST|0        Private DNS host, or 0 for off
  --launcher 0|1              replace the home screen with headroom home
  --dock "pkg1,pkg2"          up to 6 dock apps, in order
  --bench-apps "pkg1,pkg2"    two or three third-party apps to time
  --allow-risky "pkg1,..."    override risk: guards (evidence must be in the profile)
  -y                          accept the current defaults
  --dry-run                   print the file instead of writing it
EOF
}

load_conf
while [[ $# -gt 0 ]]; do
  case $1 in
    --keep|--remove|--dock|--bench-apps|--bg-restrict|--allow-risky)
      [[ $# -ge 2 ]] || die "$1 needs a value"
      case $1 in
        --keep)       [[ $KEEP_SET == 0 ]] && KEEP_RAW=$2 || KEEP_RAW="$KEEP_RAW,$2"; KEEP_SET=1 ;;
        --remove)     [[ $REMOVE_SET == 0 ]] && REMOVE_RAW=$2 || REMOVE_RAW="$REMOVE_RAW,$2"; REMOVE_SET=1 ;;
        --dock)       [[ $DOCK_SET == 0 ]] && DOCK_RAW=$2 || DOCK_RAW="$DOCK_RAW,$2"; DOCK_SET=1 ;;
        --bench-apps) [[ $BENCH_SET == 0 ]] && BENCH_RAW=$2 || BENCH_RAW="$BENCH_RAW,$2"; BENCH_SET=1 ;;
        --bg-restrict) [[ $BG_SET == 0 ]] && BG_RAW=$2 || BG_RAW="$BG_RAW,$2"; BG_SET=1 ;;
        --allow-risky) [[ $RISKY_SET == 0 ]] && RISKY_RAW=$2 || RISKY_RAW="$RISKY_RAW,$2"; RISKY_SET=1 ;;
      esac
      FLAGS_SEEN=1; shift 2 ;;
    --tier1|--tier2|--sim|--updater-keep|--dexopt|--scan-off|--trim-caches|--launcher|--anim)
      [[ $# -ge 2 ]] || die "$1 needs a value"
      case $1 in
        --tier1) TIER1=$2 ;;
        --tier2) TIER2=$2 ;;
        --sim) SIM=$2 ;;
        --updater-keep) UPDATER_KEEP=$2 ;;
        --dexopt) DEXOPT=$2 ;;
        --scan-off) SCAN_OFF=$2 ;;
        --trim-caches) TRIM_CACHES=$2 ;;
        --launcher) LAUNCHER=$2 ;;
        --anim) ANIM_SCALE=$2 ;;
      esac
      FLAGS_SEEN=1; shift 2 ;;
    --private-dns)
      [[ $# -ge 2 ]] || die "--private-dns needs a host or 0"
      if [[ $2 == 0 ]]; then PRIVATE_DNS=0; else PRIVATE_DNS=1; PRIVATE_DNS_HOST=$2; fi
      FLAGS_SEEN=1; shift 2 ;;
    -y|--yes|--dry-run)
      common_flag "$1"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown flag: $1" ;;
  esac
done

need_device
installed=$(installed_set)
third=$(third_set)
[[ -n $installed ]] || die "could not read the package list from $SERIAL"
load_device_facts

trim() { printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }
append_unique() {
  case " $1 " in
    *" $2 "*) printf '%s' "$1" ;;
    *) if [[ -z $1 ]]; then printf '%s' "$2"; else printf '%s %s' "$1" "$2"; fi ;;
  esac
}
app_to_pkg() {  # exact name from apps.txt, case-insensitive
  local want line name pkg
  want=$(lower "$1")
  while IFS= read -r line; do
    name=$(trim "${line%%  *}")
    pkg=$(trim "${line##*  }")
    if [[ $(lower "$name") == "$want" ]]; then printf '%s' "$pkg"; return 0; fi
  done <<EOF
$(list_of "$(cfile apps.txt)")
EOF
  return 1
}
resolve_item() {
  local item=$1 pkg
  if [[ $item =~ $PKG_RE ]]; then printf '%s' "$item"; return 0; fi
  pkg=$(app_to_pkg "$item") || return 1
  [[ -n $pkg ]] || return 1
  printf '%s' "$pkg"
}
resolve_list() {  # comma-separated packages or app names, or a space-separated package list
  local raw=$1 out="" item resolved tok all_pkgs
  if [[ $raw != *,* ]]; then
    all_pkgs=1
    for tok in $raw; do
      [[ $tok =~ $PKG_RE ]] || all_pkgs=0
    done
    if [[ $all_pkgs == 1 ]]; then
      for tok in $raw; do out=$(append_unique "$out" "$tok"); done
      printf '%s' "$out"; return 0
    fi
  fi
  local IFS=','
  for item in $raw; do
    item=$(trim "$item")
    [[ -n $item ]] || continue
    resolved=$(resolve_item "$item") || return 1
    [[ -n $resolved ]] || return 1
    out=$(append_unique "$out" "$resolved")
  done
  printf '%s' "$out"
}
label_for() {
  local p=$1 line pkg
  while IFS= read -r line; do
    pkg=$(trim "${line##*  }")
    if [[ $pkg == "$p" ]]; then trim "${line%%  *}"; return 0; fi
  done <<EOF
$(list_of "$(cfile apps.txt)")
EOF
  printf '%s' "$p"
}
ask_yn() {  # prompt, default y|n
  local prompt=$1 def=$2 reply
  if [[ $ASSUME_YES == 1 ]]; then [[ $def == y ]]; return; fi
  [[ -t 0 ]] || die "not a terminal: pass the answers as flags, or -y after the person agreed"
  printf '%s [%s] ' "$prompt" "$def" >&2
  read -r reply
  case $reply in
    '') [[ $def == y ]] ;;
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}
ask_line() {  # prompt, default
  local prompt=$1 def=$2 reply
  [[ $ASSUME_YES == 1 ]] && { printf '%s' "$def"; return; }
  [[ -t 0 ]] || die "not a terminal: pass the answers as flags, or -y after the person agreed"
  printf '%s [%s] ' "$prompt" "$def" >&2
  read -r reply
  [[ -n $reply ]] && printf '%s' "$reply" || printf '%s' "$def"
}
ask_choice() {  # prompt, default, allowed values
  local prompt=$1 def=$2 allowed=$3 reply
  if [[ $ASSUME_YES == 1 ]]; then printf '%s' "$def"; return; fi
  [[ -t 0 ]] || die "not a terminal: pass the answers as flags, or -y after the person agreed"
  while :; do
    printf '%s [%s] ' "$prompt" "$def" >&2
    read -r reply
    [[ -n $reply ]] || reply=$def
    case " $allowed " in *" $reply "*) printf '%s' "$reply"; return 0 ;; esac
    note "choose one of: $allowed"
  done
}

profile_list=$(pfile packages.txt)
tier3=$(list_of "$profile_list" | awk '$2 == 3 {print $1}')
tier1_count=$(list_of "$profile_list" | awk '$2 == 1 {print $1}' | while read -r p; do in_lines "$p" "$installed" && echo "$p"; done | grep -c .)
tier2_count=$(list_of "$profile_list" | awk '$2 == 2 {print $1}' | while read -r p; do in_lines "$p" "$installed" && echo "$p"; done | grep -c .)

if [[ $FLAGS_SEEN == 0 && $ASSUME_YES == 0 && $DRY_RUN == 0 ]]; then
  [[ -t 0 ]] || die "not a terminal: pass the answers as flags, or -y after the person agreed"
  # Question 1: tier-3 apps, one at a time.
  while IFS= read -r p <&3; do
    [[ -n $p ]] || continue
    in_lines "$p" "$installed" || continue
    def=n
    in_words "$p" "$REMOVE_APPS" && def=y
    if ask_yn "Disable $(label_for "$p") ($p)? You can turn it back on any time." "$def"; then
      REMOVE_APPS=$(append_unique "$REMOVE_APPS" "$p")
    else
      REMOVE_APPS=$(printf '%s\n' "$REMOVE_APPS" | tr ' ' '\n' | grep -vx "$p" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    fi
  done 3<<EOF
$tier3
EOF
  # Questions 2 and 3.
  if ask_yn "Disable $tier1_count telemetry, ads and promo packages (listed above)?" "$([[ $TIER1 == 1 ]] && echo y || echo n)"; then TIER1=1; else TIER1=0; fi
  if ask_yn "Disable $tier2_count unused system leftovers (printing, live wallpapers, screensavers...)?" "$([[ $TIER2 == 1 ]] && echo y || echo n)"; then TIER2=1; else TIER2=0; fi
  # Question 4.
  KEEP_APPS=$(ask_line "Which apps must never be touched? (navigation, music, phone link, dashcam, TPMS, OBD)" "$KEEP_APPS")
  if ! KEEP_APPS=$(resolve_list "$KEEP_APPS"); then die "an app name in the keep list matched nothing; check data/common/apps.txt or use a package name"; fi
  # Question 5 and 6.
  if ask_yn "Is there a SIM card in the unit (4G)?" "$([[ $SIM == 1 ]] && echo y || echo n)"; then SIM=1; else SIM=0; fi
  if ask_yn "Keep the firmware updater?" "$([[ $UPDATER_KEEP == 1 ]] && echo y || echo n)"; then UPDATER_KEEP=1; else UPDATER_KEEP=0; fi
  # Questions 7 to 10.
  ANIM_SCALE=$(ask_choice "Animation speed: 0.5 (faster), 0 (off), or 1 (leave)" "$ANIM_SCALE" "0 0.5 1")
  if ask_yn "Compile apps ahead of time now? It takes 5 to 30 minutes with the unit on." "$([[ $DEXOPT == 1 ]] && echo y || echo n)"; then DEXOPT=1; else DEXOPT=0; fi
  if ask_yn "Turn off always-on Wi-Fi and Bluetooth scanning?" "$([[ $SCAN_OFF == 1 ]] && echo y || echo n)"; then SCAN_OFF=1; else SCAN_OFF=0; fi
  if ask_yn "Clear app caches if storage is over 85% full?" "$([[ $TRIM_CACHES == 1 ]] && echo y || echo n)"; then TRIM_CACHES=1; else TRIM_CACHES=0; fi
  # Question 11.
  BG_RESTRICT=$(ask_line "Any apps you keep but do not need running in the background? (comma-separated)" "$BG_RESTRICT")
  if ! BG_RESTRICT=$(resolve_list "$BG_RESTRICT"); then die "an app name in the background list matched nothing; use a package name"; fi
  # Question 12.
  if ask_yn "Use Private DNS to block trackers? Every DNS lookup goes to that resolver." "$([[ $PRIVATE_DNS == 1 ]] && echo y || echo n)"; then
    PRIVATE_DNS=1
    PRIVATE_DNS_HOST=$(ask_line "Private DNS host" "$PRIVATE_DNS_HOST")
  else
    PRIVATE_DNS=0
  fi
  # Questions 13 to 15.
  if ask_yn "Replace the home screen with headroom home (no internet access, no permissions)?" "$([[ $LAUNCHER == 1 ]] && echo y || echo n)"; then LAUNCHER=1; else LAUNCHER=0; fi
  DOCK_APPS=$(ask_line "Up to 6 apps for the home screen dock, in order (comma-separated)" "$DOCK_APPS")
  if ! DOCK_APPS=$(resolve_list "$DOCK_APPS"); then die "a dock app name matched nothing; use package names"; fi
  BENCH_APPS=$(ask_line "Two or three apps to time in the benchmark (comma-separated)" "$BENCH_APPS")
  if ! BENCH_APPS=$(resolve_list "$BENCH_APPS"); then die "a benchmark app name matched nothing; use package names"; fi
fi

# Overrides from flags. Unspecified keys keep the existing conf values.
if [[ $KEEP_SET == 1 ]]; then KEEP_APPS=$(resolve_list "$KEEP_RAW") || die "an app in --keep matched nothing; use a package name or an exact apps.txt name"; fi
if [[ $REMOVE_SET == 1 ]]; then REMOVE_APPS=$(resolve_list "$REMOVE_RAW") || die "an app in --remove matched nothing; use a package name or an exact apps.txt name"; fi
if [[ $DOCK_SET == 1 ]]; then DOCK_APPS=$(resolve_list "$DOCK_RAW") || die "an app in --dock matched nothing"; fi
if [[ $BENCH_SET == 1 ]]; then BENCH_APPS=$(resolve_list "$BENCH_RAW") || die "an app in --bench-apps matched nothing"; fi
if [[ $BG_SET == 1 ]]; then BG_RESTRICT=$(resolve_list "$BG_RAW") || die "an app in --bg-restrict matched nothing"; fi
if [[ $RISKY_SET == 1 ]]; then ALLOW_RISKY=$(resolve_list "$RISKY_RAW") || die "an app in --allow-risky matched nothing"; fi

# Default benchmark apps: the first two third-party, unguarded dock apps.
if [[ $BENCH_SET == 0 && -z $BENCH_APPS ]]; then
  picked=0
  for p in $DOCK_APPS; do
    in_lines "$p" "$third" || continue
    why=$(blocking_reasons "$p")
    [[ -n $why ]] && continue
    BENCH_APPS=$(append_unique "$BENCH_APPS" "$p")
    picked=$((picked + 1))
    [[ $picked -ge 2 ]] && break
  done
fi

case $TIER1 in 0|1) ;; *) die "--tier1 must be 0 or 1" ;; esac
case $TIER2 in 0|1) ;; *) die "--tier2 must be 0 or 1" ;; esac
case $SIM in 0|1) ;; *) die "--sim must be 0 or 1" ;; esac
case $UPDATER_KEEP in 0|1) ;; *) die "--updater-keep must be 0 or 1" ;; esac
case $DEXOPT in 0|1) ;; *) die "--dexopt must be 0 or 1" ;; esac
case $SCAN_OFF in 0|1) ;; *) die "--scan-off must be 0 or 1" ;; esac
case $TRIM_CACHES in 0|1) ;; *) die "--trim-caches must be 0 or 1" ;; esac
case $LAUNCHER in 0|1) ;; *) die "--launcher must be 0 or 1" ;; esac
case $ANIM_SCALE in 0|0.5|1) ;; *) die "--anim must be 0, 0.5 or 1" ;; esac
if [[ $PRIVATE_DNS == 1 ]]; then
  [[ $PRIVATE_DNS_HOST =~ $PUBLIC_DNS_RE ]] || die "--private-dns needs a host like dns.example.org, or 0"
fi

validate_pkgs() {  # variable name, list
  local name=$1 list=$2 p
  for p in $list; do
    [[ $p =~ $PKG_RE ]] || die "$name: not a package name: $p"
    in_lines "$p" "$installed" || die "$name: $p is not installed on this unit"
  done
}
validate_pkgs KEEP_APPS "$KEEP_APPS"
validate_pkgs REMOVE_APPS "$REMOVE_APPS"
validate_pkgs DOCK_APPS "$DOCK_APPS"
validate_pkgs BENCH_APPS "$BENCH_APPS"
validate_pkgs BG_RESTRICT "$BG_RESTRICT"
validate_pkgs ALLOW_RISKY "$ALLOW_RISKY"
for p in $BENCH_APPS; do
  in_lines "$p" "$third" || die "bench app $p is not third-party; benchmark.sh refuses vendor apps"
done
[[ $(printf '%s' "$DOCK_APPS" | wc -w | tr -d ' ') -le 6 ]] || die "--dock takes at most 6 apps"
[[ $(printf '%s' "$BENCH_APPS" | wc -w | tr -d ' ') -le 3 ]] || die "--bench-apps takes at most 3 apps"

if [[ $SIM == 1 ]] && in_lines com.android.stk "$installed"; then
  KEEP_APPS=$(append_unique "$KEEP_APPS" com.android.stk)
fi

conf_body() {
  printf '# Written by scripts/configure.sh. Git-ignored: it describes this car, not the repo.\n'
  printf 'KEEP_APPS=%q\n' "$KEEP_APPS"
  printf 'REMOVE_APPS=%q\n' "$REMOVE_APPS"
  printf 'ALLOW_RISKY=%q\n' "$ALLOW_RISKY"
  printf 'TIER1=%s\n' "$TIER1"
  printf 'TIER2=%s\n' "$TIER2"
  printf 'SIM=%s\n' "$SIM"
  printf 'UPDATER_KEEP=%s\n' "$UPDATER_KEEP"
  printf 'ANIM_SCALE=%s\n' "$ANIM_SCALE"
  printf 'DEXOPT=%s\n' "$DEXOPT"
  printf 'TRIM_CACHES=%s\n' "$TRIM_CACHES"
  printf 'SCAN_OFF=%s\n' "$SCAN_OFF"
  printf 'BG_RESTRICT=%q\n' "$BG_RESTRICT"
  printf 'PRIVATE_DNS=%s\n' "$PRIVATE_DNS"
  printf 'PRIVATE_DNS_HOST=%q\n' "$PRIVATE_DNS_HOST"
  printf 'LAUNCHER=%s\n' "$LAUNCHER"
  printf 'DOCK_APPS=%q\n' "$DOCK_APPS"
  printf 'BENCH_APPS=%q\n' "$BENCH_APPS"
}

if [[ $DRY_RUN == 1 ]]; then
  conf_body
  exit 0
fi

conf_body > "$CONF.tmp"
if ! ( source "$CONF.tmp" ) >/dev/null 2>&1; then
  rm -f "$CONF.tmp"
  die "the generated configuration does not parse; nothing was written"
fi
mv "$CONF.tmp" "$CONF" || die "could not write $CONF"
chmod 600 "$CONF"
note "wrote $CONF"
