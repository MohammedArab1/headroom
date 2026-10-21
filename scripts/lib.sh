#!/usr/bin/env bash
# scripts/lib.sh: shared helpers. Sourced by every script in scripts/ and by launcher/install.sh.
# Not meant to be run. bash 3.2 compatible (macOS): no assoc arrays, mapfile, ${x,,}, tac.
# Rule 1: never trust `adb shell` exit codes, parse output.
# Rule 2: never end a pipeline in `grep -q` under pipefail (SIGPIPE); use >/dev/null.

HEADROOM_VERSION=0.1.0
ADB=${ADB:-adb}
DRY_RUN=${DRY_RUN:-0}
ASSUME_YES=${ASSUME_YES:-0}
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DATA=${HEADROOM_DATA:-$ROOT/data}     # tests point this at tests/fixtures
REPORT="$ROOT/report"
CONF=${CONF:-$ROOT/headroom.conf}
STATE_ROOT=${HEADROOM_STATE:-$HOME/.headroom}
SERIAL=${SERIAL:-${ADB_SERIAL:-}}
SDK=${SDK:-0}
PROFILE=${PROFILE:-}
STATE=""                             # set by need_device: $STATE_ROOT/<device-id>
REBOOT_SETTLE=${REBOOT_SETTLE:-40}   # seconds before polling after a reboot (tests: 0)
POLL=${POLL:-5}                      # seconds between polls (tests: 0)
SELF_PKG=app.headroom.home

# ---------- output ----------
step() { printf '\n\033[1m%s\033[0m\n' "$*"; }
note() { printf '  %s\n' "$*" >&2; }
warn() { printf '  WARNING: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# ---------- flags ----------
# Returns 0 when $1 was a flag every script understands, after applying it.
common_flag() {
  case $1 in
    --dry-run) DRY_RUN=1 ;;
    -y|--yes)  ASSUME_YES=1 ;;
    *) return 1 ;;
  esac
}

confirm() {
  [[ $ASSUME_YES == 1 ]] && return 0
  [[ -t 0 ]] || die "this step needs a yes from a person; re-run with -y once they have agreed"
  local reply
  printf '%s [y/N] ' "$1" >&2
  read -r reply
  case $reply in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# ---------- device I/O ----------
dev()  { "$ADB" -s "$SERIAL" shell "$@" 2>&1 </dev/null | tr -d '\r'; }
dev1() { dev "$@" | head -n 1; }

# Like dev, but a dropped connection stops the run instead of reading as "empty output".
dev_ok() {
  local out
  out=$(dev "$@")
  if printf '%s\n' "$out" | grep -iE "^error: (device|closed|no devices)|device '[^']*' not found|device offline" >/dev/null; then
    die "lost the connection to $SERIAL. Reconnect (scripts/connect.sh) and re-run this script."
  fi
  printf '%s\n' "$out"
}

# A device command that changes state. Honours --dry-run (message on stderr so >/dev/null can't hide it).
acmd() {
  if [[ $DRY_RUN == 1 ]]; then note "[dry-run] adb shell $*"; return 0; fi
  dev_ok "$@"
}

sha_short() { if command -v shasum >/dev/null 2>&1; then shasum -a 256; else sha256sum; fi | cut -c1-12; }
device_id() {
  printf '%s|%s|%s' "$(dev1 getprop ro.serialno)" "$(dev1 settings get secure android_id)" \
    "$(dev1 getprop ro.product.model)" | sha_short
}

need_device() {
  command -v "$ADB" >/dev/null 2>&1 || die "adb not found: brew install android-platform-tools (or export ADB=\"$ROOT/tools/pyadb\")"
  "$ADB" start-server >/dev/null 2>&1 || true
  if [[ -z $SERIAL ]]; then
    local found s ids=""
    found=$("$ADB" devices 2>/dev/null | awk 'NR>1 && $2=="device" {print $1}')
    [[ -n $found ]] || die "no head unit connected. Run scripts/connect.sh first."
    # After `adb pair` one unit can be listed twice (ip:port and its mDNS name): same device id = one unit.
    for s in $found; do SERIAL=$s; ids="$ids$(device_id)"$'\n'; done
    # shellcheck disable=SC2086
    [[ $(printf '%s' "$ids" | sort -u | grep -c .) -eq 1 ]] || die "several devices connected; set ADB_SERIAL to one of: $(printf '%s ' $found)"
    SERIAL=$(printf '%s\n' "$found" | grep ':' | head -n 1)
    [[ -n $SERIAL ]] || SERIAL=$(printf '%s\n' "$found" | head -n 1)
  fi
  [[ $(dev1 getprop sys.boot_completed) == 1 ]] || die "$SERIAL is not answering, or has not finished booting"
  SDK=$(dev1 getprop ro.build.version.sdk)
  case $SDK in ''|*[!0-9]*) die "could not read the API level from $SERIAL" ;; esac
  # API 26 (Android 8.0) is the floor: older shells lack `cmd package resolve-activity --brief`,
  # `set-home-activity` and `install-existing`, and the HOME guard must never run blind.
  [[ $SDK -ge 26 ]] || die "API $SDK (older than Android 8.0) is not supported: see docs/FAQ.md"
  STATE="$STATE_ROOT/$(device_id)"
  mkdir -p "$STATE/batches" "$STATE/checks" "$REPORT" && chmod 700 "$STATE_ROOT"
  [[ -n $PROFILE ]] || PROFILE=$(detect_profile)
  [[ -d $DATA/profiles/$PROFILE ]] || die "profile '$PROFILE' does not exist under data/profiles/"
}

