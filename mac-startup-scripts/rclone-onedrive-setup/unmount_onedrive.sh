#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${SCRIPT_DIR}/config.sh"

NO_EJECT=0
POSITIONAL=()
for arg in "$@"; do
	case "$arg" in
	--no-eject) NO_EJECT=1 ;;
	-h | --help)
		cat <<'EOF'
Usage: ./unmount_onedrive.sh [--no-eject] <DriveName>
  Tear down rclone FUSE mounts listed in config.sh, then eject each distinct
  data volume used (unless --no-eject).

  <DriveName>  Default volume name (same as mount_onedrive.sh). Rows with an
               empty MOUNT_VOLUME_OVERRIDE use this; non-empty overrides use
               other /Volumes/<name> paths. See docs/mount-volume-override.md

  --no-eject   Unmount rclone only; do not run diskutil eject.
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

if [ ! -f "$CONFIG" ]; then
	echo "Missing config.sh — copy and edit the example:" >&2
	echo "  cp config.example.sh config.sh" >&2
	exit 1
fi

set +u
# shellcheck disable=1090
source "$CONFIG"
set -u

n=${#REMOTE_PATHS[@]}
if [ "$n" -lt 1 ]; then
	echo "config.sh: add at least one entry to REMOTE_PATHS." >&2
	exit 1
fi
if [ "$n" -ne "${#LOCAL_NAMES[@]}" ] || [ "$n" -ne "${#CACHE_MAX_SIZE[@]}" ]; then
	echo "config.sh: REMOTE_PATHS, LOCAL_NAMES, and CACHE_MAX_SIZE must have the same number of entries." >&2
	exit 1
fi

if [ -z "${MOUNT_VOLUME_OVERRIDE+x}" ] || [ "${#MOUNT_VOLUME_OVERRIDE[@]}" -eq 0 ]; then
	MOUNT_VOLUME_OVERRIDE=()
	_j=0
	while [ "$_j" -lt "$n" ]; do
		MOUNT_VOLUME_OVERRIDE+=("")
		_j=$((_j + 1))
	done
elif [ "${#MOUNT_VOLUME_OVERRIDE[@]}" -ne "$n" ]; then
	echo "config.sh: MOUNT_VOLUME_OVERRIDE must have the same number of entries as REMOTE_PATHS ($n), or omit it." >&2
	exit 1
fi

uniq_vols=()
add_uniq_vol() {
	local v="$1"
	local u
	# With set -u, "${uniq_vols[@]}" errors when the array is still empty (first call).
	if ((${#uniq_vols[@]} > 0)); then
		for u in "${uniq_vols[@]}"; do
			[ "$u" = "$v" ] && return 0
		done
	fi
	uniq_vols+=("$v")
	return 0
}

echo "Unmounting rclone FUSE mounts (default volume: $DRIVE_NAME)..."

i=0
while [ "$i" -lt "$n" ]; do
	vol="${MOUNT_VOLUME_OVERRIDE[$i]:-$DRIVE_NAME}"
	add_uniq_vol "$vol"
	target="/Volumes/$vol/OneDrive/${LOCAL_NAMES[$i]}"
	umount "$target" 2>/dev/null || true
	i=$((i + 1))
done

sleep 1

if pgrep -fq "rclone mount"; then
	for vol in "${uniq_vols[@]}"; do
		pkill -f "rclone mount.*/Volumes/${vol}/OneDrive" 2>/dev/null || true
	done
fi

echo "Waiting for FUSE to release handles..."
sleep 2

i=0
while [ "$i" -lt "$n" ]; do
	vol="${MOUNT_VOLUME_OVERRIDE[$i]:-$DRIVE_NAME}"
	target="/Volumes/$vol/OneDrive/${LOCAL_NAMES[$i]}"
	umount "$target" 2>/dev/null || true
	i=$((i + 1))
done

if [ "$NO_EJECT" -eq 1 ]; then
	echo "Skipping diskutil eject (--no-eject). Volumes may still be mounted:"
	for vol in "${uniq_vols[@]}"; do
		echo "  /Volumes/$vol"
	done
	exit 0
fi

for vol in "${uniq_vols[@]}"; do
	if [ ! -d "/Volumes/$vol" ]; then
		echo "Skipping eject for $vol — volume is not mounted (often already removed when another partition on the same USB disk was ejected)."
		continue
	fi
	echo "Ejecting $vol..."
	if diskutil eject "/Volumes/$vol"; then
		echo "Safe to disconnect $vol."
	else
		echo "Eject failed for $vol — something may still be using the drive."
	fi
done
