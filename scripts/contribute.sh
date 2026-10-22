#!/usr/bin/env bash
# Turn one session into a reviewed catalog entry, with no identifiers in it.
# Usage: scripts/contribute.sh [--id ID] [--title TITLE] [--status STATUS]
#        [--platform PLATFORM] [--soc SOC] [--sdk N] [--claimed RELEASE]
#        [--ram-mb N] [--screen WxH@Ndpi] [--profile NAME]
#        [--developer-mode TEXT] [--adb-method METHOD] [--ip-location TEXT]
#        [--prompt "name|fix"]... [--quirk TEXT]... [--notes TEXT]
#        [--no-device] [--dry-run] [-y]
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PYTHON=${PYTHON:-python3}
CATALOG_DIR=${HEADROOM_CATALOG:-$ROOT/catalog/devices}

ID=""; TITLE=""; STATUS=untested; PLATFORM=unknown; SOC=""
SDK_ARG=""; CLAIMED=""; RAM_ARG=""; SCREEN=""; PROFILE_ARG=""
DEVMODE=""; ADB_METHOD=""; IP_LOCATION=""; NOTES=""
RAW_PROMPTS=""; PROMPTS=""; RAW_QUIRKS=""; QUIRKS=""
NO_DEVICE=0

usage() {
  cat <<'EOF'
usage: scripts/contribute.sh [--id ID] [--title TITLE] [--status STATUS]
       [--platform PLATFORM] [--soc SOC] [--sdk N] [--claimed RELEASE]
       [--ram-mb N] [--screen WxH@Ndpi] [--profile NAME]
       [--developer-mode TEXT] [--adb-method METHOD] [--ip-location TEXT]
       [--prompt "name|fix"]... [--quirk TEXT]... [--notes TEXT]
       [--no-device] [--dry-run] [-y]
EOF
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --id|--title|--status|--platform|--soc|--sdk|--claimed|--ram-mb|--screen|\
    --profile|--developer-mode|--adb-method|--ip-location|--notes)
      [[ $# -ge 2 ]] || die "$1 needs a value"
      case $1 in
        --id) ID=$2 ;;
        --title) TITLE=$2 ;;
        --status) STATUS=$2 ;;
        --platform) PLATFORM=$2 ;;
        --soc) SOC=$2 ;;
        --sdk) SDK_ARG=$2 ;;
        --claimed) CLAIMED=$2 ;;
        --ram-mb) RAM_ARG=$2 ;;
        --screen) SCREEN=$2 ;;
        --profile) PROFILE_ARG=$2 ;;
        --developer-mode) DEVMODE=$2 ;;
        --adb-method) ADB_METHOD=$2 ;;
        --ip-location) IP_LOCATION=$2 ;;
        --notes) NOTES=$2 ;;
      esac
      shift 2 ;;
    --prompt) [[ $# -ge 2 ]] || die "--prompt needs name|fix"; RAW_PROMPTS="$RAW_PROMPTS$2"$'\n'; shift 2 ;;
    --quirk) [[ $# -ge 2 ]] || die "--quirk needs a value"; RAW_QUIRKS="$RAW_QUIRKS$2"$'\n'; shift 2 ;;
    --no-device) NO_DEVICE=1; shift ;;
    --dry-run|-y|--yes) common_flag "$1"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown flag: $1" ;;
  esac
done

# ---- refuse identifiers in anything a person writes -------------------------
dirty_reason() {  # prints a reason and returns 0 when the text must be refused
  local text=$1
  if grep -Eiq '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' <<<"$text"; then
    echo "an IP address"; return 0
  fi
  if grep -Eiq '\b([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}\b' <<<"$text"; then
    echo "a MAC address"; return 0
  fi
  if grep -Eq '\b[A-HJ-NPR-Z0-9]{17}\b' <<<"$text"; then
    echo "a possible VIN"; return 0
  fi
  if grep -Eq '[-+]?[0-9]{1,3}\.[0-9]{4,}[[:space:]]*,[[:space:]]*[-+]?[0-9]{1,3}\.[0-9]{4,}' <<<"$text"; then
    echo "GPS coordinates"; return 0
  fi
  if grep -Eiq '[[:alnum:]._%+-]+@[[:alnum:]-]+\.[[:alnum:].]+' <<<"$text"; then
    echo "an e-mail address"; return 0
  fi
  if grep -Eq '\+?[0-9][0-9 ()-]{7,}[0-9]' <<<"$text"; then
    echo "a phone number"; return 0
  fi
  return 1
}

check_clean() {  # label text
  local why
  why=$(dirty_reason "$2")
  [[ -z $why ]] || die "$1 contains $why. Identifiers never go into the catalog; rephrase it."
}

# ---- the interview helpers --------------------------------------------------
ask_line() {  # prompt default -> ANSWER
  local prompt=$1 def=${2:-} reply
  printf '%s [%s] ' "$prompt" "$def" >&2
  read -r reply
  ANSWER=${reply:-$def}
}

ask_clean() {  # prompt default -> ANSWER
  local why
  while :; do
    ask_line "$1" "$2"
    why=$(dirty_reason "$ANSWER")
    [[ -z $why ]] || { warn "$why is an identifier; rephrase it"; continue; }
    return 0
  done
}

ask_choice() {  # prompt default choices -> ANSWER
  local prompt=$1 def=$2 choices=$3
  while :; do
    printf '%s (%s) [%s] ' "$prompt" "$choices" "$def" >&2
    read -r ANSWER
    [[ -n $ANSWER ]] || ANSWER=$def
    case " $choices " in *" $ANSWER "*) return 0 ;; esac
    warn "choose one of: $choices"
  done
}

slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9.-][^a-z0-9.-]*/-/g; s/^-*//; s/-*$//'
}

# ---- facts from the unit ----------------------------------------------------
if [[ $NO_DEVICE == 0 ]]; then
  need_device
  load_conf
  MANUFACTURER=$(dev1 getprop ro.product.manufacturer)
  MODEL=$(dev1 getprop ro.product.model)
  BOARD=$(dev1 getprop ro.product.board)
  SOC_FACT=$(dev1 getprop ro.board.platform)
  CLAIMED_FACT=$(dev1 getprop ro.build.version.release)
  MEMTOTAL=$(dev_ok 'cat /proc/meminfo' | awk '/^MemTotal:/ {print int($2/1024); exit}')
  SIZE=$(dev_ok 'wm size' | sed -n 's/.*: *\([0-9][0-9]*x[0-9][0-9]*\).*/\1/p' | tail -n 1)
  DENSITY=$(dev_ok 'wm density' | sed -n 's/.*: *\([0-9][0-9]*\).*/\1/p' | head -n 1)
  SDK_ARG=${SDK_ARG:-$SDK}
  CLAIMED=${CLAIMED:-${CLAIMED_FACT:-unknown}}
  SOC=${SOC:-${SOC_FACT:-$BOARD}}
  RAM_ARG=${RAM_ARG:-${MEMTOTAL:-256}}
  [[ -n $SCREEN || -z $SIZE || -z $DENSITY ]] || SCREEN="${SIZE}@${DENSITY}dpi"
  [[ -n $TITLE ]] || TITLE=$(printf '%s %s' "$MANUFACTURER" "$MODEL" | sed 's/^ *//; s/ *$//')
  [[ -n $PROFILE_ARG ]] || PROFILE_ARG=${PROFILE:-generic}
  MODELS=${MODEL:-}
else
  SDK_ARG=${SDK_ARG:-26}
  CLAIMED=${CLAIMED:-unknown}
  RAM_ARG=${RAM_ARG:-256}
  PROFILE_ARG=${PROFILE_ARG:-generic}
  MODELS=""
  note "no device was read: sdk/ram/claimed/profile are placeholders unless you pass flags"
fi
[[ -n $TITLE ]] || TITLE=$ID
[[ -n $PROFILE_ARG ]] || PROFILE_ARG=generic

