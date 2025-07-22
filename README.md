# DCVM - Datacenter Virtual Machine Manager

**DCVM** is a comprehensive bash script collection that allows you to easily manage your KVM/QEMU-based virtual datacenter environment. It's a powerful tool that automates virtual machine creation, management, backup, and monitoring operations.

## Quick Installation

Set up your system quickly with this single command:

```bash
curl -fsSL https://raw.githubusercontent.com/metharda/dcvm/main/install-dcvm.sh | sudo bash
```

## Features

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

## Requirements

### Hardware
- **CPU**: VT-x/AMD-V capable processor
- **RAM**: Minimum 4GB (8GB+ recommended)
- **Disk**: 50GB+ free space
- **Network**: Internet connection

### Software
- **Operating System**: Ubuntu 20.04+, Debian 11+, CentOS 8+
- **Virtualization**: KVM/QEMU support
- **Root Access**: sudo/root privileges

## Manual Installation

If you prefer step-by-step installation:

### 1. Download Repository
```bash
git clone https://github.com/metharda/dcvm.git
cd dcvm
```

### 2. Run Installation Script
```bash
sudo ./install-dcvm.sh
```

### 3. Start System
```bash
# Start new session for system aliases
source ~/.bashrc

# Check VM manager
dcvm status
```

## Usage Guide

### Basic Commands

```bash
# VM creation
dcvm create my-vm                    # Basic VM
dcvm create web-server nginx         # Web server with nginx
dcvm create db-server mysql-server   # Database server with MySQL

# VM control
dcvm start my-vm                     # Start VM
dcvm stop my-vm                      # Stop VM
dcvm restart my-vm                   # Restart VM

# Status checking
dcvm status                          # General status
dcvm ports                           # Port information
dcvm network                         # Network information
dcvm console                         # Connection information

# Backup
dcvm backup my-vm                    # Create backup
dcvm backup restore my-vm            # Restore backup
dcvm backup list-backups my-vm       # List available backups

# VM deletion
dcvm delete my-vm                    # Delete specific VM
```

### Bulk Operations

```bash
# Manage all VMs
dcvm start all                       # Start all VMs
dcvm stop all                        # Stop all VMs
dcvm restart all                     # Restart all VMs

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
- Sudo privilege control

### Security Best Practices
```bash
# SSH key creation
ssh-keygen -t rsa -b 4096 -f ~/.ssh/dcvm-key

# Secure VM creation
dcvm create secure-vm
# (Add SSH key during setup)

# Firewall settings
sudo ufw enable
sudo ufw allow 22
sudo ufw allow 2220:2250/tcp  # SSH ports
sudo ufw allow 8080:8090/tcp  # HTTP ports
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
sudo modprobe kvm
sudo modprobe kvm_intel  # For Intel
sudo modprobe kvm_amd    # For AMD
```

#### Network Connection Issues
```bash
# Restart network
sudo virsh net-destroy datacenter-net
sudo virsh net-start datacenter-net

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
sudo systemctl restart libvirtd
sudo ./install-dcvm.sh
```