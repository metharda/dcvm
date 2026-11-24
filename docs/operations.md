# Operations

Running a dcvm host day to day: what the commands do, how to read their
checks, updates, logs, settings and fixes for common problems. The full flag
reference is in [usage.md](usage.md).

- [Everyday commands](#everyday-commands)
- [Output](#output)
- [Reading the checks](#reading-the-checks)
- [After a host reboot](#after-a-host-reboot)
- [Updating dcvm](#updating-dcvm)
- [Logs and monitoring](#logs-and-monitoring)
- [Settings](#settings)
- [Troubleshooting](#troubleshooting)

See also: [Architecture](architecture.md) · [Security](security.md) ·
[Networking](networking.md) · [Backups](backups.md)

## Everyday commands

All commands need root.

| Task | Command | Notes |
| :--- | :------ | :---- |
| List VMs | `dcvm list` | Table of dcvm VMs (state, IP, vCPU, memory); other libvirt VMs are only counted |
| Overview | `dcvm status` | The same table, plus the network and port-forward state (takes no VM name) |
| Start / stop / restart | `dcvm start web`, `dcvm stop web`, `dcvm restart web` | `all` for every dcvm VM (`start` without a name too). `stop` is a graceful ACPI shutdown; `stop <vm> --force` powers off a guest that ignores it |
| Find a VM's IP | `dcvm status`, or `dcvm network` | `dcvm network` also lists static IPs and saved port mappings |
| SSH from the host | `ssh <user>@<vm-ip>` | `<user>` is `-u`, or the OS name (`ubuntu`, `debian`, `archlinux`, `kali`) |
| Reach VMs from other machines | `dcvm network ports setup` | Run again after starting or adding VMs; see [Networking](networking.md#port-forwarding) |
| Serial console | `dcvm console web` | Exit with `Ctrl+]` |
| Access summary | `dcvm console` | Without a VM name: SSH, HTTP and console hints for VMs with port mappings |
| Back up / restore | `dcvm backup create web`, `dcvm backup restore web` | The VM is shut down during the backup; see [Backups](backups.md) |
| Delete | `dcvm delete web` | No confirmation prompt; removes the disk, leases, port forwards and static IP record |
| Images | `dcvm template status`, `dcvm template download <file>` | Installed images with an integrity check; `-f` gets the newest build and moves VMs onto it |
| Health | `dcvm doctor`, `dcvm doctor --fix` | Base images of VMs and backups, kept builds, leftover downloads |

## Output

Long commands print one line per step: `✓` done, `!` done with something to
check, `✗` failed, `·` skipped. Slow steps (shutting a VM down, copying and
compressing a disk, installing packages) show a spinner with the seconds
elapsed. Details from the underlying tools are hidden when a step succeeds
and printed when it fails.

| Setting | Effect |
| :------ | :----- |
| `DCVM_VERBOSE=1` | Show every detail line (the old output), and no spinners |
| `NO_COLOR=1` | No colours ([no-color.org](https://no-color.org)); also off when the output is not a terminal or `TERM=dumb` |
| Non-UTF-8 locale or `TERM=dumb` | ASCII symbols (`+`, `x`, `!`, `-`) instead of `✓ ✗ ! ·` |

The installer writes everything, including the package manager's output, to
`/var/log/datacenter-startup.log`.

## Reading the checks

**`dcvm network ports test`** (also part of `dcvm network`) prints one row per
saved mapping:

```
  VM   PING  SSH  HTTP
  web  ✓     ✓    ✓
  ctf  ✓     ✓    ✗
```

| Column | ✓ means |
| :----- | :------ |
| Ping | The VM answers ICMP on its dcvm IP |
| SSH | The DNAT rule for the SSH host port and its FORWARD accept rule exist, and port 22 on the VM accepts TCP connections |
| HTTP | The same for the HTTP host port and port 80 |

An `✗` under HTTP is normal for a VM without a web server. An `✗` under SSH
with a `✓` under Ping usually means the rules are gone (run
`dcvm network ports apply`) or the VM is still booting.

**`dcvm delete`** checks that nothing is left and ends with
`✓ ctf deleted  No DHCP leases found, no VM or disk left`. Otherwise it lists
what remains as warnings. `! DHCP leases still exist` is harmless (the lease
expires); run `dcvm network dhcp cleanup` to drop it now.

**`dcvm template status`** marks each installed image `✓` (readable qcow2) or
`✗ ... CORRUPT` (redownload it with `dcvm template download <file> --force`;
VMs move onto the new build by themselves, see
[Base images](architecture.md#base-images)).

**`dcvm doctor`** checks the host, the dcvm network, VMs and their base
images, backups and storage, says how to fix each problem, and repairs what
is safe with `--fix`. dcvm also runs it by itself: after `self-update`, at
boot (to bring port forwards back), when `start`, `restart`, restore or
`create` fail, as one line in `dcvm status`, and hourly. Every check and
repair is described in [dcvm doctor](doctor.md).

## After a host reboot

- The dcvm network and every VM created by dcvm have autostart on, so they
  come back with libvirt.
- IP forwarding is persisted in `/etc/sysctl.d/90-dcvm.conf` by the installer
  (`dcvm doctor` checks that it is applied at boot).
- Port-forward rules live in iptables only. `dcvm-boot.service` (installed by
  the installer, or by `dcvm doctor --fix` on hosts set up earlier) runs
  `dcvm doctor --fix --quiet --only network` after libvirt starts: it starts
  the dcvm network if needed and rebuilds the saved port forwards. By hand:

  ```bash
  dcvm network ports apply   # rebuild rules from $DATACENTER_BASE/port-mappings.txt
  ```

  If VMs got new DHCP addresses, use `dcvm network ports setup` instead,
  which rediscovers them (`dcvm doctor` reports changed addresses).

## Updating dcvm

```bash
dcvm self-update --check    # compare the installed version with GitHub
dcvm self-update            # download and install the new files
dcvm self-update --force    # reinstall even if the version is the same
dcvm self-update --revert   # go back to a version saved by an earlier update
```

Self-update replaces the files in `/usr/local/bin` and `/usr/local/lib/dcvm`
and keeps the version it replaced in `/var/lib/dcvm/backups` (the last 3). It does not install
packages: when a release needs a new dependency, its
[CHANGELOG](../CHANGELOG.md) entry says so (0.9.6 added `jq` and
`dnsmasq-utils`; see [Installation](installation.md#updating-dcvm)). VMs,
backups and settings are not touched.

## Logs and monitoring

| Log | Written by |
| :-- | :--------- |
| `/var/log/datacenter-startup.log` | Installer (falls back to `/tmp/dcvm-install.log`) |
| `/var/log/dcvm-backup.log` | `dcvm backup` |
| `/var/log/dcvm/audit.log`, `journalctl -u 'dcvm@*'` | Every request from a user without root: who, what, allowed or denied, exit status ([Users and agents](users.md#audit-log)) |
| `/var/log/dcvm-reaper.log` | VMs deleted because their `--ttl` ran out |
| `/var/log/datacenter-storage.log` | `dcvm storage` / `storage-cleanup` and its hourly timer: per-VM disk usage |
| `/var/log/cloud-init-output.log`, `/var/log/dcvm-packages.log` | Inside a VM: first boot, and `-k` packages that failed to install |
| `journalctl -u libvirtd` | libvirt and QEMU |

Useful libvirt commands for a closer look:

```bash
virsh list --all                      # every VM and its state
virsh domstats web --cpu-total --balloon
virsh domblkinfo web vda              # disk size and allocation
virsh net-dhcp-leases datacenter-net  # current DHCP leases
du -sh /srv/datacenter/{vms,backups,storage/templates}
```

**Storage check.** The installer adds a systemd timer,
`datacenter-storage.timer`, that runs `dcvm storage-cleanup` every hour;
`dcvm storage` runs the same check by hand. For each running dcvm VM it
connects over SSH to the VM's IP with the host root's key (never prompting
for a password) and prints and logs the root file system usage:

```
  ✓ web             root file system 7% used
```

When a VM is more than 85% full, it gzips logs older than 7 days and, if the
NFS share is mounted in the guest, moves `/tmp` files older than 30 days and
compressed logs older than 30 days to `/mnt/shared/archived-files/<vm>`,
leaving symlinks. A VM created with `--without-ssh-key` shows
`could not check disk usage over SSH`; an ISO-installed VM with no login user
on record is skipped. If the cleanup fails (no passwordless `sudo` in the VM,
a file it could not move) the VM is reported as failed, and a share that is
not mounted as a warning.

## Settings

`/etc/dcvm-install.conf` is written by the installer and read by every
command:

| Key | Default | Meaning |
| :-- | :------ | :------ |
| `DATACENTER_BASE` | `/srv/datacenter` | Where VMs, images, backups and the NFS share live |
| `NETWORK_NAME` | `datacenter-net` | libvirt network the VMs use |
| `BRIDGE_NAME` | `virbr-dc` | Bridge of that network |
| `NETWORK_SUBNET` | `10.10.10` | First three octets of the `/24` |
| `DCVM_LIB_DIR` | `/usr/local/lib/dcvm` | Library directory (optional) |

Changing these after VMs exist does not move or reconfigure anything. Other
values are fixed in the scripts: VM defaults (2048 MB, 2 vCPUs, 30G disk,
Ubuntu 24.04) in `create-vm.sh`; backup retention (5 per VM) and shutdown
timeout (60 s) in `backup.sh`. Port forwards start at `SSH_PORT_START=2221`
and `HTTP_PORT_START=8081`, which can be set in the environment of
`dcvm network ports setup`.

## Troubleshooting

| Symptom | Likely cause | Fix |
| :------ | :----------- | :-- |
| Installer: `CPU does not support KVM` or `/dev/kvm not present` | Virtualization off in firmware, or a VM without nested virtualization | Enable VT-x/AMD-V in BIOS/UEFI; for a VM host, enable nested KVM. Check with `grep -cE 'vmx\|svm' /proc/cpuinfo` and `ls -l /dev/kvm` |
| `Configuration file not found: /etc/dcvm-install.conf` | dcvm not installed, or a clone run before installing | Run the installer |
| `Network 'datacenter-net' does not exist` | Network removed or never created | `sudo bash /usr/local/lib/dcvm/installation/install-dcvm.sh --network-only` |
| `dcvm create` fails at the template step | No internet, every mirror failed, or downloads didn't match their published checksum | `dcvm template check <file>` to test mirrors, then `dcvm template download <file>` |
| VM runs but `ssh` is refused | First boot still running (about a minute, longer with packages) | Wait, or watch with `dcvm console <vm>`; inside: `cloud-init status --wait` |
| `Permission denied (publickey,password)` | Wrong user name | Use the `-u` name, or the OS name (`ubuntu`, `debian`, `archlinux`, `kali`) |
| A `-k` package is missing in the VM | That package failed to install | Read `/var/log/dcvm-packages.log` inside the VM |
| Port forward not reachable from another machine | Rules missing after reboot, host firewall, or VM not running at setup time | `dcvm network ports test`, then `ports apply` or `ports setup`; open the ports in your firewall |
| Port forward not reachable from the host itself | DNAT rules apply to traffic arriving from outside, not to the host's own connections | From the host, use the VM's IP directly |
| VM has no IP in `dcvm status` | Still booting, or a stale lease | `dcvm network dhcp show`; `dcvm network dhcp cleanup` |
| `dcvm network dhcp clear` names a missing package | Host installed before 0.9.6 | Install `jq` and `dnsmasq-utils` (Arch: `jq`) |
| `Failed to get "write" lock` / VM won't start because its disk is locked | Stale QEMU process or libvirt lock, or two VMs using one disk | `dcvm fix-lock <vm>` (shuts the VM down, forced after 60 s, clears its locks and reports other VMs or processes on the same disk); `--all` for every VM (asks first; `--yes` without a terminal) |
| Restore says the base build is not on this host or in the archive | The backup's build is gone (a daily build, Kali, or deleted by hand) | Restore on the host it came from, or pass the original build with `--base <file>` |
| A VM hangs at boot after a template was re-downloaded (before 0.9.9) | The template was replaced under the VM's disk | `dcvm doctor --fix`; if the old base is gone, `dcvm backup restore <vm>` (restore finds the build a backup fits) |
| VNC port in use | Several VMs with VNC | `dcvm network vnc disable <vm>` on VMs that don't need it |
| `dcvm self-update` fails | GitHub unreachable or rate-limited | Retry later, `--force`, or re-run the installer |
| Out of disk space | Backups and images | `du -sh $DATACENTER_BASE/*`; delete old backups with `dcvm backup delete <vm>` |

If none of these fit, open an issue with the command, its output and the
relevant log from the table above.
