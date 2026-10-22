#!/usr/bin/env bash
# Connect to the head unit over ADB. Never scans the network: the IP comes from a person.
# Usage: scripts/connect.sh <hu-ip>[:port]
#        scripts/connect.sh --pair <hu-ip>:<pair-port> <code> --port <connect-port>
#        scripts/connect.sh --tcpip
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MODE=plain
TARGET=""
PAIR_TARGET=""
CODE=""
PORT=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --pair)
      [[ $# -ge 3 ]] || die "usage: scripts/connect.sh --pair <hu-ip>:<pair-port> <code> --port <connect-port>"
      MODE=pair; PAIR_TARGET=$2; CODE=$3; shift 3 ;;
    --port)
      [[ $# -ge 2 ]] || die "--port needs a number"
      PORT=$2; shift 2 ;;
    --tcpip)
      MODE=tcpip; shift ;;
    -h|--help)
      printf 'usage: scripts/connect.sh <hu-ip>[:port] [-y] [--dry-run]\n'
      printf '       scripts/connect.sh --pair <hu-ip>:<pair-port> <code> --port <connect-port> [-y] [--dry-run]\n'
      printf '       scripts/connect.sh --tcpip [-y] [--dry-run]\n'
      exit 0 ;;
    --dry-run|-y|--yes)
      common_flag "$1"; shift ;;
    -*)
      die "unknown flag: $1" ;;
    *)
      [[ -z $TARGET ]] || die "one head unit at a time: got '$TARGET' and '$1'"
      TARGET=$1; shift ;;
  esac
done

command -v "$ADB" >/dev/null 2>&1 || die "adb not found: brew install android-platform-tools (or export ADB=\"$ROOT/tools/pyadb\")"

hostport() {
  case $1 in
    *:*) printf '%s' "$1" ;;
    *)   printf '%s:5555' "$1" ;;
  esac
}

classify() {  # adb output, target
  local out=$1
  case $out in
    *unauthorized*|*"failed to authenticate"*)
      note "NEXT: a person taps Allow on the unit (tick Always allow). Do not retry in a loop."
      return 1 ;;
    *"No route to host"*)
      note "NEXT: macOS Local Network privacy may be blocking adb. Allow your terminal under System Settings > Privacy & Security > Local Network, then run 'adb kill-server' and retry. If it still fails and port 5555 is open, use ADB=\"$ROOT/tools/pyadb\"."
      return 1 ;;
    *"Connection refused"*|*"failed to connect"*)
      note "NEXT: check the unit's Developer options. Android 11 or later needs scripts/connect.sh --pair."
      return 1 ;;
    *timeout*|*"timed out"*)
      note "NEXT: check the IP. Some phone hotspots block traffic between connected clients."
      return 1 ;;
  esac
  note "unexpected adb output: $out"
  note "NEXT: check Developer options and the IP, then retry once."
  return 1
}

connect_to() {  # target
  local target=$1 out state
  out=$("$ADB" connect "$target" 2>&1 | tr -d '\r')
  [[ -n $out ]] && printf '%s\n' "$out" >&2
  state=$("$ADB" -s "$target" get-state 2>/dev/null | tr -d '\r')
  if [[ $state == device ]]; then
    SERIAL=$target
    note "connected: $SERIAL"
    note "NEXT: scripts/preflight.sh"
    return 0
  fi
  if [[ $state == unauthorized ]]; then
    note "NEXT: a person taps Allow on the unit (tick Always allow). Do not retry in a loop."
    return 1
  fi
  classify "$out" "$target"
}

pair_then_connect() {
  local out host
  [[ $PAIR_TARGET == *:* ]] || die "the pairing target must be <hu-ip>:<pair-port>"
  case $PORT in
    ''|*[!0-9]*) die "--port is required after pairing: it is the port shown on the Wireless debugging screen, not the pairing port" ;;
  esac
  out=$("$ADB" pair "$PAIR_TARGET" "$CODE" 2>&1 | tr -d '\r')
  [[ -n $out ]] && printf '%s\n' "$out" >&2
  case $out in
    *"Successfully paired"*) ;;
    *"Wrong password"*|*"wrong password"*)
      note "NEXT: check the pairing code and pair again. The code changes each time the dialog is opened."
      return 1 ;;
    *)
      note "unexpected adb pair output: $out"
      note "NEXT: check the pairing port and code, then retry once."
      return 1 ;;
  esac
  host=${PAIR_TARGET%%:*}
  connect_to "$host:$PORT"
}

tcpip_mode() {
  local found serial out host
  serial=$SERIAL
  found=""
  if [[ -z $serial ]]; then
    found=$("$ADB" devices 2>/dev/null | awk 'NR>1 && $2=="device" {print $1}')
    [[ -n $found ]] || die "no device connected. Run scripts/connect.sh <hu-ip> first."
    # shellcheck disable=SC2086
    [[ $(printf '%s\n' $found | grep -c .) -eq 1 ]] || die "several devices connected; set ADB_SERIAL"
    serial=$(printf '%s\n' "$found" | head -n 1)
  fi
  out=$("$ADB" -s "$serial" tcpip 5555 2>&1 | tr -d '\r')
  [[ -n $out ]] && printf '%s\n' "$out" >&2
  case $out in
    *"restarting in TCP mode"*) ;;
    *) classify "$out" "$serial"; return 1 ;;
  esac
  SERIAL=$serial
  host=${serial%%:*}
  case $host in
    *[!0-9.]*|'')
      host=$(dev1 ip route | awk '{for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}')
      [[ -n $host ]] || host=$(dev1 getprop dhcp.wlan0.ipaddress)
      ;;
  esac
  case $host in
    ''|*[!0-9.]*) die "could not read the unit's IP. Run scripts/connect.sh <hu-ip>:5555 instead." ;;
  esac
  note "TCP mode does not survive a reboot. If it is lost, reconnect over USB or Wireless debugging."
  connect_to "$host:5555"
}

if [[ $DRY_RUN == 1 ]]; then
  case $MODE in
    pair)   note "[dry-run] adb pair $PAIR_TARGET $CODE; adb connect <hu-ip>:$PORT" ;;
    tcpip)  note "[dry-run] adb -s $SERIAL tcpip 5555; adb connect <hu-ip>:5555" ;;
    *)      note "[dry-run] adb connect $(hostport "$TARGET")" ;;
  esac
  exit 0
fi

"$ADB" start-server >/dev/null 2>&1 || true

case $MODE in
  pair)  pair_then_connect ;;
  tcpip) tcpip_mode ;;
  *)
    [[ -n $TARGET ]] || die "usage: scripts/connect.sh <hu-ip>[:port] | --pair <hu-ip>:<pair-port> <code> --port <port> | --tcpip"
    connect_to "$(hostport "$TARGET")"
    ;;
esac
