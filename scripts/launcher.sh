#!/usr/bin/env bash
# Install headroom home and make it HOME. Thin wrapper around launcher/install.sh.
# Usage: scripts/launcher.sh [-y] [--dry-run] [--apk PATH] [--undo]
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
exec "$HERE/../launcher/install.sh" "$@"
