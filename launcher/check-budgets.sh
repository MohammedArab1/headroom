#!/usr/bin/env bash
# Check the release APK against the launcher's acceptance budget.
# Usage: launcher/check-budgets.sh
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$HERE" || exit 1

APK=app/build/outputs/apk/release/app-release.apk
[[ -f $APK ]] || { echo "no release APK at $APK" >&2; exit 1; }

size=$(stat -c %s "$APK" 2>/dev/null || stat -f %z "$APK")
echo "APK $((size / 1024)) KB"
[[ $size -lt 153600 ]] || { echo "over 150 KB" >&2; exit 1; }

SDK=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}
AAPT2=${AAPT2:-$SDK/build-tools/34.0.0/aapt2}
if ! command -v "$AAPT2" >/dev/null 2>&1; then
  echo "aapt2 not found: set AAPT2 or ANDROID_HOME" >&2
  exit 1
fi
perms=$("$AAPT2" dump permissions "$APK" | grep uses-permission || true)
[[ -z $perms ]] || { echo "the launcher must request no permissions: $perms" >&2; exit 1; }

if grep -E '<(service|receiver|provider)' app/src/main/AndroidManifest.xml >/dev/null; then
  echo "no background components are allowed in the launcher" >&2
  exit 1
fi

deps=$(./gradlew -q --no-daemon :app:dependencies --configuration releaseRuntimeClasspath \
  | grep -E '^[+\\]---' || true)
[[ -z $deps ]] || { echo "the launcher must have no runtime dependencies: $deps" >&2; exit 1; }

echo "budgets ok: zero permissions, no background components, no runtime dependencies"
