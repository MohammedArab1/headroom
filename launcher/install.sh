#!/usr/bin/env bash
# Build headroom home (unless --apk), install it, start it, and make it HOME.
# Usage: launcher/install.sh [--apk PATH] [--undo] [--dry-run] [-y]
# Nothing is uninstalled, and HOME is only changed after the launcher starts.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib.sh"

APK=""
UNDO=0

usage() {
  cat <<'EOF'
usage: launcher/install.sh [--apk PATH] [--undo] [--dry-run] [-y]

  --apk PATH   install an APK that has already been built (tests use this)
  --undo       put the previous HOME back; headroom home stays installed
  --dry-run    print the plan; change nothing
  -y           a person already said yes
EOF
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --apk) [[ $# -ge 2 ]] || die "--apk needs a path"; APK=$2; shift 2 ;;
    --undo) UNDO=1; shift ;;
    --dry-run|-y|--yes) common_flag "$1"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown flag: $1" ;;
  esac
done

need_device
if [[ ! -f $STATE/home-before.txt ]]; then
  home_component > "$STATE/home-before.txt"
fi
BEFORE=$(head -n 1 "$STATE/home-before.txt")
[[ -n $BEFORE ]] || die "could not read which app owns HOME; stopping before installing anything"

undo_home() {
  case $BEFORE in
    ''|android/*)
      die "HOME was the system chooser before headroom, so there is no previous launcher to restore. On the unit: Settings > Apps > headroom home > Open by default > Clear defaults." ;;
  esac
  acmd cmd package set-home-activity --user 0 "$BEFORE" >/dev/null
  acmd am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null
  [[ $DRY_RUN == 1 ]] || rm -f "$STATE/launcher-installed"
  note "HOME is back on ${BEFORE%%/*}; headroom home stays installed"
  note "to remove it by hand: adb -s $SERIAL uninstall $SELF_PKG"
}

if [[ $UNDO == 1 ]]; then
  undo_home
  exit 0
fi

load_conf
require_checked

# The SDK check comes before any build: a unit that is too old must not spend
# minutes compiling an APK it cannot install.
MIN_SDK=$(sed -n 's/^[[:space:]]*minSdk[[:space:]]\{1,\}\([0-9][0-9]*\).*/\1/p' \
  "$ROOT/launcher/app/build.gradle" | head -n 1)
[[ -n $MIN_SDK ]] || die "could not read minSdk from launcher/app/build.gradle"
if [[ $SDK -lt $MIN_SDK ]]; then
  die "this unit is API $SDK; headroom home needs API $MIN_SDK or later. Nothing has been built or installed."
fi

step "plan"
if [[ -n $APK ]]; then
  note "install $APK"
else
  note "build the release APK with dock=${DOCK_APPS:- (none)}"
  note "install it, start it, then make $SELF_PKG/.HomeActivity HOME"
fi
note "HOME now: $BEFORE"
[[ $DRY_RUN == 1 ]] && { note "dry-run: nothing changed"; exit 0; }
confirm "Install headroom home and make it HOME on $SERIAL?" || die "cancelled"

if [[ -z $APK ]]; then
  [[ -f $ROOT/launcher/gradlew ]] || die "launcher/gradlew is missing: generate the Gradle wrapper once (see launcher/README.md)"
  printf 'dock=%s\n' "$(printf '%s' "${DOCK_APPS:-}" | tr ' ' ',')" \
    > "$ROOT/launcher/headroom.local.properties"
  note "building the launcher (this can take a few minutes)"
  ( cd "$ROOT/launcher" && ./gradlew -q assembleRelease ) \
    || die "the launcher build failed: see launcher/README.md"
  APK="$ROOT/launcher/app/build/outputs/apk/release/app-release.apk"
fi
[[ -f $APK ]] || die "no APK at $APK"

step "install"
REMOTE=/data/local/tmp/headroom-home.apk
note "pushing $(basename "$APK")"
"$ADB" -s "$SERIAL" push "$APK" "$REMOTE" >/dev/null 2>&1 \
  || die "could not push the APK to $SERIAL. Reconnect and re-run."
out=$(dev pm install -r "$REMOTE")
case $out in
  *INSTALL_FAILED_UPDATE_INCOMPATIBLE*)
    die "this unit has a copy built with another key: adb -s $SERIAL uninstall $SELF_PKG, then re-run (it stores nothing worth backing up)" ;;
  *INSTALL_FAILED_OLDER_SDK*)
    die "this unit is older than the launcher's minSdk ($MIN_SDK)" ;;
  *INSTALL_FAILED_VERIFICATION_FAILURE*|*INSTALL_FAILED_INTERNAL_ERROR*)
    die "this firmware refuses sideloaded apps. The debloat half still applies; record it in the catalog." ;;
  *Success*) ;;
  *) die "the install failed: $out" ;;
esac

step "start"
out=$(dev am start -W -n "$SELF_PKG/.HomeActivity")
if printf '%s\n' "$out" | grep -E '(^Error|Error:)' >/dev/null; then
  die "headroom home did not start; HOME was not changed. Output: $out"
fi
case $out in
  *"Status: ok"*) ;;
  *) die "headroom home did not start; HOME was not changed. Output: $out" ;;
esac

step "home"
acmd cmd package set-home-activity --user 0 "$SELF_PKG/.HomeActivity" >/dev/null
NOW=$(home_component)
if [[ $NOW != "$SELF_PKG"/* ]]; then
  if [[ -n $BEFORE && $BEFORE != android/* ]]; then
    acmd cmd package set-home-activity --user 0 "$BEFORE" >/dev/null
    acmd am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null
  fi
  {
    echo "headroom home did not become HOME: this firmware ignores set-home-activity."
    echo "The unit is left on its previous home screen."
    echo
    echo "If HOME is ever wrong, run these by hand over ADB:"
    if [[ -n $BEFORE && $BEFORE != android/* ]]; then
      echo "  adb -s $SERIAL shell cmd package set-home-activity --user 0 $BEFORE"
    fi
    echo "  adb -s $SERIAL shell am start -a android.intent.action.MAIN -c android.intent.category.HOME"
    echo
    echo "On the unit: Settings > Apps > headroom home > Open by default > Clear defaults."
    echo "Then use scripts/stock-launcher.sh --handover, or record launcher.mechanism: none in the catalog."
  } > "$REPORT/launcher-rollback.txt"
  : > "$STATE/set-home-ignored"
  note "the recovery commands are in report/launcher-rollback.txt"
  die "this firmware ignores set-home-activity. HOME is back on ${BEFORE%%/*}."
fi

: > "$STATE/launcher-installed"
acmd cmd package compile -m speed -f "$SELF_PKG" >/dev/null
dev input keyevent KEYCODE_HOME >/dev/null
FG=$(resumed_activity)
note "foreground: ${FG:-unknown}"

step "next"
note "reboot test and ignition test, then scripts/verify.sh --manual"
exit 0
