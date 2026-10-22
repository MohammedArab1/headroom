#!/usr/bin/env bash
# Build, lint and budget-check the launcher in Docker, with no local JDK or Android SDK.
# Usage: launcher/docker-build.sh
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
IMAGE=headroom-launcher-build
PLATFORM=linux/amd64   # Android build-tools are x86_64; Docker emulates them on Apple Silicon.

command -v docker >/dev/null 2>&1 || { echo "docker is not installed" >&2; exit 2; }
docker info >/dev/null 2>&1 \
  || { echo "Docker is not running. Start Docker Desktop, then re-run." >&2; exit 2; }

echo "building the toolchain image ($PLATFORM; the first run downloads the SDK)" >&2
docker build --platform "$PLATFORM" -t "$IMAGE" -f "$HERE/Dockerfile" "$HERE" || exit 1

docker run --rm --platform "$PLATFORM" \
  -v "$ROOT:/work" -v headroom-gradle:/root/.gradle \
  -w /work/launcher "$IMAGE" \
  bash -lc './gradlew --no-daemon testReleaseUnitTest lintRelease assembleRelease && ./check-budgets.sh'
