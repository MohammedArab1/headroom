#!/usr/bin/env bash
# Boot the four plan resolutions, install the release APK, and take screenshots.
# Usage: launcher/emulator-check.sh [--apk PATH] [--only AVD] [--behavior] [--ui]
#
# Needs the Android SDK (ANDROID_HOME, or ~/Library/Android/sdk) with:
#   emulator, platform-tools, and system-images;android-33;google_apis;arm64-v8a
# Create them with sdkmanager; see launcher/README.md.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SDK=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}
ADB=$SDK/platform-tools/adb
EMULATOR=$SDK/emulator/emulator
AVDMANAGER=$SDK/cmdline-tools/latest/bin/avdmanager
SYSTEM_IMAGE=${SYSTEM_IMAGE:-system-images;android-33;google_apis;arm64-v8a}
APK=$ROOT/launcher/app/build/outputs/apk/release/app-release.apk
OUT=$ROOT/report/emulator
ONLY=""
BEHAVIOR=0
UI=0
PORT=5554
SERIAL=emulator-5554
EMU_PID=""

usage() {
  printf 'usage: launcher/emulator-check.sh [--apk PATH] [--only AVD] [--behavior] [--ui]\n'
  printf 'AVDs: hr-1024x600 hr-1280x720 hr-1920x720 hr-720x1280\n'
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --apk) [[ $# -ge 2 ]] || { echo "--apk needs a path" >&2; exit 2; }; APK=$2; shift 2 ;;
    --only) [[ $# -ge 2 ]] || { echo "--only needs an AVD name" >&2; exit 2; }; ONLY=$2; shift 2 ;;
    --behavior) BEHAVIOR=1; shift ;;
    --ui) UI=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown flag: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -x $ADB ]] || { echo "adb not found at $ADB; set ANDROID_HOME" >&2; exit 2; }
[[ -x $EMULATOR ]] || { echo "emulator not found at $EMULATOR; set ANDROID_HOME" >&2; exit 2; }
[[ -x $AVDMANAGER ]] || { echo "avdmanager not found at $AVDMANAGER; install cmdline-tools" >&2; exit 2; }
[[ -f $APK ]] || { echo "no APK at $APK; run launcher/docker-build.sh first" >&2; exit 2; }
mkdir -p "$OUT"
CHECK_TARGET=${ONLY:-hr-1024x600}

# avdmanager is a Java tool. Homebrew's JDK is keg-only on macOS.
if [[ -z ${JAVA_HOME:-} && -d /opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home ]]; then
  JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
  export JAVA_HOME
fi

create_avd() {  # name width height density orientation
  local name=$1 width=$2 height=$3 density=$4 orientation=$5 cfg
  cfg="$HOME/.android/avd/$name.avd/config.ini"
  if [[ ! -f $cfg ]]; then
    echo no | "$AVDMANAGER" create avd -n "$name" -k "$SYSTEM_IMAGE" --force >/dev/null \
      || return 1
  fi
  sed -i.bak \
    -e "s/^hw.lcd.width=.*/hw.lcd.width=$width/" \
    -e "s/^hw.lcd.height=.*/hw.lcd.height=$height/" \
    -e "s/^hw.lcd.density=.*/hw.lcd.density=$density/" \
    -e "s/^hw.initialOrientation=.*/hw.initialOrientation=$orientation/" \
    -e "s/^hw.ramSize=.*/hw.ramSize=2048/" \
    -e "s/^vm.heapSize=.*/vm.heapSize=256/" \
    -e "s/^disk.dataPartition.size=.*/disk.dataPartition.size=2G/" \
    -e "s/^hw.keyboard=.*/hw.keyboard=yes/" \
    -e "s/^hw.mainKeys=.*/hw.mainKeys=no/" \
    -e "s/^hw.gpu.enabled=.*/hw.gpu.enabled=yes/" \
    -e "s/^hw.gpu.mode=.*/hw.gpu.mode=swiftshader_indirect/" \
    "$cfg" || return 1
  rm -f "$cfg.bak"
  return 0
}