# ---- ask only what a robot cannot know --------------------------------------
if [[ $ASSUME_YES == 0 ]]; then
  [[ -t 0 ]] || die "this is an interview: run it from a terminal, or pass -y with the flags"
  [[ -n $TITLE ]] || { ask_clean "Unit title" "$ID"; TITLE=$ANSWER; }
  [[ -n $DEVMODE ]] || { ask_clean "How are Developer options and ADB enabled? (exact path and taps)" ""; DEVMODE=$ANSWER; }
  if [[ -z $ADB_METHOD ]]; then
    ask_choice "Which ADB method worked?" wireless-debugging \
      "wireless-debugging tcp5555 usb-device-port none"
    ADB_METHOD=$ANSWER
  fi
  [[ -n $IP_LOCATION ]] || { ask_clean "Where does the unit show its IP address?" ""; IP_LOCATION=$ANSWER; }
  ask_choice "Status" "$STATUS" "tested partial untested"
  STATUS=$ANSWER
  while :; do
    ask_line "Dialog that blocked automation, as name|fix (empty to finish)" ""
    [[ -n $ANSWER ]] || break
    RAW_PROMPTS="$RAW_PROMPTS$ANSWER"$'\n'
  done
  while :; do
    ask_clean "Quirk (empty to finish)" ""
    [[ -n $ANSWER ]] || break
    RAW_QUIRKS="$RAW_QUIRKS$ANSWER"$'\n'
  done
fi

[[ -n $ID ]] || { [[ $ASSUME_YES == 1 ]] && die "--id is required with -y"; ask_line "Catalog id" "$(slugify "$TITLE")"; ID=$ANSWER; }
[[ -n $TITLE ]] || die "--title is required"
[[ -n $DEVMODE ]] || die "--developer-mode is required (the exact path and taps)"
[[ -n $ADB_METHOD ]] || die "--adb-method is required with -y"
[[ -n $IP_LOCATION ]] || die "--ip-location is required with -y"

check_clean "--title" "$TITLE"
check_clean "--developer-mode" "$DEVMODE"
check_clean "--ip-location" "$IP_LOCATION"
check_clean "--notes" "$NOTES"

case $ID in ''|*[!a-z0-9.-]*|[.-]*) die "--id must match ^[a-z0-9][a-z0-9.-]*$" ;; esac
case $STATUS in tested|partial|untested) ;; *) die "--status must be tested, partial or untested" ;; esac
case $PLATFORM in fyt|mtc|topway|mediatek|allwinner|rockchip|qualcomm|other|unknown) ;;
  *) die "--platform must be one of fyt, mtc, topway, mediatek, allwinner, rockchip, qualcomm, other, unknown" ;;
esac
case $ADB_METHOD in wireless-debugging|tcp5555|usb-device-port|none) ;;
  *) die "--adb-method must be wireless-debugging, tcp5555, usb-device-port or none" ;;
esac
case $SDK_ARG in ''|*[!0-9]*) die "--sdk must be a number" ;; esac
[[ $SDK_ARG -ge 26 ]] || die "--sdk must be 26 or later"
case $RAM_ARG in ''|*[!0-9]*) die "--ram-mb must be a number" ;; esac
[[ $RAM_ARG -ge 256 ]] || die "--ram-mb must be at least 256"
if [[ -n $SCREEN && ! $SCREEN =~ ^[0-9]+x[0-9]+@[0-9]+dpi$ ]]; then
  die "--screen must look like 1280x720@240dpi"
fi
[[ -d $ROOT/data/profiles/$PROFILE_ARG ]] || die "profile '$PROFILE_ARG' is not under data/profiles/"

