#!/bin/bash
# Install rclone-onedrive-setup to ~/Library/Application Support/ and register a LaunchAgent.
# Usage:
#   ./install.sh              # install (requires config.sh with EXTERNAL_VOLUME_NAME)
#   ./install.sh --dry-run      # verify only; no copies, no launchctl
#   ./install.sh --uninstall    # remove LaunchAgent and install directory
#   ./install.sh --dest PATH    # override install directory (default: Application Support path below)
#   ./install.sh --label ID     # LaunchAgent label (default: com.rclone-onedrive.mount)
#   ./install.sh MyVolume       # override volume name for this run (else uses EXTERNAL_VOLUME_NAME from config.sh)
#   ./install.sh --skip-keychain   # skip interactive Keychain step (see RCLONE_CONFIG_KEYCHAIN_SERVICE in config.sh)

set -euo pipefail

readonly DEFAULT_LABEL="com.rclone-onedrive.mount"
readonly DEFAULT_DEST="${HOME}/Library/Application Support/rclone-onedrive-setup"
readonly ALIAS_HOOK_BEGIN='# >>> rclone-onedrive-setup aliases (install.sh) >>>'
readonly ALIAS_HOOK_END='# <<< rclone-onedrive-setup aliases <<<'

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN=0
UNINSTALL=0
SKIP_KEYCHAIN=0
DEST="$DEFAULT_DEST"
LABEL="$DEFAULT_LABEL"
VOLUME_OVERRIDE=""

usage() {
	sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
	exit 0
}

while [ $# -gt 0 ]; do
	case "$1" in
	--dry-run) DRY_RUN=1 ;;
	--uninstall) UNINSTALL=1 ;;
	--skip-keychain) SKIP_KEYCHAIN=1 ;;
	--dest)
		shift
		DEST="${1:?--dest requires a path}"
		;;
	--label)
		shift
		LABEL="${1:?--label requires a string}"
		;;
	-h | --help) usage ;;
	--)
		shift
		break
		;;
	-*)
		echo "Unknown option: $1" >&2
		exit 1
		;;
	*)
		VOLUME_OVERRIDE="$1"
		break
		;;
	esac
	shift
done

PLIST_PATH="${HOME}/Library/LaunchAgents/${LABEL}.plist"

log_ok() { echo "[OK] $*"; }
log_warn() { echo "[WARN] $*" >&2; }
log_fail() { echo "[FAIL] $*" >&2; }

require_darwin() {
	if [ "$(uname -s)" != "Darwin" ]; then
		log_fail "This installer supports macOS only (Darwin)."
		return 1
	fi
	log_ok "Operating system is Darwin (macOS)."
	return 0
}

check_tools() {
	local ok=0
	if command -v rclone >/dev/null 2>&1; then
		log_ok "rclone found: $(command -v rclone)"
	else
		log_fail "rclone not in PATH (required before install / dry-run)."
		echo "" >&2
		echo "Install options:" >&2
		echo "  • macOS (Homebrew):  brew install rclone" >&2
		echo "" >&2
		echo "  • To install rclone on Linux/macOS/BSD systems, run:" >&2
		echo "      sudo -v ; curl https://rclone.org/install.sh | sudo bash" >&2
		echo "" >&2
		ok=1
	fi
	if command -v plutil >/dev/null 2>&1; then
		log_ok "plutil found."
	else
		log_fail "plutil missing (unexpected on macOS)."
		ok=1
	fi
	if command -v rsync >/dev/null 2>&1; then
		log_ok "rsync found."
	else
		log_fail "rsync missing (unexpected on macOS)."
		ok=1
	fi
	return "$ok"
}

check_src_layout() {
	local err=0
	for f in mount_onedrive.sh rclone_resolve.sh startup_mount_onedrive.sh unmount_onedrive.sh config.example.sh; do
		if [ -f "$SRC/$f" ]; then
			log_ok "Source file present: $f"
		else
			log_fail "Missing required file in $SRC: $f"
			err=1
		fi
	done
	if [ -f "$SRC/config.sh" ]; then
		log_ok "config.sh present in source (will be copied)."
	else
		log_fail "config.sh missing in $SRC — run: cp config.example.sh config.sh && edit"
		err=1
	fi
	return "$err"
}