need_snapshot() { [[ -f $STATE/snapshot/meta.txt ]] || die "no snapshot of this unit yet: run scripts/preflight.sh first"; }

# ---------- config ----------
load_conf() {
  KEEP_APPS=""; REMOVE_APPS=""; ALLOW_RISKY=""; TIER1=1; TIER2=1; SIM=0; UPDATER_KEEP=1
  ANIM_SCALE=0.5; DEXOPT=1; TRIM_CACHES=0; SCAN_OFF=1; BG_RESTRICT=""
  PRIVATE_DNS=0; PRIVATE_DNS_HOST=dns.adguard-dns.com; LAUNCHER=1; DOCK_APPS=""; BENCH_APPS=""
  if [[ -f $CONF ]]; then source "$CONF" || die "$CONF is not valid; re-run scripts/configure.sh"; fi
  return 0
}

# ---------- lists ----------
list_of()   { [[ -f $1 ]] || return 0; sed 's/#.*//; s/[[:space:]]*$//' "$1" | awk 'NF'; }
first_col() { list_of "$1" | awk '{print $1}'; }
cfile()     { printf '%s' "$DATA/common/$1"; }
pfile()     { printf '%s' "$DATA/profiles/$PROFILE/$1"; }
in_lines()  { case $'\n'"$2"$'\n' in *$'\n'"$1"$'\n'*) return 0 ;; esac; return 1; }
in_words()  { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }
lower()     { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# A profile matches when every line of its match.txt holds:   prop <name>=<glob>   or   pkg <package>
detect_profile() {
  local d id ok kind arg name want got
  for d in "$DATA"/profiles/*/; do
    id=$(basename "$d")
    [[ $id == generic || ! -f $d/match.txt ]] && continue
    ok=1
    while read -r kind arg; do
      case $kind in
        prop) name=${arg%%=*}; want=${arg#*=}; got=$(dev1 getprop "$name")
              # shellcheck disable=SC2254
              case $got in $want) ;; *) ok=0 ;; esac ;;
        pkg)  present "$arg" || ok=0 ;;
        *)    ok=0 ;;
      esac
      [[ $ok == 1 ]] || break
    done < <(list_of "$d/match.txt")
    [[ $ok == 1 ]] && { printf '%s' "$id"; return; }
  done
  printf 'generic'
}

# ---------- packages ----------
present()       { dev_ok "pm path $1" | grep '^package:' >/dev/null; }
installed_set() { dev_ok 'pm list packages'    | sed -n 's/^package://p'; }
disabled_set()  { dev_ok 'pm list packages -d' | sed -n 's/^package://p'; }
third_set()     { dev_ok 'pm list packages -3' | sed -n 's/^package://p'; }
pkg_state() { # pkg, installed list, disabled list -> enabled | disabled | absent
  in_lines "$1" "$2" || { echo absent; return; }
  if in_lines "$1" "$3"; then echo disabled; else echo enabled; fi
}
home_component() {
  dev_ok 'cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME' | tail -n 1
}
home_package() { local c; c=$(home_component); printf '%s' "${c%%/*}"; }
# Every package with a HOME activity that can start now (launchers, settings fallbacks, setup wizards).
home_claimants() {
  dev_ok 'cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.HOME' \
    | grep -oE '^ *[A-Za-z0-9_.]+/[A-Za-z0-9_.$]+' | sed 's/^ *//; s#/.*##' | sort -u
}
resumed_activity() {
  dev 'dumpsys activity activities' | grep -E 'mResumedActivity|topResumedActivity' | head -n 1 \
    | sed 's/.* u0 //; s/[ }].*//'
}

# ---------- guards ----------
# Facts that decide whether a package is load-bearing. Read once per run.
load_device_facts() {
  IME=$(dev1 settings get secure default_input_method); IME_PKG=${IME%%/*}
  A11Y=$(dev1 settings get secure enabled_accessibility_services)
  POLICY=$(dev 'dumpsys device_policy')
  HOME_NOW=$(home_package)          # "android" means the chooser: no default launcher set
  HOME_CLAIMS=$(home_claimants)
  # Fail closed: a guard that cannot see HOME would let the launcher through.
  [[ $HOME_NOW =~ ^[A-Za-z_][A-Za-z0-9_.]*$ && -n $HOME_CLAIMS ]] \
    || die "could not tell which apps answer HOME ('$HOME_NOW'); stopping rather than guessing"
  NEVER=$( { first_col "$(cfile never-disable.txt)"; first_col "$(pfile never-disable.txt)"; } | sort -u)
  NEVER_RE=$(list_of "$(cfile never-patterns.txt)")
  SENSITIVE_RE=$(list_of "$(cfile sensitive-patterns.txt)")
  SENSITIVE_PERMS=$(first_col "$(cfile sensitive-permissions.txt)")
}

is_never() {
  local re
  in_lines "$1" "$NEVER" && return 0
  while IFS= read -r re; do
    [[ -n $re && $1 =~ $re ]] && return 0
  done <<EOF
$NEVER_RE
EOF
  return 1
}

# Why a package must not be disabled, one reason per line; no output = no known risk.
# "hard:" reasons can never be overridden. "risk:" reasons can, via ALLOW_RISKY in headroom.conf,
# after a person read `dumpsys package <pkg>` and agreed (AGENTS.md, "Overriding a guard").
risk_reasons() {
  local p=$1 lp d uid perm perms re
  lp=$(lower "$p")
  is_never "$p"           && echo "hard: never-disable list"
  [[ $p == "$SELF_PKG" ]] && echo "hard: headroom's own launcher"
  [[ $p == "$IME_PKG" ]]  && echo "hard: current keyboard ($IME)"
  if [[ ${IGNORE_HOME_GUARD:-} != "$p" ]]; then      # set only by stock-launcher.sh, for one package
    [[ $p == "$HOME_NOW" ]] && echo "hard: owns HOME right now (use scripts/stock-launcher.sh)"
    [[ $p != "$HOME_NOW" ]] && in_lines "$p" "$HOME_CLAIMS" && echo "hard: answers HOME (a launcher or its fallback)"
  fi
  printf '%s\n' "$POLICY" | grep -F "$p/" >/dev/null && echo "hard: named in device policy (device admin)"
  case ":$A11Y:" in *":$p/"*) echo "risk: enabled accessibility service" ;; esac
  d=$(dev "dumpsys package $p")
  uid=$(printf '%s\n' "$d" | sed -n 's/.*userId=\([0-9][0-9]*\).*/\1/p' | head -n 1)
  [[ -n $uid && $uid -lt 10000 ]] && echo "risk: shared core uid $uid (system, phone, bluetooth...)"
  printf '%s\n' "$d" | grep -E 'pkgFlags=\[[^]]*PERSISTENT' >/dev/null && echo "risk: persistent (always running)"
  perms=$(printf '%s\n' "$d" | sed -n -E '/requested permissions:/,/(install|runtime) permissions:|User [0-9]+:/p')
  for perm in $SENSITIVE_PERMS; do
    printf '%s\n' "$perms" | grep -F "$perm" >/dev/null && echo "risk: requests $perm"
  done
  while IFS= read -r re; do
    [[ -n $re && $lp =~ $re ]] && { echo "risk: name matches '$re'"; break; }
  done <<EOF
$SENSITIVE_RE
EOF
  return 0
}

# The reasons left after ALLOW_RISKY: what actually blocks a package.
blocking_reasons() {
  local r
  risk_reasons "$1" | while IFS= read -r r; do
    case $r in
      hard:*) echo "$r" ;;
      risk:*) in_words "$1" "${ALLOW_RISKY:-}" || echo "$r" ;;
    esac
  done
}

