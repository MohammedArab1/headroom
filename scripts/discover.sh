#!/usr/bin/env bash
# Read-only inventory: what is installed, what looks safe, what looks car-critical.
# Never changes the unit. Writes report/discover-<date>.txt.
# Usage: scripts/discover.sh [--dry-run] [--labels] [--screens]
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LABELS=0
SCREENS=0
while [[ $# -gt 0 ]]; do
  case $1 in
    --labels) LABELS=1; shift ;;
    --screens) SCREENS=1; shift ;;
    --dry-run|-y|--yes) common_flag "$1"; shift ;;
    -h|--help)
      printf 'usage: scripts/discover.sh [--dry-run] [--labels] [--screens]\n'
      exit 0 ;;
    *) die "unknown flag: $1" ;;
  esac
done

need_device
load_device_facts
home_comp=$(home_component)
[[ $LABELS == 1 ]] && note "--labels is not implemented yet; reporting package names only"
[[ $SCREENS == 1 ]] && note "--screens is not implemented yet; no screenshot taken"

installed=$(installed_set)
disabled=$(disabled_set)
third=$(third_set)
[[ -n $installed ]] || die "could not read the package list from $SERIAL"
paths_raw=$(dev_ok 'pm list packages -f')
known=$(list_of "$(cfile candidates.txt)")

TELEMETRY_RE='analytics|telemetry|tracker|tracking|crash|logger|logkit|feedback|bugreport|report|stat(s|istics)?|mtklogger|loggerui'
ADS_RE='(^|\.)ads?([._]|$)|adservice|advert|promo|recommend|push|messagebox|splash'
STORE_RE='appstore|market|(^|\.)store([._]|$)|autoinstall|(^|\.)pai([._]|$)'
MEDIA_RE='gallery|music|video|player|browser|filemanager|fileexplorer|email|calendar|weather|news|game'
FACTORY_RE='factory|engineer|(^|[._])(fac|test|cts)([._]|$)'
PKG_RE='^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$'

