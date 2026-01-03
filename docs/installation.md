# Installation Guide

This guide will walk you through installing DCVM (Datacenter Virtual Machine Manager) on your system.

## Prerequisites

### Hardware Requirements

- **CPU**: VT-x/AMD-V capable processor (hardware virtualization support)
- **RAM**: Minimum 4GB (8GB+ recommended)
- **Disk**: 50GB+ free space
- **Network**: Internet connection for downloading VM templates

### Software Requirements

- **Operating System**: Ubuntu 20.04+, Debian 11+, Arch Linux
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

Optional: you can override the download source via environment variables if needed:

- DCVM_REPO_TARBALL_URL: Full tar.gz URL to download the repo
- DCVM_REPO_SLUG: owner/repo (default: metharda/dcvm)
- DCVM_REPO_BRANCH: branch name (default: main)

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

### 4. Follow the Installation Wizard

The installer will prompt you for:

- Installation directory (default: `/srv/datacenter`)
- Network name (default: `datacenter-net`)
- Bridge name (default: `virbr-dc`)

## Installation Process

The installer will:

1. ✅ Check system requirements
2. ✅ Install required packages (qemu-kvm, libvirt, etc.)
3. ✅ Configure KVM/QEMU virtualization
4. ✅ Set up the virtual network
5. ✅ Create directory structure
6. ✅ Configure NFS for shared storage
7. ✅ Set up systemd services
8. ✅ Install the `dcvm` command

## Post-Installation

### Verify Installation

Check that DCVM is installed correctly:

```bash
dcvm --version
```

### Check System Status

View the status of DCVM services:

```bash
systemctl status libvirtd
systemctl status nfs-server
```

### Test Network Configuration

Verify the virtual network:

```bash
dcvm network
```

## Configuration

### Main Configuration File

Location: `/etc/dcvm-install.conf`

Edit this file to customize:

- Base directory
- Network settings
- Storage configuration
- Backup settings

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
sudo apt install qemu-kvm libvirt-daemon-system libvirt-clients \
    bridge-utils virt-manager nfs-kernel-server

# Arch Linux
sudo pacman -S qemu-full libvirt virt-install virt-viewer \
    bridge-utils nfs-utils cdrtools dnsmasq ebtables iptables dmidecode
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

**Warning**: This will remove DCVM but will NOT delete your VMs!

## Updating DCVM

To update to the latest version:

```bash
dcvm self-update
```

To check for updates without installing:

```bash
dcvm self-update --check
```

## Next Steps

After installation:

1. Read the [Usage Guide](usage.md)
2. Create your first VM
3. Explore [Examples](examples/)

## Support

For issues and questions:

- GitHub Issues: https://github.com/metharda/dcvm/issues
- Documentation: https://github.com/metharda/dcvm/docs