# ---------- changing packages ----------
# Both print NOTHING when the unit stopped answering (dev_ok's die only ends the $( ) subshell),
# so callers can tell a lost connection from an odd answer: `r=$(disable_one p); [[ -n $r ]] || die`.
disable_one() {  # prints: disabled | refused | suspect: <output> | dry-run
  local out
  out=$(acmd pm disable-user --user 0 "$1" | head -n 1)
  [[ $DRY_RUN == 1 ]] && { echo dry-run; return 0; }
  [[ -n $out ]] || return 1
  case $out in
    *"new state: disabled-user"*)                            echo disabled ;;
    *[Pp]rotected*|*SecurityException*|*"Cannot disable"*)   echo refused ;;
    *)                                                       echo "suspect: $out" ;;
  esac
}
enable_one() {   # prints: enabled | suspect: <output> | dry-run
  local out
  out=$(acmd pm enable --user 0 "$1" | head -n 1)
  [[ $DRY_RUN == 1 ]] && { echo dry-run; return 0; }
  [[ -n $out ]] || return 1
  case $out in *"new state: enabled"*) echo enabled ;; *) echo "suspect: $out" ;; esac
}

# ---------- batches (the recovery record) ----------
new_batch_id() { printf '%s-%s' "$1" "$(date +%Y%m%d-%H%M%S)"; }
# Lines "pkg<TAB>before" on stdin. Written atomically BEFORE the first command: the state before the
# change is what undo needs, and a record written afterwards would describe an already-changed unit.
write_plan() {
  local f="$STATE/batches/$1.tsv"
  [[ -e $f ]] && die "batch $1 already exists"
  cat > "$f.tmp" && mv "$f.tmp" "$f" && printf '%s\n' "$1" >> "$STATE/batches/order.txt"
}
journal() { printf '%s\t%s\t%s\t%s\n' "$(date +%Y-%m-%dT%H:%M:%S)" "$1" "$2" "$3" >> "$STATE/journal.tsv"; }
batches_newest_first() { [[ -f $STATE/batches/order.txt ]] && sed '1!G;h;$!d' "$STATE/batches/order.txt"; return 0; }
unchecked_batches() {
  local b
  batches_newest_first | while read -r b; do
    [[ -e $STATE/batches/$b.checked || -e $STATE/batches/$b.restored ]] || echo "$b"
  done
}
require_checked() {
  local u; u=$(unchecked_batches | head -n 1)
  [[ -z $u ]] && return 0
  die "batch $u has not passed the car checks. A person runs scripts/verify.sh --manual (or undo it: scripts/restore.sh --last)."
}

