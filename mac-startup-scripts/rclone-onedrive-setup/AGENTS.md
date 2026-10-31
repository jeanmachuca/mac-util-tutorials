# AGENTS.md — rclone-onedrive-setup

macOS-only Bash tooling that mounts OneDrive folders via **rclone + macFUSE** onto an
external volume (default `/Volumes/<Volume>/OneDrive/<LocalName>`), with an optional
LaunchAgent login mount, encrypted rclone config, and safe unmount/eject.

## Golden rules

- **Never commit `config.sh`.** It contains the user's real OneDrive layout. Only
  `config.example.sh` is tracked. The repo has `githooks/pre-commit` to block it.
- **Never write secrets to files or logs.** The rclone config password lives in the
  macOS Keychain; scripts read it into `RCLONE_CONFIG_PASS` at runtime. Use
  `security` interactively, never a password argument in shell history.
- **Stateful commands are real system actions.** `mount_onedrive.sh`,
  `unmount_onedrive.sh`, `install.sh`, and `reset_rclone_config.sh` change mounts,
  launchd, or delete config. Prefer `--help` / `--dry-run`, and ask before running
  them against a machine with active mounts.
- **Stay compatible with stock macOS `/bin/bash` 3.2.** No associative arrays,
  `mapfile`, `${var,,}`, or other Bash 4+ features.
- **Keep config arrays aligned by index.** `REMOTE_PATHS`, `LOCAL_NAMES`,
  `CACHE_MAX_SIZE`, and optional `MOUNT_VOLUME_OVERRIDE` must all have the same
  length. At most one `REMOTE_PATHS` entry may be empty (OneDrive root);
  `LOCAL_NAMES` and `CACHE_MAX_SIZE` entries must be non-empty.
- **Mount path contract:** `/Volumes/<resolved-volume>/OneDrive/<LOCAL_NAMES[i]>`.
  A row uses `MOUNT_VOLUME_OVERRIDE[i]` when non-empty, else the default volume.

## Layout

| Path | Role |
|------|------|
| `README.md` | Full user guide (install, mount, eject safety, LaunchAgent, troubleshooting). Keep it in sync with behavior changes. |
| `config.example.sh` | Tracked config template. |
| `config.sh` | Local, gitignored, never edit/replace without care. |
| `mount_onedrive.sh` | Validates config, resolves rclone, optionally reads Keychain, unmounts each target, starts `rclone mount` (`--daemon` by default; `--no-daemon` for launchd). |
| `unmount_onedrive.sh` | Unmounts every configured target, kills matching `rclone mount` per volume, retries, then `diskutil eject`s each distinct volume unless `--no-eject`. |
| `login.sh` / `logout.sh` | Thin wrappers that default the volume to `EXTERNAL_VOLUME_NAME`. |
| `startup_mount_onedrive.sh` | LaunchAgent entry point: sleeps `STARTUP_MOUNT_DELAY_SEC` (default 10s), then `exec mount_onedrive.sh --no-daemon`. |
| `install.sh` | Dry-run/install/uninstall: rsyncs to `~/Library/Application Support/rclone-onedrive-setup/`, writes and loads a LaunchAgent, optionally stores the Keychain password, appends shell helper functions to `~/.zshrc` and `~/.bash_profile`. |
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
./mount_onedrive.sh MyVolume     # daemonized mounts
./login.sh                       # mount using EXTERNAL_VOLUME_NAME
./unmount_onedrive.sh MyVolume   # tear down mounts, then eject
./logout.sh --no-eject           # tear down rclone only
./check_rclone_config.sh         # config integrity
./reset_rclone_config.sh -y      # backup + remove local rclone.conf
```

After `install.sh`, shell helpers are available after `source ~/.zshrc`:
`install_rclone_onedrive`, `mount_rclone_onedrive`, `unmount_rclone_onedrive`,
`login_rclone_onedrive`, `logout_rclone_onedrive`, `check_rclone_onedrive`,
`reset_rclone_onedrive`, `uninstall_rclone_onedrive`, `rclone_onedrive_help`.

## Validation

There is no automated test suite. Use:

```bash
for f in *.sh; do bash -n "$f"; done
shellcheck install.sh mount_onedrive.sh unmount_onedrive.sh login.sh logout.sh \
  startup_mount_onedrive.sh rclone_resolve.sh check_rclone_config.sh \
  reset_rclone_config.sh setup_rclone_encryption_keychain.sh
./install.sh --dry-run   # macOS + rclone + config.sh required
plutil -lint ~/Library/LaunchAgents/<label>.plist
```

Known pre-existing shellcheck findings (do not treat as new regressions):
`check_rclone_config.sh:106` SC2034 (unused `encrypted`) and `:136` SC2001;
`mount_onedrive.sh:13` SC1091 (sourced `config.sh` not passed with `-x`).

## Conventions

- Bash scripts start with `#!/bin/bash` and `set -euo pipefail` where practical.
  `unmount_onedrive.sh` intentionally uses `set +u` around `source config.sh` and
  `set -u` after, because optional variables may be absent.
- Source config as `set +u; source config.sh; set -u`; quote all paths (volumes can
  contain spaces); use arrays and `local`.
- Resolve rclone through `rclone_resolve.sh` (`set_rclone_executable`) in new
  scripts rather than bare `rclone` calls.
- `install.sh` uses `[OK]`, `[WARN]`, `[FAIL]` log helpers and tabs; match the file
  you edit.
- User-facing behavior changes need a `README.md` update; deep layouts go in
  `docs/`.
- Commit style observed: `rclone-onedrive-setup: <imperative summary>`.
  Follow the workspace SDLC guide (topic branches, PRs, no rebase, SemVer).

## Gotchas

- **LaunchAgent must use `--no-daemon`.** Plain `mount_onedrive.sh` daemonizes and
  returns, so launchd can lose the mount. `startup_mount_onedrive.sh` handles this.
- **launchd has a minimal PATH.** Plists set
  `/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin`; set `RCLONE_BIN` if rclone lives
  elsewhere.
- **Edits in the clone do not update the installed copy.** Re-run `./install.sh`
  after changing scripts.
- **Unmount order matters:** targets first, then `pkill` per `/Volumes/<vol>/OneDrive`,
  wait, unmount again, then eject. Ejecting one partition can remove sibling volumes
  on the same disk; the script skips volumes that already disappeared.
- **`CACHE_DIR` under `/Volumes/` must already exist.** The script refuses to create
  it there (prevents writing cache to the system disk).
- **Keychain-loading logic is duplicated** in `mount_onedrive.sh` and
  `check_rclone_config.sh`. Keep both in sync.
- **`install.sh` needs `/usr/bin/python3`** (via Xcode CLT) to generate the plist.
- **`install.sh` rsync excludes** `.git`, `.DS_Store`, `*.swp`, `.cursor`.
- **The pre-commit hook is opt-in:** from the repo root run
  `git config core.hooksPath githooks`. It is not enabled in every clone.
- Do not put an open Final Cut Pro library (or similar bundle/database) under a
  FUSE-mounted `OneDrive/` path; use native APFS beside it and copy closed bundles
  to OneDrive. See `docs/external-disk-exfat-apfs-work-cache-example.md`.