# Every symlink under root must resolve; dangling symlinks fail install / dry-run.
# Excludes .git and .cursor (same as rsync).
check_symlinks_in_tree() {
	local root="$1"
	local ctx="${2:-$root}"
	local broken=0
	local n=0
	local f t

	if [ ! -d "$root" ]; then
		return 0
	fi

	while IFS= read -r -d '' f; do
		n=$((n + 1))
		if [ -L "$f" ] && [ ! -e "$f" ]; then
			t="$(readlink "$f" 2>/dev/null || printf '%s' '?')"
			log_fail "Broken symlink in $ctx: $f -> $t"
			broken=$((broken + 1))
		fi
	done < <(find "$root" -type l ! -path '*/.git/*' ! -path '*/.cursor/*' -print0 2>/dev/null)

	if [ "$broken" -gt 0 ]; then
		log_fail "Symlink integrity check failed ($broken broken symlink(s) in $ctx)."
		return 1
	fi
	if [ "$n" -eq 0 ]; then
		log_ok "Symlink integrity: OK (no symlinks under $ctx)."
	else
		log_ok "Symlink integrity: OK ($n symlink(s) under $ctx)."
	fi
	return 0
}

# Shell aliases point at these files; ensure they exist before editing ~/.zshrc (not covered by symlink scan).
check_shell_alias_targets() {
	local d="$1"
	local ctx="${2:-install directory}"
	local name

	for name in install.sh mount_onedrive.sh rclone_resolve.sh unmount_onedrive.sh login.sh logout.sh check_rclone_config.sh reset_rclone_config.sh; do
		if [ ! -f "$d/$name" ]; then
			log_fail "Shell alias target missing ($ctx): $d/$name"
			return 1
		fi
	done
	log_ok "Shell alias targets OK ($ctx): install.sh, mount_onedrive.sh, rclone_resolve.sh, unmount_onedrive.sh, login.sh, logout.sh, check_rclone_config.sh, reset_rclone_config.sh"
	return 0
}

# Validate config.sh (same rules as mount_onedrive.sh + EXTERNAL_VOLUME_NAME for LaunchAgent).
# Second arg: if "1", skip EXTERNAL_VOLUME_NAME check (volume passed on install.sh command line).
validate_config_sh() {
	local cfg="$1"
	local skip_external="${2:-0}"
	local err_msg

	if [ ! -f "$cfg" ]; then
		log_fail "Missing config file: $cfg"
		return 1
	fi

	if ! err_msg="$(
		set +u
		# shellcheck disable=1090
		if ! source "$cfg" 2>/dev/null; then
			echo "Could not source config (syntax error?): $cfg"
			exit 1
		fi
		set -u

		if [ -z "${REMOTE_NAME:-}" ]; then
			echo "REMOTE_NAME must be set (non-empty)."
			exit 1
		fi

		local n=${#REMOTE_PATHS[@]}
		if [ "$n" -lt 1 ]; then
			echo "REMOTE_PATHS must contain at least one folder."
			exit 1
		fi
		if [ "$n" -ne "${#LOCAL_NAMES[@]}" ]; then
			echo "LOCAL_NAMES must have the same number of entries as REMOTE_PATHS ($n)."
			exit 1
		fi
		if [ "$n" -ne "${#CACHE_MAX_SIZE[@]}" ]; then
			echo "CACHE_MAX_SIZE must have the same number of entries as REMOTE_PATHS ($n)."
			exit 1
		fi

		local i=0
		while [ "$i" -lt "$n" ]; do
			if [ -z "${REMOTE_PATHS[$i]:-}" ]; then
				echo "REMOTE_PATHS[$i] is empty."
				exit 1
			fi
			if [ -z "${LOCAL_NAMES[$i]:-}" ]; then
				echo "LOCAL_NAMES[$i] is empty."
				exit 1
			fi
			if [ -z "${CACHE_MAX_SIZE[$i]:-}" ]; then
				echo "CACHE_MAX_SIZE[$i] is empty."
				exit 1
			fi
			i=$((i + 1))
		done

		if [ "$skip_external" != 1 ] && [ -z "${EXTERNAL_VOLUME_NAME:-}" ]; then
			echo "EXTERNAL_VOLUME_NAME must be set, or pass the volume as: ./install.sh YourVolumeName"
			exit 1
		fi
	)"; then
		log_fail "config.sh validation failed ($cfg): $err_msg"
		return 1
	fi

	log_ok "config.sh validated: $cfg"
	return 0
}