PATHS=""
while IFS= read -r line; do
  [[ -n $line ]] || continue
  case $line in
    package:*=*) ;;
    *) continue ;;
  esac
  path=${line%%=*}; path=${path#package:}
  pkg=${line##*=}
  PATHS="$PATHS$pkg"$'\t'"$path"$'\n'
done <<EOF
$paths_raw
EOF

path_for() { printf '%s' "$PATHS" | awk -F '\t' -v p="$1" '$1==p {print $2; exit}'; }
known_tier() { printf '%s\n' "$known" | awk -v p="$1" '$1==p {print $2; exit}'; }
matches_any() {
  local re
  while IFS= read -r re; do
    [[ -n $re && $1 =~ $re ]] && return 0
  done <<EOF
$2
EOF
  return 1
}
one_line() { printf '%s' "$1" | tr '\n' ' ' | sed 's/[[:space:]]*$//'; }

candidate_block() {  # pkg category tier state kind path launcher-count services receivers why
  local p=$1 cat=$2 tier=$3 state=$4 kind=$5 path=$6 lc=$7 services=$8 receivers=$9 why=${10:-}
  local icon="no"
  [[ $lc -gt 0 ]] && icon="yes ($lc)"
  printf '  %-44s %-10s tier %-7s %-8s %s\n' "$p" "$cat" "$tier" "$state" "$kind"
  printf '      apk: %s\n' "${path:-unknown}"
  printf '      launcher icon: %s\n' "$icon"
  printf '      services: %s\n' "${services:-(none)}"
  printf '      receivers: %s\n' "${receivers:-(none)}"
  if [[ -n $why ]]; then
    printf '      evidence:\n'
    printf '%s\n' "$why" | sed 's/^/        /'
  fi
}

SEC1_T1=""; SEC1_T2=""; SEC1_T3=""
SEC2=""; FACTORY=""; PROFILE_BLOCK=""; NEVER_BLOCK=""
N_CORE=0; N_OTHER=0; N_CAND=0

while IFS= read -r p; do
  [[ -n $p ]] || continue
  if ! [[ $p =~ $PKG_RE ]]; then
    warn "skipping an unexpected package name: $p"
    continue
  fi
  state=$(pkg_state "$p" "$installed" "$disabled")
  if in_lines "$p" "$third"; then kind=thirdparty; else kind=system; fi
  lp=$(lower "$p")

  category=""; tier=""
  if is_never "$p"; then
    category=core; tier=never
  elif [[ $lp =~ $FACTORY_RE ]]; then
    category=factory; tier=never
  elif matches_any "$lp" "$SENSITIVE_RE"; then
    category=car-name; tier=verify
  else
    kt=$(known_tier "$p")
    if [[ -n $kt ]]; then
      category=known; tier=$kt
    elif [[ $lp =~ $TELEMETRY_RE ]]; then
      category=telemetry; tier=1
    elif [[ $lp =~ $ADS_RE ]]; then
      category=ads-promo; tier=1
    elif [[ $lp =~ $STORE_RE ]]; then
      category=store; tier=2
    elif [[ $lp =~ $MEDIA_RE ]]; then
      category=media-dupe; tier=3
    else
      case $p in
        android|android.*|com.android|com.android.*|com.google|com.google.*)
          category=other; tier=none ;;
        *)
          if [[ $kind == system ]]; then
            category=vendor; tier=verify
          else
            category=other; tier=none
          fi ;;
      esac
    fi
  fi

  case $category in
    core) N_CORE=$((N_CORE + 1)); continue ;;
    factory)
      FACTORY="$FACTORY  $p  (factory or test app: never open it)"$'\n'
      continue ;;
    other) N_OTHER=$((N_OTHER + 1)); continue ;;
  esac

  N_CAND=$((N_CAND + 1))
  dump=$(dev "dumpsys package $p")
  why=$(risk_reasons_with_dump "$p" "$dump")
  launchers=$(dev_ok "cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.LAUNCHER $p")
  lc=$(printf '%s\n' "$launchers" | sed -n 's/^ *//p' | grep -c .)
  services=$(printf '%s\n' "$dump" | grep -oE '[A-Za-z_][A-Za-z0-9_$]*Service' \
    | grep -vx 'Service' | sort -u | tr '\n' ',' | sed 's/,$//; s/,/, /g')
  receivers=$(printf '%s\n' "$dump" \
    | grep -oE 'android\.intent\.action\.[A-Z_]+|[A-Za-z0-9_.]+\.(ACC|REVERSE|KEY|ILL)[A-Za-z0-9_.]*' \
    | sort -u | head -n 8 | tr '\n' ',' | sed 's/,$//; s/,/, /g')
  apath=$(path_for "$p")
  block=$(candidate_block "$p" "$category" "$tier" "$state" "$kind" "$apath" "$lc" "$services" "$receivers" "$why")
  if [[ -z $why && ($category == car-name || $category == vendor) ]]; then
    block="$block"$'\n'"      note: verify by hand ($category)"
  fi

  if [[ -n $why ]]; then
    SEC2="$SEC2$block"$'\n'
    NEVER_BLOCK="$NEVER_BLOCK# $p # $category; $(one_line "$why")"$'\n'
  elif [[ $category == car-name || $category == vendor ]]; then
    SEC2="$SEC2$block"$'\n'
    NEVER_BLOCK="$NEVER_BLOCK# $p # $category; verify by hand"$'\n'
  else
    case $tier in
      1) SEC1_T1="$SEC1_T1$block"$'\n' ;;
      2) SEC1_T2="$SEC1_T2$block"$'\n' ;;
      3) SEC1_T3="$SEC1_T3$block"$'\n' ;;
    esac
    PROFILE_BLOCK="$PROFILE_BLOCK# $p $tier # $category; no risk reasons; evidence in the report"$'\n'
  fi
