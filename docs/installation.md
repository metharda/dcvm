# Installation Guide

This guide will walk you through installing dcvm, a VM manager, on your system.

## Prerequisites

### Hardware Requirements

- **CPU**: VT-x/AMD-V capable processor (hardware virtualization support)
- **RAM**: Minimum 4GB (8GB+ recommended)
- **Disk**: 50GB+ free space
- **Network**: Internet connection for downloading VM templates

### Software Requirements

- **Operating System**: Ubuntu 20.04+, Debian 11+, Arch Linux, Fedora
- **Privileges**: Root access required
- **Virtualization**: KVM/QEMU support

## Quick Installation

### Using curl

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/metharda/dcvm/main/lib/installation/install-dcvm.sh)"
```

### Using wget

```bash
bash -c "$(wget -qO- https://raw.githubusercontent.com/metharda/dcvm/main/lib/installation/install-dcvm.sh)"
```

To read the installer before it runs as root, download it first:

```bash
curl -fsSL -o install-dcvm.sh https://raw.githubusercontent.com/metharda/dcvm/main/lib/installation/install-dcvm.sh
less install-dcvm.sh
sudo bash install-dcvm.sh
```

The installer downloads the rest of dcvm from the same repository, all from
the commit the branch points to when it starts. To install from a fork or
another branch, set:

- `DCVM_REPO_SLUG`: `owner/repo` (default: `metharda/dcvm`)
- `DCVM_REPO_BRANCH`: branch name (default: `main`)

```bash
DCVM_REPO_SLUG=you/dcvm DCVM_REPO_BRANCH=my-branch \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/you/dcvm/my-branch/lib/installation/install-dcvm.sh)"
```

## Manual Installation

### 1. Check Virtualization Support

Verify that your CPU supports virtualization:

```bash
# Check for virtualization support
egrep -c '(vmx|svm)' /proc/cpuinfo
```

If the output is greater than 0, your CPU supports virtualization.

### 2. Clone the Repository

```bash
git clone https://github.com/metharda/dcvm.git
cd dcvm
```

### 3. Run the Installer

```bash
sudo bash lib/installation/install-dcvm.sh
```

It installs this checkout only when no other user can change it: the
checkout and every folder above it must belong to root or to you (the
`sudo` caller) and not be writable by group or others, and so must every
file in it. Otherwise it prints a warning and installs from GitHub instead.

### 4. Follow the Installation Wizard

In a terminal, the installer asks (press Enter for the default):

- Installation directory (default: `/srv/datacenter`)
- Network name (default: `datacenter-net`)
- Bridge name (default: `virbr-dc`)
- Network subnet (default: `10.10.10`, for `10.10.10.0/24`)
- Whether to download all eight cloud images now, or each one on its first
  `dcvm create`
- Whether to enable tab completion in your shell (default: yes)
- Whether to set up the NFS shared folder (default: no; see
  [Security](security.md#network-exposure))

Without a terminal (for example piped input) it uses the defaults, skips the
image download and does not set up NFS. The first four answers are saved to
`/etc/dcvm-install.conf`; running the installer again reuses them.

## Installation Process

The installer will:

1. Install the packages with `apt` (Debian, Ubuntu and derivatives),
   `pacman` (Arch and derivatives) or `dnf` (Fedora): QEMU/KVM, libvirt, virt-install,
   genisoimage/cdrtools, libguestfs-tools, NFS utilities, `jq`, dnsmasq tools,
   `aria2` (fast image downloads), Python 3 (the socket for users without root)
2. Check that the CPU supports KVM and `/dev/kvm` exists
3. Install `dcvm` to `/usr/local/bin` and its libraries to `/usr/local/lib/dcvm`
4. Start libvirtd
5. Create the directories under the installation directory
6. Offer to download the cloud images
7. Enable IP forwarding (and persist it in `/etc/sysctl.d/90-dcvm.conf`)
8. Create the NAT network (DHCP `.10`-`.200`, autostart on)
9. Offer tab completion and the NFS share
10. Start stopped VMs on the dcvm network (other VMs on the host are left alone)
11. Install `datacenter-storage.timer`, which runs `dcvm storage-cleanup` and a
    quiet `dcvm doctor` hourly, `dcvm-boot.service`, which brings the dcvm
    network and port forwards back after a reboot, `dcvm.socket` with the
    `dcvm` and `dcvm-admin` groups, for users without root, and
    `dcvm-reaper.timer`, which deletes VMs whose `--ttl` has passed
12. Offer to make the user who ran `sudo` a dcvm admin, so they can use dcvm
    without sudo from their next login ([Users and agents](users.md))

On a fresh Ubuntu 24.04 host (a GitHub runner, when recording the README
demo) the package install took 47 seconds and the rest a few more.

The NFS share, if you enable it, is exported to the dcvm subnet only. On a
host installed before 0.9.8 it was exported to every host; run the installer
again and answer `y` to the NFS question to limit it.

## Post-Installation

### Verify Installation

Check that DCVM is installed correctly:

```bash
dcvm --version
```

### Check System Status

View the status of the services dcvm relies on:

```bash
systemctl status libvirtd
systemctl list-timers datacenter-storage.timer
systemctl status nfs-server   # only if you enabled the NFS share
```

### Test Network Configuration

Verify the virtual network:

```bash
dcvm network
```

## Configuration

### Main Configuration File

Location: `/etc/dcvm-install.conf`

It holds `DATACENTER_BASE`, `NETWORK_NAME`, `BRIDGE_NAME` and
`NETWORK_SUBNET`, read by every dcvm command. Changing a value later does not
move existing files or reconfigure the network. See
[Operations › Settings](operations.md#settings) for the other knobs.

### Network Configuration

For advanced network configuration, see [Networking Guide](networking.md).

## Troubleshooting

### Virtualization Not Enabled

If you get an error about virtualization support:

**BIOS Settings:**

1. Reboot your system
2. Enter BIOS/UEFI settings
3. Enable Intel VT-x or AMD-V
4. Save and reboot

### Permission Issues

Ensure you're running as root:

```bash
sudo -i
```

### Network Conflicts

If you have network conflicts:

```bash
# Check existing networks
virsh net-list --all

