#!/bin/bash
# LaunchAgent entry point: wait so Finder/session are ready, then run mount_gdrive.sh.
# Not intended for interactive use — use ./login.sh or ./mount_gdrive.sh directly.
#
# Usage (launchd): /bin/bash .../startup_mount_gdrive.sh <VolumeName>
# Calls mount_gdrive.sh --no-daemon so rclone stays attached to this process (launchd).
# Environment: STARTUP_MOUNT_DELAY_SEC (default 10) — set in the plist by install.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DELAY="${STARTUP_MOUNT_DELAY_SEC:-10}"

if [ -z "${1:-}" ]; then
	echo "startup_mount_gdrive.sh: missing volume name" >&2
	exit 1
fi

echo "startup_mount_gdrive: sleeping ${DELAY}s before mount (volume: $1)..."
sleep "$DELAY"

exec "$SCRIPT_DIR/mount_gdrive.sh" --no-daemon "$1"
