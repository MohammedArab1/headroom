#!/usr/bin/env bash
# The whole pass, one step at a time. Stops at the first failure and at every car-check gate.
# Usage: scripts/all.sh [--dry-run] [-y]
set -uo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FLAGS=("$@")
run() { "$@" ${FLAGS[@]+"${FLAGS[@]}"}; }   # bash 3.2-safe empty-array expansion
source "$DIR/lib.sh"

case " ${*:-} " in
  *" --help "*|*" -h "*) printf 'usage: scripts/all.sh [--dry-run] [-y]\n'; exit 0 ;;
esac

run "$DIR/preflight.sh" || exit 1
[[ -f $CONF ]] || run "$DIR/configure.sh" || exit 1
load_conf
ls "$REPORT"/bench-before-*.json >/dev/null 2>&1 || run "$DIR/benchmark.sh" --label before || exit 1

for t in 1 2 3; do
  run "$DIR/debloat.sh" --tier "$t" || exit 1
  "$DIR/verify.sh" || exit 1
  [[ " ${FLAGS[*]-} " == *" --dry-run "* ]] && continue
  echo "Car checks for tier $t: a person answers them now."
  "$DIR/verify.sh" --manual || exit 1
done

run "$DIR/tune.sh" || exit 1
if [[ $LAUNCHER == 1 ]]; then run "$DIR/launcher.sh" || exit 1; fi
"$DIR/verify.sh" || exit 1

echo "Now reboot once and cycle the ignition once, then: scripts/verify.sh --manual"
echo "Then: scripts/benchmark.sh --label after && tools/bench_compare.py report/bench-before-*.json report/bench-after-*.json"