# Load EXTERNAL_VOLUME_NAME (and nothing else destructive) from a config file
read_volume_from_config() {
	local cfg="$1"
	if [ ! -f "$cfg" ]; then
		echo ""
		return 0
	fi
	# shellcheck disable=1090
	set +u
	# shellcheck source=/dev/null
	source "$cfg" 2>/dev/null || true
	set -u
	echo "${EXTERNAL_VOLUME_NAME:-}"
}

resolve_volume() {
	local v=""
	if [ -n "$VOLUME_OVERRIDE" ]; then
		echo "$VOLUME_OVERRIDE"
		return 0
	fi
	v="$(read_volume_from_config "$SRC/config.sh")"
	if [ -z "$v" ] && [ -f "$DEST/config.sh" ]; then
		v="$(read_volume_from_config "$DEST/config.sh")"
	fi
	echo "$v"
}

validate_volume() {
	local v="$1"
	if [ -z "$v" ]; then
		log_fail "No volume name. Set EXTERNAL_VOLUME_NAME in config.sh or pass: ./install.sh MyVolume"
		log_fail "Add to config.sh: EXTERNAL_VOLUME_NAME=\"MyPassport\""
		return 1
	fi
	case "$v" in
	*/* | *\\*)
		log_fail "Volume name must not contain path separators: $v"
		return 1
		;;
	esac
	log_ok "External volume name: $v"
	return 0
}

check_dest_parent() {
	local parent gp
	parent="$(dirname "$DEST")"
	if [ -d "$parent" ] && [ -w "$parent" ]; then
		log_ok "Install parent writable: $parent"
		return 0
	fi
	# e.g. ~/Library/Application Support may exist but parent of *that* is ~/Library
	gp="$(dirname "$parent")"
	if [ -d "$gp" ] && [ -w "$gp" ]; then
		log_ok "Can create install path (writable: $gp → $(basename "$parent")/…)"
		return 0
	fi
	if [ ! -d "$parent" ] && [ ! -d "$gp" ]; then
		log_fail "Parent directories do not exist: $parent"
		return 1
	fi
	log_fail "Install path not writable (check permissions): $parent"
	return 1
}

volume_present_warning() {
	local v="$1"
	if [ -d "/Volumes/$v" ]; then
		log_ok "Drive currently visible at /Volumes/$v"
	else
		log_warn "Drive not mounted now at /Volumes/$v (normal if unplugged). LaunchAgent will mount at login when it appears."
	fi
}

read_keychain_service_from_config() {
	local cfg="$1"
	(
		set +u
		# shellcheck disable=1090
		source "$cfg" 2>/dev/null || exit 1
		printf '%s' "${RCLONE_CONFIG_KEYCHAIN_SERVICE:-}"
	)
}

read_keychain_account_from_config() {
	local cfg="$1"
	(
		set +u
		# shellcheck disable=1090
		source "$cfg" 2>/dev/null || exit 1
		printf '%s' "${RCLONE_CONFIG_KEYCHAIN_ACCOUNT:-}"
	)
}

# Store rclone config encryption master password in macOS Keychain (same lookup as mount_onedrive.sh).
prompt_and_store_rclone_keychain_password() {
	local cfg="$1"
	local svc acct acct_use p1 p2

	svc="$(read_keychain_service_from_config "$cfg")" || {
		log_fail "Could not read $cfg for Keychain settings."
		return 1
	}
	if [ -z "$svc" ]; then
		log_ok "Keychain password step skipped (set RCLONE_CONFIG_KEYCHAIN_SERVICE in config.sh to enable)."
		return 0
	fi

	if [ "$SKIP_KEYCHAIN" -eq 1 ]; then
		log_warn "Keychain password step skipped (--skip-keychain). Add the password yourself; see README."
		return 0
	fi

	if [ ! -t 0 ]; then
		log_warn "Keychain: stdin is not a TTY — skipping interactive password. Run install in Terminal or use security add-generic-password manually."
		return 0
	fi

	if ! command -v security >/dev/null 2>&1; then
		log_fail "security(1) not found."
		return 1
	fi

	acct="$(read_keychain_account_from_config "$cfg")"
	acct_use="${acct:-$USER}"

	echo ""
	echo "Encrypted rclone.conf: store the master password in your login Keychain."
	echo "  Service: $svc"
	echo "  Account: $acct_use"
	echo ""

	read -r -s -p "Enter rclone config encryption password: " p1 || true
	echo ""
	read -r -s -p "Confirm password: " p2 || true
	echo ""

	if [ "$p1" != "$p2" ]; then
		log_fail "Passwords do not match."
		unset p1 p2
		return 1
	fi
	if [ -z "$p1" ]; then
		log_fail "Password is empty."
		unset p1 p2
		return 1
	fi

	echo ""
	echo "Saving to your login Keychain via macOS \`security\` (service: $svc)…"
	echo "If you see more prompts (e.g. \"password data for new item\" / \"retype\"), that is"
	echo "Keychain confirming the stored secret — not this installer asking again by mistake."
	echo ""

	# Probe once, then add OR update once. (Trying add then add -U caused two security(1) flows and extra prompts.)
	local keychain_exists=0
	if security find-generic-password -a "$acct_use" -s "$svc" >/dev/null 2>&1; then
		keychain_exists=1
	fi

	# security -w reads a password *line* from stdin; without a trailing newline it may read
	# nothing and fall back to interactive "password data for new item" / "retype" prompts.
	if [ "$keychain_exists" -eq 1 ]; then
		if printf '%s\n' "$p1" | security add-generic-password -a "$acct_use" -s "$svc" -U -w; then
			log_ok "Keychain: updated password for service '$svc'."
		else
			log_fail "security add-generic-password -U failed. Remove any conflicting item in Keychain Access or fix permissions."
			unset p1 p2
			return 1
		fi
	else
		if printf '%s\n' "$p1" | security add-generic-password -a "$acct_use" -s "$svc" -w; then
			log_ok "Keychain: saved password for service '$svc' (new item)."
		else
			log_fail "security add-generic-password failed. Remove any conflicting item in Keychain Access or fix permissions."
			unset p1 p2
			return 1
		fi
	fi

	unset p1 p2
	return 0
}

write_plist_xml() {
	export INSTALL_PLIST_OUT="$1"
	export INSTALL_PLIST_LABEL="$LABEL"
	export INSTALL_LAUNCHD_SCRIPT="$2"
	export INSTALL_VOLUME="$3"
	/usr/bin/python3 <<'PY'
import os
import plistlib

out = os.environ["INSTALL_PLIST_OUT"]
label = os.environ["INSTALL_PLIST_LABEL"]
startup = os.environ["INSTALL_LAUNCHD_SCRIPT"]
volume = os.environ["INSTALL_VOLUME"]

pl = {
    "Label": label,
    "ProgramArguments": ["/bin/bash", startup, volume],
    "RunAtLoad": True,
    "EnvironmentVariables": {
        "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
        "STARTUP_MOUNT_DELAY_SEC": "10",
    },
    "StandardOutPath": "/tmp/rclone-onedrive-mount.log",
    "StandardErrorPath": "/tmp/rclone-onedrive-mount.err",
    "KeepAlive": False,
}
with open(out, "wb") as f:
    plistlib.dump(pl, f, fmt=plistlib.FMT_XML)
PY
}

generate_and_lint_plist() {
	local tmp="$1"
	local launchd_script="$2"
	local volume="$3"
	write_plist_xml "$tmp" "$launchd_script" "$volume"
	if ! plutil -lint "$tmp" >/dev/null; then
		log_fail "Generated plist failed plutil -lint"
		plutil -lint "$tmp" || true
		return 1
	fi
	log_ok "Generated plist validates with plutil."
	return 0
}

run_dry_run() {
	echo ""
	echo "=== Dry-run: rclone-onedrive-setup ==="
	echo "No files will be copied and launchd will not be changed."
	echo ""

	local err=0
	local skip_ev=0
	[ -n "$VOLUME_OVERRIDE" ] && skip_ev=1

	require_darwin || err=1
	check_tools || err=1
	check_src_layout || err=1
	check_symlinks_in_tree "$SRC" "source tree" || err=1
	check_shell_alias_targets "$SRC" "source tree" || err=1
	if [ "$err" -eq 0 ] && ! validate_config_sh "$SRC/config.sh" "$skip_ev"; then
		err=1
	fi
	check_dest_parent || err=1

	local vol
	vol="$(resolve_volume)"
	if ! validate_volume "$vol"; then
		err=1
	else
		volume_present_warning "$vol"
	fi

	local ksvc
	ksvc="$(read_keychain_service_from_config "$SRC/config.sh" 2>/dev/null || true)"
	if [ -n "$ksvc" ]; then
		if [ "$SKIP_KEYCHAIN" -eq 1 ]; then
			log_ok "Keychain: real install would skip the password prompt (--skip-keychain)."
		else
			echo "Keychain: real install would prompt for the rclone config encryption password and run security add-generic-password (service: $ksvc)."
		fi
	else
		log_ok "Keychain: real install would not prompt (RCLONE_CONFIG_KEYCHAIN_SERVICE empty in config.sh)."
	fi

	local launchd_script="${DEST}/startup_mount_onedrive.sh"
	local mount_script="${DEST}/mount_onedrive.sh"
	echo ""
	echo "Planned install directory: $DEST"
	echo "Planned LaunchAgent plist:  $PLIST_PATH"
	echo "Planned login command:       /bin/bash $launchd_script $vol  (sleeps 10s, then $mount_script)"
	echo ""
	echo "Files to sync (rsync excludes: .git, .DS_Store, *.swp, .cursor):"
	echo "  Source: $SRC/"
	echo "  Dest:   $DEST/"
	echo ""

	if [ "$err" -eq 0 ]; then
		local tmp
		tmp="$(mktemp -t rclone-onedrive-plist.XXXXXX.plist)"
		if generate_and_lint_plist "$tmp" "$launchd_script" "$vol"; then
			log_ok "Dry-run plist XML is valid."
		else
			err=1
		fi
		rm -f "$tmp"
	fi

	echo ""
	if [ "$err" -eq 0 ]; then
		echo "========== Dry-run summary (nothing was written) =========="
		echo ""
		echo "Symlinks in the source tree were checked above (dangling symlinks would have failed)."
		echo "Shell hook targets (install.sh, mount_onedrive.sh, rclone_resolve.sh, unmount_onedrive.sh, login.sh, logout.sh, check_rclone_config.sh, reset_rclone_config.sh) were checked in the source tree."
		echo ""
		echo "Would rsync from:"
		echo "    $SRC/"
		echo "Would install to:"
		echo "    $DEST/"
		echo "Would write plist:"
		echo "    $PLIST_PATH"
		echo "Would ensure directory:"
		echo "    ${HOME}/Library/LaunchAgents/"
		echo "Would append shell helper functions to:"
		echo "    ${HOME}/.zshrc"
		echo "    ${HOME}/.bash_profile"
		echo "    (install_rclone_ondrive, mount_rclone_ondrive, unmount_rclone_onedrive, login_rclone_ondrive, logout_rclone_onedrive, check_rclone_ondrive, reset_rclone_ondrive, uninstall_rclone_onedrive)"
		echo ""
		if [ -n "${ksvc:-}" ]; then
			if [ "$SKIP_KEYCHAIN" -eq 1 ]; then
				echo "Keychain: skipped (--skip-keychain)."
			else
				echo "Would prompt for rclone encryption password → Keychain (service: $ksvc)."
			fi
		else
			echo "Keychain: no prompt (set RCLONE_CONFIG_KEYCHAIN_SERVICE to enable)."
		fi
		echo ""
		echo "Files that would be copied (same layout as after real install):"
		find "$SRC" -type f \
			! -path '*/.git/*' \
			! -path '*/.cursor/*' \
			! -name '.DS_Store' \
			! -name '*.swp' 2>/dev/null |
			LC_ALL=C sort | sed "s|^$SRC/|$DEST/|" | sed 's/^/    /'
		echo ""
		echo "LaunchAgent would run at login:"
		echo "    /bin/bash $launchd_script $vol"
		echo "    (STARTUP_MOUNT_DELAY_SEC=10, then mount_onedrive.sh)"
		echo ""
		echo "==========================================================="
		echo "Dry-run OK. Run without --dry-run to install."
	else
		echo "Dry-run finished with errors. Fix the issues above before installing."
	fi
	return "$err"
}

# Remove marked blocks written by this installer (aliases now; legacy PATH blocks from older installs).
remove_rclone_setup_shell_hooks_from_file() {
	local f="$1"
	[ -f "$f" ] || return 0
	if grep -qF 'rclone-onedrive-setup aliases (install.sh)' "$f" 2>/dev/null; then
		sed -i '' "/^# >>> rclone-onedrive-setup aliases (install.sh) >>>\$/,/^# <<< rclone-onedrive-setup aliases <<<\$/d" "$f"
	fi
	if grep -qF 'rclone-onedrive-setup PATH (install.sh)' "$f" 2>/dev/null; then
		sed -i '' "/^# >>> rclone-onedrive-setup PATH (install.sh) >>>\$/,/^# <<< rclone-onedrive-setup PATH <<<\$/d" "$f"
	fi
}

remove_shell_alias_hooks() {
	local f
	for f in "${HOME}/.zshrc" "${HOME}/.bash_profile"; do
		remove_rclone_setup_shell_hooks_from_file "$f"
	done
}

# Single-quote a string for safe embedding in shell rc (handles spaces and ' in paths).
shell_single_quote() {
	printf "'"
	printf '%s' "$1" | sed "s/'/'\\\\''/g"
	printf "'"
}

# Shell functions (not aliases: zsh splits alias values at spaces, breaking paths under Application Support).
install_shell_alias_hooks() {
	local dest="$1"
	local f

	for f in "${HOME}/.zshrc" "${HOME}/.bash_profile"; do
		touch "$f"
		remove_rclone_setup_shell_hooks_from_file "$f"
		{
			echo "$ALIAS_HOOK_BEGIN"
			echo "install_rclone_ondrive() { command $(shell_single_quote "${dest}/install.sh") \"\$@\"; }"
			echo "mount_rclone_ondrive() { command $(shell_single_quote "${dest}/mount_onedrive.sh") \"\$@\"; }"
			echo "unmount_rclone_onedrive() { command $(shell_single_quote "${dest}/unmount_onedrive.sh") \"\$@\"; }"
			echo "login_rclone_ondrive() { command $(shell_single_quote "${dest}/login.sh") \"\$@\"; }"
			echo "logout_rclone_onedrive() { command $(shell_single_quote "${dest}/logout.sh") \"\$@\"; }"
			echo "check_rclone_ondrive() { command $(shell_single_quote "${dest}/check_rclone_config.sh") \"\$@\"; }"
			echo "reset_rclone_ondrive() { command $(shell_single_quote "${dest}/reset_rclone_config.sh") \"\$@\"; }"
			echo "uninstall_rclone_onedrive() { command $(shell_single_quote "${dest}/install.sh") --uninstall \"\$@\"; }"
			echo "$ALIAS_HOOK_END"
			echo ""
		} >>"$f"
		log_ok "Shell helper functions appended: $f"
	done
}

print_install_summary() {
	local dest="$1"
	local plist="$2"
	local launchd_script="$3"
	local mount_script="$4"
	local vol="$5"
	local label="$6"

	echo ""
	echo "========== Install summary =========="
	echo ""
	echo "Install directory (rsync target):"
	echo "    $dest"
	echo ""
	echo "Paths touched / written:"
	echo "    • $dest/"
	echo "    • $plist"
	echo "    • ${HOME}/Library/LaunchAgents/  (directory ensured)"
	echo "    • ${HOME}/.zshrc  (shell helpers — see below)"
	echo "    • ${HOME}/.bash_profile  (same, for bash login shells)"
	echo ""
	echo "Shell helpers (functions; after source or new terminal):"
	echo "    install_rclone_ondrive    → ${dest}/install.sh"
	echo "    mount_rclone_ondrive      → ${dest}/mount_onedrive.sh"
	echo "    unmount_rclone_onedrive   → ${dest}/unmount_onedrive.sh"
	echo "    login_rclone_ondrive      → ${dest}/login.sh"
	echo "    logout_rclone_onedrive    → ${dest}/logout.sh"
	echo "    check_rclone_ondrive      → ${dest}/check_rclone_config.sh"
	echo "    reset_rclone_ondrive      → ${dest}/reset_rclone_config.sh"
	echo "    uninstall_rclone_onedrive → ${dest}/install.sh --uninstall"
	echo "    In this session run:  source ~/.zshrc   # or ~/.bash_profile"
	echo ""
	echo "Files installed under install directory:"
	if [ -d "$dest" ]; then
		find "$dest" -type f 2>/dev/null | LC_ALL=C sort | sed 's/^/    /'
	else
		echo "    (directory missing — unexpected)"
	fi
	echo ""
	echo "LaunchAgent:"
	echo "    Label:           $label"
	echo "    Domain:          gui/$(id -u)"
	echo "    Runs at login:   /bin/bash $launchd_script $vol"
	echo "                     (waits STARTUP_MOUNT_DELAY_SEC, default 10s, then $mount_script)"
	echo ""
	echo "Log files (stdout/stderr from mount at login):"
	echo "    /tmp/rclone-onedrive-mount.log"
	echo "    /tmp/rclone-onedrive-mount.err"
	echo ""
	echo "Try a mount now (after source, or use full path):"
	echo "    mount_rclone_ondrive $vol"
	echo "    login_rclone_ondrive      # uses EXTERNAL_VOLUME_NAME from config.sh"
	echo "    # or: $mount_script $vol  (LaunchAgent uses $launchd_script)"
	echo ""
	local ksvc_sum
	if ksvc_sum="$(read_keychain_service_from_config "$dest/config.sh" 2>/dev/null)" && [ -n "$ksvc_sum" ]; then
		echo "Keychain: mount_onedrive.sh will read the encryption password using service '$ksvc_sum' (see RCLONE_CONFIG_KEYCHAIN_* in config.sh)."
	fi
	echo ""
	echo "====================================="
}

do_uninstall() {
	echo "Uninstalling LaunchAgent and $DEST ..."
	if launchctl print "gui/$(id -u)/${LABEL}" >/dev/null 2>&1; then
		launchctl bootout "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null || true
		log_ok "LaunchAgent unloaded (if it was loaded)."
	fi
	rm -f "$PLIST_PATH"
	log_ok "Removed plist: $PLIST_PATH"
	remove_shell_alias_hooks
	log_ok "Removed shell helper block (and legacy PATH hooks) from ~/.zshrc and ~/.bash_profile (if present)."
	if [ -d "$DEST" ]; then
		rm -rf "$DEST"
		log_ok "Removed install directory: $DEST"
	fi
	echo "Uninstall complete."
}

do_install() {
	local skip_ev=0
	[ -n "$VOLUME_OVERRIDE" ] && skip_ev=1

	require_darwin || exit 1
	check_tools || exit 1
	check_src_layout || exit 1
	check_symlinks_in_tree "$SRC" "source tree" || exit 1
	validate_config_sh "$SRC/config.sh" "$skip_ev" || exit 1
	check_dest_parent || exit 1

	local vol
	vol="$(resolve_volume)"
	validate_volume "$vol" || exit 1

	echo ""
	echo "Installing to: $DEST"
	mkdir -p "$DEST"

	rsync -a \
		--exclude '.git' \
		--exclude '.DS_Store' \
		--exclude '*.swp' \
		--exclude '.cursor' \
		"$SRC/" "$DEST/"

	check_symlinks_in_tree "$DEST" "install directory" || exit 1

	chmod +x "$DEST/mount_onedrive.sh" "$DEST/startup_mount_onedrive.sh" "$DEST/unmount_onedrive.sh" "$DEST/login.sh" "$DEST/logout.sh" "$DEST/check_rclone_config.sh" "$DEST/reset_rclone_config.sh" "$DEST/install.sh" "$DEST/setup_rclone_encryption_keychain.sh" 2>/dev/null || true

	if [ ! -f "$DEST/config.sh" ]; then
		if [ -f "$SRC/config.sh" ]; then
			cp "$SRC/config.sh" "$DEST/config.sh"
			log_ok "Copied config.sh from source."
		else
			cp "$DEST/config.example.sh" "$DEST/config.sh"
			log_warn "Created config.sh from config.example.sh — edit EXTERNAL_VOLUME_NAME and OneDrive paths in $DEST/config.sh"
		fi
	fi

	validate_config_sh "$DEST/config.sh" "$skip_ev" || exit 1

	if [ -z "$VOLUME_OVERRIDE" ]; then
		vol="$(read_volume_from_config "$DEST/config.sh")"
		validate_volume "$vol" || exit 1
	fi

	prompt_and_store_rclone_keychain_password "$DEST/config.sh" || exit 1

	local launchd_script="${DEST}/startup_mount_onedrive.sh"
	local mount_script="${DEST}/mount_onedrive.sh"
	mkdir -p "${HOME}/Library/LaunchAgents"

	local tmp
	tmp="$(mktemp -t rclone-onedrive-plist.XXXXXX.plist)"
	export INSTALL_PLIST_OUT="$tmp"
	if ! generate_and_lint_plist "$tmp" "$launchd_script" "$vol"; then
		rm -f "$tmp"
		exit 1
	fi
	mv "$tmp" "$PLIST_PATH"
	log_ok "Installed plist: $PLIST_PATH"

	# Reload agent
	if launchctl print "gui/$(id -u)/${LABEL}" >/dev/null 2>&1; then
		launchctl bootout "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null || true
	fi
	if launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null; then
		log_ok "LaunchAgent registered (bootstrap gui/$(id -u))."
	else
		# Older macOS
		if launchctl load "$PLIST_PATH" 2>/dev/null; then
			log_ok "LaunchAgent registered (load)."
		else
			log_warn "Could not bootstrap/load automatically. Try: launchctl bootstrap gui/$(id -u) $PLIST_PATH"
		fi
	fi

	check_shell_alias_targets "$DEST" "install directory" || exit 1

	install_shell_alias_hooks "$DEST"

	print_install_summary "$DEST" "$PLIST_PATH" "$launchd_script" "$mount_script" "$vol" "$LABEL"
}

# ---- main ----

if [ "$UNINSTALL" -eq 1 ]; then
	if [ "$DRY_RUN" -eq 1 ]; then
		echo "Dry-run with --uninstall is not supported." >&2
		exit 1
	fi
	do_uninstall
	exit 0
fi

if [ "$DRY_RUN" -eq 1 ]; then
	run_dry_run
	exit $?
fi

do_install
