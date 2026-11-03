# dcvm

[![Tests](https://github.com/metharda/dcvm/actions/workflows/test.yaml/badge.svg)](https://github.com/metharda/dcvm/actions/workflows/test.yaml)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-0.9.5-informational.svg)](CHANGELOG.md)

**Ready Linux VMs on one machine with one command: dcvm is a VM manager for students, homelabs, CTF and security practice, and anyone who wants a Linux box to try things on.**

<!-- DEMO GIF: placeholder, add docs/assets/demo.gif later -->

dcvm is a set of Bash scripts on top of KVM/QEMU and libvirt. `dcvm create myvm` builds a VM from a Debian, Ubuntu, Arch Linux or Kali Linux cloud image (or from an installer ISO), sets it up with cloud-init, and attaches it to a private NAT network with DHCP. Other `dcvm` commands start and stop VMs, forward host ports to them, and back them up, export and import them.

## Quick Installation

You can setup dcvm quickly with `curl` or `wget` commands: (you should be in root user)

| Method   | Command                                                                                                         |
| :------- | :-------------------------------------------------------------------------------------------------------------- |
| **curl** | `bash -c "$(curl -fsSL https://raw.githubusercontent.com/metharda/dcvm/main/lib/installation/install-dcvm.sh)"` |
| **wget** | `bash -c "$(wget -qO- https://raw.githubusercontent.com/metharda/dcvm/main/lib/installation/install-dcvm.sh)"`  |

### Review before you run

The one-liners above run the installer as root without showing it to you first. To read it before it runs, download it, review it, then run it:

```bash
curl -fsSL -o install-dcvm.sh https://raw.githubusercontent.com/metharda/dcvm/main/lib/installation/install-dcvm.sh
less install-dcvm.sh
sudo bash install-dcvm.sh
```

The installer then downloads the rest of dcvm from the same repository and branch (`metharda/dcvm`, `main`, or `DCVM_REPO_SLUG` and `DCVM_REPO_BRANCH` below). To review everything before installing, use the [Manual Installation](#manual-installation) steps instead.

### Custom Branch or Fork Installation

You can install from a different branch or fork using environment variables:

| Use Case                                     | Command                                                                                                                                                                              |
| :------------------------------------------- | :----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Install from a specific branch**           | `DCVM_REPO_BRANCH=<awesome-branch> bash -c "$(curl -fsSL https://raw.githubusercontent.com/metharda/dcvm/<awesome-branch>/lib/installation/install-dcvm.sh)"`                        |
| **Install from a fork**                      | `DCVM_REPO_SLUG=<yourusername>/dcvm bash -c "$(curl -fsSL https://raw.githubusercontent.com/<yourusername>/dcvm/main/lib/installation/install-dcvm.sh)"`                             |
| **Install from a fork with specific branch** | `DCVM_REPO_SLUG=yourusername/dcvm DCVM_REPO_BRANCH=feature-test bash -c "$(curl -fsSL https://raw.githubusercontent.com/<yourusername>/dcvm/main/lib/installation/install-dcvm.sh)"` |

**Available environment variables:**

- `DCVM_REPO_SLUG`: Repository in format `owner/repo` (default: `metharda/dcvm`)
- `DCVM_REPO_BRANCH`: Branch name (default: `main`)

## Features

### Virtual Machine Management

- **Automated VM Creation**: Debian 11/12/13, Ubuntu 20.04/22.04/24.04, Kali Linux and Arch Linux based VMs with cloud-init support
- **Custom ISO Support**: Create VMs from any installer ISO (Windows, Arch, Fedora, etc.)
- **User-Friendly Wizard**: Step-by-step VM configuration
- **Resource Optimization**: Automatic sizing based on host system resources
- **Package Management**: Pre-installed packages like nginx, apache2, mysql-server, docker

### Network Management

- **Isolated Network**: Private NAT network (`datacenter-net` by default, 10.10.10.0/24)
- **Automatic DHCP**: Dynamic IP assignment
- **Port Forwarding**: Automatic port forwarding for SSH and HTTP access
- **VNC Management**: Enable/disable VNC graphics for remote access
- **Connection Testing**: VM accessibility verification

### Storage & Backup

- **Shared NFS**: File sharing between VMs
- **Automated Backup**: Snapshot backup system
- **Storage Monitoring**: Disk usage tracking and cleanup
- **Archiving**: Automatic archiving of old files

### System Management

- **Centralized Management**: All operations through `dcvm` command
- **Self-Update**: Update DCVM with a single command
- **System Services**: systemd integration
- **Log Management**: Detailed operation logs
- **Security**: SSH key-based secure access

## Why dcvm?

| Tool | What it is for | Hosts | Worth knowing |
| :--- | :------------- | :---- | :------------ |
| **dcvm** | Ready Linux VMs from a built-in menu of 8 cloud images (Debian 11/12/13, Ubuntu 20.04/22.04/24.04, Arch Linux, Kali Linux), or any installer ISO | Linux with KVM and libvirt; the installer sets up dependencies on Debian/Ubuntu-based and Arch-based hosts | One CLI also covers a private NAT network, SSH/HTTP port forwarding from the host (`dcvm network ports setup`), backups with export/import between hosts, VNC on/off and an NFS share. Needs root. |
| [Multipass](https://documentation.ubuntu.com/multipass/en/latest/) | Cloud-style Ubuntu VMs (plus other Linux images), customised with cloud-init | Linux, macOS, Windows | Cross-platform, has a GUI client, and has snapshots, clones and folder mounts built in |
| [Vagrant](https://developer.hashicorp.com/vagrant/intro) + [vagrant-libvirt](https://vagrant-libvirt.github.io/vagrant-libvirt/) | Reproducible development environments described in a `Vagrantfile` | Vagrant runs on Linux, macOS and Windows; vagrant-libvirt needs libvirt and QEMU | The environment lives in a file you can commit and share, so a team gets the same VM with `vagrant up`; provisions with shell scripts, Chef or Puppet |
| [virt-install](https://github.com/virt-manager/virt-manager/blob/main/man/virt-install.rst) | libvirt's command-line tool for provisioning KVM, Xen or container guests | Linux with libvirt | Exposes libvirt's install methods (ISO, network install tree, PXE, existing disk, unattended installs, cloud-init) and fine-grained device options; you choose and combine them yourself |
| [quickemu](https://github.com/quickemu-project/quickemu) | Quickly creating and running optimised Windows, macOS and Linux VMs with QEMU; `quickget` downloads the OS image | Linux, macOS | Supports far more guest systems (including macOS and Windows), runs VMs without elevated permissions, and has SPICE, file sharing and USB pass-through |

dcvm is a convenience layer for one Linux host: it handles the image, network, user and SSH key setup and port forwards for you, and its VMs are ordinary libvirt domains created with `virt-install`, so `virsh` still works on them. Choose another tool if you need a macOS host (Multipass, quickemu, Vagrant) or a Windows host (Multipass, Vagrant), macOS or tuned Windows guests (quickemu), an environment defined in a file that others can recreate (Vagrant), snapshots instead of full backups (Multipass), or full control over every libvirt option (virt-install).

## Requirements

### Hardware

- **CPU**: VT-x/AMD-V capable processor
- **RAM**: Minimum 4GB (8GB+ recommended)
- **Disk**: 50GB+ free space
- **Network**: Internet connection

### Software

- **Operating System**: Ubuntu 20.04+, Debian 11+, Arch Linux
- **Virtualization**: KVM/QEMU support
- **Root Access**: sudo/root privileges

## Installation

### Quick Install (Recommended)

See installation commands at the top of this README.

### Manual Installation

If you prefer step-by-step installation:

#### 1. Clone Repository

```bash
git clone https://github.com/metharda/dcvm.git
cd dcvm
```

#### 2. Run Installation Script

```bash
sudo bash lib/installation/install-dcvm.sh
```

#### 3. Verify Installation

```bash
dcvm --version
dcvm status
```

For detailed installation instructions, see [Installation Guide](docs/installation.md).

## Quick Start

### Create Your First VM

```bash
# Interactive mode (recommended for first time)
dcvm create myvm

# Or use force mode with defaults (defaults to Ubuntu 24.04)
dcvm create myvm -f -p mypassword123
```

### Check VM Status

```bash
dcvm list
dcvm status myvm
```

### Connect to Your VM

```bash
# Find VM IP
dcvm network

# SSH username: -u <name> if you set one at create time, otherwise the OS
# default (e.g. ubuntu, debian). create-iso VMs have no recorded user, so
# SSH hints fall back to admin as a guess.
# For Ubuntu 24.04 (default OS):
ssh ubuntu@<vm-ip>
```

## Usage Guide

### Basic Commands

```bash
# Create VMs
dcvm create myvm                     # Interactive mode
dcvm create webserver -f -p pass123  # Force mode with password (Ubuntu 24.04)
dcvm create myvm -o /path/to/iso     # Create from custom ISO
dcvm create-iso myvm --iso /path/to/archlinux.iso  # Alternative ISO syntax

# Manage VMs
dcvm list                            # List all VMs
dcvm start myvm                      # Start VM
dcvm stop myvm                       # Stop VM
dcvm restart myvm                    # Restart VM
dcvm delete myvm                     # Delete VM
dcvm console myvm                    # Connect to console

# Network
dcvm network                         # Show network info
dcvm network ports setup             # Setup port forwarding
dcvm network vnc status myvm         # Check VNC status
dcvm network vnc disable myvm        # Disable VNC (free port)
dcvm network vnc enable myvm         # Enable VNC

# Storage & Backup
dcvm backup myvm                     # Backup VM
dcvm restore myvm                    # Restore VM
dcvm storage                         # Show storage info
dcvm storage-cleanup                 # Clean up storage

# System
dcvm fix-lock                        # Fix locked resources
dcvm self-update                     # Update to latest version
dcvm self-update --check             # Check for updates
dcvm uninstall                       # Uninstall DCVM
dcvm --version                       # Show version
dcvm --help                          # Show help
```

For detailed usage, see [Usage Guide](docs/usage.md).

## Documentation

- **[Installation Guide](docs/installation.md)** - Detailed installation instructions
- **[Usage Guide](docs/usage.md)** - Complete command reference
- **[Examples](docs/examples/)** - Practical examples and tutorials

## Project Structure

```
dcvm/                     # repository root
├── dcvm                  # CLI entry point
├── lib/                  # core, installation, network, storage, utils
├── docs/                 # guides and architecture notes
└── .github/workflows/    # CI
```

See [docs/project-structure.md](docs/project-structure.md) for the full layout.

### Bulk Operations

```bash
# Manage all VMs
dcvm start                           # Start all VMs
dcvm stop                            # Stop all VMs
dcvm restart                         # Restart all VMs

# Network management
dcvm network ports setup             # Port forwarding setup
dcvm network dhcp show               # Show DHCP leases
dcvm network dhcp clear -a           # Clear all leases
```

### VM Creation Example

```bash
# Create web server
dcvm create web-server nginx,mysql-server

# After VM creation:
# 1. IP address is automatically assigned
# 2. SSH access is prepared
# 3. Port forwarding is configured
# 4. NFS share is mounted
```

## Network Configuration

### Default Network Settings

- **Network Range**: 10.10.10.0/24
- **Gateway**: 10.10.10.1
- **DHCP Pool**: 10.10.10.100-10.10.10.254
- **DNS**: Host system DNS

### Port Mapping

- **SSH**: starts at port 2221 (one host port per VM)
- **HTTP**: starts at port 8081 (one host port per VM)
- **See current mappings**: `dcvm network ports show`
- **Access**: `ssh -p <ssh-port> <username>@<host-ip>` — username is `-u` if set at create time, otherwise the OS default; create-iso VMs fall back to `admin` as a guess

## Directory Structure

```
/srv/datacenter/
├── vms/                    # VM disk files
│   ├── vm1/
│   │   ├── vm1-disk.qcow2
│   │   └── cloud-init/
├── storage/
│   └── templates/          # Base OS images
├── nfs-share/              # Shared files
├── backups/                # VM backups
└── scripts/                # Management scripts
```

## Script Descriptions

### Main Scripts

- **`install-dcvm.sh`**: System installation and startup
- **`vm-manager.sh`**: Central VM management interface

### Helper Scripts

- **`create-vm.sh`**: New VM creation wizard
- **`delete-vm.sh`**: VM deletion and cleanup
- **`backup.sh`**: Backup and restore
- **`setup-port-forwarding.sh`**: Port forwarding setup
- **`storage-manager.sh`**: Storage space management
- **`dhcp.sh`**: DHCP management
- **`fix-lock.sh`**: System lock fix

## Security

### Access Control

- SSH key-based authentication
- Strong password policies
- Isolated network environment
- Privilege control

### Security Best Practices

```bash
# SSH key creation
ssh-keygen -t rsa -b 4096 -f ~/.ssh/dcvm-key

# Firewall settings
ufw enable
ufw allow 22
ufw allow 2220:2250/tcp  # SSH ports
ufw allow 8080:8090/tcp  # HTTP ports
```

## Monitoring and Maintenance

### System Status

```bash
dcvm status                 # General system status
virsh list --all           # All VMs
virsh net-list             # Network status
```

### Log Files

```bash
tail -f /var/log/datacenter-startup.log        # System logs
tail -f /var/log/datacenter-storage.log        # Storage logs
journalctl -u libvirtd                         # KVM/QEMU logs
```

### Performance Monitoring

```bash
# VM resource usage
virsh domstats --cpu-total --balloon

# Network traffic
virsh domifstat vm-name vnet0

# Disk I/O
virsh domblkstat vm-name vda
```

## Troubleshooting

### Common Issues

#### No KVM Support

```bash
# Check CPU virtualization support
egrep -c '(vmx|svm)' /proc/cpuinfo

# Load KVM modules
modprobe kvm
modprobe kvm_intel  # For Intel
modprobe kvm_amd    # For AMD
```

#### Network Connection Issues

```bash
# Restart network
virsh net-destroy datacenter-net
virsh net-start datacenter-net

# DHCP cleanup
dcvm network dhcp clear -a
```

#### VM Startup Issues

```bash
# Check VM state
virsh domstate vm-name

# Check VM logs
virsh console vm-name

# Check disk file
ls -la /srv/datacenter/vms/vm-name/
```

### Complete System Reset

```bash
# WARNING: Deletes all VMs!
dcvm delete --all

# Restart system services
systemctl restart libvirtd
./install-dcvm.sh
```
## License
This project is licensed under the Apache License, Version 2.0.
See the `LICENSE` file for details.