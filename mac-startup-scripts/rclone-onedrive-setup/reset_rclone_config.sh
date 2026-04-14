#!/bin/bash
# Remove the rclone configuration file so you can run `rclone config` from scratch.
# Optionally backs up first, optionally removes the Keychain item used for config encryption.
#
# Usage:
#   ./reset_rclone_config.sh
#   ./reset_rclone_config.sh -y                    # skip typing RESET (still backs up by default)
#   ./reset_rclone_config.sh -y --no-backup        # destructive: no backup file
#   ./reset_rclone_config.sh --dry-run
#   ./reset_rclone_config.sh --remove-keychain -y  # also delete Keychain password (see config.sh)
#   ./reset_rclone_config.sh --help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${SCRIPT_DIR}/config.sh"

YES=0
DRY_RUN=0
NO_BACKUP=0
REMOVE_KEYCHAIN=0

usage() {
	sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
	exit 0
}

while [ $# -gt 0 ]; do
	case "$1" in
	-h | --help) usage ;;
	-y | --yes) YES=1 ;;
	--dry-run) DRY_RUN=1 ;;
	--no-backup) NO_BACKUP=1 ;;
	--remove-keychain) REMOVE_KEYCHAIN=1 ;;
	*)
		echo "Unknown option: $1" >&2
		exit 1
		;;
	esac
	shift
done

if [ "$NO_BACKUP" -eq 1 ] && [ "$YES" -eq 0 ]; then
	echo "Error: --no-backup requires -y (refusing to delete without backup without explicit -y)." >&2
	exit 1
fi

if [ -f "$CONFIG" ]; then
	set +u
	# shellcheck disable=1090
	source "$CONFIG" 2>/dev/null || {
		echo "Warning: could not source $CONFIG — Keychain options may be unavailable." >&2
	}
	set -u
fi

die() {
	echo "Error: $*" >&2
	exit 1
}

if ! command -v rclone >/dev/null 2>&1; then
	die "rclone not in PATH."
fi

RCONF="$(rclone config file 2>/dev/null | tail -n 1)"
[ -n "$RCONF" ] || die "Could not determine config path (rclone config file)."

if [ ! -e "$RCONF" ]; then
	echo "Nothing to reset: config file does not exist yet:"
	echo "  $RCONF"
	echo "Run: rclone config"
	exit 0
fi

echo "Rclone config file:"
echo "  $RCONF"
echo ""

if [ "$DRY_RUN" -eq 1 ]; then
	echo "[dry-run] Would remove the file above."
	if [ "$NO_BACKUP" -eq 0 ]; then
		echo "[dry-run] Would copy it to: ${RCONF}.bak.$(date +%Y%m%d%H%M%S) (example path; real run uses time of copy)"
	else
		echo "[dry-run] Would NOT keep a backup (--no-backup)."
	fi
	if [ "$REMOVE_KEYCHAIN" -eq 1 ] && [ -n "${RCLONE_CONFIG_KEYCHAIN_SERVICE:-}" ]; then
		echo "[dry-run] Would try to delete Keychain item (service: ${RCLONE_CONFIG_KEYCHAIN_SERVICE})."
	elif [ "$REMOVE_KEYCHAIN" -eq 1 ]; then
		echo "[dry-run] --remove-keychain ignored (set RCLONE_CONFIG_KEYCHAIN_SERVICE in config.sh or env)."
	fi
	exit 0
fi

if [ "$YES" -eq 0 ]; then
	echo "This deletes your local rclone remotes and tokens in that file."
	echo "OneDrive in the cloud is unchanged; you will need to run rclone config again."
	echo ""
	read -r -p "Type RESET to continue: " confirm || true
	if [ "$confirm" != "RESET" ]; then
		echo "Aborted."
		exit 1
	fi
fi

BACKUP=""
if [ "$NO_BACKUP" -eq 0 ]; then
	BACKUP="${RCONF}.bak.$(date +%Y%m%d%H%M%S)"
	cp -f "$RCONF" "$BACKUP"
	echo "Backup saved:"
	echo "  $BACKUP"
else
	echo "No backup created (--no-backup)."
fi

rm -f "$RCONF"
echo "Removed: $RCONF"

if [ "$REMOVE_KEYCHAIN" -eq 1 ] && [ -n "${RCLONE_CONFIG_KEYCHAIN_SERVICE:-}" ]; then
	if [ "$(uname -s)" != "Darwin" ]; then
		echo "Keychain removal skipped (not macOS)."
	elif ! command -v security >/dev/null 2>&1; then
		echo "Keychain removal skipped (security not found)."
	else
		svc="$RCLONE_CONFIG_KEYCHAIN_SERVICE"
		set +e
		if [ -n "${RCLONE_CONFIG_KEYCHAIN_ACCOUNT:-}" ]; then
			security delete-generic-password -a "$RCLONE_CONFIG_KEYCHAIN_ACCOUNT" -s "$svc" 2>/dev/null
		else
			security delete-generic-password -a "$USER" -s "$svc" 2>/dev/null || security delete-generic-password -s "$svc" 2>/dev/null
		fi
		st=$?
		set -e
		if [ "$st" -eq 0 ]; then
			echo "Removed Keychain item for service: $svc"
		else
			echo "Keychain: could not delete automatically (item missing or different -a/-s). Remove it in Keychain Access if needed."
		fi
	fi
elif [ "$REMOVE_KEYCHAIN" -eq 1 ]; then
	echo "Keychain: --remove-keychain ignored — set RCLONE_CONFIG_KEYCHAIN_SERVICE in config.sh (or environment) first."
fi

echo ""
echo "Next steps:"
echo "  1. Run: rclone config"
echo "  2. Update this repo's config.sh (REMOTE_NAME, REMOTE_PATHS, …) if your remote name changed."
echo "  3. Optional: ./setup_rclone_encryption_keychain.sh  # encrypt + Keychain again"
echo "  4. ./check_rclone_config.sh  # verify"
