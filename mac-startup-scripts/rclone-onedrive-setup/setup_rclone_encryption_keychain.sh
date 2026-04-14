#!/bin/bash
# Enable rclone config file encryption and store the master password in macOS Keychain.
# Aligns with mount_onedrive.sh + config.sh (RCLONE_CONFIG_KEYCHAIN_*).
#
# Usage:
#   ./setup_rclone_encryption_keychain.sh
#   ./setup_rclone_encryption_keychain.sh --encryption-only   # no Keychain (e.g. Linux or manual Keychain)
#   ./setup_rclone_encryption_keychain.sh --help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${SCRIPT_DIR}/config.sh"
ENCRYPTION_ONLY=0

usage() {
	sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
	exit 0
}

while [ $# -gt 0 ]; do
	case "$1" in
	--encryption-only) ENCRYPTION_ONLY=1 ;;
	-h | --help) usage ;;
	*)
		echo "Unknown option: $1" >&2
		exit 1
		;;
	esac
	shift
done

if [ -f "$CONFIG" ]; then
	# shellcheck source=config.sh
	set +u
	# shellcheck disable=1090
	source "$CONFIG" 2>/dev/null || true
	set -u
fi

SERVICE="${RCLONE_CONFIG_KEYCHAIN_SERVICE:-}"
ACCOUNT="${RCLONE_CONFIG_KEYCHAIN_ACCOUNT:-}"

die() {
	echo "Error: $*" >&2
	exit 1
}

if ! command -v rclone >/dev/null 2>&1; then
	die "rclone not found in PATH. Install it first (see README: Install dependencies)."
fi

if [ "$ENCRYPTION_ONLY" -eq 0 ] && [ "$(uname -s)" != "Darwin" ]; then
	echo "Note: Keychain is macOS-only. Use --encryption-only or run on a Mac for full setup." >&2
	ENCRYPTION_ONLY=1
fi

if [ "$ENCRYPTION_ONLY" -eq 0 ] && ! command -v security >/dev/null 2>&1; then
	die "macOS security(1) not found."
fi

rclone_conf_path() {
	# Last line of `rclone config file` is the path rclone will use.
	rclone config file 2>/dev/null | tail -n 1
}

config_is_encrypted() {
	local f="$1"
	[ -f "$f" ] || return 1
	head -n 1 "$f" | grep -q '^# Encrypted rclone configuration'
}

read_secret_twice() {
	local prompt="$1"
	local a b
	read -r -s -p "$prompt" a || true
	echo "" >&2
	read -r -s -p "Confirm password: " b || true
	echo "" >&2
	if [ "$a" != "$b" ]; then
		die "Passwords do not match."
	fi
	if [ -z "$a" ]; then
		die "Password is empty."
	fi
	printf '%s' "$a"
}

read_secret_once() {
	local prompt="$1"
	local a
	read -r -s -p "$prompt" a || true
	echo "" >&2
	if [ -z "$a" ]; then
		die "Password is empty."
	fi
	printf '%s' "$a"
}

store_keychain() {
	local svc="$1"
	local acct="$2"
	local pass="$3"

	if printf '%s' "$pass" | security add-generic-password -a "$acct" -s "$svc" -w 2>/dev/null; then
		echo "Keychain: saved new item for service '$svc' (account: $acct)."
	elif printf '%s' "$pass" | security add-generic-password -a "$acct" -s "$svc" -U -w 2>/dev/null; then
		echo "Keychain: updated existing item for service '$svc' (account: $acct)."
	else
		die "security add-generic-password failed. Fix Keychain permissions or remove a conflicting item."
	fi
}

RCONF="$(rclone_conf_path)"
[ -n "$RCONF" ] || die "Could not determine rclone config path (rclone config file)."

if [ ! -f "$RCONF" ]; then
	echo "Config file not found yet: $RCONF"
	echo "Create at least one remote first:  rclone config"
	exit 1
fi

echo "Using rclone config: $RCONF"
echo ""

if [ -z "$SERVICE" ]; then
	if [ "$ENCRYPTION_ONLY" -eq 0 ]; then
		read -r -p "Keychain service name [rclone-onedrive-config]: " in_svc || true
		SERVICE="${in_svc:-rclone-onedrive-config}"
	else
		SERVICE="rclone-onedrive-config"
	fi