boot_avd() {  # name
  local name=$1 booted=""
  "$ADB" kill-server >/dev/null 2>&1 || true
  "$EMULATOR" -avd "$name" -port "$PORT" -no-window -no-audio -no-boot-anim \
    -no-snapshot -gpu swiftshader_indirect -no-metrics \
    > "$OUT/$name-emulator.log" 2>&1 </dev/null &
  EMU_PID=$!
  "$ADB" wait-for-device >/dev/null 2>&1 || return 1
  for _ in $(seq 1 120); do
    booted=$("$ADB" -s "$SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
    [[ $booted == 1 ]] && { sleep 3; return 0; }
    sleep 3
  done
  return 1
}

stop_avd() {
  "$ADB" -s "$SERIAL" emu kill >/dev/null 2>&1 || true
  sleep 2
  if [[ -n $EMU_PID ]] && kill -0 "$EMU_PID" 2>/dev/null; then
    kill "$EMU_PID" 2>/dev/null || true
  fi
  EMU_PID=""
}

setup_device() {
  "$ADB" -s "$SERIAL" shell settings put global device_provisioned 1 >/dev/null 2>&1 || true
  "$ADB" -s "$SERIAL" shell settings put secure user_setup_complete 1 >/dev/null 2>&1 || true
  "$ADB" -s "$SERIAL" shell settings put secure tv_user_setup_complete 1 >/dev/null 2>&1 || true
  "$ADB" -s "$SERIAL" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
  "$ADB" -s "$SERIAL" shell wm dismiss-keyguard >/dev/null 2>&1 || true
}

install_apk() {
  local out
  "$ADB" -s "$SERIAL" push "$APK" /data/local/tmp/headroom-home.apk >/dev/null 2>&1 || return 1
  out=$("$ADB" -s "$SERIAL" shell pm install -r /data/local/tmp/headroom-home.apk | tr -d '\r')
  case $out in
    *Success*) return 0 ;;
    *INSTALL_FAILED_UPDATE_INCOMPATIBLE*)
      # A rebuilt APK may carry a different debug key. The AVD holds nothing worth keeping.
      "$ADB" -s "$SERIAL" uninstall app.headroom.home >/dev/null 2>&1 || true
      out=$("$ADB" -s "$SERIAL" shell pm install /data/local/tmp/headroom-home.apk | tr -d '\r')
      case $out in
        *Success*) return 0 ;;
      esac
      ;;
  esac
  echo "install failed: $out" >&2
  return 1
}

start_home() {
  local out
  out=$("$ADB" -s "$SERIAL" shell am start -W -n app.headroom.home/.HomeActivity | tr -d '\r')
  case $out in
    *"Status: ok"*) ;;
    *) echo "the launcher did not start: $out" >&2; return 1 ;;
  esac
  "$ADB" -s "$SERIAL" shell cmd package set-home-activity --user 0 \
    app.headroom.home/.HomeActivity >/dev/null 2>&1 || true
  "$ADB" -s "$SERIAL" shell input keyevent KEYCODE_HOME >/dev/null 2>&1 || true
  sleep 2
}

screenshot() {  # file
  "$ADB" -s "$SERIAL" exec-out screencap -p > "$1"
  [[ -s $1 ]]
}

screenshot_settled() {  # file; headless swiftshader needs time to compose
  sleep 4
  screenshot "$1"
}

