# AGENTS.md — rclone-gdrive-setup

macOS-only Bash tooling that mounts Google Drive folders via **rclone + macFUSE** onto an
external volume (default `/Volumes/<Volume>/GoogleDrive/<LocalName>`), with an optional
LaunchAgent login mount, encrypted rclone config, safe unmount/eject, and Google Drive
Shared Drive / “Shared with me” selectors.

## Golden rules

- **Never commit `config.sh`.** It contains the user's real Google Drive layout. Only
  `config.example.sh` is tracked. The repo has `githooks/pre-commit` to block it.
- **Never write secrets to files or logs.** The rclone config password lives in the
  macOS Keychain; scripts read it into `RCLONE_CONFIG_PASS` at runtime. Use
  `security` interactively, never a password argument in shell history.
- **Stateful commands are real system actions.** `mount_gdrive.sh`,
  `unmount_gdrive.sh`, `install.sh`, and `reset_rclone_config.sh` change mounts,
  launchd, or delete config. Prefer `--help` / `--dry-run`, and ask before running
  them against a machine with active mounts.
- **Stay compatible with stock macOS `/bin/bash` 3.2.** No associative arrays,
  `mapfile`, `${var,,}`, or other Bash 4+ features. Also avoid expanding an empty
  array under `set -u` (Bash 3.2 errors); guard with `${#arr[@]} -gt 0` or build a
  non-empty command array first.
- **Keep config arrays aligned by index.** `REMOTE_PATHS`, `LOCAL_NAMES`,
  `CACHE_MAX_SIZE`, optional `MOUNT_VOLUME_OVERRIDE`, optional `GDRIVE_TEAM_DRIVE`,
  and optional `GDRIVE_SHARED_WITH_ME` must all have the same length. At most one
  `REMOTE_PATHS` entry may be empty (Google Drive root); `LOCAL_NAMES` and
  `CACHE_MAX_SIZE` entries must be non-empty.
- **Mount path contract:** `/Volumes/<resolved-volume>/GoogleDrive/<LOCAL_NAMES[i]>`.
  A row uses `MOUNT_VOLUME_OVERRIDE[i]` when non-empty, else the default volume.
- **`GDRIVE_TEAM_DRIVE[i]` and `GDRIVE_SHARED_WITH_ME[i]` are mutually exclusive.**
  The former passes `--drive-team-drive <id>`; the latter passes
  `--drive-shared-with-me` for that row.
- **Do not claim native Google Docs are editable through the mount.** They are
  exported as `.docx` / `.xlsx` / `.pptx` / `.svg` by default. Document that editing
  must happen in the web UI or use `--drive-skip-gdocs`.
- **Warn about shortcut folder deletion.** Deleting a Google Drive folder shortcut
  through the mount can delete the linked folder's contents. Prefer managing
  shortcuts in the web UI, or `--drive-skip-shortcuts`.

## Layout

| Path | Role |
|------|------|
| `README.md` | Full user guide (install, mount, eject safety, LaunchAgent, Google Drive caveats, troubleshooting). Keep it in sync with behavior changes. |
| `config.example.sh` | Tracked config template. |
| `config.sh` | Local, gitignored, never edit/replace without care. |
| `mount_gdrive.sh` | Validates config, resolves rclone, optionally reads Keychain, unmounts each target, starts `rclone mount` (`--daemon` by default; `--no-daemon` for launchd). Adds per-row `--drive-team-drive` / `--drive-shared-with-me` and global `GDRIVE_MOUNT_FLAGS`. |
| `unmount_gdrive.sh` | Unmounts every configured target, kills matching `rclone mount` per volume, retries, then `diskutil eject`s each distinct volume unless `--no-eject`. |
| `login.sh` / `logout.sh` | Thin wrappers that default the volume to `EXTERNAL_VOLUME_NAME`. |
| `startup_mount_gdrive.sh` | LaunchAgent entry point: sleeps `STARTUP_MOUNT_DELAY_SEC` (default 10s), then `exec mount_gdrive.sh --no-daemon`. |
| `install.sh` | Dry-run/install/uninstall: rsyncs to `~/Library/Application Support/rclone-gdrive-setup/`, writes and loads a LaunchAgent, optionally stores the Keychain password, appends shell helper functions to `~/.zshrc` and `~/.bash_profile`. |
| `check_rclone_config.sh` | Verifies `rclone.conf` exists/readable/decryptable and remotes load. |
| `reset_rclone_config.sh` | Backs up and removes the local `rclone.conf` (cloud data untouched); optional Keychain removal. |
| `setup_rclone_encryption_keychain.sh` | Enables/rotates rclone config encryption and stores the master password in Keychain. |
| `rclone_resolve.sh` | Sourced helper that resolves `RCLONE` via `RCLONE_BIN` or `command -v rclone`. |
| `launchd/*.plist.example` | Manual LaunchAgent template. |
| `docs/` | Volume overrides, repeated mounts, exFAT/APFS/cache layouts, FCP caveats. |

## Common commands

