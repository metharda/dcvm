# DCVM Quick Start Guide

## Installation

```bash
# Clone repository
git clone <your-repo-url>
cd dcvm

# Run installer
sudo bash install/install-dcvm.sh

# Verify installation
dcvm --version
dcvm status
```

## Basic Commands

### Create a VM
```bash
# Interactive mode (prompts for details)
sudo dcvm create myvm

# Force mode (quick, no prompts)
sudo dcvm create myvm -f -p mypassword

# With custom specs
sudo dcvm create myvm -c 4 -r 8192 -s 50
```

### Manage VMs
```bash
# List all VMs
dcvm list

# Start a VM
sudo dcvm start myvm

# Stop a VM
sudo dcvm stop myvm

# Delete a VM
sudo dcvm delete myvm
```

### Networking
```bash
# Get VM IP
dcvm ip myvm

# Setup port forwarding
sudo dcvm port-forward myvm 8080 80

# Cleanup DHCP
sudo dcvm cleanup-dhcp
```

### Storage & Backup
```bash
# Backup a VM
sudo dcvm backup myvm

# Check storage
dcvm storage-status

# Check all storage
dcvm storage-status --all
```

## Configuration

Main config: `/etc/dcvm/dcvm.conf`

```bash
# Edit configuration
sudo vim /etc/dcvm/dcvm.conf

# Network settings
sudo vim /etc/dcvm/network.conf
```

## Getting Help

```bash
# General help
dcvm --help

# Command-specific help
dcvm create --help
dcvm delete --help
```

## Force Mode Benefits

Force mode (`-f` flag) provides:
- ✅ Non-interactive operation
- ✅ Compact, log-style output
- ✅ Perfect for automation/scripts
- ✅ Faster execution

Example force mode output:
```
[dcvm] Creating VM: myvm
[dcvm] Configuration: 4 vCPUs, 8192 MB RAM, 50 GB disk
[dcvm] Downloading cloud image
[dcvm] Creating disk image
[dcvm] Installing VM
[dcvm] ✓ VM created successfully
```

## Troubleshooting

Common issues:

1. **"VM already exists"** - Delete existing VM first or choose different name
2. **"No network connectivity"** - Check NFS server and network bridge
3. **"Permission denied"** - Use `sudo` for create/delete/start/stop commands


## Next Steps

- Read [Usage Guide](usage.md) for detailed command reference
- Check [examples/basic-vm-creation.md](examples/basic-vm-creation.md) for workflows
- Review [project-structure.md](project-structure.md) to understand architecture
- Read [CONTRIBUTING.md](../CONTRIBUTING.md) if you want to contribute

## Support

- Documentation: `docs/` directory
- Examples: `docs/examples/` directory
- Issues: Open an issue on GitHub