# Before any reboot: the list a person can re-enable by hand in Settings > Apps if ADB does not come back.
write_manual_undo() {  # batch-id
  { echo "If ADB does not come back: on the unit open Settings > Apps (show system apps),"
    echo "open each app below and tap Enable. Then reboot the unit."
    cut -f1 "$STATE/batches/$1.tsv"; } > "$REPORT/manual-undo-$1.txt"
  note "manual undo list (no laptop needed): report/manual-undo-$1.txt (photograph it)"
}

# ---------- reboot ----------
reboot_wait() {
  note "rebooting $SERIAL (engine running outdoors, or a charger connected)"
  "$ADB" -s "$SERIAL" reboot >/dev/null 2>&1 || true
  sleep "$REBOOT_SETTLE"
  local i
  for _ in $(seq 1 60); do
    reconnect_quietly
    [[ $(dev1 getprop sys.boot_completed) == 1 ]] && { note "booted"; return 0; }
    sleep "$POLL"
  done
  die "the unit did not come back over ADB. Check it by hand. Wireless debugging changes port after a reboot: run scripts/connect.sh."
}

# tcp/5555 serials reconnect with `adb connect`. Wireless-debugging serials may return on a new port,
# announced over mDNS. A phone with Wireless debugging also announces itself: the device id must match.
reconnect_quietly() {
  [[ $("$ADB" -s "$SERIAL" get-state 2>/dev/null) == device ]] && return 0
  case $SERIAL in *:*) "$ADB" connect "$SERIAL" >/dev/null 2>&1 || true ;; esac
  [[ $("$ADB" -s "$SERIAL" get-state 2>/dev/null) == device ]] && return 0
  local m old=$SERIAL
  for m in $("$ADB" mdns services 2>/dev/null | awk '/_adb-tls-connect/ {print $NF}'); do
    "$ADB" connect "$m" >/dev/null 2>&1 || continue
    SERIAL=$m
    [[ "$STATE_ROOT/$(device_id)" == "$STATE" ]] && return 0
    SERIAL=$old
  done
  return 0
}
