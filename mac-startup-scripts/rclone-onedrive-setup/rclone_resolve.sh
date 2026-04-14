# shellcheck shell=bash
# Source after config.sh (when present). Sets RCLONE to the full path used to run rclone.
# Optional in config.sh: RCLONE_BIN="/path/to/rclone" if PATH is wrong (e.g. under launchd).
# Otherwise uses the same resolution as `command -v rclone` (prefer this over `which` in scripts).

set_rclone_executable() {
	if [ -n "${RCLONE_BIN:-}" ]; then
		if [ ! -x "$RCLONE_BIN" ]; then
			echo "Error: RCLONE_BIN is not an executable file: $RCLONE_BIN" >&2
			return 1
		fi
		RCLONE="$RCLONE_BIN"
		export RCLONE
		return 0
	fi
	local cand
	cand="$(command -v rclone 2>/dev/null || true)"
	if [ -n "$cand" ] && [ -x "$cand" ]; then
		RCLONE="$cand"
		export RCLONE
		return 0
	fi
	echo "Error: rclone not on PATH (command -v rclone). Install it or set RCLONE_BIN in config.sh." >&2
	return 1
}