first_docked_package() {
  local packages candidate
  packages=$("$ADB" -s "$SERIAL" shell pm list packages | tr -d '\r')
  for candidate in com.google.android.deskclock com.google.android.contacts \
    com.google.android.calendar com.android.chrome com.android.deskclock \
    com.android.contacts com.android.calendar; do
    if grep -qx "package:$candidate" <<<"$packages"; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

reload_count() {
  "$ADB" -s "$SERIAL" logcat -d -s headroom:D 2>/dev/null | grep -c "catalog reload"
}

behavior_checks() {  # avd name
  local name=$1 pkg before after delta
  # Enable the debug tag, then start the process fresh so the count is exact.
  "$ADB" -s "$SERIAL" shell setprop log.tag.headroom DEBUG >/dev/null 2>&1 || true
  "$ADB" -s "$SERIAL" shell am force-stop app.headroom.home >/dev/null 2>&1 || true
  "$ADB" -s "$SERIAL" logcat -c >/dev/null 2>&1 || true
  "$ADB" -s "$SERIAL" shell am start -W -n app.headroom.home/.HomeActivity >/dev/null 2>&1 || true
  sleep 8  # let package broadcasts from boot settle before measuring
  before=$(reload_count)
  for _ in $(seq 1 10); do
    "$ADB" -s "$SERIAL" shell input keyevent KEYCODE_HOME >/dev/null 2>&1 || true
  done
  sleep 2
  after=$(reload_count)
  delta=$((after - before))
  "$ADB" -s "$SERIAL" logcat -d -v time -s headroom:D > "$OUT/$name-behavior.log" 2>/dev/null || true
  echo "catalog reloads: $before before, $after after 10 HOME presses (delta $delta, want 0)"
  if [[ $before -lt 1 ]]; then
    echo "FAIL: the app never logged a reload; the debug tag did not switch on" >&2
    return 1
  fi
  if [[ $delta -ne 0 ]]; then
    echo "FAIL: HOME presses re-scanned the package list" >&2
    return 1
  fi

  pkg=$(first_docked_package) || { echo "no docked package to disable; skipping"; return 0; }
  echo "dock disable test with $pkg"
  screenshot "$OUT/$name-dock-before.png" || true
  "$ADB" -s "$SERIAL" shell pm disable-user --user 0 "$pkg" >/dev/null 2>&1 || true
  sleep 2
  screenshot "$OUT/$name-dock-disabled.png" || true
  "$ADB" -s "$SERIAL" shell pm enable --user 0 "$pkg" >/dev/null 2>&1 || true
  sleep 2
  screenshot "$OUT/$name-dock-enabled.png" || true
}

ui_dump() {
  "$ADB" -s "$SERIAL" shell rm -f /data/local/tmp/ui.xml >/dev/null 2>&1 || true
  "$ADB" -s "$SERIAL" shell uiautomator dump /data/local/tmp/ui.xml >/dev/null 2>&1 || true
  "$ADB" -s "$SERIAL" shell cat /data/local/tmp/ui.xml 2>/dev/null | tr -d '\r'
}

ui_xml() {
  local xml i
  for i in 1 2 3; do
    xml=$(ui_dump)
    if [[ $xml == *"<hierarchy"* ]]; then
      printf '%s' "$xml"
      return 0
    fi
    sleep 1
  done
  return 1
}

ui_count() {  # attr value
  ui_xml | grep -o "<node[^>]*$1=\"$2\"[^>]*>" | grep -c .
}

ui_count_prefix() {  # attr prefix
  ui_xml | grep -o "<node[^>]*$1=\"$2[^\"]*\"[^>]*>" | grep -c .
}

ui_bounds() {  # attr value
  local node
  node=$(ui_xml | grep -o "<node[^>]*$1=\"$2\"[^>]*>" | head -n 1)
  [[ -n $node ]] || return 1
  printf '%s' "$node" | sed -n 's/.*bounds="\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]".*/\1 \2 \3 \4/p'
}

ui_bounds_prefix() {  # attr prefix
  local node
  node=$(ui_xml | grep -o "<node[^>]*$1=\"$2[^\"]*\"[^>]*>" | head -n 1)
  [[ -n $node ]] || return 1
  printf '%s' "$node" | sed -n 's/.*bounds="\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]".*/\1 \2 \3 \4/p'
}

ui_tap() {  # attr value
  local b
  b=$(ui_bounds "$1" "$2") || return 1
  # shellcheck disable=SC2086
  set -- $b
  "$ADB" -s "$SERIAL" shell input tap $(( ($1 + $3) / 2 )) $(( ($2 + $4) / 2 ))
}

ui_tap_prefix() {  # attr prefix
  local b
  b=$(ui_bounds_prefix "$1" "$2") || return 1
  # shellcheck disable=SC2086
  set -- $b
  "$ADB" -s "$SERIAL" shell input tap $(( ($1 + $3) / 2 )) $(( ($2 + $4) / 2 ))
}

ui_tiles() {
  ui_xml | grep -o '<node[^>]*class="android.view.View"[^>]*content-desc="[^"]\+"[^>]*>' | grep -c .
}

ui_focused_tiles() {
  ui_xml | grep -o '<node[^>]*content-desc="[^"]\+"[^>]*focused="true"[^>]*>' | grep -c .
}

ui_key() {  # keycode
  "$ADB" -s "$SERIAL" shell input keyevent "$1" >/dev/null 2>&1 || true
  sleep 1
}

ui_home() {
  "$ADB" -s "$SERIAL" shell am start -W -n app.headroom.home/.HomeActivity >/dev/null 2>&1 || true
  sleep 1
  ui_key KEYCODE_HOME
}

ui_reset_options() {
  ui_tap text "Reset to defaults" || return 1
  sleep 1
  ui_tap text "OK" || return 1
  sleep 1
  [[ $(ui_count_prefix text "Dock slots: 5") -ge 1 ]]
}

ui_checks() {  # avd name
  local name=$1 tiles item b home_tiles anchor
  echo "ui checks"

  # Start from the build defaults so the check is repeatable.
  ui_home
  ui_tap text "Options" || { echo "FAIL: could not open Options" >&2; return 1; }
  sleep 1
  ui_reset_options || { echo "FAIL: could not reset to defaults" >&2; return 1; }
  ui_key KEYCODE_BACK
  home_tiles=$(ui_tiles)
  echo "  home tiles: $home_tiles"
  [[ $home_tiles -ge 4 ]] || { echo "FAIL: the dock did not render" >&2; return 1; }

  # All apps.
  ui_tap content-desc "All apps" || { echo "FAIL: could not open All apps" >&2; return 1; }
  sleep 1
  tiles=$(ui_tiles)
  echo "  all-apps tiles on screen: $tiles"
  screenshot_settled "$OUT/$name-allapps.png" || true
  [[ $tiles -ge 10 ]] || { echo "FAIL: the app grid is empty" >&2; return 1; }
  ui_key KEYCODE_BACK

  # Options rows and the hidden-apps dialog.
  ui_tap text "Options" || { echo "FAIL: could not open Options" >&2; return 1; }
  sleep 1
  for item in "Dock slots: " "Clock: " "Grid columns: " "Hidden apps ("; do
    [[ $(ui_count_prefix text "$item") -ge 1 ]] \
      || { echo "FAIL: Options row missing: $item" >&2; return 1; }
  done
  screenshot_settled "$OUT/$name-options.png" || true
  ui_tap_prefix text "Hidden apps (" \
    || { echo "FAIL: could not open Hidden apps" >&2; return 1; }
  sleep 1
  [[ $(ui_count text "OK") -ge 1 ]] \
    || { echo "FAIL: the hidden-apps dialog did not open" >&2; return 1; }
  screenshot_settled "$OUT/$name-hidden.png" || true
  ui_key KEYCODE_BACK

  # A setting must survive a new process.
  ui_tap_prefix text "Dock slots" \
    || { echo "FAIL: could not tap Dock slots" >&2; return 1; }
  sleep 1
  [[ $(ui_count_prefix text "Dock slots: 6") -ge 1 ]] \
    || { echo "FAIL: dock slots did not change to 6" >&2; return 1; }
  "$ADB" -s "$SERIAL" shell am force-stop app.headroom.home >/dev/null 2>&1 || true
  sleep 1
  ui_home
  ui_tap text "Options" || { echo "FAIL: could not reopen Options" >&2; return 1; }
  sleep 1
  [[ $(ui_count_prefix text "Dock slots: 6") -ge 1 ]] \
    || { echo "FAIL: dock slots did not survive a restart" >&2; return 1; }
  ui_reset_options || { echo "FAIL: could not restore defaults" >&2; return 1; }
  ui_key KEYCODE_BACK

  # D-pad: the chips come first, then the dock tiles.
  for item in 1 2 3 4 5 6 7 8; do
    ui_key KEYCODE_DPAD_DOWN
    [[ $(ui_focused_tiles) -ge 1 ]] && break
  done
  [[ $(ui_focused_tiles) -ge 1 ]] \
    || { echo "FAIL: the D-pad did not focus a tile" >&2; return 1; }
  screenshot_settled "$OUT/$name-dpad.png" || true
  echo "  D-pad focus reached a tile"

  # Long press: the menu must offer all six actions, and Hide must remove a dock tile.
  anchor="Clock"
  b=$(ui_bounds content-desc "$anchor") || {
    anchor="Settings"
    b=$(ui_bounds content-desc "$anchor")
  } || { echo "FAIL: no dock tile to long-press" >&2; return 1; }
  # shellcheck disable=SC2086
  set -- $b
  "$ADB" -s "$SERIAL" shell input swipe \
    $(( ($1 + $3) / 2 )) $(( ($2 + $4) / 2 )) \
    $(( ($1 + $3) / 2 )) $(( ($2 + $4) / 2 )) 1200 >/dev/null 2>&1 || true
  sleep 1
  for item in "Add to dock" "Remove from dock" "Move left" "Move right" "Hide" "App info"; do
    [[ $(ui_count text "$item") -ge 1 ]] \
      || { echo "FAIL: long-press menu missing: $item" >&2; return 1; }
  done
  screenshot_settled "$OUT/$name-longpress.png" || true

  ui_tap text "Hide" || { echo "FAIL: could not choose Hide" >&2; return 1; }
  sleep 1
  tiles=$(ui_tiles)
  echo "  home tiles after Hide: $tiles"
  [[ $tiles -eq $((home_tiles - 1)) ]] \
    || { echo "FAIL: Hide did not remove the docked app" >&2; return 1; }
  [[ $(ui_count content-desc "$anchor") -eq 0 ]] \
    || { echo "FAIL: $anchor is still on the home screen" >&2; return 1; }
  screenshot_settled "$OUT/$name-hidden-app.png" || true

  # Reset clears the hidden set and puts the tile back in its old place.
  ui_tap text "Options" \
    || { echo "FAIL: could not open Options after Hide" >&2; return 1; }
  sleep 1
  ui_reset_options || { echo "FAIL: could not reset after Hide" >&2; return 1; }
  ui_key KEYCODE_BACK
  tiles=$(ui_tiles)
  [[ $tiles -eq $home_tiles ]] \
    || { echo "FAIL: reset did not bring the hidden app back" >&2; return 1; }

  ui_home
  screenshot_settled "$OUT/$name-ui-home.png" || true
  echo "  -> UI screenshots in $OUT"
}

while read -r name width height density orientation <&3; do
  [[ -n $name ]] || continue
  [[ -n $ONLY && $ONLY != "$name" ]] && continue
  echo "== $name: ${width}x${height} @ ${density}dpi ($orientation)"
  if ! create_avd "$name" "$width" "$height" "$density" "$orientation"; then
    echo "could not create or configure $name" >&2
    exit 1
  fi
  if ! boot_avd "$name"; then
    echo "boot failed; see $OUT/$name-emulator.log" >&2
    stop_avd
    exit 1
  fi
  setup_device
  if ! install_apk; then
    stop_avd
    exit 1
  fi
  if ! start_home; then
    stop_avd
    exit 1
  fi
  "$ADB" -s "$SERIAL" shell wm size | tr -d '\r' | sed 's/^/  /'
  "$ADB" -s "$SERIAL" shell wm density | tr -d '\r' | sed 's/^/  /'
  if ! screenshot "$OUT/$name.png"; then
    echo "screenshot failed" >&2
    stop_avd
    exit 1
  fi
  echo "  -> $OUT/$name.png"
  if [[ $BEHAVIOR == 1 && $name == "$CHECK_TARGET" ]]; then
    if ! behavior_checks "$name"; then
      stop_avd
      exit 1
    fi
  fi
  if [[ $UI == 1 && $name == "$CHECK_TARGET" ]]; then
    if ! ui_checks "$name"; then
      stop_avd
      exit 1
    fi
  fi
  stop_avd
done 3<<'EOF'
hr-1024x600 1024 600 160 landscape
hr-1280x720 1280 720 240 landscape
hr-1920x720 1920 720 320 landscape
hr-720x1280 720 1280 240 portrait
EOF

echo "screenshots in $OUT"