# Modify network settings during installation
```

### Missing Dependencies

Manually install dependencies:

```bash
# Ubuntu/Debian
sudo apt update
sudo apt install qemu-system-x86 qemu-utils libvirt-daemon-system libvirt-clients \
    bridge-utils virt-manager nfs-kernel-server jq dnsmasq-utils aria2

# Arch Linux
sudo pacman -S qemu-full libvirt virt-install virt-viewer \
    bridge-utils nfs-utils cdrtools dnsmasq ebtables iptables dmidecode jq aria2

# Fedora
sudo dnf install qemu-system-x86 qemu-img libvirt-daemon-kvm libvirt-daemon-config-network \
    libvirt-client virt-install bridge-utils nfs-utils genisoimage libguestfs guestfs-tools \
    jq dnsmasq dnsmasq-utils iptables-nft aria2
```

## Uninstallation

To completely remove DCVM:

```bash
dcvm uninstall
```

Or manually:

```bash
sudo bash /usr/local/lib/dcvm/installation/uninstall-dcvm.sh
```

> [!WARNING]
> **Uninstalling DCVM is destructive and cannot be undone.** `dcvm uninstall` asks for confirmation first, then will:
>
> - **Permanently delete every DCVM VM** (all VMs attached to the dcvm network, `datacenter-net` by default), including their disks and storage (`virsh undefine --remove-all-storage`). Disk volumes the domain references are removed wherever they live on the host.
> - **Remove the entire `DATACENTER_BASE` directory** (`rm -rf "$DATACENTER_BASE"`), which includes **all VM backups** stored in `$DATACENTER_BASE/backups`. It is left alone if it has no `vms/` and `storage/` folders or is a system folder such as `/`, `/var` or `/home`.
> - Remove the dcvm network, port-forwarding rules, DHCP leases, the NFS share's line in `/etc/exports`, the storage service, the `dcvm` command/libraries, and `/etc/dcvm-install.conf`.
> - Delete `/var/log/datacenter-startup.log`.
> - Remove `alias dcvm` and `dcvm-completion.sh` lines from `~/.bashrc`, `~/.zshrc`, `~/.bash_profile`, and `~/.profile` (leaving `.bak` copies), and remove the bash completion scripts.
>
> To keep a VM, either detach it from the dcvm network before uninstalling (uninstall only deletes VMs attached to it), or save its definition (`virsh dumpxml <vm>`) and copy its disk images off the host. Copy any backups you want out of `$DATACENTER_BASE/backups`.

## Updating DCVM

To update to the latest version:

```bash
dcvm self-update
```

After an update, dcvm runs a short `dcvm doctor --quiet` that lists anything
the new version needs from you (tools to install, services, VMs to pin).
`sudo dcvm doctor --fix` repairs the safe ones; see [dcvm doctor](doctor.md).

To check for updates without installing:

```bash
dcvm self-update --check
```

Every file comes from the same commit. If GitHub has an older version than
the installed one, `dcvm self-update` changes nothing; `--force` installs it
anyway, and `--revert` goes back to a version saved on this host.

### aria2 (0.9.8)

Since 0.9.8 the installer installs `aria2`, and image downloads use it to
fetch each image from the fastest mirrors at once. On a host installed
earlier, install it once (`sudo apt install aria2`, or `sudo pacman -S aria2`);
without it, downloads use curl, one mirror at a time, as before.

### Dependencies added in 0.9.6

`dcvm self-update` updates the dcvm files only; it does not install packages.
Since 0.9.6, DHCP lease cleanup (`dcvm network dhcp clear` and `dcvm delete`)
needs `jq` and `dhcp_release`, which the installer now installs. On a host
installed before 0.9.6, install them once:

```bash
# Debian, Ubuntu, Kali
sudo apt update
sudo apt install jq dnsmasq-utils

# Arch Linux (dhcp_release comes with dnsmasq)
sudo pacman -S jq
```

Without them, `dcvm network dhcp clear` (other than `--all`) fails with an
error that names the package to install, and `dcvm delete` still deletes the
VM but prints that error and leaves the VM's DHCP lease listed until it
expires.

## Next Steps

After installation:

1. Read the [Usage Guide](usage.md)
2. Create your first VM
3. Explore [Examples](examples/)

## Support

For issues and questions:

- GitHub Issues: https://github.com/metharda/dcvm/issues
- Documentation: [docs/](https://github.com/metharda/dcvm/tree/main/docs) and [Operations › Troubleshooting](operations.md#troubleshooting)