```bash
cp config.example.sh config.sh   # first-time local config
./install.sh --dry-run           # validate tools, config, paths, plist; writes nothing
./install.sh                     # install to Application Support + LaunchAgent
./mount_gdrive.sh MyVolume       # daemonized mounts
./login.sh                       # mount using EXTERNAL_VOLUME_NAME
./unmount_gdrive.sh MyVolume     # tear down mounts, then eject
./logout.sh --no-eject           # tear down rclone only
./check_rclone_config.sh         # config integrity
./reset_rclone_config.sh -y      # backup + remove local rclone.conf
```

After `install.sh`, shell helpers are available after `source ~/.zshrc`:
`install_rclone_gdrive`, `mount_rclone_gdrive`, `unmount_rclone_gdrive`,
`login_rclone_gdrive`, `logout_rclone_gdrive`, `check_rclone_gdrive`,
`reset_rclone_gdrive`, `uninstall_rclone_gdrive`, `rclone_gdrive_help`.

## Validation

There is no automated test suite. Use:

```bash
for f in *.sh; do bash -n "$f"; done
shellcheck install.sh mount_gdrive.sh unmount_gdrive.sh login.sh logout.sh \
  startup_mount_gdrive.sh rclone_resolve.sh check_rclone_config.sh \
  reset_rclone_config.sh setup_rclone_encryption_keychain.sh
./install.sh --dry-run   # macOS + rclone + config.sh required
plutil -lint ~/Library/LaunchAgents/<label>.plist
```

Also validate the manual plist template:

```bash
plutil -lint launchd/com.example.rclone-gdrive.plist.example
```

Known pre-existing shellcheck findings (do not treat as new regressions):
`check_rclone_config.sh` may report SC1091 for sourced `config.sh`; use
`shellcheck -x` if you want it to follow the source.

## Conventions

- Bash scripts start with `#!/bin/bash` and `set -euo pipefail` where practical.
  `unmount_gdrive.sh` intentionally uses `set +u` around `source config.sh` and
  `set -u` after, because optional variables may be absent.
- Source config as `set +u; source config.sh; set -u`; quote all paths (volumes can
  contain spaces); use arrays and `local`.
- Resolve rclone through `rclone_resolve.sh` (`set_rclone_executable`) in new
  scripts rather than bare `rclone` calls.
- `install.sh` uses `[OK]`, `[WARN]`, `[FAIL]` log helpers and tabs; match the file
  you edit.
- User-facing behavior changes need a `README.md` update; deep layouts go in
  `docs/`.
- Commit style observed: `rclone-gdrive-setup: <imperative summary>`.
  Follow the workspace SDLC guide (topic branches, PRs, no rebase, SemVer).

## Gotchas

- **LaunchAgent must use `--no-daemon`.** Plain `mount_gdrive.sh` daemonizes and
  returns, so launchd can lose the mount. `startup_mount_gdrive.sh` handles this.
- **launchd has a minimal PATH.** Plists set
  `/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin`; set `RCLONE_BIN` if rclone lives
  elsewhere.
- **Edits in the clone do not update the installed copy.** Re-run `./install.sh`
  after changing scripts.
- **Unmount order matters:** targets first, then `pkill` per `/Volumes/<vol>/GoogleDrive`,
  wait, unmount again, then eject. Ejecting one partition can remove sibling volumes
  on the same disk; the script skips volumes that already disappeared.
- **`CACHE_DIR` under `/Volumes/` must already exist.** The script refuses to create
  it there (prevents writing cache to the system disk).
- **Keychain-loading logic is duplicated** in `mount_gdrive.sh` and
  `check_rclone_config.sh`. Keep both in sync.
- **`install.sh` needs `/usr/bin/python3`** (via Xcode CLT) to generate the plist.
- **`install.sh` rsync excludes** `.git`, `.DS_Store`, `*.swp`, `.cursor`.
- **The pre-commit hook is opt-in:** from the repo root run
  `git config core.hooksPath githooks`. It is not enabled in every clone.
- **Google Drive shared client ID:** rclone's shared Google Drive `client_id` is
  being retired during 2026. The README recommends creating your own OAuth client
  ID. Do not reintroduce instructions that imply the shared app is durable.
- **OAuth Testing mode:** an External OAuth app in Testing may expire refresh tokens
  after about 7 days. Document `rclone config reconnect gdrive:` and publishing /
  Internal app options.
- **Google Docs:** default export formats are `docx,xlsx,pptx,svg`; edits through the
  mount do not round-trip into native Google Docs. `GDRIVE_MOUNT_FLAGS` can hide
  them (`--drive-skip-gdocs`) or export as PDF (`--drive-export-formats pdf`).
- **Shortcuts:** deleting a folder shortcut through the mount can delete the linked
  folder's contents. Use `--drive-skip-shortcuts` or the web UI.
- **Quotas:** Google Drive API rate limits, download quota, 750 GiB/day upload, and
  10 TiB/day download limits are real. `--tpslimit`, `--drive-stop-on-upload-limit`,
  and `--drive-stop-on-download-limit` are the relevant knobs.
- Do not put an open Final Cut Pro library (or similar bundle/database) under a
  FUSE-mounted `GoogleDrive/` path; use native APFS beside it and copy closed bundles
  to Google Drive. See `docs/external-disk-exfat-apfs-work-cache-example.md`.
