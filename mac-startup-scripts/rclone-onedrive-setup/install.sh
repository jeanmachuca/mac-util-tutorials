#!/bin/bash
# Install rclone-onedrive-setup to ~/Library/Application Support/ and register a LaunchAgent.
# Usage:
#   ./install.sh              # install (requires config.sh with EXTERNAL_VOLUME_NAME)
#   ./install.sh --dry-run      # verify only; no copies, no launchctl
#   ./install.sh --uninstall    # remove LaunchAgent and install directory
#   ./install.sh --dest PATH    # override install directory (default: Application Support path below)
#   ./install.sh --label ID     # LaunchAgent label (default: com.rclone-onedrive.mount)
#   ./install.sh MyVolume       # override volume name for this run (else uses EXTERNAL_VOLUME_NAME from config.sh)

set -euo pipefail

readonly DEFAULT_LABEL="com.rclone-onedrive.mount"
readonly DEFAULT_DEST="${HOME}/Library/Application Support/rclone-onedrive-setup"
readonly ALIAS_HOOK_BEGIN='# >>> rclone-onedrive-setup aliases (install.sh) >>>'
readonly ALIAS_HOOK_END='# <<< rclone-onedrive-setup aliases <<<'

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN=0
UNINSTALL=0
DEST="$DEFAULT_DEST"
LABEL="$DEFAULT_LABEL"
VOLUME_OVERRIDE=""

usage() {
	sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
	exit 0
}

while [ $# -gt 0 ]; do
	case "$1" in
	--dry-run) DRY_RUN=1 ;;
	--uninstall) UNINSTALL=1 ;;
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
	for f in mount_onedrive.sh unmount_onedrive.sh config.example.sh; do
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

write_plist_xml() {
	export INSTALL_PLIST_OUT="$1"
	export INSTALL_PLIST_LABEL="$LABEL"
	export INSTALL_MOUNT_SCRIPT="$2"
	export INSTALL_VOLUME="$3"
	/usr/bin/python3 <<'PY'
import os
import plistlib

out = os.environ["INSTALL_PLIST_OUT"]
label = os.environ["INSTALL_PLIST_LABEL"]
mount = os.environ["INSTALL_MOUNT_SCRIPT"]
volume = os.environ["INSTALL_VOLUME"]

pl = {
    "Label": label,
    "ProgramArguments": ["/bin/bash", mount, volume],
    "RunAtLoad": True,
    "EnvironmentVariables": {
        "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
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
	local mount_script="$2"
	local volume="$3"
	write_plist_xml "$tmp" "$mount_script" "$volume"
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

	local mount_script="${DEST}/mount_onedrive.sh"
	echo ""
	echo "Planned install directory: $DEST"
	echo "Planned LaunchAgent plist:  $PLIST_PATH"
	echo "Planned mount command:       /bin/bash $mount_script $vol"
	echo ""
	echo "Files to sync (rsync excludes: .git, .DS_Store, *.swp, .cursor):"
	echo "  Source: $SRC/"
	echo "  Dest:   $DEST/"
	echo ""

	if [ "$err" -eq 0 ]; then
		local tmp
		tmp="$(mktemp -t rclone-onedrive-plist.XXXXXX.plist)"
		if generate_and_lint_plist "$tmp" "$mount_script" "$vol"; then
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
		echo "Would rsync from:"
		echo "    $SRC/"
		echo "Would install to:"
		echo "    $DEST/"
		echo "Would write plist:"
		echo "    $PLIST_PATH"
		echo "Would ensure directory:"
		echo "    ${HOME}/Library/LaunchAgents/"
		echo "Would append shell aliases to:"
		echo "    ${HOME}/.zshrc"
		echo "    ${HOME}/.bash_profile"
		echo "    (install_rclone_ondrive, mount_rclone_ondrive, unmount_rclone_onedrive, uninstall_rclone_onedrive)"
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
		echo "    /bin/bash $mount_script $vol"
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

# Shell aliases so script names do not clutter PATH (replaced on reinstall; strips legacy PATH hook).
install_shell_alias_hooks() {
	local dest="$1"
	local f

	for f in "${HOME}/.zshrc" "${HOME}/.bash_profile"; do
		touch "$f"
		remove_rclone_setup_shell_hooks_from_file "$f"
		{
			echo "$ALIAS_HOOK_BEGIN"
			echo "alias install_rclone_ondrive=$(shell_single_quote "${dest}/install.sh")"
			echo "alias mount_rclone_ondrive=$(shell_single_quote "${dest}/mount_onedrive.sh")"
			echo "alias unmount_rclone_onedrive=$(shell_single_quote "${dest}/unmount_onedrive.sh")"
			echo "alias uninstall_rclone_onedrive=$(shell_single_quote "${dest}/install.sh --uninstall")"
			echo "$ALIAS_HOOK_END"
			echo ""
		} >>"$f"
		log_ok "Shell aliases appended: $f"
	done
}

print_install_summary() {
	local dest="$1"
	local plist="$2"
	local mount_script="$3"
	local vol="$4"
	local label="$5"

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
	echo "    • ${HOME}/.zshrc  (aliases — see below)"
	echo "    • ${HOME}/.bash_profile  (same, for bash login shells)"
	echo ""
	echo "Shell aliases (after source or new terminal):"
	echo "    install_rclone_ondrive    → ${dest}/install.sh"
	echo "    mount_rclone_ondrive      → ${dest}/mount_onedrive.sh"
	echo "    unmount_rclone_onedrive   → ${dest}/unmount_onedrive.sh"
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
	echo "    Runs at login:   /bin/bash $mount_script $vol"
	echo ""
	echo "Log files (stdout/stderr from mount at login):"
	echo "    /tmp/rclone-onedrive-mount.log"
	echo "    /tmp/rclone-onedrive-mount.err"
	echo ""
	echo "Try a mount now (after source, or use full path):"
	echo "    mount_rclone_ondrive $vol"
	echo "    # or: $mount_script $vol"
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
	log_ok "Removed shell aliases (and legacy PATH hooks) from ~/.zshrc and ~/.bash_profile (if present)."
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

	chmod +x "$DEST/mount_onedrive.sh" "$DEST/unmount_onedrive.sh" "$DEST/install.sh" 2>/dev/null || true

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

	local mount_script="${DEST}/mount_onedrive.sh"
	mkdir -p "${HOME}/Library/LaunchAgents"

	local tmp
	tmp="$(mktemp -t rclone-onedrive-plist.XXXXXX.plist)"
	export INSTALL_PLIST_OUT="$tmp"
	if ! generate_and_lint_plist "$tmp" "$mount_script" "$vol"; then
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

	install_shell_alias_hooks "$DEST"

	print_install_summary "$DEST" "$PLIST_PATH" "$mount_script" "$vol" "$LABEL"
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
