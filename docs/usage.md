# Usage Guide

Complete guide for using DCVM to manage virtual machines.

## Command Structure

```bash
dcvm <command> [options] [arguments]
```

## Virtual Machine Management

### Creating a VM

#### Interactive Mode (Default)
```bash
dcvm create myvm
```

The wizard will prompt you for:
- Operating system (Debian 12, Debian 11, Ubuntu 22.04, Ubuntu 20.04)
- Username (default: admin)
- Password
- Root access settings
- Memory allocation
- CPU count
- Disk size
- SSH key setup

#### Force Mode (Non-Interactive)
```bash
dcvm create myvm -f -p password123
```

Uses default values for all unspecified options.

#### Custom Configuration
```bash
dcvm create myvm \
  -u admin \
  -p securepass123 \
  -m 4096 \
  -c 4 \
  -d 50G \
  -o 3 \
  --enable-root \
  -k nginx,mysql-server
```

**Options:**
- `-u, --username`: VM username (default: admin)
- `-p, --password`: User password (required in force mode)
- `-m, --memory`: Memory in MB (default: 2048)
- `-c, --cpus`: Number of CPUs (default: 2)
- `-d, --disk`: Disk size (default: 20G)
- `-o, --os`: OS choice (1=Debian12, 2=Debian11, 3=Ubuntu22.04, 4=Ubuntu20.04)
- `--enable-root`: Enable root login
- `-r, --root-password`: Set root password
- `-k, --packages`: Comma-separated package list
- `--with-ssh-key`: Enable SSH key authentication
- `--without-ssh-key`: Disable SSH key (password only)
- `-f, --force`: Force mode (no prompts)

### Creating a VM from Custom ISO

For installing operating systems not available via cloud-init (Windows, Arch Linux, custom distros, etc.):

#### Interactive ISO Mode
```bash
dcvm create myvm -o /path/to/installer.iso
# or
dcvm create-iso myvm --iso /path/to/installer.iso
```

The wizard will prompt you for:
- Memory allocation
- CPU count
- Disk size
- Graphics type (VNC, SPICE, or none)
- OS variant (for libvirt optimization)
- Boot order
- Static IP (optional)

#### ISO Mode with Options
```bash
dcvm create-iso archvm --iso /path/to/archlinux.iso \
  -m 4096 \
  -c 4 \
  -d 50G \
  --graphics vnc \
  --os-variant archlinux \
  --boot cdrom,hd
```

**ISO Options:**
- `--iso, -o`: Path to installer ISO (required)
- `-m, --memory`: Memory in MB
- `-c, --cpus`: Number of CPUs
- `-d, --disk`: Disk size (formats: 20G, 512M, 1T)
- `--graphics`: vnc, spice, or none (default: vnc)
- `--os-variant`: libosinfo variant (e.g., ubuntu22.04, win10, archlinux)
- `--boot`: Boot order (default: cdrom,hd)
- `--ip`: Static IP address (manual configuration required in VM)
- `--copy-iso`: Copy ISO to VM directory

**Connecting to Installer:**
```bash
# Get VNC display port
virsh vncdisplay myvm

# Console (for --graphics none)
dcvm console myvm
```

**Note:** Force mode (-f) is not supported for ISO installations as they require interactive setup.

### Listing VMs

```bash
dcvm list
```

Shows all VMs with their status, memory, CPUs, and IP addresses.

### Checking VM Status

```bash
# Single VM
dcvm status myvm

# All VMs
dcvm status
```

### Starting a VM

```bash
dcvm start myvm
```

### Stopping a VM

```bash
dcvm stop myvm
```

### Restarting a VM

```bash
dcvm restart myvm
```

### Connecting to VM Console

```bash
dcvm console myvm
```

**Tip**: Press `Ctrl+]` to exit the console.

### Deleting a VM

```bash
dcvm delete myvm
```

**Warning**: This permanently removes the VM and its data!

## Network Management

### View Network Information

```bash
dcvm network
```

Shows:
- Network configuration
- Bridge status
- VM IP addresses
- DHCP leases

### Setup Port Forwarding

```bash
dcvm network ports setup
```

Automatically sets up port forwarding for:
- SSH access (port 2222+)
- HTTP access (port 8080+)

### Clean DHCP Leases

```bash
dcvm network dhcp cleanup
```

Removes stale DHCP lease entries.

