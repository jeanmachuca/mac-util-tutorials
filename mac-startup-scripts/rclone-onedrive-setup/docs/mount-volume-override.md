# Optional `MOUNT_VOLUME_OVERRIDE`

`config.sh` can define **`MOUNT_VOLUME_OVERRIDE`** as a **bash array** with the **same length** as **`REMOTE_PATHS`**, **`LOCAL_NAMES`**, and **`CACHE_MAX_SIZE`**.

For each index **`i`**:

- **`MOUNT_VOLUME_OVERRIDE[i]`** empty (`""`) → that mount uses the **default volume** passed to **`mount_onedrive.sh`** (same as **`EXTERNAL_VOLUME_NAME`** when you use **`login.sh`** / LaunchAgent).
- **`MOUNT_VOLUME_OVERRIDE[i]`** non-empty → that row is mounted under:

  **`/Volumes/<override>/OneDrive/<LOCAL_NAMES[i]>/`**

  instead of **`/Volumes/<default>/OneDrive/...`**.

So you can split **different OneDrive folders** onto **different disks or partitions** (for example **APFS** for one tree and **exFAT** for the rest) while keeping **one `config.sh`** and **one** `rclone` remote.

## When this is useful

- **Mixed filesystems on one physical disk** — e.g. a small **APFS** volume for paths that need **macOS-native** behavior (metadata, bundles) and a large **exFAT** volume for cross-platform bulk storage and other mounts (see [apfs-cache-partition-exfat-example.md](apfs-cache-partition-exfat-example.md) for cache layout; this doc is about **where the FUSE mount points live**, not only cache). A **three-volume** layout (exFAT + APFS work + APFS cache) is sketched in [external-disk-exfat-apfs-work-cache-example.md](external-disk-exfat-apfs-work-cache-example.md).
- **Multiple external volumes** — e.g. **`EXT1TB`** for most mounts and **`VideoSSD`** for a heavy **video** folder, all in one config.
- **Same machine, different disks** — default argument to **`mount_onedrive.sh`** is still the “main” volume; overrides pick **other** `/Volumes/...` names when needed.

## Requirements

1. **Every** override volume that appears in **`MOUNT_VOLUME_OVERRIDE`** must **exist** under **`/Volumes/`** before **`mount_onedrive.sh`** runs (disk plugged in, volume mounted).
2. **`CACHE_DIR`**, if set, remains **global**: all mounts still share that **`--cache-dir`** unless you change the scripts.
3. **`unmount_onedrive.sh`** reads **`config.sh`**, unmounts **each configured target path**, **`pkill`s** `rclone` per involved volume, then **`diskutil eject`s each distinct** data volume used (unless **`--no-eject`**). Pass the **same default `<DriveName>`** you use with **`mount_onedrive.sh`** (rows with `""` use that name).

## Edge cases

| Situation | Note |
|-----------|------|
| **Duplicate `LOCAL_NAMES` on the same volume** | Two rows with the same **`LOCAL_NAMES`** entry and the **same** resolved volume → **same mountpoint**; the second mount would **collide** with the first. Use **unique** folder names per volume, or different volumes. |
| **Finder / favorites** | Each row may point to a **different** `/Volumes/...` path; sidebar shortcuts must match **actual** paths after mount. |
| **`--no-eject` with multiple data volumes** | Skips **all** `diskutil eject` calls; eject manually when appropriate. |
| **Ejecting one partition removes the whole USB disk** | On some enclosures, **`diskutil eject`** on the first volume **unmounts the entire device**, so **`/Volumes/<other>`** disappears before the script reaches it. **`unmount_onedrive.sh`** then **skips** eject for paths that are **already gone** (not an error). |
| **LaunchAgent** | Still passes **one** volume name (usually **`EXTERNAL_VOLUME_NAME`**); overrides in **`MOUNT_VOLUME_OVERRIDE`** do **not** change that argument—they only change **which rows** use other volumes. |

## Omitting the array (backward compatible)

If **`MOUNT_VOLUME_OVERRIDE`** is **missing** or **empty**, the scripts behave as before: **all** mounts use **only** the **`DriveName`** argument to **`mount_onedrive.sh`**.
