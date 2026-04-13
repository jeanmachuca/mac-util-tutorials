# Copy this file to config.sh and edit for your account.
#   cp config.example.sh config.sh
#
# List remote folders with:
#   rclone lsd your-remote-name:

REMOTE_NAME="onedrive"

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
