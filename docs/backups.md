# Backup and Restore

This guide covers VM backup and restore operations in DCVM.

## Backup

Create a backup for a VM:
```bash
dcvm backup create <vm>
```

List backups:
```bash
dcvm backup list [<vm>]
```

Delete a backup:
```bash
# Interactive delete menu for a VM
dcvm backup delete <vm_name>

# Delete specific backup (vm-date-time)
dcvm backup delete <vm_name>-<YYYYMMDD>_<HHMMSS>
```

Export a backup archive:
```bash
# Export to default directory ($DATACENTER_BASE/backups/exports)
dcvm backup export <vm> <backup_date>

# Export to specific directory
dcvm backup export <vm> <backup_date> /path/to/export/dir
```

Import a backup archive:
```bash
# Import and restore (optional: rename VM)
dcvm backup import /path/to/archive.tar.gz [new_vm_name]
```

## Restore

Restore the latest backup:
```bash
# Standard command
dcvm backup restore <vm>

# Shortcut
dcvm restore <vm>
```

Restore a specific backup (`backup_date` is a raw `YYYYMMDD_HHMMSS` timestamp, the same day selector as export/delete, `dd.mm.yyyy[-N]`, or `latest`):
```bash
dcvm backup restore <vm> <backup_date>
```

Restore as a new VM (the original VM is left as is):
```bash
dcvm backup restore <vm> <backup_date> <new_vm_name>
```

Latest backup under a new name (the date is positional, so pass `latest` or an empty one):
```bash
dcvm backup restore <vm> latest <new_vm_name>
dcvm backup restore <vm> '' <new_vm_name>
```

If `<new_vm_name>` already exists, restore asks you to type `yes` and then replaces that VM (its disk is deleted). The new VM gets new MAC addresses (and so its own DHCP IP) and drops the source VM's NVRAM path. Port forwards are not copied, so run `dcvm network ports setup` afterwards.

When `virt-customize` (libguestfs-tools) is installed, the copy's disk is changed offline before the VM is defined: the hostname and its `/etc/hosts` entries are set to the new name, `/etc/machine-id` is emptied so systemd generates a new one, and new SSH host keys are generated on first boot. Without `virt-customize`, restore warns and the copy keeps the source's hostname, machine-id and host keys.

If the source VM has a static IP (`$DATACENTER_BASE/config/network/<vm>.conf`), that address is set inside the guest, so the copy keeps it: restore warns, and does not start the copy or set it to autostart. Change the IP inside the guest before starting it. The same applies to `dcvm backup import <package> <new_vm_name>`, which also skips the SSH key setup prompt in that case.

## Where backups are stored
- Default path: `$DATACENTER_BASE/backups`
- File naming: `<vm>-<YYYYMMDD>_<HHMMSS>` and `<vm>-disk-<YYYYMMDD>_<HHMMSS>.qcow2(.gz)`

## Tips
- Keep recent N backups and remove older ones regularly (`dcvm storage-cleanup`).
- Store backups on a separate disk for safety.
- Test your restore process periodically.
