# dcvm doctor

One command that checks everything dcvm depends on, explains each problem
with its fix, and repairs what is safe to repair. It also runs by itself at
the moments problems usually appear. New in 0.9.9.

- [Running it](#running-it)
- [What it checks](#what-it-checks)
- [What --fix repairs](#what---fix-repairs)
- [Options](#options)
- [Automatic runs](#automatic-runs)
- [Reading the output](#reading-the-output)

See also: [Base images](base-images.md) · [Operations](operations.md) ·
[Troubleshooting](operations.md#troubleshooting)

## Running it

```bash
sudo dcvm doctor          # report
sudo dcvm doctor --fix    # report and repair what is safe
```

```
Doctor  host, network, vms, backups, storage, builds

Host
  ✓ KVM             /dev/kvm present, libvirt answering
  ✓ Tools           all present
  ✓ Shell alias     no old dcvm alias
  ✓ Services        hourly storage check, boot service
  ✓ dcvm            0.9.9, the latest

Network  datacenter-net
  ✓ datacenter-net  active, autostart, bridge virbr-dc, DHCP running
  ! IP forwarding   on but not persisted (off after a reboot): --fix turns it on
  · Port forwards   none saved
  ✓ DHCP leases     no stale leases

VMs
  VM       STATE      IP           BASE                                                 STATUS
  deneme   ● running  10.10.10.82  ubuntu-24.04-server-cloudimg-amd64-04e8f2461a16.img  ✓ current build
  deneme2  ● running  10.10.10.12  ubuntu-24.04-server-cloudimg-amd64-04e8f2461a16.img  ✓ current build

Backups  /srv/datacenter/backups
  ✓ Records         2 with a base record, 4 from before 0.9.9 (matched by a file system check when restored)

Storage  /srv/datacenter
  ✓ Free space      163 GB free
  ✓ Leftovers       no files from interrupted operations
  ✓ Templates       all pass qemu-img check

Builds  /srv/datacenter/storage/templates/builds
  BUILD                                                USED BY
  ubuntu-24.04-server-cloudimg-amd64-04e8f2461a16.img  current template, deneme, deneme2, 2 backups
  ubuntu-24.04-server-cloudimg-amd64-6e7016f2c9f4.img  kept: disks or backups from before 0.9.9 may need it

! 1 problem found  dcvm doctor --fix repairs what it safely can
```

It takes a few seconds; `--fast` skips the two slow checks.

## What it checks

### Host

| Check | Problem it finds |
| :---- | :--------------- |
| KVM | `/dev/kvm` missing (virtualization off in the firmware, or no nested KVM), or libvirt not answering |
| Tools | Missing `qemu-img`, `virsh`, `virt-install`, `jq`, `dhcp_release`, `aria2c`, `guestfish`, `virt-customize`, `xz`, `curl` or `genisoimage`, with the `apt install` / `pacman -S` / `dnf install` command for your distribution. `dcvm self-update` replaces dcvm's files but never installs packages, so updated hosts can miss tools a release needs |
| Shell alias | An `alias dcvm=…` line in `.bashrc`, `.zshrc`, `.profile`, … of root or the user who ran sudo. Installs before 0.9 added it; it hides `/usr/local/bin/dcvm` and every command fails with `no such file or directory` |
| Services | `datacenter-storage.timer`, `dcvm-boot.service`, the socket for users without root (`dcvm.socket`) or the `--ttl` timer (`dcvm-reaper.timer`) missing, disabled or from an older version (see [Automatic runs](#automatic-runs)) |
| Install | dcvm's files, `/etc/dcvm-install.conf` or a folder above them (such as a group-writable `/usr/local`) changeable by a non-root user, who could then run code as root through dcvm |
| Users | Members of `dcvm` who are also in `libvirt`, `disk` or `docker`, which is root on the host and bypasses dcvm's limits |
| NFS share | An export without `all_squash`, a share other host users can open, or setuid/device files left in it: root in a VM could get root on the host this way (see [Security](security.md#network-exposure)) |
| Permissions | VM disks or installer ISOs open to other local users, cloud-init seed folders and files (password hashes) not 700/600 and owned by root, VM folders other users can list, or a backups folder they can open |
| dcvm | A newer version on GitHub (skipped with `--fast` and when offline) |

### Network

| Check | Problem it finds |
| :---- | :--------------- |
| The dcvm network | Not defined, inactive or without autostart; its bridge missing; its DHCP server (dnsmasq) not running |
| IP forwarding | Off (VMs have no internet), or on but not applied at boot. dcvm asks systemd which files it loads: Debian 13 no longer reads `/etc/sysctl.conf` |
| Port forwards | Saved mappings without live iptables rules, as after every reboot; a VM whose address changed since the mapping was saved |
| DHCP leases | Leases that expired or belong to VMs that no longer exist |

### VMs

A table with each VM's state, IP, base build and base status, then one line
per other problem:

| Check | Problem it finds |
| :---- | :--------------- |
| Base | On an older build (moves at its next start, or now with `--fix` if it is off); a disk from before 0.9.9 not pinned yet; a base that was replaced after the VM was created (see [Base images](base-images.md#upgrading-from-098-or-earlier)); a missing base build |
| Stuck at boot | Running for more than 3 minutes without an address, with its CPU use. A VM busy at 100% with no address is usually hung at boot; look at `dcvm console <vm>` |
| Autostart | A dcvm VM that does not start with the host |
| Locked disk | A stopped VM whose disk is still locked, so it would not start (`dcvm fix-lock <vm>`) |
| Owners | Owner records left for VMs that no longer exist |

### Backups

| Check | Problem it finds |
| :---- | :--------------- |
| Records | How many backups record their base build and how many are from before 0.9.9 |
| Base builds | A recorded build that is not on this host (restore then fetches it from the archive, if it is there) |
| Coverage | dcvm VMs with no backup, or whose newest backup is older than 30 days (informational) |

### Storage

| Check | Problem it finds |
| :---- | :--------------- |
| Free space | Less free space than the largest VM disk (a backup could not fit), or less than twice its size |
| VM folders | Folders in `$DATACENTER_BASE/vms` without a VM (reported only: they may hold data) |
| Leftovers | Files older than an hour from interrupted downloads, restores or base moves |
| Templates | Templates that fail `qemu-img check` (skipped with `--fast`) |

### Builds

The base builds in `templates/builds/` and what uses each: the current
template, VMs, backups, VMs that will be pinned at their next start, or
nothing. See [Base images](base-images.md#builds).

## What --fix repairs

`--fix` changes only what can be changed without risk or a decision from you:

| Problem | Repair |
| :------ | :----- |
| dcvm network inactive or without autostart | Started and set to autostart |
| IP forwarding off or not persisted | Turned on and written to `/etc/sysctl.d/90-dcvm.conf` |
| Port forward rules missing | `dcvm network ports apply` |
| Stale DHCP leases | `dcvm network dhcp cleanup` |
| Old `alias dcvm=` lines | Removed (a `.bak` copy of the file is kept); open a new shell afterwards |
| Services missing or outdated | Installed and enabled, with the `dcvm` and `dcvm-admin` groups |
| dcvm's files changeable by others | Made root-owned and not group- or world-writable (folders above them are only reported) |
| Owner records of deleted VMs | Removed |
| Unsafe NFS export | `all_squash` to the `dcvm-nfs` account, share mode `700`, setuid and device files moved to `$DATACENTER_BASE/quarantine/` |
| Loose permissions | VM files `600`, VM folders `711`, backups folder `700` |
| VM without autostart | Autostart turned on |
| Old base still held open by a running VM | Saved into `builds/`, and the VM is pinned to it at its next start |
| VM from before 0.9.9 | Pinned to its build (a running one at its next start) |
| Stopped VM on an older build | Moved onto the current build |
| Unused builds | Deleted (never while disks or backups from before 0.9.9 exist) |
| Leftover files | Deleted |

What it leaves to you, with the command to run: missing packages, a locked
disk (`dcvm fix-lock`), a changed VM address (`dcvm network ports setup`),
low disk space, orphan VM folders, corrupt templates and broken VMs (restore
a backup).

## Options

| Option | Effect |
| :----- | :----- |
| `--fix` | Repair what is safe (above) |
| `--quiet` | Print only problems and what `--fix` repaired; exit status 1 when problems remain. For scripts and timers |
| `--only <areas>` | Comma separated: `host`, `network`, `vms`, `backups`, `storage`, `builds`. Example: `--only network,vms` |
| `--vm <name>` | Only this VM in the `vms` area |
| `--fast` | Skip the slow checks: the newer-version lookup, template integrity, and the CPU measurement of a VM stuck at boot |
| `--summary` | One line, and only when there are problems (used by `dcvm status`) |

```bash
dcvm doctor --only network --fix      # what dcvm-boot.service runs, with --quiet
dcvm doctor --only vms --vm web       # one VM
dcvm doctor --quiet || echo "dcvm needs attention"
```

## Automatic runs

dcvm runs the doctor by itself where problems usually show up:

| When | What runs | Why |
| :--- | :-------- | :-- |
| After `dcvm self-update` | `--quiet --fast --only host,vms` | Self-update only replaces files: this shows tools a release needs, services to install and VMs to pin |
| At boot (`dcvm-boot.service`) | `--fix --quiet --only network` | iptables rules are not saved across reboots: the network and port forwards come back on their own |
| `dcvm start`, `restart` or a restore fails | `--quiet --fast --only host,network,vms --vm <vm>` | The reason (lock, base image, network) and the fix, right after the error |
| `dcvm create` fails | `--quiet --fast --only host,network,storage` | Missing tools, network or disk space |
| `dcvm status` | `--summary` | One line when something needs attention |
| Hourly (`datacenter-storage.timer`) | `--quiet --fast`, after the storage check | Problems go to the journal: `journalctl -u datacenter-storage.service` |

The installer sets up `dcvm-boot.service` and the timer. On hosts installed
before 0.9.9, `dcvm doctor` reports them as missing and `dcvm doctor --fix`
installs them:

```bash
systemctl status dcvm-boot.service datacenter-storage.timer
journalctl -u dcvm-boot.service -b       # what it fixed at this boot
```

## Reading the output

- `✓` fine, or repaired (`--fix`)
- `!` a problem; the text says what to do, and whether `--fix` handles it
- `✗` a problem that stops something from working
- `·` information, not a problem

The last line counts the problems: `✓ No problems found`, `! 2 problems
found`, or after `--fix`, `! 1 problem left`. With `--quiet`, only `!`, `✗`
and repaired lines are printed, and the exit status is 0 only when no
problems remain.
