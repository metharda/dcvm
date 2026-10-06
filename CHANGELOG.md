# Changelog

All notable changes to DCVM are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
DCVM does not publish git tags; versions below are the `Version:` string reported
by `dcvm version` (defined in `show_version()` in the `dcvm` entry point), and the
date is the day that version first landed on `main`. Entries were reconstructed
from git history, so the commit or PR is listed for each release.

## [Unreleased]

## [0.9.2] - 2026-10-06

Docs, CI reliability, and related fixes. Ships via self-update when the
installed version differs from main.

### Added

- `CHANGELOG.md` covering 0.5.2 through 0.9.2, reconstructed from git history.
- Contributor guidance in `CONTRIBUTING.md` for CI rules, the repository test
  suite, and testing a clone when DCVM is already installed.
- Pull-request formatting check: `shfmt -i 2 -d` (check-only; no rewrite or
  bot commit on the PR branch).

### Changed

- README SSH access example uses the recorded cloud-init username (and port /
  host placeholders) instead of a hard-coded `admin@host-ip`.
- `docs/CODE-ORGANIZATION.md` documents `get_vm_username` alongside the other
  VM getters and on the `export -f` line.
- Lint CI now runs `shellcheck -S error` on each shell file (plus `bash -n`),
  fixing the `xargs -I{}` collapse that previously meant lint checked nothing.
- Six lib scripts reformatted with `shfmt -i 2` so local and CI formatting
  agree (these files ship via self-update).
- `docs/project-structure.md` tree regenerated from the tracked files
  (removed nonexistent `bin/`, `config/`, `templates/` and `tests/`); README
  port mapping corrected to start at 2221/8081, with `dcvm network ports show`.

### Removed

- Approval-triggered format workflow that auto-committed `shfmt` results as
  `github-actions[bot]`. On approval it pushed to a `<pr>/merge` ref instead
  of the PR branch.

### Fixed

- Welcome page now shows the VM name and username instead of blanks.
- Cloud-init `runcmd` nginx/apache index commands are now single-quoted so
  the `User: ` in them no longer turns the item into a YAML mapping.
- Test suite: the `--full` VM lifecycle test creates its VM with `-o 5`
  (Ubuntu 22.04, the image it originally targeted) instead of `-o 3`, which
  became Debian 11 after the 0.9.0 OS menu renumber. CI does not run this
  test; it needs `--full`, root and a downloaded template.

## [0.9.1] - 2026-10-06

Self-update delivers these when the installed version differs from main.
0.9.1 is what ships Tailscale (and the related fixes) to 0.9.0 installs.
PR #32 (73624ac, a83dc88).

### Added

- Tailscale integration for VM creation (9191006, be08fb8, 95a4b6a):
  - `-k tailscale` installs Tailscale inside the VM via cloud-init.
  - `--tailscale-authkey <key>` auto-joins the VM to your tailnet when used
    with `-f` / `--force` (and installs Tailscale even if it is not listed in
    `-k`). Without `-f`, interactive mode prompts for an auth key instead.
  - Arch Linux guests install Tailscale with `pacman` (with retries);
    Debian/Ubuntu/Kali guests use the official install script, retried to
    survive apt lock contention during first boot.
  - Documented in `docs/usage.md` ("Create a VM with Tailscale VPN").

### Changed

- `validate_username` now rejects reserved names (`root`, `admin`,
  `administrator`, `sysadmin`, `user`, `guest`) for the VM user (9191006).
- Uninstall documentation now warns that `dcvm uninstall` deletes every
  datacenter VM (and its storage), removes `DATACENTER_BASE` (including
  backups), and cleans up network, logs, aliases, and completions (73624ac).

### Fixed

- Arch Linux VM networking: cloud-init network config for Arch guests now
  targets `enp1s0` (DHCP with `dhcp-identifier: mac`, or static IP with
  gateway/nameservers) instead of the generic `id0` entry used for other
  distros, fixing Arch VMs coming up without working networking (db5c65a).
- `self-update`: use `((++updated_count))` instead of `((updated_count++))`
  so the first increment no longer returns a non-zero status under
  `set -e` (db5c65a).
- Cloud-init `runcmd`: the `echo "User: ..." >> /var/log/cloud-init-final.log`
  line is now single-quoted so the `: ` inside it no longer breaks YAML
  parsing of user-data (95a4b6a).
- `get_vm_username <vm>` reads the login name from the VM's cloud-init
  user-data (users list name, then `VM_USERNAME=`), falling back to `admin`
  only when nothing is recorded; used for SSH hints, DHCP renew, and storage
  checks (a83dc88).

## [0.9.0] - 2026-01-05

PR #26 (109eb9c).

### Added

- New guest OS options: Debian 13, Ubuntu 24.04 and Kali Linux.
- `dcvm template <cmd>` (alias `dcvm mirror`) for template/mirror management
  (`list`, `download`, `check`), routed to `lib/utils/mirror-manager.sh`.

