# Backup and Restore

This guide covers VM backup and restore operations in DCVM.

## Backup

Create a backup for a VM:
```bash
sudo dcvm backup create <vm>
```

List backups:
```bash
dcvm backup list [<vm>]
```

Delete a backup:
```bash
sudo dcvm backup delete <vm> <timestamp>
```

Export a backup archive:
```bash
sudo dcvm backup export <vm> <timestamp> --output /path/to/file.tar.gz
```

## Restore

Restore the latest backup:
```bash
sudo dcvm backup restore <vm>
```

Restore a specific timestamp:
```bash
sudo dcvm backup restore <vm> <timestamp>
```

## Where backups are stored
- Default path: `$DATACENTER_BASE/backups`
- File naming: `<vm>-<YYYYMMDD>_<HHMMSS>` and `<vm>-disk-<YYYYMMDD>_<HHMMSS>.qcow2(.gz)`

## Tips
- Keep recent N backups and remove older ones regularly (`dcvm storage-cleanup`).
- Store backups on a separate disk for safety.
- Test your restore process periodically.
