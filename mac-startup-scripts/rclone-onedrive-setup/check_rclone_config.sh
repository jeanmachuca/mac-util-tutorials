#!/bin/bash
# Verify rclone can read and decrypt ~/.config/rclone/rclone.conf (integrity check).
# Uses config.sh next to this script for Keychain (optional), same rules as mount_onedrive.sh.
#
# Usage: ./check_rclone_config.sh
#        ./check_rclone_config.sh --help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${SCRIPT_DIR}/config.sh"

usage() {
	sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'
	exit 0
}

case "${1:-}" in
-h | --help) usage ;;
"") ;;
*)
	echo "Unknown option: $1" >&2
	exit 1
	;;
esac

ok() { echo "[OK] $*"; }
fail() { echo "[FAIL] $*" >&2; }
warn() { echo "[WARN] $*" >&2; }

if [ -f "$CONFIG" ]; then
	set +u
	# shellcheck disable=1090
	source "$CONFIG" 2>/dev/null || {
		fail "Could not source $CONFIG (syntax error?)."
		exit 1
	}
	set -u
else
	warn "No config.sh next to this script — Keychain settings must come from the environment (RCLONE_CONFIG_KEYCHAIN_SERVICE) or use RCLONE_CONFIG_PASS for encrypted configs."
fi

# shellcheck source=rclone_resolve.sh
source "${SCRIPT_DIR}/rclone_resolve.sh"
if ! set_rclone_executable; then
	exit 1
fi

load_rclone_config_pass_from_keychain() {
	if [ -n "${RCLONE_CONFIG_PASS:-}" ]; then
		return 0
	fi
	if [ -z "${RCLONE_CONFIG_KEYCHAIN_SERVICE:-}" ]; then
		return 0
	fi
	if [ "$(uname -s)" != "Darwin" ]; then
		fail "RCLONE_CONFIG_KEYCHAIN_SERVICE is set but this is not macOS (Darwin)."
		return 1
	fi
	if ! command -v security >/dev/null 2>&1; then
		fail "macOS security(1) not found; cannot read Keychain password."
		return 1
	fi

	local pass
	local st=0
	if [ -n "${RCLONE_CONFIG_KEYCHAIN_ACCOUNT:-}" ]; then
		pass="$(security find-generic-password -a "$RCLONE_CONFIG_KEYCHAIN_ACCOUNT" -s "$RCLONE_CONFIG_KEYCHAIN_SERVICE" -w 2>/dev/null)" || st=$?
	else
		pass="$(security find-generic-password -s "$RCLONE_CONFIG_KEYCHAIN_SERVICE" -w 2>/dev/null)" || st=$?
	fi

	if [ "$st" -ne 0 ] || [ -z "$pass" ]; then
		fail "Could not read rclone config password from Keychain (service: ${RCLONE_CONFIG_KEYCHAIN_SERVICE})."
		return 1
	fi

	pass="${pass%$'\n'}"
	pass="${pass%$'\r'}"
	export RCLONE_CONFIG_PASS="$pass"
	return 0
}

ok "rclone found: $RCLONE"

RCONF="$("$RCLONE" config file 2>/dev/null | tail -n 1)"
if [ -z "$RCONF" ]; then
	fail "Could not determine config path (rclone config file)."
	exit 1
fi
ok "Config path: $RCONF"

if [ ! -e "$RCONF" ]; then
	fail "Config file does not exist yet. Run: rclone config"
	exit 1
fi

if [ ! -r "$RCONF" ]; then
	fail "Config file is not readable: $RCONF"
	exit 1
fi
ok "Config file exists and is readable."

encrypted=0
if head -n 1 "$RCONF" | grep -q '^# Encrypted rclone configuration'; then
	encrypted=1
	ok "Config is encrypted."
	if [ -z "${RCLONE_CONFIG_PASS:-}" ]; then
		if ! load_rclone_config_pass_from_keychain; then
			fail "Set RCLONE_CONFIG_PASS, or configure RCLONE_CONFIG_KEYCHAIN_SERVICE in config.sh (see README)."
			exit 1
		fi
	fi
	if [ -z "${RCLONE_CONFIG_PASS:-}" ]; then
		fail "Encrypted config requires RCLONE_CONFIG_PASS or Keychain (RCLONE_CONFIG_KEYCHAIN_* in config.sh)."
		exit 1
	fi
	ok "Decryption password available (environment or Keychain)."
	if ! "$RCLONE" config encryption check >/dev/null 2>&1; then
		fail "rclone config encryption check — wrong password or corrupted encrypted file?"
		exit 1
	fi
	ok "rclone config encryption check passed (file decrypts)."
else
	ok "Config is not encrypted (plain INI-style file)."
fi

if ! remotes="$("$RCLONE" listremotes 2>/dev/null)"; then
	fail "rclone listremotes failed — config may be corrupt or unreadable."
	exit 1
fi
if [ -z "$remotes" ]; then
	warn "No remotes defined yet (empty config). Add one with: rclone config"
else
	ok "Remotes load successfully:"
	echo "$remotes" | sed 's/^/    /'
fi

if [ -f "$CONFIG" ] && [ -n "${REMOTE_NAME:-}" ]; then
	if echo "$remotes" | grep -qx "${REMOTE_NAME}:"; then
		ok "Remote \"$REMOTE_NAME\" from config.sh is present in rclone config."
	else
		warn "config.sh REMOTE_NAME=\"$REMOTE_NAME\" not found in listremotes. Update REMOTE_NAME or rclone config."
	fi
fi

echo ""
echo "Integrity check passed."
exit 0