### Changed

- **Breaking:** OS menu renumbered (`-o 1` is now Debian 13; `-o 3` is Debian
  11). Default OS changed from Ubuntu 22.04 to Ubuntu 24.04 (`DEFAULT_OS=4`).
- **Breaking:** Default username is now per-OS via `default_username()` (for
  example `ubuntu`, `debian`, `archlinux`, `kali`), not a single shared
  default. Docs updates alone did not introduce this; create-time behavior
  changed.
- **Breaking:** Kali and Debian 13 require VNC (`OS_REQUIRES_VNC`). Kali disk
  size must be at least 30G (`MIN_DISK_SIZE_GB["kali"]=30`).
- `create-iso` was dropped from the main help output but is still routed to
  `lib/core/custom-iso.sh`.
- `self-update` improvements (`lib/installation/self-update.sh`).
- DHCP handling reworked (`lib/network/dhcp.sh`) and mirror manager expanded.
- Test suite (`lib/utils/test-suite.sh`) substantially expanded.
- Help output re-aligned; docs updated for default SSH usernames, VNC,
  backups and networking; `docs/backup-restore.md` renamed to `docs/backups.md`.

## [0.8.0] - 2025-12-25

PR #24 (d9336b1).

### Added

- `dcvm network vnc <enable|disable|status> <vm>` to toggle VNC graphics on
  a VM and free VNC ports after ISO installation (also listed in the main
  help output).
- Custom ISO: auto-detect and copy ISOs from restricted directories
  (`/root`, `/home`); VNC binds to `127.0.0.1` (use an SSH tunnel for remote
  access); early ISO detection with `-o file.iso`.

### Changed

- `format.yaml` workflow now runs `shfmt` when a PR review is approved
  (or on manual dispatch) instead of after all checks pass.

### Fixed

- DHCP lease corruption when deleting VMs (JSON now edited with `jq`
  instead of `sed`).
- Port forwarding variables lost in a `while read` subshell (now uses
  process substitution).
- Stdout pollution in `get_vm_ip_advanced()` (status messages go to stderr).
- `FORCE_MODE` passed incorrectly to `custom-iso.sh` (the string `"false"`
  was treated as true).

## [0.7.2] - 2025-12-19

PR #21 (658ee60).

### Changed

- Installer output uses `print_status_log` consistently.

### Fixed

- Installer: `install_by_fetch` handles the `dcvm` binary explicitly after
  its move from `bin/dcvm` to the repository root, logging success/failure.

## [0.7.1] - 2025-12-18

PR #19 (fde93c6), PR #20 (25ef022).

Version jumped from 0.5.2 to 0.7.1 (no 0.6.x releases).

### Added

- CI workflows: version-bump enforcement (`version-bump.yaml`), quick test
  matrix (`test.yaml`), lint (`bash -n` + `shellcheck`) and `shfmt` format.
- `lib/utils/test-suite.sh` repository test suite.

### Changed

- License changed to Apache License 2.0.
- All shell scripts reformatted with `shfmt -i 2`.
- Lint and test workflows no longer run on pushes to `main`, only on PRs (#20).

## [0.5.2] - 2025-11-18

Version `0.5.2` first appeared in `bin/dcvm` in de6400d (#12) on 2025-11-18.
Later commits kept the same version string until 0.7.1.

### Added

- Modular `bin/` + `lib/` layout and project documentation (#12, de6400d).
- Improved installer (`lib/installation/install-dcvm.sh`) (#13, 12cdf24).
- Full Arch Linux guest support and Arch cloud-init fixes (#15, c001e8b).
- `dcvm self-update` with version checks and backup/rollback (#17, e40e630).
- `dcvm create-iso` (`lib/core/custom-iso.sh`) for VMs from custom installer
  ISOs, replacing `create-from-iso.sh` (#17).
- Mirror manager (`lib/utils/mirror-manager.sh`) with mirror speed tests and
  fallbacks for Debian, Ubuntu and Arch Linux images (#17).
- Static IP option and interactive prompts for memory, CPUs and disk size (#17).

### Changed

- `dcvm` entry point moved from `bin/dcvm` to the repository root (#17).
- Unified logging format; `vm_exists` replaced by `check_vm_exists`;
  `fix-lock` argument handling and verbosity improved (#17).
- IP validation checks the address is inside the configured subnet (#17).

[Unreleased]: https://github.com/metharda/dcvm/compare/95a4b6a...HEAD
[0.9.2]: https://github.com/metharda/dcvm/pull/34
[0.9.1]: https://github.com/metharda/dcvm/pull/32
[0.9.0]: https://github.com/metharda/dcvm/commit/109eb9c
[0.8.0]: https://github.com/metharda/dcvm/commit/d9336b1
[0.7.2]: https://github.com/metharda/dcvm/commit/658ee60
[0.7.1]: https://github.com/metharda/dcvm/commit/fde93c6
[0.5.2]: https://github.com/metharda/dcvm/commit/de6400d