done <<EOF
$(printf '%s\n' "$installed" | sort)
EOF

n_installed=$(printf '%s\n' "$installed" | grep -c .)
n_disabled=$(printf '%s\n' "$disabled" | grep -c .)
n_third=$(printf '%s\n' "$third" | grep -c .)
profile_hint=$PROFILE
[[ $profile_hint == generic ]] && profile_hint="<id>"

SECTION1="1. likely safe to disable"
if [[ -n $SEC1_T1 ]]; then
  SECTION1="$SECTION1"$'\n'"  tier 1 · telemetry / ads / promo"$'\n'"$SEC1_T1"
else
  SECTION1="$SECTION1"$'\n'"  tier 1 · (none)"
fi
if [[ -n $SEC1_T2 ]]; then
  SECTION1="$SECTION1"$'\n'"  tier 2 · system leftovers"$'\n'"$SEC1_T2"
else
  SECTION1="$SECTION1"$'\n'"  tier 2 · (none)"
fi
if [[ -n $SEC1_T3 ]]; then
  SECTION1="$SECTION1"$'\n'"  tier 3 · apps a person might use"$'\n'"$SEC1_T3"
else
  SECTION1="$SECTION1"$'\n'"  tier 3 · (none)"
fi

ADMINS=$(printf '%s\n' "$POLICY" | grep -oE '[A-Za-z_][A-Za-z0-9_.]*/[A-Za-z0-9_.$]+' | sort -u)
A11Y_SHOW=${A11Y:-}
[[ -z $A11Y_SHOW || $A11Y_SHOW == null ]] && A11Y_SHOW="(none)"
ADMINS_SHOW=$(printf '%s\n' "$ADMINS" | sed '/^$/d' | tr '\n' ' ')
[[ -z $ADMINS_SHOW ]] && ADMINS_SHOW="(none)"

report_file="$REPORT/discover-$(date +%Y%m%d-%H%M%S).txt"
mkdir -p "$REPORT"
{
  printf 'headroom discover · %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'profile %s · API %s · %s installed · %s disabled · %s third-party · %s candidates\n' \
    "$PROFILE" "$SDK" "$n_installed" "$n_disabled" "$n_third" "$N_CAND"
  printf 'core (never touched): %s · other (not suggested): %s\n\n' "$N_CORE" "$N_OTHER"
  printf '%s\n' "$SECTION1"
  printf '\n2. looks car-critical: verify, probably keep\n'
  if [[ -n $SEC2 ]]; then printf '%s' "$SEC2"; else printf '  (none)\n'; fi
  printf '\n3. factory or test: never open these\n'
  if [[ -n $FACTORY ]]; then printf '%s' "$FACTORY"; else printf '  (none)\n'; fi
  printf '\n4. who answers HOME / keyboard / accessibility / device admin\n'
  printf '  HOME          %s\n' "${home_comp:-unknown}"
  printf '  HOME claims   %s\n' "$(printf '%s\n' "$HOME_CLAIMS" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  printf '  keyboard      %s\n' "${IME:-unknown}"
  printf '  accessibility %s\n' "$A11Y_SHOW"
  printf '  device admin  %s\n' "$ADMINS_SHOW"
  printf '\n5. paste-ready blocks (commented out: a name is not evidence)\n'
  printf '# data/profiles/%s/packages.txt\n' "$profile_hint"
  if [[ -n $PROFILE_BLOCK ]]; then printf '%s' "$PROFILE_BLOCK"; else printf '# (no safe candidates)\n'; fi
  printf '# data/profiles/%s/never-disable.txt\n' "$profile_hint"
  if [[ -n $NEVER_BLOCK ]]; then printf '%s' "$NEVER_BLOCK"; else printf '# (nothing flagged)\n'; fi
} > "$report_file"

printf '%s\n' "$SECTION1" | head -n 20
printf '\nreport: %s\n' "$report_file"
