#!/bin/bash
# Mount OneDrive using config.sh — same as mount_onedrive.sh but defaults the volume to EXTERNAL_VOLUME_NAME.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${SCRIPT_DIR}/config.sh"

usage() {
	echo "Usage: ./login.sh [DriveName]"
	echo "  With no argument, uses EXTERNAL_VOLUME_NAME from config.sh (same as install.sh / LaunchAgent)."
	echo "  Example: ./login.sh"
	echo "  Example: ./login.sh MyPassport"
	exit 0
}

case "${1:-}" in
-h | --help) usage ;;
esac

if [ ! -f "$CONFIG" ]; then
	echo "Missing config.sh — copy and edit the example:" >&2
	echo "  cp config.example.sh config.sh" >&2
	exit 1
fi

# shellcheck source=config.sh
set +u
# shellcheck disable=1090
source "$CONFIG"
set -u

VOL="${1:-${EXTERNAL_VOLUME_NAME:-}}"
if [ -z "$VOL" ]; then
	echo "No drive name. Set EXTERNAL_VOLUME_NAME in config.sh or pass:" >&2
	echo "  ./login.sh MyPassport" >&2
	exit 1
fi

exec "$SCRIPT_DIR/mount_onedrive.sh" "$VOL"