fi
if [ -z "${ACCOUNT:-}" ]; then
	ACCOUNT="$USER"
fi

TMPDIR="${TMPDIR:-/tmp}"
TMP_PW="$(mktemp "$TMPDIR/rclone-enc-pw.XXXXXX")"
TMP_OLD="$(mktemp "$TMPDIR/rclone-enc-old.XXXXXX")"
TMP_NEW="$(mktemp "$TMPDIR/rclone-enc-new.XXXXXX")"
TMP_PCMD="$(mktemp "$TMPDIR/rclone-enc-pcmd.XXXXXX.sh")"
cleanup() {
	rm -f "$TMP_PW" "$TMP_OLD" "$TMP_NEW" "$TMP_PCMD" 2>/dev/null || true
}
trap cleanup EXIT INT TERM
chmod 600 "$TMP_PW" "$TMP_OLD" "$TMP_NEW" "$TMP_PCMD" 2>/dev/null || true

export RCLONE_CONFIG="${RCONF}"

if config_is_encrypted "$RCONF"; then
	echo "Config is already encrypted. You can change the password (Keychain will store the NEW password)."
	OLDP="$(read_secret_once "Current rclone config encryption password: ")"
	printf '%s' "$OLDP" >"$TMP_OLD"
	NEWP="$(read_secret_twice "New rclone config encryption password: ")"
	printf '%s' "$NEWP" >"$TMP_NEW"
	unset OLDP NEWP

	cat >"$TMP_PCMD" <<'EOS'
#!/bin/bash
set -euo pipefail
if [ "${RCLONE_PASSWORD_CHANGE:-}" = "1" ]; then
	exec cat "${RCLONE_ENC_NEW_FILE}"
else
	exec cat "${RCLONE_ENC_OLD_FILE}"
fi
EOS
	# shellcheck disable=SC2094
	export RCLONE_ENC_OLD_FILE="$TMP_OLD"
	export RCLONE_ENC_NEW_FILE="$TMP_NEW"
	chmod 700 "$TMP_PCMD"

	if ! rclone --password-command "$TMP_PCMD" config encryption set; then
		die "rclone config encryption set failed (wrong current password?)."
	fi
	echo "rclone: encryption password changed."

	MASTER="$(cat "$TMP_NEW")"
else
	echo "Config is not encrypted yet. A master password will wrap this file (tokens + remotes):"
	echo "  $RCONF"
	NEWP="$(read_secret_twice "Choose rclone config encryption password: ")"
	printf '%s' "$NEWP" >"$TMP_PW"
	unset NEWP

	if ! rclone --password-command "/bin/cat ${TMP_PW}" config encryption set; then
		die "rclone config encryption set failed."
	fi
	echo "rclone: config file is now encrypted."

	MASTER="$(cat "$TMP_PW")"
fi

printf '%s' "$MASTER" >"$TMP_PW"
if ! rclone --password-command "/bin/cat ${TMP_PW}" config encryption check; then
	die "rclone config encryption check failed after setup."
fi
echo "rclone: encryption check OK."

if [ "$ENCRYPTION_ONLY" -eq 1 ]; then
	echo ""
	echo "Done (encryption only). Export RCLONE_CONFIG_PASS for this shell when using rclone, or configure Keychain on macOS."
	echo "Add to config.sh when you use this repo's mounts:"
	echo "  RCLONE_CONFIG_KEYCHAIN_SERVICE=\"$SERVICE\""
	echo "  # RCLONE_CONFIG_KEYCHAIN_ACCOUNT=\"$ACCOUNT\""
	exit 0
fi

echo ""
echo "Storing master password in Keychain (service: $SERVICE, account: $ACCOUNT)..."
store_keychain "$SERVICE" "$ACCOUNT" "$MASTER"

echo ""
echo "Add these lines to your config.sh (same folder as mount_onedrive.sh) if not already set:"
echo "  RCLONE_CONFIG_KEYCHAIN_SERVICE=\"$SERVICE\""
echo "  RCLONE_CONFIG_KEYCHAIN_ACCOUNT=\"$ACCOUNT\""
echo ""
echo "Then run:  ./mount_onedrive.sh <YourVolume>"
echo "Or re-run ./install.sh if you use the LaunchAgent installer."
