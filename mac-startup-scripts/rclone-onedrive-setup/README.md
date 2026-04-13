# rclone OneDrive on macOS (external drive)

Mount Microsoft OneDrive to folders on an external volume using **rclone** and **macFUSE**, instead of relying on Apple’s OneDrive client.

### What this setup is for

This workflow is aimed at **day-to-day use with large files**—especially **video and audio** (masters, project media, long recordings, music libraries)—where you want OneDrive to show up as **normal folders on an external disk** you can open in **Finder**, **Preview**, **Quick Look**, or **creative apps**, without filling your **internal SSD** with cache and placeholders. It is **not** primarily a “developer stack” tutorial: you do **not** need to be syncing **code repositories** or running **builds** on these mounts for the approach to make sense.

You can still use the same pattern for other big binaries (disk images, archives, datasets). Sections below mention **Docker** and **IDEs** only because those combinations are where **misunderstandings about mounts and disks** often turn into lost work—not because this repo assumes you are coding on the mount.

### A personal note (why this repo exists)

I put this together for my own **day-to-day work with large video and audio** on a Mac, using OneDrive as the backing store but wanting the files to feel like a **normal external disk**—not a sync client that quietly **eats the internal SSD** or behaves oddly under **heavy browsing and big transfers**. Along the way I ran into real friction: **APFS** on that portable drive collided with **permissions and tooling** (including containers), and I learned the hard way how easy it is to **misread where data actually lives** when cloud mounts, Docker, and Finder are all in the mix.

**Rclone on the host**, with **explicit cache limits on the external volume** and a **strict unmount-before-eject habit**, finally matched how I think about “this folder is my drive.” I scrubbed anything specific to my own folders or employer, kept the scripts generic, and published it so anyone facing the same Mac + OneDrive + big files headache has a **straight path** without retracing every dead end I hit.

## Why rclone instead of the official OneDrive app (especially on Mac)?

The official **OneDrive** client on macOS is built for typical “sync my files” use. It integrates through Apple’s **File Provider** stack. That works well for many people, but it creates recurring pain when you work with **very large files on an external volume** (and for some heavy technical workflows: huge folder trees, containers, build tools).

### What goes wrong with the official app on macOS

1. **Internal disk pressure (“Files On-Demand” and local cache)**  
   Even when you *intend* everything to live on an external drive, the client still leans on the **internal SSD**: metadata, placeholders, and downloaded chunks often land under locations such as `~/Library/CloudStorage`. Under load, that can **fill the system volume** while you still think “my data is on the USB disk.” When the internal disk is full, apps fail to save, sync stalls, and you can end up with **incomplete local copies** or **failed operations** that feel like data problems.

2. **Opaque behavior for heavy file access**  
   File Provider–backed folders can be **slower or less predictable** when you browse big trees, scrub timelines, or let apps **watch** folders. That matters for **video/audio pipelines** and asset libraries as much as for code. Rclone exposes OneDrive as a **normal path** you control, with explicit **VFS cache limits** on the volume you choose (here, your external disk), so large reads/writes are easier to reason about than an invisible cache on the system drive.

3. **You choose where the cache lives and how big it is**  
   With `rclone mount` you set **`--vfs-cache-max-size`** (and related flags) so growth is bounded on **your** drive, not an invisible expansion on the internal SSD.

### How people accidentally get hurt (including “data loss” stories)

These are not theoretical edge cases; they show up in real setups:

| Situation | What actually happens |
|-----------|-------------------------|
| **Force-ejecting an external drive** while a cloud filesystem is still mounted | macOS may **force-close** FUSE mounts. You risk **I/O errors**, **corrupted partial writes**, and **ghost processes** still pointing at paths that no longer exist. The cloud copy may still be fine, but **local work in flight** can be damaged or confusing to recover. |
| **Running `rclone mount` only inside Docker Desktop for Mac** and mapping a folder from an external disk into the container | Docker runs in a **Linux VM**. A FUSE mount performed *inside* the container typically lives in that VM’s view of the world. The “files” you see in the container are **not reliably the same as what macOS Finder shows on the physical disk**. People assume “it’s on my external drive,” unplug or eject, and then discover **nothing they expected was persisted on the USB volume**—or they mix up **cloud vs local vs VM**. That mismatch is often described as **data loss**, even when the root cause is **where the bytes were actually written**. |
| **Internal SSD full** because of OneDrive cache | Saves and sync operations fail (including **large media exports** or copies to the “external” location); you may lose time or end up with **incomplete local files** if you do not notice the disk is full. |

**Rclone on the Mac host** (this repo’s approach) addresses the intent: **Finder and your apps see the same mount**, cache limits can target **external storage**, and the provided **`unmount_onedrive.sh`** workflow is meant to **tear down mounts before eject**, reducing the “force eject / corrupt / zombie mount” class of failures.