## Storage and Backup

### Backup a VM

```bash
dcvm backup myvm
```

Creates a snapshot backup in the backup directory.

### Restore a VM

```bash
dcvm restore myvm
```

Restores VM from the latest backup.

### View Storage Information

```bash
dcvm storage
```

Shows:
- Total storage usage
- VM disk usage
- Available space
- Template sizes

### Storage Cleanup

```bash
dcvm storage-cleanup
```

Removes:
- Old backups (keeps last 7 by default)
- Unused templates
- Temporary files

## SSH Access

### Using SSH Keys (Recommended)

If SSH key was configured during VM creation:

```bash
ssh admin@<vm-ip>
```

### Using Password

```bash
ssh admin@<vm-ip>
# Enter password when prompted
```

### Finding VM IP Address

```bash
dcvm network | grep myvm
# or
dcvm status myvm
```

## File Transfer

### Using SCP

```bash
# Copy to VM
scp file.txt admin@<vm-ip>:/home/admin/

# Copy from VM
scp admin@<vm-ip>:/path/to/file.txt ./
```

### Using SFTP

```bash
sftp admin@<vm-ip>
```

### Using Shared NFS

All VMs have access to shared storage at `/mnt/shared`:

```bash
# On host
cp /srv/datacenter/nfs-share/file.txt .

# On VM
ls /mnt/shared/
```

## Package Installation

### During VM Creation

```bash
dcvm create webserver -f -p pass123 -k nginx,php,mysql-server
```

### After VM Creation

Connect to VM and use apt:

```bash
ssh admin@<vm-ip>
sudo apt update
sudo apt install package-name
```

## Common Operations

### Create a Web Server VM

```bash
dcvm create webserver \
  -f -p securepass \
  -m 2048 -c 2 -d 30G \
  -k nginx,php,mysql-server
```

### Create a Database Server VM

```bash
dcvm create dbserver \
  -f -p securepass \
  -m 4096 -c 4 -d 100G \
  -k mysql-server
```

### Create a Docker Host VM

```bash
dcvm create dockerhost \
  -f -p securepass \
  -m 8192 -c 4 -d 200G \
  -k docker.io
```

## Tips and Best Practices

### 1. Resource Allocation
- Don't allocate all host resources to VMs
- Leave at least 1 CPU and 25% RAM for the host
- Monitor host resource usage

### 2. Backups
- Backup VMs regularly
- Test restore procedures
- Keep backups on separate storage

### 3. Security
- Use strong passwords
- Enable SSH key authentication
- Disable root login when not needed
- Keep VMs updated

### 4. Networking
- Use port forwarding for external access
- Configure firewall rules as needed
- Monitor network traffic

### 5. Storage
- Clean up old backups regularly
- Monitor disk usage
- Plan for growth

## Troubleshooting

### VM Won't Start

```bash
# Check VM status
dcvm status myvm

# Check system logs
journalctl -xe

# Fix locked resources
dcvm fix-lock
```

### Can't Connect to VM

```bash
# Verify VM is running
dcvm status myvm

# Check network
dcvm network

# Verify SSH service in VM
dcvm console myvm
# Then: systemctl status ssh
```

### Out of Space

```bash
# Check storage
dcvm storage

# Clean up
dcvm storage-cleanup

# Delete unused VMs
dcvm delete old-vm
```

## Advanced Usage

For advanced topics, see:
- [Networking Guide](networking.md)
- [Backup and Restore](backup-restore.md)
- [Troubleshooting](troubleshooting.md)
- [Examples](examples/)

## Updating DCVM

### Check for Updates

```bash
dcvm self-update --check
```

### Update to Latest Version

```bash
dcvm self-update
```

### Force Update

```bash
dcvm self-update --force
```

The self-update command will:
- Check the current installed version
- Compare with the latest version on GitHub
- Backup current installation
- Download and install new files
- Restore backup if update fails

## Uninstalling DCVM

To completely remove DCVM from your system:

```bash
dcvm uninstall
```

**Warning:** This will remove all DCVM files but will NOT delete your VMs.

## Getting Help

```bash
# General help
dcvm help

# Command-specific help
dcvm create --help
dcvm create-iso --help
dcvm self-update --help
```

## Next Steps

- Explore [Examples](examples/)
- Read [Networking Guide](networking.md)
- Learn about [Backup Strategies](backup-restore.md)