# prompts and quirks are repeatable; each part is cleaned separately.
add_prompt() {
  local line=$1 name fix why
  [[ $line == *"|"* ]] || die "--prompt needs name|fix"
  name=${line%%|*}; fix=${line#*|}
  [[ -n $name && -n $fix ]] || die "--prompt needs both a name and a fix"
  why=$(dirty_reason "$name"); [[ -z $why ]] || die "a prompt name contains $why; rephrase it"
  why=$(dirty_reason "$fix"); [[ -z $why ]] || die "a prompt fix contains $why; rephrase it"
  PROMPTS="$PROMPTS$name|$fix"$'\n'
}
while IFS= read -r line; do [[ -n $line ]] && add_prompt "$line"; done <<< "$RAW_PROMPTS"
while IFS= read -r line; do
  [[ -n $line ]] || continue
  check_clean "--quirk" "$line"
  QUIRKS="$QUIRKS$line"$'\n'
done <<< "$RAW_QUIRKS"

# ---- the records the scripts already keep ----------------------------------
CAR_CHECKS=""
CHECK_FAILED=0
if [[ $NO_DEVICE == 0 ]]; then
  latest=""
  for f in "$STATE"/checks/*.tsv; do [[ -e $f ]] && latest=$f; done
  if [[ -n $latest ]]; then
    while IFS=$'\t' read -r cid ans _batch; do
      [[ -n $cid ]] || continue
      case $ans in
        y) CAR_CHECKS="$CAR_CHECKS$cid=pass"$'\n' ;;
        n) CAR_CHECKS="$CAR_CHECKS$cid=fail"$'\n'; CHECK_FAILED=1 ;;
        s) CAR_CHECKS="$CAR_CHECKS$cid=n/a"$'\n' ;;
      esac
    done < "$latest"
  fi
fi
if [[ $STATUS == tested && ( -z $CAR_CHECKS || $CHECK_FAILED == 1 ) ]]; then
  die "status tested needs a checks file with no failed answer; run scripts/verify.sh --manual first"
fi

BENCH=""
latest_report() {
  local label=$1 f last=""
  for f in "$REPORT/bench-$label-"*.json; do [[ -e $f ]] && last=$f; done
  printf '%s' "$last"
}
json_value() { sed -n "s/.*\"$2\": *\([0-9][0-9]*\).*/\1/p" "$1" | head -n 1; }
if [[ $NO_DEVICE == 0 ]]; then
  before=$(latest_report before)
  after=$(latest_report after)
  if [[ -n $before && -n $after ]]; then
    for key in mem_available_kb app_processes home_ms; do
      b=$(json_value "$before" "$key"); a=$(json_value "$after" "$key")
      [[ -n $b && -n $a ]] && BENCH="$BENCH  $key: [$b, $a]"$'\n'
    done
  fi
fi

LAUNCHER_MECH=""; STOCK_PKG=""; STOCK_DISABLED=""
if [[ $NO_DEVICE == 0 ]]; then
  if [[ -f $STATE/launcher-installed ]]; then
    LAUNCHER_MECH=set_home_activity
  elif [[ -f $STATE/set-home-ignored ]]; then
    LAUNCHER_MECH=none
  fi
  if [[ -f $STATE/home-before.txt ]]; then
    hb=$(head -n 1 "$STATE/home-before.txt")
    case $hb in
      ''|android/*) ;;
      *)
        STOCK_PKG=${hb%%/*}
        [[ $STOCK_PKG == "$SELF_PKG" ]] && STOCK_PKG=""
        if [[ -n $STOCK_PKG ]]; then
          if in_lines "$STOCK_PKG" "$(disabled_set)"; then STOCK_DISABLED=true; else STOCK_DISABLED=false; fi
        fi ;;
    esac
  fi
fi

# ---- YAML -------------------------------------------------------------------
q() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  printf '"%s"' "$s"
}

emit_yaml() {
  printf '# Written by scripts/contribute.sh. Identifiers are refused on the way in.\n'
  printf 'id: %s\n' "$(q "$ID")"
  printf 'title: %s\n' "$(q "$TITLE")"
  printf 'platform: %s\n' "$(q "$PLATFORM")"
  [[ -z $SOC ]] || printf 'soc: %s\n' "$(q "$SOC")"
  printf 'status: %s\n' "$(q "$STATUS")"
  printf 'tested_on: %s\n' "$(q "$(date -u +%Y-%m-%d)")"
  if [[ -n $MODELS ]]; then
    printf 'models:\n  - %s\n' "$(q "$MODELS")"
  else
    printf 'models: []\n'
  fi
  printf 'android:\n  claimed: %s\n  sdk: %s\n' "$(q "$CLAIMED")" "$SDK_ARG"
  printf 'ram_mb_real: %s\n' "$RAM_ARG"
  [[ -z $SCREEN ]] || printf 'screen: %s\n' "$(q "$SCREEN")"
  printf 'developer_mode: %s\n' "$(q "$DEVMODE")"
  printf 'adb:\n  method: %s\n' "$(q "$ADB_METHOD")"
  printf 'ip_location: %s\n' "$(q "$IP_LOCATION")"
  printf 'profile: %s\n' "$(q "$PROFILE_ARG")"
  if [[ -n $PROMPTS ]]; then
    printf 'prompts:\n'
    while IFS='|' read -r name fix; do
      [[ -n $name ]] || continue
      printf '  - name: %s\n    fix: %s\n' "$(q "$name")" "$(q "$fix")"
    done <<< "$PROMPTS"
  else
    printf 'prompts: []\n'
  fi
  if [[ -n $LAUNCHER_MECH ]]; then
    printf 'launcher:\n  mechanism: %s\n' "$(q "$LAUNCHER_MECH")"
    [[ -z $STOCK_PKG ]] || printf '  stock_package: %s\n' "$(q "$STOCK_PKG")"
    [[ -z $STOCK_PKG ]] || printf '  stock_disabled_ok: %s\n' "$STOCK_DISABLED"
  fi
  if [[ -n $CAR_CHECKS ]]; then
    printf 'car_checks:\n'
    while IFS='=' read -r cid result; do
      [[ -n $cid ]] || continue
      printf '  %s: %s\n' "$(q "$cid")" "$(q "$result")"
    done <<< "$CAR_CHECKS"
  else
    printf 'car_checks: {}\n'
  fi
  if [[ -n $BENCH ]]; then
    printf 'benchmark:\n'
    while read -r line; do [[ -n $line ]] && printf '  %s\n' "$line"; done <<< "$BENCH"
  else
    printf 'benchmark: {}\n'
  fi
  if [[ -n $QUIRKS ]]; then
    printf 'quirks:\n'
    while IFS= read -r line; do
      [[ -n $line ]] && printf '  - %s\n' "$(q "$line")"
    done <<< "$QUIRKS"
  else
    printf 'quirks: []\n'
  fi
  printf 'known_limits: []\n'
  [[ -n $NOTES ]] || NOTES="Written by scripts/contribute.sh; no identifiers."
  printf 'notes: %s\n' "$(q "$NOTES")"
}

if [[ $DRY_RUN == 1 ]]; then
  tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/headroom-catalog.XXXXXX")
  out="$tmpdir/$ID.yaml"
  emit_yaml > "$out"
  cat "$out"
  if "$PYTHON" "$ROOT/catalog/validate.py" "$out"; then
    note "dry-run: nothing written"
  else
    rm -rf "$tmpdir"
    exit 1
  fi
  rm -rf "$tmpdir"
  exit 0
fi

mkdir -p "$CATALOG_DIR"
out="$CATALOG_DIR/$ID.yaml"
if [[ -e $out ]]; then
  confirm "$out exists. Replace it?" || die "cancelled"
else
  confirm "Write $out?" || die "cancelled"
fi
emit_yaml > "$out"
if ! "$PYTHON" "$ROOT/catalog/validate.py" "$out"; then
  die "the catalog entry did not validate; fix $out (or delete it) and try again"
fi

step "next"
note "git checkout -b catalog/$ID"
note "git add $out"
note "git commit -m \"catalog: add $ID\""
note "gh pr create --fill"