This is **not** a claim that Microsoft’s client loses cloud data in normal use. It *is* an explanation of why **people who live in large media files on Mac** (and other power users) often prefer rclone: **predictable paths**, **bounded cache on the disk you choose**, and **fewer surprises** when combining OneDrive with **external drives**—including when you also use **developer tools** or **Docker** elsewhere in your workflow.

## Prerequisites

- macOS with administrator access (for macFUSE approval in System Settings)
- An external disk formatted with a macOS-friendly filesystem (commonly **exFAT** for portability and large files)
- A Microsoft account with OneDrive

## 1. Install dependencies

Install in this order.

### Homebrew

If you do not have [Homebrew](https://brew.sh/):

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

### macFUSE

macFUSE provides the kernel interface rclone needs for `rclone mount`:

```bash
brew install --cask macfuse
```

After installation, open **System Settings → Privacy & Security** and approve the macFUSE system extension if macOS prompts you. A restart may be required.

### rclone

```bash
brew install rclone
```

Confirm:

```bash
rclone version
```

## 2. Configure the OneDrive remote

Create or update the remote interactively:

```bash
rclone config
```

Typical choices:

1. **New remote** → pick a short name (this repo’s example uses `onedrive`).
2. **Storage** → **Microsoft OneDrive** (or **Microsoft OneDrive for Business** if you use work/school).
3. Complete the browser **OAuth** sign-in when rclone asks.

List top-level folders to see exact path names (including spaces):

```bash
rclone lsd onedrive:
```

(Replace `onedrive` if you chose a different remote name.)

## 3. Install these scripts

Clone or copy this repository to a folder on your Mac, for example:

```bash
git clone <your-repo-url>
cd rclone-onedrive-setup
```

Make the scripts executable:

```bash
chmod +x mount_onedrive.sh unmount_onedrive.sh
```

## 4. Create your `config.sh`

The mount script reads **`config.sh`** (not committed to git). Copy the example and edit it:

```bash
cp config.example.sh config.sh
```

Edit `config.sh` so that:

- **`REMOTE_NAME`** matches the name you used in `rclone config`.
- **`REMOTE_PATHS`** lists folders **on OneDrive** (as returned by `rclone lsd`).
- **`LOCAL_NAMES`** lists the folder names you want under `/Volumes/<YourDrive>/OneDrive/` on the external disk.
- **`CACHE_MAX_SIZE`** sets a per-mount VFS cache limit (for example `50G`).

All four arrays must have the **same number** of entries. You can use one folder or many.

## 5. Mount

1. Plug in the external drive and note its volume name in Finder (for example `MyPassport`).
2. Run:

```bash
./mount_onedrive.sh MyPassport
```

Use the **exact** volume name as shown under `/Volumes/`.

Mounted paths will be:

```text
/Volumes/<DriveName>/OneDrive/<LOCAL_NAMES entries>
```

## 6. Unmount and eject safely

Before unplugging the drive, stop the mounts and eject:

```bash
./unmount_onedrive.sh MyPassport
```

This unmounts subfolders under `.../OneDrive/`, stops matching `rclone mount` processes for that drive, then runs `diskutil eject`.

## Optional: run mounts at login (LaunchAgent)

To run the mount script when you log in (after the external disk is connected), install a **LaunchAgent** that calls the script with your volume name.

1. Replace placeholders in the plist below: your macOS username, full path to `mount_onedrive.sh`, and your volume name.
2. Save as `~/Library/LaunchAgents/com.example.rclone-onedrive.plist` (use a unique label; reverse-DNS style is typical).
3. Load it:

```bash
launchctl load ~/Library/LaunchAgents/com.example.rclone-onedrive.plist
```

Example plist (edit all `CHANGE_ME` values):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.example.rclone-onedrive</string>
    <key>ProgramArguments</key>
    <array>
        <string>/CHANGE_ME/full/path/to/mount_onedrive.sh</string>
        <string>CHANGE_ME_VolumeName</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/rclone-onedrive-mount.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/rclone-onedrive-mount.err</string>
</dict>
</plist>
```

**Note:** If the external disk is not connected at login, the script exits with an error until the disk is present; you can run `./mount_onedrive.sh` manually when you plug it in.

## Troubleshooting

| Issue | What to try |
|--------|-------------|
| Mount fails: directory not empty | The scripts use `--allow-non-empty`. If it still fails, remove stray files in the mount folder (except do not delete data you care about). |
| I/O or “stuck” mount after unplugging | Always run `unmount_onedrive.sh` before disconnecting. In a bad state: `umount` the paths under `.../OneDrive/` or stop the matching `rclone` processes, then try again. |
| OneDrive auth expired | `rclone config reconnect onedrive:` (adjust remote name if needed). |
| macFUSE / security prompts | Re-check **Privacy & Security** and macFUSE documentation for your macOS version. |

## Why exFAT for the external drive (and APFS pain points in this setup)

This project assumes the OneDrive mount tree lives on a **removable** disk you may use with **more than one OS**, or alongside **Docker** and other tools. In that situation **APFS on the external drive** caused concrete problems; **exFAT** avoided them.

### Specific issues with APFS here

1. **macOS permissions vs containers**  
   APFS carries **full macOS ownership and ACL semantics** on every file. When the same volume is accessed from the **host** and from **software that does not see the world like Finder** (for example **Docker Desktop**, where file access is bridged through a Linux VM), you often hit **“Operation not permitted” / “Permission denied”** for paths that look fine in Finder. The UID/GID and ignore-ownership toggles become a debugging loop instead of transparent access.

2. **Mental model: “this disk is my portable workspace”**  
   With APFS, the external disk behaves like **another Mac home folder**, not like a **neutral data slab**. Tools that expect simple, portable paths (sync scripts, bind mounts, CI-style layouts) keep running into **permission edges** that exFAT simply does not have in the same form.

3. **Portability**  
   **APFS** is Apple-first. **Windows** does not mount APFS out of the box; **Linux** support exists but is not something you want to rely on for a drive you move between machines. **exFAT** is boring and universally readable/writable, which matches “external OneDrive bridge I plug into different computers.”

4. **Performance trade-off**  
   **APFS** on a good external SSD is often **faster** on a Mac-only, single-user setup. **exFAT** is usually **slower** and **less crash-resilient** than APFS. This README still recommends exFAT for this **workflow** because **predictable access and portability** mattered more than squeezing the last bit of APFS performance.

### Terabyte-scale copies: fast externals (e.g. NVMe) ↔ SD cards

Moving **1–2 TB** (or more) between a **fast USB/NVMe-class enclosure** and an **SD card** is **much harder than it sounds**, even when Finder reports “copying…”

- **The SD card is the bottleneck.** Peak megabytes-per-second numbers on the box are often **burst** ratings. **Sustained writes**—what a huge copy actually uses—can **collapse** after a short time (heat, card quality, controller throttling). A transfer that “should” take an hour on paper can turn into **many hours** or span **overnight**.
- **Lots of small files** (audio projects, image sequences, unpacked archives) amplify the pain: **metadata and seek overhead** dominates, and progress is uneven.
- **Sleep, cables, hubs, and accidental eject** during a multi-hour job are realistic failure modes. If you **delete the source** before you **verify the destination**, you have classic **self-inflicted data loss**—the filesystem did not “eat” your files; the copy never truly finished.
- **Capacity traps.** SD cards are a common target for **counterfeits** (reporting fake size). A 2 TB job to a bad card can **fail silently** or **overwrite earlier data** in ways you only notice later.

For huge moves, prefer **tools that can resume or verify** (`rsync`, `rclone copy`, dedicated backup utilities), **stable power**, and **checksum or spot-check verification** before you reclaim space on the source. This repo is about **OneDrive mounts**, not a full migration guide—but the same discipline applies when you are shuffling **local** terabytes between media types.

### Data-loss footguns with **APFS** and **Mac OS Extended (Journaled)** on removable media

**Journaling** (HFS+ “Mac OS Extended (Journaled)” or APFS’s own design) mainly helps the **filesystem stay consistent** after a crash or sudden unplug. It does **not** mean “my 1 TB copy is magically all-or-nothing.” If a copy is **interrupted**, you often get a **mix of complete files, partial files, and missing files** on the destination—while the volume still mounts cleanly. That is a frequent source of **“I lost data”** stories that are really **unverified or partial transfers**.

**APFS** on small removable media (especially **SD cards**) can be **finicky**: not every card/controller pairing is a good long-term fit for heavy writes, and **snapshots** (Time Machine–related or otherwise) can **surprise you with space usage** until you understand what is holding blocks. **Permissions and ACLs** still apply, so copies to or from **non-APFS** volumes can **silently drop metadata** you assumed traveled with the file.

**Mac OS Extended (Journaled)** is **legacy-first**: fine on Mac-centric spinning disks, but **poor for sharing** with current Windows/Linux without extra software, and it shares the same **“copy finished?”** ambiguity as APFS for huge jobs.

**exFAT** is not a magic shield—**yank the card mid-write** and you can still corrupt the filesystem—but for **cross-device shuffling of large media** it avoids **Mac-only permission baggage** and **cross-OS surprises**, which is why this project keeps recommending it for the **OneDrive bridge drive** even though APFS is technically “nicer” on paper for a single Mac.

### Summary

**exFAT**: large files (unlike FAT32), works on **Windows, macOS, and Linux** without extra drivers, and **avoids the APFS permission friction** that showed up when combining **host mounts, rclone, and Docker-style tooling** on the same external volume.

If your drive is **Mac-only**, **not** shared with other OSes, and **not** bound into containers, **APFS** can be a better technical fit—at the cost of the issues above when you step outside that box.

## License

Add a `LICENSE` file if you publish this repository (for example MIT), so others know how they may use it.
