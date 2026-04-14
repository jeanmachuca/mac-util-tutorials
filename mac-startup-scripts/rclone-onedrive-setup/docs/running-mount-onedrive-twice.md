# Running `mount_onedrive.sh` more than once

`mount_onedrive.sh` is designed so a **second run** refreshes mounts: it **unmounts** each configured target (best effort), then starts **`rclone mount`** again. It does **not** stack a second mount on top of the first without tearing down the old one.

## What the script does each time

For every entry in **`REMOTE_PATHS`** / **`LOCAL_NAMES`** (under `/Volumes/<DriveName>/OneDrive/<local_name>/`):

1. **`umount <target>`** — errors are ignored (`2>/dev/null || true`). If a FUSE mount was already active on that path, this tears it down.
2. **`mkdir -p <target>`**
3. **`rclone mount …`** — either with **`--daemon`** (default) or in the background when using **`--no-daemon`**.

So running the script again is effectively **remount**, not “double mount.”

## Default mode (`--daemon`) — typical interactive use

```bash
./mount_onedrive.sh MyPassport
./mount_onedrive.sh MyPassport   # second time
```

Each invocation **unmounts** then starts **new** `rclone` processes (daemonized). Safe to repeat when you want a clean remount after a glitch or config change.

## `--no-daemon` / `--persistent` — LaunchAgent and long-lived shells

**`startup_mount_onedrive.sh`** calls **`mount_onedrive.sh --no-daemon`**. The script stays in the foreground and **`wait`s** on each `rclone` PID so **launchd** keeps a single long-lived job.

- **Do not** start a **second** `--no-daemon` run while the first is still waiting (e.g. LaunchAgent running **and** you run `./mount_onedrive.sh --no-daemon` in another terminal). The second run will **`umount`** the same paths, which usually **stops** the first run’s `rclone` processes and ends the first script’s **`wait`**. You get overlapping, confusing behavior.
- For a **manual remount** while debugging launchd, prefer:
  - **`./mount_onedrive.sh MyPassport`** (default **`--daemon`**), or  
  - **`launchctl kickstart -k gui/$(id -u)/<your-label>`** (see README),  
  rather than a second full **`--no-daemon`** session.

## LaunchAgent + manual `mount_onedrive.sh` (default)

If the **LaunchAgent** is running **`--no-daemon`** and you run **`./mount_onedrive.sh MyPassport`** from Terminal **without** `--no-daemon`:

- The **`umount`** step **clears** mounts the agent had started; the agent’s **`rclone`** processes may **exit**.
- Your Terminal run starts **new** daemonized `rclone` mounts.

Avoid overlapping mounts you don’t intend unless you are deliberately remounting; use **`unmount_onedrive.sh`** first if you want a fully clean state.

## Summary

| Scenario | What happens |
|----------|----------------|
| **`mount_onedrive.sh` twice (default)** | **Unmount** each target, then **new** `rclone --daemon`. Remount / refresh. |
| **Two `--no-daemon` runs at once** | Second run **unmounts** first run’s mounts; avoid. |
| **Agent + default manual run** | **Unmount** disrupts agent mounts; new daemons from Terminal. |

See also the main **[README](../README.md)** — §5 Mount, §6 Unmount, and LaunchAgent notes.
