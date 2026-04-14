# Copy this file to config.sh and edit for your account.
#   cp config.example.sh config.sh
#
# List remote folders with:
#   rclone lsd your-remote-name:
#
# Optional: absolute path to rclone if `command -v rclone` fails under launchd. Example:
# RCLONE_BIN="/opt/homebrew/bin/rclone"

REMOTE_NAME="onedrive"

# External disk volume name as shown in Finder / /Volumes/ (required for install.sh + LaunchAgent)
EXTERNAL_VOLUME_NAME="MyPassport"

# Paths on the cloud remote (same names you see in rclone / OneDrive)
REMOTE_PATHS=(
  "Documents"
  "Photos"
)

# Folder names on your external drive under: /Volumes/<DriveName>/OneDrive/
LOCAL_NAMES=(
  "Documents"
  "Photos"
)

# VFS cache cap per mount (e.g. 10G, 500M)
CACHE_MAX_SIZE=(
  "50G"
  "10G"
)

# --- Optional: encrypted rclone.conf + macOS Keychain ---
# If you run: rclone config encryption set
# then rclone needs RCLONE_CONFIG_PASS. Do not put the password in this file.
# Easiest: ./setup_rclone_encryption_keychain.sh  (encrypts + Keychain)
# Integrity: ./check_rclone_config.sh  (verify rclone can read and decrypt ~/.config/rclone/rclone.conf)
# Full reset: ./reset_rclone_config.sh  (remove local rclone.conf; backs up by default — cloud unchanged)
# 1) Set the service name here (must match Keychain). Leave empty to skip Keychain.
# 2) Add the password: run setup_rclone_encryption_keychain.sh, ./install.sh (it prompts), or manually:
#    security add-generic-password -a "$USER" -s "rclone-onedrive-config" -w
#    (put -w last; Terminal prompts — do not paste the password into the command line)
#    Or: ./install.sh --skip-keychain  then add the item yourself.
RCLONE_CONFIG_KEYCHAIN_SERVICE=""
# Optional: Keychain "account" field; must match -a if you used it when adding the item.
# RCLONE_CONFIG_KEYCHAIN_ACCOUNT=""
