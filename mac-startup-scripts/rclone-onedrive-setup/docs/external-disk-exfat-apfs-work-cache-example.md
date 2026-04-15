# Example: exFAT bulk + APFS work volume + APFS cache (one external disk)

This describes a **single external SSD** (for example **1 TB** USB or NVMe) divided into **three** separate volumes—typical when you want **cross-platform exFAT** for most cloud-backed paths, a **dedicated APFS volume** for one or more OneDrive folders that benefit from **APFS semantics**, and a **dedicated APFS cache** for **`rclone`** (see also [apfs-cache-partition-exfat-example.md](apfs-cache-partition-exfat-example.md) for cache-only splits).

Names below are **placeholders**—use your own Finder volume names.

| Volume (example name) | Size (example) | Format | Role |
|----------------------|----------------|--------|------|
| **BulkExFAT** | ~650 GB | **exFAT** | Default **`rclone mount`** targets: `/Volumes/BulkExFAT/OneDrive/…` — good for **Windows** access and large bulk trees. |
| **WorkAPFS** | ~250 GB | **APFS** | Optional **per-row** data volume via **`MOUNT_VOLUME_OVERRIDE`** for folders where **APFS** on the host is preferable to exFAT (metadata-heavy workflows, macOS-first trees). Still **cloud-backed** via **`rclone`**; not a substitute for a **local-only** pro-app library unless you design it that way. |
| **RcloneCache** | ~100 GB | **APFS** | **`CACHE_DIR` only** — VFS cache and metadata; same role as in the two-partition doc. |

Together: **two data-capable volumes** (exFAT + APFS “work”) plus **one cache-only** APFS volume.

## Why three volumes?

- **exFAT** stays the **default** (**`EXTERNAL_VOLUME_NAME`** / argument to **`mount_onedrive.sh`**) for **most** **`REMOTE_PATHS`** rows (**`MOUNT_VOLUME_OVERRIDE`** empty).
- **WorkAPFS** holds **selected** mount points (**`MOUNT_VOLUME_OVERRIDE`** = `WorkAPFS` for those rows) so their FUSE paths live on **APFS** while the rest stay on **exFAT**.
- **RcloneCache** isolates **cache churn** and caps footprint on a **small** APFS slice.

## Disk Utility

Use **Partition** on the **physical** disk when you need **different formats** (exFAT vs APFS) on the **same** device. **Add Volume** inside one APFS container only adds more **APFS** volumes sharing that container’s pool—it does **not** create an **exFAT** slice next to APFS.

After setup you should see three mount points, for example:

```text
/Volumes/BulkExFAT      ← exFAT: default OneDrive mounts
/Volumes/WorkAPFS       ← APFS: override rows only
/Volumes/RcloneCache    ← APFS: --cache-dir only
```

Create **`BulkExFAT/OneDrive`** and **`WorkAPFS/OneDrive`** as needed (folders) before or on first mount; **`mount_onedrive.sh`** runs **`mkdir -p`** on each target path.

## `config.sh` sketch (generic)

```bash
REMOTE_NAME="onedrive"
EXTERNAL_VOLUME_NAME="BulkExFAT"
CACHE_DIR="/Volumes/RcloneCache"

REMOTE_PATHS=(
  "Projects"
  "Media"
  "Deliverables"
)

LOCAL_NAMES=(
  "Projects"
  "Media"
  "Deliverables"
)

CACHE_MAX_SIZE=(
  "20G"
  "40G"
  "15G"
)

# "" = use BulkExFAT; one row can use WorkAPFS for that tree only
MOUNT_VOLUME_OVERRIDE=(
  ""
  "WorkAPFS"
  ""
)
```

Mount with:

```bash
./mount_onedrive.sh BulkExFAT
```

**`unmount_onedrive.sh BulkExFAT`** tears down **all** configured targets and **ejects each distinct** volume used (**BulkExFAT**, **WorkAPFS**, and any others in **`MOUNT_VOLUME_OVERRIDE`**). **`RcloneCache`** is ejected too if it was mounted as a separate volume—use **`--no-eject`** if you need volumes left mounted.

## Caveats

- **Same USB/NVMe link** for all three: throughput is **shared**; this layout optimizes **filesystem fit** and **roles**, not raw bandwidth.
- **`CACHE_MAX_SIZE`**: keep the **sum** of caps within **RcloneCache** size with **headroom** ([Cache max size treatment](apfs-cache-partition-exfat-example.md#cache-max-size-treatment)).

<a id="fcp-libraries-vs-onedrive-mount"></a>

### Final Cut Pro, consolidated libraries, and “live in the cloud”

A path like **`/Volumes/WorkAPFS/OneDrive/…`** is still a **`rclone mount`** (FUSE → OneDrive), even though **WorkAPFS** is a **real APFS** partition. The **partition format** does **not** turn that folder into plain local disk for apps that expect **local** semantics (heavy metadata, databases, tight I/O).

- **Do not** place an **open** **Final Cut Pro** library (including **consolidated** libraries) **under** **`…/OneDrive/…`** on any override volume if you want stable behavior—FCP can **hang** or misbehave there.
- **Do** keep **active** **`.fcpbundle`** trees on the **same** APFS work volume **beside** `OneDrive`, e.g. **`/Volumes/WorkAPFS/Final Cut Libraries/MyProject.fcpbundle`** — native APFS for the bundle, **no** `rclone` in that path.
- **“Consolidated in the cloud”** is still realistic: **quit FCP**, then **`rclone copy`** (or Finder copy to a mounted OneDrive folder) the **closed** library to OneDrive for **archive / backup**. You are not editing from the cloud path; you are **publishing** a **point-in-time** consolidated bundle there.

The same distinction applies to other **pro-app bundles** you would avoid on a **network** mount: keep **live** projects **outside** **`…/OneDrive/…`** on **native** APFS; use **`rclone`** paths under **`OneDrive/`** for **ingest, delivery, and archived copies** only.

This edge case is also summarized in **[mount-volume-override.md](mount-volume-override.md)**.

## See also

- **[mount-volume-override.md](mount-volume-override.md)** — semantics of **`MOUNT_VOLUME_OVERRIDE`**.
- **[apfs-cache-partition-exfat-example.md](apfs-cache-partition-exfat-example.md)** — **two-partition** exFAT + APFS cache (simpler layout without a separate “work” APFS data volume).
