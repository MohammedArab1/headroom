#!/usr/bin/env bash
# End a session: turn ADB off on the unit, then prove port 5555 is closed.
# Usage: scripts/close-adb.sh <hu-ip> [--keep-pairing] [--dry-run]
#        scripts/close-adb.sh --keep-pairing            (uses SERIAL's IP)
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HOST=""
KEEP_PAIRING=0
usage() {
  printf 'usage: scripts/close-adb.sh <hu-ip> [--keep-pairing] [--dry-run]\n' >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --keep-pairing) KEEP_PAIRING=1; shift ;;
    --dry-run|-y|--yes) common_flag "$1"; shift ;;
    -*) usage ;;
    *)
      [[ -z $HOST ]] || usage
      HOST=$1; shift ;;
  esac
done

if [[ -z $HOST && -n $SERIAL ]]; then
  case $SERIAL in
    *:*)
      HOST=${SERIAL%%:*}
      case $HOST in *[!0-9.]*) HOST="" ;; esac ;;
  esac
fi

step "on the unit (a person does this)"
note "1. Settings > Developer options: turn off Wireless debugging and USB debugging."
if [[ $KEEP_PAIRING == 1 ]]; then
  note "2. Keep the USB debugging authorisations (--keep-pairing)."
else
  note "2. Tap Revoke USB debugging authorisations."
fi
note "3. Reboot the unit."
note "4. Run this script again (or let the check below run) to prove the port is closed."

if [[ $DRY_RUN == 1 ]]; then
  note "[dry-run] would probe ${HOST:-<hu-ip>}:5555"
  exit 0
fi

if [[ -z $HOST ]]; then
  note "No fixed IP or port to probe. Wireless debugging uses a random port."
  if command -v "$ADB" >/dev/null 2>&1; then
    left=$("$ADB" mdns services 2>/dev/null | awk '/_adb-tls-connect/ {print $NF}')
    if [[ -n $left ]]; then
      warn "the unit is still advertised over mDNS: $left"
      warn "turn Wireless debugging off on the unit, then check again"
      exit 1
    fi
    note "no head unit is advertised over mDNS"
    exit 0
  fi
  usage
fi

PYTHON=${PYTHON:-python3}
out=$("$PYTHON" "$ROOT/tools/adb_closed.py" "$HOST" 2>&1)
rc=$?
printf '%s\n' "$out" >&2
case $rc in
  0) note "ADB is off. Session closed." ;;
  1) warn "ADB is still open on $HOST:5555. Finish the steps above, then run this script again." ;;
  *) warn "could not check the port. Check it by hand from another device before driving." ;;
esac
exit "$rc"
