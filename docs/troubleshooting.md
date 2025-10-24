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

If the problem persists, please open an issue with logs from `/var/log/datacenter-startup.log` (or `/tmp/dcvm-install.log`).
