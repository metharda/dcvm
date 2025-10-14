# DCVM - Datacenter Virtual Machine Manager

**DCVM** is a comprehensive bash script collection that allows you to easily manage your KVM/QEMU-based virtual datacenter environment. It's a powerful tool that automates virtual machine creation, management, backup, and monitoring operations.

## 🚀 Quick Installation

You can setup dcvm quickly with `curl` or `wget` commands: (you should be in root user)

| Method    | Command                                                                                           |
| :-------- | :------------------------------------------------------------------------------------------------ |
| **curl**  | `bash -c "$(curl -fsSL https://raw.githubusercontent.com/metharda/dcvm/main/install/install-dcvm.sh)"`    |
| **wget**  | `bash -c "$(wget -qO- https://raw.githubusercontent.com/metharda/dcvm/main/install/install-dcvm.sh)"`    |

## ✨ Features

### Virtual Machine Management
- **Automated VM Creation**: Debian 12-based VMs with cloud-init support
- **User-Friendly Wizard**: Step-by-step VM configuration
- **Resource Optimization**: Automatic sizing based on host system resources
- **Package Management**: Pre-installed packages like nginx, apache2, mysql-server, docker

### Network Management
- **Isolated Network**: Private datacenter-net network (10.10.10.0/24)
- **Automatic DHCP**: Dynamic IP assignment
- **Port Forwarding**: Automatic port forwarding for SSH and HTTP access
- **Connection Testing**: VM accessibility verification

### Storage & Backup
- **Shared NFS**: File sharing between VMs
- **Automated Backup**: Snapshot backup system
- **Storage Monitoring**: Disk usage tracking and cleanup
- **Archiving**: Automatic archiving of old files

### System Management
- **Centralized Management**: All operations through `dcvm` command
- **System Services**: systemd integration
- **Log Management**: Detailed operation logs
- **Security**: SSH key-based secure access

## 📋 Requirements

### Hardware
- **CPU**: VT-x/AMD-V capable processor
- **RAM**: Minimum 4GB (8GB+ recommended)
- **Disk**: 50GB+ free space
- **Network**: Internet connection

### Software
- **Operating System**: Ubuntu 20.04/22.04, Debian 11/12
- **Virtualization**: KVM/QEMU support
- **Root Access**: sudo/root privileges

## 📦 Installation

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
sudo bash install/install-dcvm.sh
```

#### 3. Verify Installation
```bash
dcvm --version
dcvm status
```

For detailed installation instructions, see [Installation Guide](docs/installation.md).

### 🔁 Shell Tab Completion (Bash/Zsh)

We provide tab completion for dcvm commands, VM names and backup/DHCP subcommands.

What it completes:
- Top-level commands: create, delete, list, start, stop, restart, console, network, setup-forwarding, clear-leases, backup, storage, storage-cleanup, fix-lock, uninstall, version, help
- VM names for commands like: delete, start, stop, restart, console, status, backup create/restore/delete/export/troubleshoot
- DHCP helpers: subcommands (show, clear-mac, clear-vm, clear-all, cleanup, renew, files, help) and known MAC addresses from leases

Quick enable (recommended on macOS zsh):
1) Copy the completion script to a shared location:
	sudo mkdir -p /usr/local/share/dcvm
	sudo cp completions/dcvm-completion.sh /usr/local/share/dcvm/
2) Add this line to your ~/.zshrc:
	source /usr/local/share/dcvm/dcvm-completion.sh
3) Restart your shell: exec zsh

Bash (Linux) system-wide:
1) Ensure bash-completion is installed.
2) Copy the script to bash completion dir:
	sudo mkdir -p /etc/bash_completion.d
	sudo cp completions/dcvm-completion.sh /etc/bash_completion.d/dcvm
3) Restart your shell.

Notes:
- The script auto-detects zsh and enables bashcompinit automatically.
- Lease MAC suggestions read dnsmasq leases from /var/lib/libvirt/dnsmasq/<bridge>.leases when readable.

## 🎯 Quick Start

### Create Your First VM

```bash
# Interactive mode (recommended for first time)
dcvm create myvm

# Or use force mode with defaults
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

# SSH into VM
ssh admin@<vm-ip>
```

## 📚 Usage Guide

### Basic Commands

```bash
# Create VMs
dcvm create myvm                     # Interactive mode
dcvm create webserver -f -p pass123  # Force mode with password

# Manage VMs
dcvm list                            # List all VMs
dcvm start myvm                      # Start VM
dcvm stop myvm                       # Stop VM
dcvm restart myvm                    # Restart VM
dcvm delete myvm                     # Delete VM
dcvm console myvm                    # Connect to console

# Network
dcvm network                         # Show network info
dcvm setup-forwarding                # Setup port forwarding

# Storage & Backup
dcvm backup myvm                     # Backup VM
dcvm restore myvm                    # Restore VM
dcvm storage                         # Show storage info
dcvm storage-cleanup                 # Clean up storage

# System
dcvm fix-lock                        # Fix locked resources
dcvm --version                       # Show version
dcvm --help                          # Show help
```

For detailed usage, see [Usage Guide](docs/usage.md).

## 📖 Documentation

- **[Installation Guide](docs/installation.md)** - Detailed installation instructions
- **[Usage Guide](docs/usage.md)** - Complete command reference
- **[Examples](docs/examples/)** - Practical examples and tutorials
- **Configuration** - See `config/` directory for examples

## 🗂️ Project Structure

```
dcvm/
├── bin/                          # Main executable
│   └── dcvm                      # CLI entry point
├── lib/                          # Core libraries
│   ├── core/                    # VM management
│   ├── network/                 # Network utilities
│   ├── storage/                 # Backup & storage
│   └── utils/                   # Common utilities
├── install/                      # Installation scripts
├── config/                       # Configuration examples
├── templates/                    # VM templates
├── docs/                         # Documentation
└── tests/                        # Tests (future)
```
dcvm backup list                                        # List all backups (grouped by VM)
dcvm backup list my-vm                                  # List backups of a VM (shows date-id)
dcvm backup delete my-vm                                # Interactive delete (choose 1,2,3)
dcvm backup delete my-vm-10.01.2025                     # Delete backups of that day (by date-id)
dcvm backup delete my-vm-10.01.2025-N                   # Delete the precise backup
dcvm backup export my-vm 20250722_143052 /tmp           # Export as portable tar.gz (custom dir)
dcvm backup import /tmp/my-vm-20250722_143052.tar.gz    # Import and restore

# VM deletion
dcvm delete my-vm                    # Delete specific VM
dcvm uninstall                       # Uninstall the whole app
```

### Bulk Operations

```bash
# Manage all VMs
dcvm start                           # Start all VMs
dcvm stop                            # Stop all VMs
dcvm restart                         # Restart all VMs

# Network management
dcvm setup-forwarding                # Port forwarding setup
dcvm clear-leases show               # Show DHCP leases
dcvm clear-leases clear-all          # Clear all leases
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
- **SSH**: 2220+ ports (per VM)
- **HTTP**: 8080+ ports (per VM)
- **Access**: `ssh -p 2221 admin@host-ip`

## Directory Structure

```
/srv/datacenter/
├── vms/                    # VM disk files
│   ├── vm1/
│   │   ├── vm1-disk.qcow2
│   │   └── cloud-init/
├── storage/
│   └── templates/          # Base OS images
├── nfs-share/             # Shared files
├── backups/               # VM backups
└── scripts/               # Management scripts
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
- **`dhcp-cleanup.sh`**: DHCP lease cleanup
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
dcvm clear-leases clear-all
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
