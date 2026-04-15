#!/bin/bash
# Unmount and eject using config.sh — same as unmount_onedrive.sh but defaults the volume to EXTERNAL_VOLUME_NAME.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${SCRIPT_DIR}/config.sh"

usage() {
	echo "Usage: ./logout.sh [--no-eject] [DriveName]"
	echo "  With no drive argument, uses EXTERNAL_VOLUME_NAME from config.sh."
	echo "  --no-eject   Unmount rclone only; do not run diskutil eject (see unmount_onedrive.sh)."
	echo "  Example: ./logout.sh"
	echo "  Example: ./logout.sh MyPassport"
	echo "  Example: ./logout.sh --no-eject"
	exit 0
}

POSITIONAL=()
NO_EJECT=0
for arg in "$@"; do
	case "$arg" in
	--no-eject) NO_EJECT=1 ;;
	-h | --help) usage ;;
	*) POSITIONAL+=("$arg") ;;
	esac
done

if [ "${#POSITIONAL[@]}" -gt 1 ]; then
	echo "Too many arguments." >&2
	echo "Usage: ./logout.sh [--no-eject] [DriveName]" >&2
	exit 1
fi

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

VOL="${POSITIONAL[0]:-${EXTERNAL_VOLUME_NAME:-}}"
if [ -z "$VOL" ]; then
	echo "No drive name. Set EXTERNAL_VOLUME_NAME in config.sh or pass:" >&2
	echo "  ./logout.sh MyPassport" >&2
	exit 1
fi

if [ "$NO_EJECT" -eq 1 ]; then
	exec "$SCRIPT_DIR/unmount_onedrive.sh" --no-eject "$VOL"
else
	exec "$SCRIPT_DIR/unmount_onedrive.sh" "$VOL"
fi
