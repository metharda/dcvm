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

### Fixed

- `backup export` refuses a descriptor that isn't a regular file opened for writing (#82).
- Ctrl-C exits 130 and a module killed by a signal 128+N, not 241; a client outside the `dcvm` group exits 77 (#73).
- VMs created by a `dcvm-admin` get the admin's SSH key (#74).
- A cancelled create no longer leaves a VM marked ready; its name, quota and staged ISO are freed (#80).
- In-place `backup restore` checks the quota (#79).
- `dcvm backup export ... --full` works over the socket (#71).
- `backup restore` checks the backup, base build and quota before it touches the existing VM, stops a paused VM too, and puts the old VM back if define fails (#75).
- `backup import` refuses to overwrite an existing backup and never deletes one it did not create (#75).
- `backup export` writes to the caller's file through the descriptor, never by reopening it as root (#82).
- `backup export` accepts `latest` and `<vm>-<id>` (#71).
- `dcvm create web,web` no longer overwrites the disk of the VM it just made: repeated names, newlines and empty entries are refused, and a failed create never removes a defined VM's folder (#78).
- cloud-init quotes the hostname, user and SSH key, so names like `yes` or `123` and key comments with `: ` or `#` work; root uses only the first key of `~/.ssh/id_rsa.pub`; `--tailscale-authkey` must look like `tskey-...` and `-k tailscale-exporter` no longer counts as Tailscale (#70).
- Declining "Create it?" exits 130, and a VM whose first start fails is undefined instead of left without a disk (#80).
- Helpers that run Python no longer import modules from the working directory (#81).
- DHCP lease cleanup reports a matched lease without an IPv4 address as not released, works on a stopped network without `dhcp_release`, and rewrites a 0-byte status file as `[]` (uninstall too) (#42).
- `dcvm network dhcp cleanup` goes on after a failed release and reports how many were released (#42).
- Lease MAC completion reads the `.status` file; nothing lists or truncates the unused `.leases` file any more (#43).
- `delete` no longer ends with "No DHCP leases found" after a failed release; the missing `dhcp_release` error names the package for every distro and shows only when a lease needs releasing (#44).
- `dcvm reap` keeps owner records while libvirt is not answering (#72).
- `dcvm info <missing vm>` exits 1; `dcvm ssh/exec/cp` keep its exit code and work without `/usr/local/bin` in `PATH` (#73).
- `dcvm exec`/`ssh`: remote command arguments can no longer be read as ssh options.
- `dcvm fix-lock` really repairs the definition (only the VM's own disk), says when nothing changed, and keeps VNC passwords (#83).
- `dcvm fix-lock` gives a running VM 60 seconds to shut down instead of 3.
- `dcvm doctor` reports a disk as locked or a template as corrupt only when qemu-img says so (#83).
- Installer: `--network-name VALUE` works, the bridge name fits 15 bytes, and a
  network that fails to define or start fails the install (#68).
- Debian/Ubuntu install `iptables`; `dcvm doctor` checks for it (#68).
- `dcvm network status` and `bridge` no longer abort when the bridge is missing (#69).
- DHCP cleanup and `doctor --fix` keep every lease whose MAC belongs to a VM,
  whatever the guest's hostname, and clean orphans without a hostname (#76).
- Port forwards rewrite only traffic to the host, so VM egress to ports
  2221+/8081+ is no longer redirected; `doctor --fix` or `dcvm network ports apply`
  replaces older rules (#77).
- `delete --all` removes only the deleted VMs' forwards and keeps a refused
  VM's lease, mapping and rules (#77).

## [0.9.10] - 2026-11-23

dcvm for people and agents without root, and Fedora 44. See
[Users and agents](docs/users.md).

**Upgrading:** `sudo dcvm self-update` installs the socket, the groups and the
`--ttl` timer by itself. Existing VMs and backups belong to root; let others in
with `sudo dcvm user add <user> [--admin]` and hand VMs over with
`sudo dcvm owner <vm> <user>`. Nothing changes for root.

### Added

- Users without root: members of the `dcvm` group run `dcvm` from their own
  accounts. A systemd socket starts one root process per request
  (`lib/server/dcvm-server.py`, Python standard library only) that identifies
  the caller from the kernel, checks every argument against what a user may
  do, the VM's owner, protection and quotas, takes a lock on the VM and runs
  the usual scripts with a clean environment. Files cross as file
  descriptors and secrets through a pipe, never as paths or command-line
  arguments. Members of `dcvm-admin` can do everything root can.
- VM owners (`/var/lib/dcvm/vms`) and backup owners: users see and change only
  their own VMs and backups. `dcvm list` and `dcvm status` show an OWNER
  column to root and admins, and `list --json` includes each VM's owner.
- Quotas per user (`/etc/dcvm/limits.conf`; defaults 5 VMs, 8 vCPUs, 16 GB
  memory, 200 GB disk).
- An audit log of every request through the socket
  (`/var/log/dcvm/audit.log`).
- For scripts and agents: `create --wait`, `--json` and `--ttl` (a timer
  deletes the VM afterwards), `list --json`, `info <vm> [--json]`, `whoami`,
  `ssh`, `exec` and `cp` with the caller's own key, `protect`/`unprotect`, and
  `dcvm help agents`. Without a terminal dcvm never asks; `delete` from a
  script by a non-root user needs `--yes`.
- `dcvm user add|remove|list [--admin]` and `dcvm owner <vm> <user>` for admins.
- `network ports add|remove <vm>`: forwards for one VM, without renumbering
  the others.
- VNC set up by a user without root gets a random password, shown only to the
  owner.
- Fedora 44 Cloud as OS 9, from ten mirrors, checked against Fedora's
  `CHECKSUM` file, with dnf package names and services in cloud-init.
- `dcvm doctor` checks that dcvm's files can't be changed by non-root users,
  warns about users also in `libvirt`, `disk` or `docker`, and removes owner
  records of deleted VMs.
- ISO VMs for agents: `create-iso` (and `create -o file.iso`) take
  `--json`, `--wait`, `--ttl` and `-u <login user>`, so an unattended ISO
  (an agent's own image) can be created, reached over SSH and thrown away.
- `--uefi` for ISO and cloud VMs. The installer adds the OVMF firmware.

### Changed

- Restored VMs and disks repaired by `fix-lock` are mode 600 (was 660, readable
  by the `kvm` group on Debian), and their folders 711.
- `self-update --revert` removes the socket before going back to an older
  version.

### Fixed

- `fix-lock` printed "libvirtd not responding" and "VM not found in libvirt
  after cleanup" after a successful run.
- `dcvm <command> --help` shows help for every command and role and never
  runs it. Before, `delete web --help` deleted `web`, `network stop --help`
  stopped the network and users got no help at all.
- Without a terminal, dcvm no longer waits forever on a question; errors go
  to stderr, so `--json` output stays clean.
- Agents can create VMs from an ISO (`create-iso -f` uses defaults) with
  `--ttl`; an ISO libosinfo doesn't recognize installs as a generic OS.
- `create --wait --json` reports `"ready"` and exits 1 if SSH never
  answered. `delete` exits non-zero when the VM survives and clears a record
  left by a create that never finished. `list --json` fails when libvirt
  doesn't answer.
- `ssh`, `exec` and `cp` say when the VM isn't running.
- Users can run `backup delete <vm> <id>` and use ids as `backup list`
  prints them; `--json` and `--verbose` work in any position.
- The `--ttl` reaper no longer races a command on the same VM.
- An ISO VM boots its disk and falls back to the ISO while the disk is
  empty, in a single definition: the installer's reboot lands in the
  installed OS and the VM keeps running. Before, the reboot powered the VM
  off, and restarting it mid-install lost the ISO.
- `delete --all` no longer removes the folder and disk of a VM it refused
  (a protected VM) or failed to delete, and `delete` keeps the disk when
  libvirt won't remove the VM.
- UEFI VMs can be deleted. Deleting a VM no longer lets libvirt remove
  storage, which could have taken a shared ISO with it.
- An option without its value (`dcvm create web -m`) no longer loops
  forever. `create-iso` refuses unknown options; `create -o file.iso`
  refuses options only cloud images use, including `-p`.
- `dcvm fix-lock --all` no longer stops libvirt VMs that aren't dcvm's.
  Declining `dcvm network dhcp renew` no longer renews every lease anyway.
  Restore refuses to replace a protected VM for root and admins too.
- `-k default-mysql-server` on Fedora installs MariaDB.
- A failed `create-iso` removes what it made; ISOs with a comma in their
  path work; ISO VMs get the disk and network devices the detected OS has
  drivers for, so Windows installers see their disk.

### Security

- A user could restore or export another user's backup by its exact id,
  after backing up a VM whose name starts with the other VM's name. Every
  backup path now checks the owner.
- Deleting a VM also removed the port forwards of addresses it prefixed
  (deleting `10.10.10.2` removed those of `.20` to `.29` and `.200` to
  `.254`), for root too.
- A static `--ip` or a port forward to an address another VM holds is
  refused.
- Restoring a backup as a new VM, or answering `create`'s prompts, can no
  longer go over a user's quota.
- The client's claim to run in a terminal is checked against the files it
  passes; `-pSECRET` no longer reaches the audit log; the client no longer
  overwrites an existing SSH private key.
- `dcvm console`, failure summaries and ownership errors no longer show
  other users' VMs.

## [0.9.9.1] - 2026-11-22

Security update. Hosts where other people use VMs, or that restore backups
from elsewhere, should update now.

**Upgrading:** after `sudo dcvm self-update`, run `sudo dcvm doctor --fix`.
It secures the NFS export if there is one and closes VM files and backups
to other local users. If it moved files out of the NFS share, a VM may have
had root on the host.

### Security

- NFS share: root in any VM could leave a setuid-root program in the share
  (`no_root_squash`, mode `1777`) that any local user on the host could run.
  The export now uses `all_squash` to a `dcvm-nfs` account, the share is mode
  `700`, and setuid and device files are moved to
  `$DATACENTER_BASE/quarantine/`.
- Restoring or importing a crafted backup could run commands or write files
  as root:
  - the base record's image name became a file path (`image=../../etc/…`);
  - a path in the VM definition was pasted into `sed` (whose `e` flag runs
    commands);
  - the definition itself was defined almost as is.

  Base records are now validated, and the definition is rebuilt from an
  allowlist (one disk, no host devices, shared folders, `qemu:commandline`,
  security labels or host paths).
- Backup disks must be plain qcow2: a qcow2 external data file, a VMDK
  extent or a `json:` backing could point a VM at a host file or another
  VM's disk. A backing path through `builds/../` is no longer accepted.
- Import archives may not contain links, and their file names cannot become
  VM names like `all` or `--all`, which commands read as "every VM".
- `cloud-init.iso` (password hash, Tailscale key, MySQL password), VM disks
  and backups were readable by every local user. New files are private, and
  `dcvm doctor --fix` closes existing ones.
- Exports no longer include the seed's `user-data`.
- `COLUMNS` or `UI_COLS` could run commands through shell arithmetic.
- `dcvm doctor --fix` removed leftover files with an unquoted `rm`: a file
  name with `*` deleted files in the working directory, such as `/bin`.
- `fix-lock` killed every QEMU process whose command line contained the VM
  name (`web` also matched `web-prod`) and deleted matching lock files in
  `/tmp`, `/var/tmp`, `/dev/shm` and `/var/lock`. It now uses libvirt's
  pidfile and that VM's own lock files.
- Port forwarding and the installer wrote fixed file names in `/tmp`, which
  another local user could replace with a symlink.
- VM addresses for port forwards and SSH came from the guest agent first,
  which a guest can make claim the gateway or another VM. Host-side DHCP
  leases (by MAC) and static records come first now, and only valid host
  addresses in the subnet are accepted.

### Changed

- `self-update` downloads into a staging folder and installs in one swap only
  when every file arrived, includes non-shell files, sets owner and modes
  itself, and runs the new version's `post-update.sh`; `--revert` swaps the
  saved version back in whole.
- VM names cannot start with a hyphen or be `all`, `latest` or `help`.
- The NFS line in new VMs' `/etc/fstab` has `nofail`, so a VM doesn't wait
  for the share at boot.
- `dcvm doctor` no longer suggests "updating" to an older release.

## [0.9.9] - 2026-11-21

Base images that can no longer be replaced under a VM, and `dcvm doctor`.
See [Base images](docs/base-images.md) and [dcvm doctor](docs/doctor.md).

**Upgrading:** VMs and backups made before this version refer to their
template by name and do not record their base build. Run `dcvm doctor` once:
it shows which VMs it can pin to their build and does so with `--fix` (a
running VM is pinned at its next start through dcvm). Until those disks and
backups are gone, dcvm deletes no base build.

### Added

- Immutable base builds: every downloaded cloud image is kept as
  `storage/templates/builds/<image>-<sha256:12>.<ext>` (a hardlink, no extra
  space) with its SHA-256 and SHA-512, and VM disks refer to that file instead
  of `templates/<image>`. An old build is deleted automatically once no VM,
  backup or template uses it.
- `dcvm template download -f` and `-a -f` move VMs onto the new build by
  themselves: stopped VMs at once, running ones the next time dcvm stops,
  restarts or backs them up (`--restart`: now, after asking). Moving uses
  qemu-img's safe rebase on a copy of the disk, so what the VM sees does not
  change and an interruption cannot damage the disk.
- Backups record the build their disk is on. Restore and import check for
  that build first: on the host, else they fetch exactly that build from the
  image's archive by checksum, and download a current build only when no
  template of the image exists; the restored VM then moves onto the current
  build. Backups from before this version are matched to a build with a
  read-only file system check. `--base <file>` names the build directly.
- `dcvm backup export --full` flattens the disk into one standalone file;
  the default stays thin and now includes the base record.
- `dcvm doctor [--fix] [--quiet]` checks the host (KVM, libvirt, missing
  tools with their install command, old `alias dcvm=` lines, a newer dcvm),
  the network (state, IP forwarding at boot, port forward rules missing after
  a reboot, stale leases), VMs (base build, stuck at boot without an address,
  autostart, locked disks), backups (base records, missing builds, VMs
  without a recent backup) and storage (free space for a backup, orphan VM
  folders, leftovers, corrupt templates). `--fix` repairs what is safe, for
  example restoring port forward rules, persisting IP forwarding, removing old
  aliases, saving an old base a running VM still holds open and moving VMs to
  the current build; `--quiet` prints only problems and fixes.
- dcvm runs `dcvm doctor` by itself: after `self-update` (new tools,
  services, VMs to pin), at boot through the new `dcvm-boot.service` (with
  `--fix` for the network, so port forward rules come back after a reboot),
  when `start`, `restart`, restore or `create` fail (the reason and the fix
  for that VM), as one line in `dcvm status` when a fast check finds
  problems, and hourly after the storage check (logged to the journal).
  `dcvm doctor` gained `--only <areas>`, `--vm <name>`, `--fast` and
  `--summary`.
- A backup checks the free space before it shuts the VM down, so a backup
  that cannot fit leaves the VM running.
- New VMs install pending updates on first boot (`package_upgrade`); Debian
  VMs get unattended-upgrades.
- Fedora hosts: the installer installs the packages with `dnf`, and
  `dcvm doctor` names Fedora's packages for missing tools.

### Fixed

- `dcvm template download --force` deleted the image before downloading the
  new one, so VMs and backups built on it broke at their next boot (the VM
  saw a mix of two file systems and hung), and a failed download left no
  image at all. The old build is now kept and the file is only replaced when
  the download succeeds.
- Restore downloaded the newest image when a backup's base was missing,
  which restored the disk onto a different build. It now restores only onto
  the exact build, and resolves it before touching an existing VM.
- IP forwarding was persisted in `/etc/sysctl.conf`, which Debian 13 no
  longer reads at boot. The installer and `dcvm network ip-forwarding on`
  now write `/etc/sysctl.d/90-dcvm.conf`.
- `dcvm storage` (and the hourly check) only checked the first running VM:
  `ssh` read the rest of the VM list from the loop's input.
- Backup forced a VM off 60 seconds after asking it to shut down, even while
  it was still booting. It now lets a VM that started less than 90 seconds
  ago finish booting, and on a terminal asks before forcing it off.
- The installer stopped at the packages step with `ID_LIKE: unbound variable`
  on distributions whose `/etc/os-release` has no `ID_LIKE` line, such as
  Fedora. Distribution detection is now one shared function for the
  installer and `dcvm doctor`.
- The installer stopped without a message after the packages step on Fedora
  and Arch: it looked for apt's `newly installed` line, and the failed match
  ended the script. It now reads the apt, dnf or pacman summary of this run.
- Port forwards did not reach VMs from other machines where libvirt uses its
  nftables firewall backend (the default on Fedora and Arch): libvirt rejects
  forwarded connections in its own table, which iptables rules cannot
  override. The installer sets `firewall_backend = "iptables"` in
  `/etc/libvirt/network.conf` and reapplies saved port forwards.
- With firewalld running, VMs could not mount the NFS share: libvirt's zone
  rejects NFS. The installer allows `nfs`, `rpc-bind` and `mountd` in the
  zone of dcvm's bridge.
- The NFS server was started but not enabled, so on Fedora it was off after a
  host reboot and every VM waited 90 seconds for `/mnt/shared` at boot.

## [0.9.8] - 2026-11-20

Security and correctness fixes found while rewriting the documentation.

**Upgrading:** install `aria2` once (`sudo apt install aria2`, or
`sudo pacman -S aria2`) for faster image downloads; self-update does not
install packages. `dcvm self-update` does not touch `/etc/exports`. If you
enabled the NFS share on a host installed before 0.9.8, it is exported to
every host (`*`); re-run the installer and answer `y` to the NFS question to
limit it to the dcvm subnet and make it writable for VM users.

### Added

- `dcvm create --disable-root` keeps root login off (`PermitRootLogin no`,
  root password locked), also in force mode, which otherwise turns root login
  on. It can't be combined with `-u root`, `--enable-root` or `-r`.
- Cloud image downloads are checked against the checksum their publisher
  lists next to them (`SHA256SUMS`, `SHA512SUMS` or `<file>.SHA256`), on the
  mirror used or on another mirror serving the same file name. A download
  that matches no published checksum is discarded and the next mirror is
  tried; if no mirror publishes one, the file is kept with a warning. Only
  the size was checked before.
- Image downloads use aria2c, which the installer now installs, fetching
  each image from the four fastest mirrors at once. aria2c support existed
  but never ran: the installer didn't install it. Without aria2, downloads
  use curl, one mirror at a time, as before.
- New cloud image mirrors in Europe, Asia and the Americas (GWDG,
  ftp.acc.umu.se, Yandex, NJU, CERNET and more), so the speed test picks a
  nearby one wherever dcvm runs. aria2c only combines mirrors that serve the
  same file as the fastest one (same name and size).

### Security

- The NFS share is exported to the dcvm subnet only, not to `*` (any host
  that could reach the NFS port could mount it read-write as root). Re-running
  the installer replaces the old export line.

### Changed

- New output for the long screens: `dcvm create`, `delete`, `backup create`
  and `restore`, `network ports setup/show/test`, `list`, `status`,
  `start/stop/restart` and the installer print a title, one aligned line per
  step (`✓`, `!`, `✗`), a spinner with elapsed time for slow steps, and a
  result line or box with next steps. `dcvm list` and `status` show a table
  of dcvm VMs and only count other libvirt VMs. The installer runs the
  package manager behind a spinner and logs its output. Details from the
  underlying tools are hidden on success and shown on failure;
  `DCVM_VERBOSE=1` shows everything. Colour is off when the output is not a
  terminal, with `NO_COLOR` or `TERM=dumb`, and symbols fall back to ASCII
  outside UTF-8 locales.
- The same design on every other screen: `dcvm network` (one overview of the
  network, DHCP leases, static IPs and port forwards with their checks) and
  its `status`, `leases`, `bridge`, `config`, `ip-forwarding` and `vnc`
  commands; `network ports rules/apply/clear`; `network dhcp`; `backup list`,
  `delete`, `export`, `import` and `ssh-setup`; `template`; `fix-lock` (one
  line per phase instead of `[N/9]` headers); `self-update`; `uninstall`;
  `storage`; `delete --all`; `start/stop/restart` without a VM name;
  `console` without a VM name; the interactive `dcvm create` wizard and
  `create-iso`. Help texts are reorganized and coloured on a terminal.
  `backup list` is one table for all VMs (VM state, ID, time taken, age,
  size, notes) with the total size. Image downloads (`dcvm template
  download`, `dcvm create` when the image is missing, backup restore and
  the installer) show the image with the chosen mirror, the downloader and
  a progress bar with size, speed and time left underneath, then collapse
  into one summary line.
- `dcvm self-update` keeps the version it replaced in `/var/lib/dcvm/backups`
  (the last 3), so `--revert` can undo an update that installed fine but
  broke something ([#55](https://github.com/metharda/dcvm/issues/55)). It
  deleted the copy after every successful update.
- `dcvm console <vm>` attaches to the VM's serial console, as `dcvm help`
  says. Without a name it still prints access hints, but no longer the
  incorrect `Default login: admin / admin123` line.
- `dcvm storage` / `storage-cleanup` (and the hourly timer) connect to each
  running dcvm VM's IP over SSH with the host's key and print its disk usage.
  They used the host address from `DATACENTER_IP`, which the installer never
  set, so every check failed silently; they also no longer wait 30 seconds or
  prompt for a password, run the cleanup with `sudo`, and archive to
  `/mnt/shared` only when the NFS share is mounted.
- The installer's slow steps use the same live block as downloads: a
  spinner with the step's latest output line underneath (Packages: a bar
  over downloading, unpacking and setting up), collapsing into the step's
  line when done; a failed step lists the tool's error lines under it. Every
  `ui_run` spinner (backups, exports, template checks) shows the latest
  output line the same way.

### Fixed

- `dcvm delete` printed `/etc/iptables/rules.v4: No such file or directory`
  on hosts without iptables-persistent. Rules are saved there only when
  `/etc/iptables` exists ([#54](https://github.com/metharda/dcvm/issues/54)).
- Long VM names pushed the columns of `backup list` and the `Next steps`
  lines together; both size their columns to the content now
  ([#56](https://github.com/metharda/dcvm/issues/56)).
- Tables dropped empty cells, so `dcvm list` showed a stopped VM's vCPU count
  under IP.
- `dcvm console` (without a VM name), `dcvm network config` and `dhcp renew`
  used `DATACENTER_IP` from the config for the host address, which the
  installer never sets, and printed an empty address. They detect it now,
  like `network ports setup`.
- `dcvm network bridge` always reported dnsmasq as not running.
- Most fallback mirrors were dead (404 or unreachable): Debian had 2 working
  of 5, Ubuntu 22.04 and 20.04 one each, Kali's second entry served 404.
  They are removed. Ubuntu 24.04 no longer mixes the daily `noble/current`
  build with the release build.
- The Kali image URL pointed to `cloud-images/current/` with the version in
  the file name, so it broke at every Kali release; it uses the release
  folder (`cloud-images/kali-2026.3/`) now. The second Kali URL
  (cdimage.kali.org) never worked: only kali.download has the cloud images.
- The installer started every stopped libvirt VM on the host, not only dcvm
  VMs, and stopped with an error right after starting the first one
  (`((n++))` at 0 fails under `set -e`). It now starts only VMs on the dcvm
  network and finishes.
- The installer always reported `NFS server is not installed` on hosts with
  many systemd units: `systemctl list-unit-files | grep -q` failed under
  `pipefail` when grep exited early.
- The NFS share folder was `root:root 755`, so only root in a guest could
  write to `/mnt/shared`. The installer now sets mode `1777` (writable for
  every VM user, sticky like `/tmp`).
- Guests mounted the NFS share from `10.10.10.1` and `dcvm delete --all`
  matched `10.10.10.` regardless of `NETWORK_SUBNET`; both use the configured
  subnet now, as does the installer's summary.

- The installer's network summary printed a stray `0` line under
  `NAT rules active`, and `dcvm network vnc enable|disable` printed
  `integer expression expected` from its "is the VM running" check when the
  VM was stopped. `$(... | grep -c pattern || echo 0)` captured the count
  twice (`grep -c` already prints `0` when nothing matches); these now use
  `|| true`, as does `dcvm self-update`'s file count. The test suite now fails
  on the pattern.
- `dcvm backup restore <vm>` (in place) gave the VM new MAC addresses, so a
  DHCP VM came back with a new IP and its saved port forwards pointed at the
  old one. Only a restore under a new name changes MACs now.
- Restore removed versioned q35 machine types such as `pc-q35-8.2` or
  `pc-q35-noble`, so libvirt fell back to i440fx and rejected the VM's PCIe
  controllers; every restore of a dcvm VM needed two failed `virsh define`
  attempts and printed PCI controller warnings. Restore now uses plain `q35`,
  which also works on a host with a different QEMU version.
- The installer failed on Ubuntu 26.04 with `Package 'qemu-kvm' has no
  installation candidate`: `qemu-kvm` became a virtual package there with two
  providers. It installs `qemu-system-x86` and `qemu-utils` directly, which
  works on every supported Debian and Ubuntu release, and uses `apt-get`
  instead of `apt` (no "unstable CLI" warning).
- Run through `curl … | bash` on a terminal narrower than 80 columns, the
  installer left a copy of a step's spinner line behind on every redraw
  (`Packages 14s`, `Packages 19s`, …): `tput` reported 80 columns there, so
  long output lines wrapped and the live block miscounted its height. The
  width now comes from the terminal itself, the block counts wrapped rows,
  and backslashes in tool output are printed as they are.
- On a host with an `alias dcvm=…/scripts/vm-manager.sh` line left in a shell
  startup file by an install before 0.9, every `dcvm` command failed with
  `no such file or directory: /srv/datacenter/scripts/vm-manager.sh`: the
  alias shadows `/usr/local/bin/dcvm`. The installer now removes such lines
  for root and the user who ran `sudo` (keeping a `.bak` copy), as the
  uninstaller already did.

## [0.9.7] - 2026-11-16

Small fixes for VM deletion, guest setup and DHCP lease cleanup.

### Changed

- The Kali Linux cloud image is now 2026.3; the 2025.4 image is no longer
  available (#45).
- The VM's `cloud-init` folder, which holds the user-data, is created with
  mode 700 (#45).

### Fixed

- `dcvm delete` destroys and undefines the VM's own libvirt storage pool, so
  no pool is left pointing at a removed folder. A missing pool is skipped, and
  other pools, including the templates folder, are never touched (#48).
- On Arch Linux, `-k docker.io` installs the `docker` package (#45).
- DHCP lease cleanup returns an error, and releases nothing, when it cannot
  write the lease status file back; it used to report success (#42).
- DHCP lease lines are matched only when their MAC address column holds a
  MAC address (#42).

## [0.9.6] - 2026-11-03

Bug fixes for VM passwords, DHCP lease matching and Arch Linux VMs.

**Upgrading:** `dcvm self-update` updates the dcvm files only and does not
install packages. On a host installed before 0.9.6, install `jq` and
`dnsmasq-utils` (Debian, Ubuntu, Kali) or `jq` (Arch Linux, whose `dnsmasq`
already ships `dhcp_release`); see
[Updating DCVM](docs/installation.md#updating-dcvm). Without them,
`dcvm network dhcp clear` (other than `--all`) fails with an error that names
the package to install, and `dcvm delete` still deletes the VM but prints that
error and leaves the VM's lease listed until it expires.

### Changed

- `-k mysql-server` installs MariaDB (service `mariadb`) on Debian 11/12/13,
  Kali and Arch Linux, which have no `mysql-server` package; only Ubuntu keeps
  MySQL. `-k default-mysql-server` also runs the database setup: it
  installs as named on Debian, Kali (MariaDB) and Ubuntu (MySQL), and as
  `mariadb` on Arch Linux. Other names containing `mysql` no longer trigger
  the setup (#36).
- With MariaDB (Debian, Kali, Arch Linux), the database root user keeps its
  passwordless login from the system root account (`sudo mariadb`) and also
  gets the VM password (#36).
- Passwords must not contain line breaks (`\n`, `\r`, U+0085 and the Unicode
  line and paragraph separators U+2028, U+2029). The length limit is still
  128 characters; its error now says "at most 128 characters" (#36).
- `dhcp clear <vm|mac>` and `dhcp clear --stale` no longer restart the
  network; only `dhcp clear --all` does. With no matching lease, `clear`
  says so and changes nothing (#37).
- `dhcp clear <vm|mac>`, `dhcp clear --stale` and `delete` release the
  cleared lease in the running dnsmasq with `dhcp_release` and remove it from
  libvirt's status file, so the address can be handed out again right away.
  Without `dhcp_release` or `jq`, `dhcp clear` fails with an error that names
  the package to install, and changes nothing. It also fails, instead of
  reporting success, when the status file cannot be read, the lock times out
  or `dhcp_release` itself fails (#37).
- `dhcp clear <vm>` keeps a static DHCP reservation for the VM's MAC;
  `delete` removes the deleted VM's reservation (#37).
- `delete` no longer stops or removes host systemd units whose name contains
  the VM name; dcvm does not create per-VM units.
- The installer also installs `jq` and `dhcp_release` (`dnsmasq-utils` on
  Debian/Ubuntu; Arch already gets it with `dnsmasq`), which lease cleanup
  uses (#37).

### Fixed

- Passwords containing ` #`, quotes, `\`, `$`, backticks or `: ` now work: the
  user, root and MySQL passwords are set to exactly the value entered (#36).
- MySQL setup no longer leaves `$VM_USERNAME`/`$VM_PASSWORD` unexpanded; with
  username `root` only the root password is set (#36).
- `-k docker` adds the VM user to the `docker` group (the name was not
  expanded) (#36).
- `dcvm network dhcp clear <vm>`, `delete` and the IP lookup match the whole
  hostname (any case), so `vm1` no longer hits `vm10` or `vm1-copy`, and a
  name such as `254` or `ipv4` no longer clears other leases (#37).
- Clearing a lease removes whole entries from the libvirt status file instead
  of single lines, which left invalid JSON (#37).
- `delete` without `jq`, or with a status file `jq` cannot parse, leaves the
  status file unchanged instead of emptying it, which dropped every VM's
  lease (#37).
- Arch Linux VMs get Arch package names (`openssh`, `nfs-utils`), the `sshd`
  unit, the Arch sftp-server path and Arch nginx/Apache paths (#38).
- A password changed inside the VM (`passwd`) now survives a reboot: the user
  and root passwords are set once at first boot, as SHA-512 hashes, instead of
  by a `bootcmd` that reset them on every boot (#36).
- nginx, Apache and Docker setup runs only for `-k nginx`, `-k apache2` (also
  `-k apache` on Arch Linux) and `-k docker`/`docker.io`; packages such as
  `nginx-extras`, `libapache2-mod-php` and `python3-docker` install as typed
  without it (#38).
- `dhcp clear` (all forms) and `delete` no longer send SIGHUP to dnsmasq,
  which never found libvirt's dnsmasq and does not drop leases, and no longer
  edit a `.leases` file, which libvirt does not use (#37).

### Security

- The root password is no longer written to user-data in plain text, and the
  user and root passwords are no longer part of a `bootcmd` shell command.
  With `-k mysql-server` or `-k default-mysql-server`, user-data still holds
  the VM password, base64-encoded, in the database setup file that the VM
  deletes after use (#36).

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
  automatic commit on the PR branch).

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

- Approval-triggered format workflow that auto-committed `shfmt` results
  from the GitHub Actions account. On approval it pushed to a `<pr>/merge`
  ref instead of the PR branch.

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

[Unreleased]: https://github.com/metharda/dcvm/compare/v0.9.10...HEAD
[0.9.10]: https://github.com/metharda/dcvm/compare/v0.9.9...v0.9.10
[0.9.9.1]: https://github.com/metharda/dcvm/pull/64
[0.9.9]: https://github.com/metharda/dcvm/compare/v0.9.8...v0.9.9
[0.9.8]: https://github.com/metharda/dcvm/compare/v0.9.7...v0.9.8
[0.9.7]: https://github.com/metharda/dcvm/compare/v0.9.6...v0.9.7
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
