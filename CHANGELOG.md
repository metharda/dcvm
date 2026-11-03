# Changelog

All notable changes to dcvm are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versions are the `Version:` string reported by `dcvm version` (defined in
`show_version()` in the `dcvm` entry point). Each release is tagged `vX.Y.Z` on
`main`, and each version heading links to the compare between the previous tag
and its own (0.5.2, the first tag, links to its tag page). The date is the day
that version first landed on `main`. Entries were reconstructed from git
history, so the commit or PR is listed for each release.

## [Unreleased]

## [0.9.6] - 2026-11-03

Bug fixes for VM passwords, DHCP lease matching and Arch Linux VMs.

### Fixed

- Passwords containing ` #`, quotes, `\`, `$`, backticks or `: ` now work: the
  user, root and MySQL passwords are set to exactly the value entered (#36).
- MySQL setup no longer leaves `$VM_USERNAME`/`$VM_PASSWORD` unexpanded; with
  username `root` only the root password is set (#36).
- `-k docker` adds the VM user to the `docker` group (the name was not
  expanded).
- `dcvm network dhcp clear <vm>`, `delete` and the IP lookup match the whole
  hostname (any case), so `vm1` no longer hits `vm10` or `vm1-copy`, and a
  name such as `254` or `ipv4` no longer clears other leases (#37).
- Clearing a lease removes whole entries from the libvirt status file instead
  of single lines, which left invalid JSON (#37).
- Arch Linux VMs get Arch package names (`openssh`, `nfs-utils`), the `sshd`
  unit, the Arch sftp-server path and Arch nginx/Apache paths (#38).
- A password changed inside the VM (`passwd`) now survives a reboot: the user
  and root passwords are set once at first boot, as SHA-512 hashes, instead of
  by a `bootcmd` that reset them on every boot. The root password is no longer
  written to user-data in plain text (#36).
- nginx, Apache and Docker setup runs only for `-k nginx`, `-k apache2` and
  `-k docker`/`docker.io`; packages such as `nginx-extras`,
  `libapache2-mod-php` and `python3-docker` install as typed without it (#38).
- `dhcp clear`, `dhcp clear --stale` and `delete` no longer send SIGHUP to
  dnsmasq, which never found libvirt's dnsmasq and does not drop leases, and
  no longer edit a `.leases` file, which libvirt does not use (#37).

### Changed

- `-k mysql-server` installs MariaDB (service `mariadb`) on Debian 11/12/13,
  Kali and Arch Linux, which have no `mysql-server` package; only Ubuntu keeps
  MySQL. `-k default-mysql-server` also runs the database setup: it
  installs as named on Debian, Kali (MariaDB) and Ubuntu (MySQL), and as
  `mariadb` on Arch Linux. Other names containing `mysql` no longer trigger
  the setup (#36).
- `dhcp clear <vm|mac>` and `dhcp clear --stale` no longer restart the
  network; only `dhcp clear --all` does. With no matching lease, `clear`
  says so and changes nothing (#37).
- `delete` no longer stops or removes host systemd units whose name contains
  the VM name; dcvm does not create per-VM units.
- Without `jq`, lease cleanup leaves the status file unchanged instead of
  emptying it.
- Passwords may be up to 128 characters and must not contain line breaks,
  including the Unicode line and paragraph separators (U+2028, U+2029) and
  U+0085 (#36).
- With MariaDB (Debian, Kali, Arch Linux), the database root user keeps its
  passwordless login from the system root account (`sudo mariadb`) and also
  gets the VM password (#36).
- `dhcp clear <vm|mac>`, `dhcp clear --stale` and `delete` release the
  cleared lease in the running dnsmasq with `dhcp_release` and remove it from
  libvirt's status file, so the address can be handed out again right away.
  Without `dhcp_release` or `jq`, `dhcp clear` fails with an error that names
  the package to install, and changes nothing (#37).
- `dhcp clear <vm>` keeps a static DHCP reservation for the VM's MAC;
  `delete` removes the deleted VM's reservation (#37).
- The installer also installs `jq` and `dhcp_release` (`dnsmasq-utils` on
  Debian/Ubuntu; Arch already gets it with `dnsmasq`), which lease cleanup
  uses (#37).

## [0.9.5] - 2026-11-03

README pitch and the dcvm name in the docs and the CLI.

### Changed

- README opens with a one-line pitch for students, homelab users, CTF and
  security practice, and anyone who wants ready Linux VMs on one machine, and
  the intro no longer describes a "virtual datacenter environment".
- README has a "Why dcvm?" section comparing dcvm with Multipass, Vagrant +
  vagrant-libvirt, virt-install and quickemu, with links to their docs.
- README shows badges for the test workflow, the Apache-2.0 license and the
  version. The version badge is static and is bumped by hand (see
  `CONTRIBUTING.md`).
- README install section has a "Review before you run" note: download the
  installer, read it, then run it.
- The docs call the project "dcvm, a VM manager" instead of "Datacenter
  Virtual Machine Manager". Config, path and network names such as
  `DATACENTER_BASE`, `/srv/datacenter` and `datacenter-net` are unchanged.
- CLI messages, help text and the systemd unit `Description=` lines say
  "dcvm" instead of "datacenter" or "DCVM", including the installer,
  uninstaller and `dcvm self-update` output, and `dcvm --version` prints
  "dcvm - a VM manager". Function, variable, unit, log and path names are
  unchanged.

### Fixed

- `docs/examples/basic-vm-creation.md` links to `docs/backups.md` instead of
  the old, missing `docs/backup-restore.md`.
- In `dcvm network help`, the fallback network name on the
  `start|stop|restart` line is `datacenter-net`, the default in
  `lib/utils/common.sh`, instead of `datacenter`. The line still shows the
  configured network name, so the printed help does not change.

## [0.9.4] - 2026-10-08

Post-merge documentation follow-up to 0.9.3.

### Changed

- `docs/usage.md` lists the `<vm>-dd.mm.yyyy[-N]` backup ID from `backup list`
  as a restore date.

## [0.9.3] - 2026-10-08

Bug fixes for VM creation, backup restore/import, DHCP and port checks.

### Added

- `dcvm backup restore <vm> [backup_date [new_vm_name]]` restores a backup as a
  new VM, leaving the original VM as is; use `latest` (or `''`) as the date
  for the latest backup (#28). Restore also accepts the backup IDs that
  `backup list` prints (`<vm>-dd.mm.yyyy[-N]`) and the bare day selector
  (`dd.mm.yyyy[-N]`).
- A copy restored or imported under a new name gets a new machine-id and new
  SSH host keys (regenerated on first boot) along with the new hostname when
  `virt-customize` is available, and the source VM's NVRAM path is dropped
  from its XML. If the source VM has a static IP recorded on this host, the
  copy is not started or set to autostart, and a warning says it keeps that
  IP.

### Changed

- `docs/CODE-ORGANIZATION.md` lists `trim_whitespace` and
  `validate_vm_name_list` and states the real `validate_vm_name` rule.
- README project tree shows `dcvm` as the CLI entry point inside the
  repository root.
- `root` is now accepted as a VM username (0.9.1 reserved it): cloud-init
  configures the existing root account (password, SSH key, `/root`, root SSH
  login) instead of creating a user, and `dcvm create` warns that root login
  is being configured. With `-k mysql-server`, the MySQL `CREATE USER` and
  `GRANT` steps are skipped for root (#29).

### Fixed

- `dcvm create ''` (or options with no VM name) now exits non-zero with
  "VM name required"; `dcvm create` with no arguments or `--help` still shows
  usage.
- `-k` packages are installed one by one, so one unavailable name no longer
  stops every package (including the base packages) from installing;
  invalid package names are rejected before anything is created (#30).
- Backup import (and restore under a new name) sets the guest hostname and
  its `/etc/hosts` entries to the new VM name when `virt-customize` is
  available. SSH key setup looks up the VM IP every 2s for up to 120s (the
  last lookup can end a few seconds later) instead of continuing with "N/A"
  (#27).
- `dcvm backup import <package> <new_vm_name>` rejects an invalid new name
  before anything is copied.
- Port connectivity checks (`dcvm network ports test`, `dcvm network show`)
  check the DNAT and FORWARD rules that `dcvm network ports setup` adds and
  the VM port, instead of probing `127.0.0.1`, which reported working forwards
  as failed (refs #31).
- `dcvm network dhcp cleanup` runs the stale-lease cleanup (same as
  `dhcp clear --stale`). After #26 it printed "Unknown command" even though
  help advertised it.
- Top-level `dcvm help`, shell completion and internal callers use the current
  `dhcp` subcommands (`clear`, `clear --all`) instead of `clear-all`,
  `clear-vm` and `clear-mac`, which #26 removed.
- `dcvm delete` no longer restarts the network: it removes the VM's lease
  entries from dnsmasq's lease and status files and reloads dnsmasq. If a
  lease is still listed afterwards, it prints "They expire on their own; to
  remove stale leases now: dcvm network dhcp cleanup (restarts <network> if
  it removes any)".

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
- Lint workflow runs with read-only `contents` permission and builds its file
  list inside the lint step (`git ls-files -z`), so file names can't inject
  shell.

### Removed

- Approval-triggered format workflow that auto-committed `shfmt` results as
  `github-actions[bot]`. On approval it pushed to a `<pr>/merge` ref instead
  of the PR branch.

### Fixed

- `dcvm create` now validates every VM name before creating anything: 3-64
  characters, letters, numbers, `_` and `-` only. Names with quotes or other
  unsafe characters (which produced broken cloud-init) and short names like
  `db` are now rejected.
- nginx/apache2 welcome page (`/var/www/html/index.html`) now shows the VM
  name and username instead of blanks; the heredoc was quoted, so the
  variables were never expanded.
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
  dcvm VM (and its storage), removes `DATACENTER_BASE` (including
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

PR #20 (25ef022), PR #21 (658ee60).

### Changed

- Lint and test workflows no longer run on pushes to `main`, only on PRs (#20).
- Installer output uses `print_status_log` consistently.

### Fixed

- Installer: `install_by_fetch` handles the `dcvm` binary explicitly after
  its move from `bin/dcvm` to the repository root, logging success/failure.

## [0.7.1] - 2025-12-18

PR #13 (12cdf24), PR #15 (c001e8b), PR #17 (e40e630), PR #19 (fde93c6).

Version jumped from 0.5.2 to 0.7.1 (no 0.6.x releases).

### Added

- Improved installer (`lib/installation/install-dcvm.sh`) (#13, 12cdf24).
- Full Arch Linux guest support and Arch cloud-init fixes (#15, c001e8b).
- `dcvm self-update` with version checks and backup/rollback (#17, e40e630).
- `dcvm create-iso` (`lib/core/custom-iso.sh`) for VMs from custom installer
  ISOs, replacing `create-from-iso.sh` (#17).
- Mirror manager (`lib/utils/mirror-manager.sh`) with mirror speed tests and
  fallbacks for Debian, Ubuntu and Arch Linux images (#17).
- Static IP option and interactive prompts for memory, CPUs and disk size (#17).
- CI workflows: version-bump enforcement (`version-bump.yaml`), quick test
  matrix (`test.yaml`), lint (`bash -n` + `shellcheck`) and `shfmt` format.
- `lib/utils/test-suite.sh` repository test suite.

### Changed

- License changed to Apache License 2.0.
- All shell scripts reformatted with `shfmt -i 2`.
- `dcvm` entry point moved from `bin/dcvm` to the repository root (#17).
- Unified logging format; `vm_exists` replaced by `check_vm_exists`;
  `fix-lock` argument handling and verbosity improved (#17).
- IP validation checks the address is inside the configured subnet (#17).

## [0.5.2] - 2025-11-18

Version `0.5.2` first appeared in `bin/dcvm` in de6400d (#12) on 2025-11-18.
Later commits (#13, #15, #17) kept the same version string, but they landed
after the `v0.5.2` tag, so they are listed under 0.7.1.

### Added

- Modular `bin/` + `lib/` layout and project documentation (#12, de6400d).

[Unreleased]: https://github.com/metharda/dcvm/compare/v0.9.6...HEAD
[0.9.6]: https://github.com/metharda/dcvm/compare/v0.9.5...v0.9.6
[0.9.5]: https://github.com/metharda/dcvm/compare/v0.9.4...v0.9.5
[0.9.4]: https://github.com/metharda/dcvm/compare/v0.9.3...v0.9.4
[0.9.3]: https://github.com/metharda/dcvm/compare/v0.9.2...v0.9.3
[0.9.2]: https://github.com/metharda/dcvm/compare/v0.9.1...v0.9.2
[0.9.1]: https://github.com/metharda/dcvm/compare/v0.9.0...v0.9.1
[0.9.0]: https://github.com/metharda/dcvm/compare/v0.8.0...v0.9.0
[0.8.0]: https://github.com/metharda/dcvm/compare/v0.7.2...v0.8.0
[0.7.2]: https://github.com/metharda/dcvm/compare/v0.7.1...v0.7.2
[0.7.1]: https://github.com/metharda/dcvm/compare/v0.5.2...v0.7.1
[0.5.2]: https://github.com/metharda/dcvm/releases/tag/v0.5.2
