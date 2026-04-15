# Example: APFS cache partition + exFAT data on one external disk

This describes a **1 TB** external disk split into:

| Partition | Size   | Format | Role |
|-----------|--------|--------|------|
| **Data**  | ~950 GB | **exFAT** | Cross-platform access; your **`rclone mount`** targets live here under `/Volumes/<DataVolume>/OneDrive/…`. |
| **Cache** | **50 GB** | **APFS** | **rclone VFS cache only** — many small files and churn behave better than on exFAT; keeps cache off the **internal** SSD. |

`rclone` still reads/writes **cloud ↔ cache ↔ FUSE mount** as usual; the **mount points** stay on the **exFAT** volume. Only the **cache directory** is pointed at the **APFS** partition via **`--cache-dir`**.

## Why split the disk this way?

- **exFAT** on the large partition: handy if you also use the disk on **Windows** or need a single shared data volume.
- **APFS** on a small dedicated partition: better fit for the **VFS cache** workload (lots of small files/metadata) than exFAT alone.
- **Bounded cache footprint**: the **50 GB** partition caps how much disk space the cache can occupy on that volume (together with **`--vfs-cache-max-size`** in **`config.sh`**).

## Partitioning (overview)

1. **Back up** anything on the disk you care about. Resizing or repartitioning can erase data if you choose the wrong options.
2. Open **Disk Utility**, select the **physical** disk (not only a volume).
3. Use **Partition** (or **Volume** / **+** depending on macOS version) to create:
   - One volume: **exFAT**, name e.g. `MyPassport` (your **data** volume — this is what you pass to **`mount_onedrive.sh`** and what **`EXTERNAL_VOLUME_NAME`** refers to).
   - One volume: **APFS**, size **50 GB**, name e.g. **`RcloneCache`** (only for cache; Mac-only is fine).

After plugging the disk in, you should see **two** entries under **`/Volumes/`**, for example:

```text
/Volumes/MyPassport      ← exFAT: OneDrive mount targets
/Volumes/RcloneCache     ← APFS: rclone --cache-dir only
```

## `config.sh` settings

1. Set **`EXTERNAL_VOLUME_NAME`** (and the argument to **`mount_onedrive.sh`**) to the **exFAT** data volume name — e.g. **`MyPassport`**, not the cache volume.

2. Set **`CACHE_DIR`** to the **APFS** volume mount point (must match the name in Finder / **`/Volumes/`**):

   ```bash
   CACHE_DIR="/Volumes/RcloneCache"
   ```

3. Set **`CACHE_MAX_SIZE`** (see **[Cache max size treatment](#cache-max-size-treatment)** below).

The installer and **`mount_onedrive.sh`** pass **`--cache-dir "$CACHE_DIR"`** when **`CACHE_DIR`** is set (see **`config.example.sh`**).

### Cache max size treatment

- **One entry per mount:** **`CACHE_MAX_SIZE`** is parallel to **`REMOTE_PATHS`** and **`LOCAL_NAMES`** — same number of entries. Each value is passed to **`rclone mount`** as **`--vfs-cache-max-size`** for **that** mount only (e.g. first row → first remote folder).
- **Small cache partition:** Each cap is an **upper bound** for that mount’s VFS cache, not a pre-allocation. For planning, treat **the sum of all caps** as the **worst-case** stress on the cache volume (rclone also evicts under load, but open files and bursts matter). On a **50 GB** APFS cache volume, keep the **combined** caps **plus headroom** below **50 GB** (for example three mounts at **`15G`** each, not three at **`50G`**).
- **After you change sizes:** Unmount, edit **`config.sh`**, mount again. New caps apply on the **next** start; **existing files** under **`CACHE_DIR`** may remain until **rclone** evicts them under the new limits (they are not the cloud copy).
- **Adding more `LOCAL_NAMES`:** Each extra mount adds **another** cache budget line and more **`vfs/…`** / **`vfsMeta/…`** usage under **`CACHE_DIR`**. Increase **`CACHE_MAX_SIZE`** length accordingly and re-check the **combined** caps against the APFS partition size.

## Order of operations

1. Connect the external disk so **both** volumes mount (data + cache).
2. Run **`./mount_onedrive.sh <DataVolumeName>`** (or your LaunchAgent / **`login.sh`**).

If **`CACHE_DIR`** is under **`/Volumes/`** and that volume is **not** mounted, **`mount_onedrive.sh`** exits with an error instead of creating a stray folder on the system volume — **mount the cache partition first**.

## Caveats

- **Same physical disk**: cache and data still **share** the USB/NVMe bandwidth; this layout mainly helps **filesystem fit**, **cache bounds**, and **sparing internal SSD**, not doubling throughput.
- **Unplugging the disk** while mounts are active is still unsafe — use **`unmount_onedrive.sh`** / **`logout.sh`** first (see README **§6**).

## See also

- **[mount-volume-override.md](mount-volume-override.md)** — put **some** OneDrive mount points on a **different data volume** (e.g. APFS vs exFAT) using **`MOUNT_VOLUME_OVERRIDE`**; that is separate from **`CACHE_DIR`** (cache only).
- **[external-disk-exfat-apfs-work-cache-example.md](external-disk-exfat-apfs-work-cache-example.md)** — **three** volumes on one external disk: **exFAT** default + **APFS** for selected rows + **APFS** cache (generic example names).
