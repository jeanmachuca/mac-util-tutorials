#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${SCRIPT_DIR}/config.sh"

if [ ! -f "$CONFIG" ]; then
    echo "Missing config.sh — copy and edit the example:"
    echo "  cp config.example.sh config.sh"
    exit 1
fi
# shellcheck source=config.sh
source "$CONFIG"

# If rclone.conf is encrypted, set RCLONE_CONFIG_PASS before any rclone invocation.
# Optional: read the master password from macOS Keychain (see config.example.sh + README).
load_rclone_config_pass_from_keychain() {
	if [ -n "${RCLONE_CONFIG_PASS:-}" ]; then
		return 0
	fi
	if [ -z "${RCLONE_CONFIG_KEYCHAIN_SERVICE:-}" ]; then
		return 0
	fi
	if [ "$(uname -s)" != "Darwin" ]; then
		echo "Error: RCLONE_CONFIG_KEYCHAIN_SERVICE is set but this is not macOS (Darwin)." >&2
		exit 1
	fi
	if ! command -v security >/dev/null 2>&1; then
		echo "Error: macOS security(1) not found; cannot read Keychain password." >&2
		exit 1
	fi

	local pass
	local st=0
	if [ -n "${RCLONE_CONFIG_KEYCHAIN_ACCOUNT:-}" ]; then
		pass="$(security find-generic-password -a "$RCLONE_CONFIG_KEYCHAIN_ACCOUNT" -s "$RCLONE_CONFIG_KEYCHAIN_SERVICE" -w 2>/dev/null)" || st=$?
	else
		pass="$(security find-generic-password -s "$RCLONE_CONFIG_KEYCHAIN_SERVICE" -w 2>/dev/null)" || st=$?
	fi

	if [ "$st" -ne 0 ] || [ -z "$pass" ]; then
		echo "Error: Could not read rclone config password from Keychain." >&2
		echo "  Service: ${RCLONE_CONFIG_KEYCHAIN_SERVICE}" >&2
		if [ -n "${RCLONE_CONFIG_KEYCHAIN_ACCOUNT:-}" ]; then
			echo "  Account: ${RCLONE_CONFIG_KEYCHAIN_ACCOUNT}" >&2
		fi
		echo "  Create or fix the item (see README: encrypting rclone.conf and Keychain)." >&2
		exit 1
	fi

	# security -w may include a trailing newline
	pass="${pass%$'\n'}"
	pass="${pass%$'\r'}"
	export RCLONE_CONFIG_PASS="$pass"
	return 0
}

load_rclone_config_pass_from_keychain

if [ -z "${1:-}" ]; then
    echo "Usage: ./mount_onedrive.sh [DriveName]"
    echo "Example: ./mount_onedrive.sh MyExternalDrive"
    exit 1
fi

n=${#REMOTE_PATHS[@]}
if [ "$n" -lt 1 ]; then
    echo "config.sh: add at least one entry to REMOTE_PATHS."
    exit 1
fi
if [ "$n" -ne "${#LOCAL_NAMES[@]}" ] || [ "$n" -ne "${#CACHE_MAX_SIZE[@]}" ]; then
    echo "config.sh: REMOTE_PATHS, LOCAL_NAMES, and CACHE_MAX_SIZE must have the same number of entries."
    exit 1
fi

DRIVE_NAME=$1
BASE_PATH="/Volumes/$DRIVE_NAME/OneDrive"

if [ ! -d "/Volumes/$DRIVE_NAME" ]; then
    echo "Error: Drive /Volumes/$DRIVE_NAME not found."
    exit 1
fi

echo "Starting rclone mounts on $DRIVE_NAME..."

i=0
while [ "$i" -lt "$n" ]; do
    remote="${REMOTE_PATHS[$i]}"
    local_name="${LOCAL_NAMES[$i]}"
    cache="${CACHE_MAX_SIZE[$i]}"
    target="$BASE_PATH/$local_name"

    umount "$target" 2>/dev/null || true
    mkdir -p "$target"

    rclone mount "${REMOTE_NAME}:${remote}" "$target" \
        --allow-non-empty \
        --vfs-cache-mode full \
        --vfs-cache-max-size "$cache" \
        --daemon
    i=$((i + 1))
done

echo "Mounts active under $BASE_PATH"
