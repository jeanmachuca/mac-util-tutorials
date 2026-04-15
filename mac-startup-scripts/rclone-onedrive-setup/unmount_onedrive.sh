#!/bin/bash

NO_EJECT=0
POSITIONAL=()
for arg in "$@"; do
	case "$arg" in
	--no-eject) NO_EJECT=1 ;;
	-h | --help)
		cat <<'EOF'
Usage: ./unmount_onedrive.sh [--no-eject] <DriveName>
  Tear down rclone FUSE mounts under /Volumes/<DriveName>/OneDrive/, then
  eject the volume (unless --no-eject).

  --no-eject   Unmount rclone only; do not run diskutil eject. Use when the
               data volume should stay mounted (e.g. another partition on the
               same physical disk is still in use).
EOF
		exit 0
		;;
	-*)
		echo "Unknown option: $arg" >&2
		echo "Usage: ./unmount_onedrive.sh [--no-eject] <DriveName>" >&2
		exit 1
		;;
	*) POSITIONAL+=("$arg") ;;
	esac
done

if [ "${#POSITIONAL[@]}" -ne 1 ]; then
	echo "Usage: ./unmount_onedrive.sh [--no-eject] <DriveName>" >&2
	exit 1
fi

DRIVE_NAME="${POSITIONAL[0]}"
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

if [ "$NO_EJECT" -eq 1 ]; then
	echo "Skipping diskutil eject (--no-eject). Volume /Volumes/$DRIVE_NAME may still be mounted."
	exit 0
fi

echo "Ejecting $DRIVE_NAME..."
if diskutil eject "/Volumes/$DRIVE_NAME"; then
	echo "Safe to disconnect $DRIVE_NAME."
else
	echo "Eject failed — something may still be using the drive."
fi
