# Operations

Running a dcvm host day to day: what the commands do, how to read their
checks, updates, logs, settings and fixes for common problems. The full flag
reference is in [usage.md](usage.md).

- [Everyday commands](#everyday-commands)
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
| List VMs | `dcvm list` | All libvirt VMs, then the ones on the dcvm network with their state |
| Overview | `dcvm status` | VMs, port-forward rules, networks and each dcvm VM's IP (takes no VM name) |
| Start / stop / restart | `dcvm start web`, `dcvm stop web`, `dcvm restart web` | Without a name: every dcvm VM. `stop` is a graceful ACPI shutdown |
| Find a VM's IP | `dcvm status`, or `dcvm network` | `dcvm network` also lists static IPs and saved port mappings |
| SSH from the host | `ssh <user>@<vm-ip>` | `<user>` is `-u`, or the OS name (`ubuntu`, `debian`, `archlinux`, `kali`) |
| Reach VMs from other machines | `dcvm network ports setup` | Run again after starting or adding VMs; see [Networking](networking.md#port-forwarding) |
| Serial console | `virsh console web` | Exit with `Ctrl+]` |
| Access summary | `dcvm console` | Prints SSH/HTTP/console hints for VMs with port mappings; it does not attach to a console |
| Back up / restore | `dcvm backup create web`, `dcvm backup restore web` | The VM is shut down during the backup; see [Backups](backups.md) |
| Delete | `dcvm delete web` | No confirmation prompt; removes the disk, leases, port forwards and static IP record |
| Images | `dcvm template status`, `dcvm template download <file>` | Installed images with an integrity check |

## Reading the checks

**`dcvm network ports test`** (also part of `dcvm network`) prints one row per
saved mapping:

```
VM_NAME        : Ping  SSH   HTTP
web            : ✓     ✓     ✗
```

| Column | ✓ means |
| :----- | :------ |
| Ping | The VM answers ICMP on its dcvm IP |
| SSH | The DNAT rule for the SSH host port and its FORWARD accept rule exist, and port 22 on the VM accepts TCP connections |
| HTTP | The same for the HTTP host port and port 80 |

An `✗` under HTTP is normal for a VM without a web server. An `✗` under SSH
with a `✓` under Ping usually means the rules are gone (run
`dcvm network ports apply`) or the VM is still booting.

**`dcvm delete`** ends with a verification block: `✓ VM completely removed
from libvirt`, `✓ No DHCP leases found` and `✓ Disk file removed`. A
`✗ DHCP leases still exist` line is harmless (the lease expires); run
`dcvm network dhcp cleanup` to drop it now.

**`dcvm template status`** marks each installed image `✓` (readable qcow2) or
`✗ ... CORRUPT` (redownload it with `dcvm template download <file> --force`,
which breaks VMs built on the old file).

## After a host reboot

- The dcvm network and every VM created by dcvm have autostart on, so they
  come back with libvirt.
- IP forwarding is persisted in `/etc/sysctl.conf` by the installer.
- Port-forward rules live in iptables only. They come back only if your
  system restores `/etc/iptables/rules.v4` at boot (for example the
  `iptables-persistent` package). Otherwise run:

  ```bash
  dcvm network ports apply   # rebuild rules from $DATACENTER_BASE/port-mappings.txt
  ```

  If VMs got new DHCP addresses, use `dcvm network ports setup` instead,
  which rediscovers them.

## Updating dcvm

```bash
dcvm self-update --check    # compare the installed version with GitHub
dcvm self-update            # download and install the new files
dcvm self-update --force    # reinstall even if the version is the same
dcvm self-update --revert   # go back to the copy saved before the last update
```

Self-update replaces the files in `/usr/local/bin` and `/usr/local/lib/dcvm`
and keeps the previous version in `/var/lib/dcvm/backups`. It does not install
packages: when a release needs a new dependency, its
[CHANGELOG](../CHANGELOG.md) entry says so (0.9.6 added `jq` and
`dnsmasq-utils`; see [Installation](installation.md#updating-dcvm)). VMs,
backups and settings are not touched.

## Logs and monitoring

| Log | Written by |
| :-- | :--------- |
| `/var/log/datacenter-startup.log` | Installer (falls back to `/tmp/dcvm-install.log`) |
| `/var/log/dcvm-backup.log` | `dcvm backup` |
| `/var/log/datacenter-storage.log` | `dcvm storage` / `storage-cleanup` and its hourly timer |
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
`datacenter-storage.timer`, that runs `dcvm storage-cleanup` every hour
(`dcvm storage` runs the same check by hand; it prints nothing and writes to
its log). After a 30-second delay it connects over SSH to each VM that has a
port mapping and, when the VM's root file system is more than 85% full,
moves files older than 30 days from `/tmp` and old logs to
`/mnt/shared/archived-files`. It reaches VMs through the host address in
`DATACENTER_IP` in `/etc/dcvm-install.conf`, which the installer does not
set; without it every check logs `Failed to check disk usage`. Check disk use
with the `du` and `virsh domblkinfo` commands above instead.

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
| `dcvm create` fails at the template step | No internet or every mirror failed | `dcvm template check <file>` to test mirrors, then `dcvm template download <file>` |
| VM runs but `ssh` is refused | First boot still running (about a minute, longer with packages) | Wait, or watch with `virsh console <vm>`; inside: `cloud-init status --wait` |
| `Permission denied (publickey,password)` | Wrong user name | Use the `-u` name, or the OS name (`ubuntu`, `debian`, `archlinux`, `kali`) |
| A `-k` package is missing in the VM | That package failed to install | Read `/var/log/dcvm-packages.log` inside the VM |
| Port forward not reachable from another machine | Rules missing after reboot, host firewall, or VM not running at setup time | `dcvm network ports test`, then `ports apply` or `ports setup`; open the ports in your firewall |
| Port forward not reachable from the host itself | DNAT rules apply to traffic arriving from outside, not to the host's own connections | From the host, use the VM's IP directly |
| VM has no IP in `dcvm status` | Still booting, or a stale lease | `dcvm network dhcp show`; `dcvm network dhcp cleanup` |
| `dcvm network dhcp clear` names a missing package | Host installed before 0.9.6 | Install `jq` and `dnsmasq-utils` (Arch: `jq`) |
| `Failed to get "write" lock` / VM won't start because its disk is locked | Stale QEMU process or libvirt lock, or two VMs using one disk | `dcvm fix-lock <vm>` (force-stops the VM, clears its locks and reports other VMs on the same disk); `--all` for every VM |
| Backup restore says the backing file is missing | The VM's cloud image was removed from `storage/templates` | Restore downloads it again; it must be the same image file the VM was built on |
| VNC port in use | Several VMs with VNC | `dcvm network vnc disable <vm>` on VMs that don't need it |
| `dcvm self-update` fails | GitHub unreachable or rate-limited | Retry later, `--force`, or re-run the installer |
| Out of disk space | Backups and images | `du -sh $DATACENTER_BASE/*`; delete old backups with `dcvm backup delete <vm>` |

If none of these fit, open an issue with the command, its output and the
relevant log from the table above.
