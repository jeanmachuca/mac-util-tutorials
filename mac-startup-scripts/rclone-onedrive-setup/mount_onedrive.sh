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
