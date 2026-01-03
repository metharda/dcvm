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
dcvm backup export <vm> <timestamp>

# Export to specific directory
dcvm backup export <vm> <timestamp> /path/to/export/dir
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

Restore a specific timestamp:
```bash
dcvm backup restore <vm> <timestamp>
```

## Where backups are stored
- Default path: `$DATACENTER_BASE/backups`
- File naming: `<vm>-<YYYYMMDD>_<HHMMSS>` and `<vm>-disk-<YYYYMMDD>_<HHMMSS>.qcow2(.gz)`

## Tips
- Keep recent N backups and remove older ones regularly (`dcvm storage-cleanup`).
- Store backups on a separate disk for safety.
- Test your restore process periodically.
