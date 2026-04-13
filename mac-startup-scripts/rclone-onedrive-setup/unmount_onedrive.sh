#!/bin/bash

if [ -z "${1:-}" ]; then
    echo "Usage: ./unmount_onedrive.sh [DriveName]"
    echo "Example: ./unmount_onedrive.sh MyExternalDrive"
    exit 1
fi

DRIVE_NAME=$1
BASE_PATH="/Volumes/$DRIVE_NAME/OneDrive"

echo "Unmounting rclone FUSE mounts under $BASE_PATH..."
if [ -d "$BASE_PATH" ]; then
    for target in "$BASE_PATH"/*; do
        [ -e "$target" ] || continue
        [ -d "$target" ] || continue
        umount "$target" 2>/dev/null || true
    done
fi

sleep 1

if pgrep -fq "rclone mount"; then
    pkill -f "rclone mount.*/Volumes/${DRIVE_NAME}/OneDrive" 2>/dev/null || true
fi

echo "Waiting for FUSE to release handles..."
sleep 2

if [ -d "$BASE_PATH" ]; then
    for target in "$BASE_PATH"/*; do
        [ -e "$target" ] || continue
        [ -d "$target" ] || continue
        umount "$target" 2>/dev/null || true
    done
fi

echo "Ejecting $DRIVE_NAME..."
if diskutil eject "/Volumes/$DRIVE_NAME"; then
    echo "Safe to disconnect $DRIVE_NAME."
else
    echo "Eject failed — something may still be using the drive."
fi
