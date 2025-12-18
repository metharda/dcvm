# Troubleshooting

Common issues and how to diagnose/fix them.

## Virtualization not available
- Ensure VT-x/AMD-V is enabled in BIOS/UEFI.
- Verify on host:
```bash
egrep -c '(vmx|svm)' /proc/cpuinfo
ls -l /dev/kvm
```

## libvirtd not running
```bash
systemctl status libvirtd
sudo systemctl start libvirtd
```

## Cannot connect to VM
```bash
# Is VM running?
dcvm status <vm>
# Network state
dcvm network
# DHCP leases
dcvm network dhcp show
# Open console
dcvm console <vm>
```

## Port forwarding not working
```bash
sudo dcvm network ports show
sudo dcvm network ports apply
sudo dcvm network ports test
```

## Disk space issues
```bash
dcvm storage
sudo dcvm storage-cleanup
```

## Locked resources
```bash
sudo dcvm fix-lock
```

## Custom ISO VM issues

### Cannot connect to VNC
```bash
# Get VNC display port
virsh vncdisplay <vm_name>

# Check if VM is running
dcvm status <vm_name>

# Try console mode instead
dcvm console <vm_name>
```

### ISO not booting
- Verify ISO file is valid and not corrupted
- Check boot order is set to `cdrom,hd`
- Try with `--graphics none` for text-based installers

### OS variant not found
```bash
# List available OS variants
osinfo-query os | grep -i <distro_name>

# Or leave empty for generic settings
dcvm create-iso myvm --iso /path/to/iso
```

## Update issues

### Self-update fails
```bash
# Check network connectivity
curl -I https://raw.githubusercontent.com/metharda/dcvm/main/dcvm

# Force update
dcvm self-update --force

# Manual update (re-run installer)
bash -c "$(curl -fsSL https://raw.githubusercontent.com/metharda/dcvm/main/lib/installation/install-dcvm.sh)"
```

### Version mismatch after update
```bash
# Check current version
dcvm --version

# Force reinstall
dcvm self-update --force
```

If the problem persists, please open an issue with logs from `/var/log/datacenter-startup.log` (or `/tmp/dcvm-install.log`).
