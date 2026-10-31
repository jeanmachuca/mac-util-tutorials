# Copy this file to config.sh and edit for your account.
#   cp config.example.sh config.sh
#
# List remote folders with:
#   rclone lsd gdrive:
#
# Optional: absolute path to rclone if `command -v rclone` fails under launchd. Example:
# RCLONE_BIN="/opt/homebrew/bin/rclone"

REMOTE_NAME="gdrive"

# External disk volume name as shown in Finder / /Volumes/ (required for install.sh + LaunchAgent)
EXTERNAL_VOLUME_NAME="MyPassport"

# Paths on the cloud remote (same names you see in rclone / Google Drive)
REMOTE_PATHS=(
  "Documents"
  "Photos"
)

# Folder names on your external drive under: /Volumes/<DriveName>/GoogleDrive/
LOCAL_NAMES=(
  "Documents"
  "Photos"
)

# Optional: per-mount data volume (Finder name under /Volumes/). Same length as REMOTE_PATHS.
# Use "" to use <DriveName> from mount_gdrive.sh / EXTERNAL_VOLUME_NAME for that row.
# Non-empty: mount that row under /Volumes/<name>/GoogleDrive/<LOCAL_NAMES[i]>/
# See docs/mount-volume-override.md (APFS vs exFAT, multiple disks).
# Three-volume example (exFAT + APFS work + APFS cache): docs/external-disk-exfat-apfs-work-cache-example.md
MOUNT_VOLUME_OVERRIDE=(
  ""
  ""
)

# --- Optional: Google Drive Shared Drives ("Team Drives") ---
# Same length as REMOTE_PATHS. Leave "" for rows that live in "My Drive".
# A non-empty value is a Shared Drive ID (not its display name). List IDs with:
#   rclone backend drives gdrive:
# The REMOTE_PATHS entry for that row is then relative to that Shared Drive's root.
# GDRIVE_TEAM_DRIVE=(
#   ""
#   "0AJxxxxxxxxxxxxxxxxx"
# )

# --- Optional: Google Drive "Shared with me" ---
# Same length as REMOTE_PATHS. Use "1" for a row that lives in "Shared with me";
# leave "" otherwise. This passes --drive-shared-with-me for that mount only.
# Mutually exclusive with GDRIVE_TEAM_DRIVE on the same row.
# GDRIVE_SHARED_WITH_ME=(
#   ""
#   ""
# )

# --- Optional: extra rclone flags for every mount (advanced) ---
# One array entry per flag; these are appended to every `rclone mount` command.
# Useful Google Drive examples:
#   GDRIVE_MOUNT_FLAGS=(
#     "--drive-skip-gdocs"          # hide native Google Docs/Sheets/Slides
#     "--drive-export-formats" "pdf" # export Docs as PDF instead of .docx
#     "--tpslimit" "10"              # calm API rate limits with many mounts
#     "--drive-chunk-size" "64M"     # faster large uploads on fast links
#   )
# Do not put --daemon / --no-daemon here; mount_gdrive.sh controls that.
# GDRIVE_MOUNT_FLAGS=()

# VFS cache cap per mount — one value per REMOTE_PATHS/LOCAL_NAMES entry (passed as
# --vfs-cache-max-size). With CACHE_DIR on a small APFS partition, sum of caps should
# fit that volume with headroom. See docs/apfs-cache-partition-exfat-example.md
CACHE_MAX_SIZE=(
  "50G"
  "10G"
)

# Optional: put the VFS cache on another volume (e.g. a small APFS partition on the same
# external disk while Google Drive folders stay on exFAT). See docs/apfs-cache-partition-exfat-example.md
# CACHE_DIR="/Volumes/RcloneCache"

# --- Optional: encrypted rclone.conf + macOS Keychain ---
# If you run: rclone config encryption set
# then rclone needs RCLONE_CONFIG_PASS. Do not put the password in this file.
# Easiest: ./setup_rclone_encryption_keychain.sh  (encrypts + Keychain)
# Integrity: ./check_rclone_config.sh  (verify rclone can read and decrypt ~/.config/rclone/rclone.conf)
# Full reset: ./reset_rclone_config.sh  (remove local rclone.conf; backs up by default — cloud unchanged)
# 1) Set the service name here (must match Keychain). Leave empty to skip Keychain.
# 2) Add the password: run setup_rclone_encryption_keychain.sh, ./install.sh (it prompts), or manually:
#    security add-generic-password -a "$USER" -s "rclone-gdrive-config" -w
#    (put -w last; Terminal prompts — do not paste the password into the command line)
#    Or: ./install.sh --skip-keychain  then add the item yourself.
RCLONE_CONFIG_KEYCHAIN_SERVICE=""
# Optional: Keychain "account" field; must match -a if you used it when adding the item.
# RCLONE_CONFIG_KEYCHAIN_ACCOUNT=""
