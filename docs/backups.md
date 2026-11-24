# Backup and Restore

This guide covers VM backup and restore operations in DCVM.

A backup shuts the VM down (gracefully, forced after 60 seconds), copies its
disk and libvirt configuration, compresses the disk with gzip, and starts the
VM again if it was running. On the demo host a fresh Ubuntu 24.04 VM took 20
seconds to back up and 80 seconds to restore. The 5 most recent backups of
each VM are kept; older ones are removed after each new backup.

> [!NOTE]
> The disk in a backup is the VM's qcow2 *overlay*: only the VM's own changes,
> on top of the exact base build it was made on. Each backup records that
> build (`base` in its folder: image, SHA-256, SHA-512), and dcvm keeps the
> build in `storage/templates/builds/` while any backup needs it. Restore and
> import find it by themselves and move the restored VM onto the current
> build of its image; see [Restore](#restore) and
> [Base images](base-images.md). A `--full` export contains a standalone disk
> that needs no base at all.

See also: [Architecture](architecture.md#backups) ·
[Security](security.md#backups-and-exports)

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

# Delete one backup, without asking: an ID as for restore (dd.mm.yyyy[-N],
# dd.mm.yyyy-HH:MM:SS, YYYYMMDD_HHMMSS or latest), or <vm>-<id> in one argument
dcvm backup delete <vm_name> <backup_id>
dcvm backup delete <vm_name>-<dd.mm.yyyy>[-N]

# Every backup; asks first, --yes without a terminal
dcvm backup delete --all
```

Deleting an ID that matches no backup fails (exit 1).

Backup folders are `700` and every file in them `600`, for created and
imported backups alike.

Export a backup archive:
```bash
# Thin (default): the overlay disk plus the record of its base build
dcvm backup export <vm> [<backup_date>] [/path/to/export/dir]

# Full: the disk flattened into one standalone file; larger, but restores on
# any host without the base build
dcvm backup export <vm> [<backup_date>] [/path/to/export/dir] --full
```

The default directory is `$DATACENTER_BASE/backups/exports`. A thin package
is usually much smaller; the importing host needs the recorded base build,
which import finds as described under [Restore](#restore).

A package holds the disk, the VM definition, the base record and the seed's
`meta-data` and `network-config`, without the seed's `user-data` (password
hash, Tailscale key, MySQL password).

When root or a `dcvm-admin` exports, the guest's `authorized_keys` files are
removed from the packaged disk with guestfish. A user's export never opens the
disk (it is guest-controlled, see [Restore](#restore)), so their package keeps
the VM's own `authorized_keys`: those are the user's keys, and the package goes
to that user.

Import a backup archive:
```bash
# Import and restore (optional: rename VM)
dcvm backup import /path/to/archive.tar.gz [new_vm_name]
```

Import refuses archives with links or special files, and file names that
don't give a valid VM name and backup date. If the restore fails, the
imported backup is removed again. Archives are untrusted: see
[Security](security.md#backups-and-exports) for what restore checks and drops.

## Owners

Each backup records the owner of the VM it was taken from (an `owner` file in
the backup folder). Users without root see, restore, export and delete only
their own backups, and rotation keeps the last three per owner, so a later VM
that reuses a name never touches the previous owner's backups. Backups from
before 0.9.10 belong to root. See [Users and agents](users.md#ownership).

## Restore

Restoring over an existing VM asks you to type `yes`, then replaces the VM's
disk and definition; `--yes` skips the question (needed without a terminal,
for example from an agent). The VM keeps its MAC addresses, so a DHCP VM gets
its old IP back and saved port forwards still match.

A restored VM is set to autostart and started, whatever state it was in when
the backup was taken (backups record no state; every backup is taken with the
VM shut down). The exceptions, a copy that keeps another VM's static IP and a
disk another VM still uses, are described below. Stop it afterwards with
`dcvm stop <vm>` if you want it off.

**Base check.** Before anything of an existing VM is touched, restore (and
import) unpacks the disk and looks for the base build it was made on:

| This host has | What happens | Downloads |
| :------------ | :----------- | :-------- |
| That exact build (found by SHA-256) | Used, then the disk moves onto the current build of its image | None |
| Another build of the image | The original build is fetched from the image's archive by its checksum (Ubuntu `release-<date>`, Debian dated folders, Arch versions), the disk moves onto the installed current build | Only the original build |
| No template of that image | The current build is downloaded and installed, then as above | Current build, plus the original |
| A backup from before 0.9.9 (no record) | The disk is checked with a read-only file system check against each build of its image on this host; the one it fits is used | None |
| None of the above | Restore stops and says so; nothing is changed | None |

Moving onto another build uses qemu-img's safe rebase, so the VM sees exactly
the same disk; it works on a copy that replaces the disk only when it
succeeds. Daily builds are not kept in the archives, and Kali images are
converted locally, so their original build can only come from this host or
`--base`:

```bash
dcvm backup restore <vm> <backup_date> --base /path/to/original-build.img
```

Restore the latest backup:
```bash
# Standard command
dcvm backup restore <vm>

# Shortcut
dcvm restore <vm>
```

Restore a specific backup (`backup_date` is a raw `YYYYMMDD_HHMMSS` timestamp, the ID as `backup list` shows it (`<vm>-dd.mm.yyyy[-N]`), the bare day selector `dd.mm.yyyy[-N]`, or `latest`):
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

When `virt-customize` (libguestfs-tools) is installed, the copy's disk is changed offline before the VM is defined: the hostname and its `/etc/hosts` entries are set to the new name, `/etc/machine-id` is emptied so systemd generates a new one, and new SSH host keys are generated on first boot. Without `virt-customize`, restore warns and the copy keeps the source's hostname, machine-id and host keys. For a user (not root or `dcvm-admin`), the guest disk is untrusted, so root never opens it with libguestfs, not on restore and not on export: the copy gets a fresh cloud-init seed with a new instance ID and its own hostname, and on first boot cloud-init sets the hostname and generates new SSH host keys, and the machine-id is reset once. A guest without cloud-init (an ISO install) keeps the source's identity; reset it inside the guest. `backup import` is for admins only, and an imported archive restored under a new name does go through `virt-customize` as root: the admin chose to import that archive.

If the source VM has a static IP recorded on this host (`$DATACENTER_BASE/config/network/<source_vm>.conf`, written by `dcvm create --ip`), that address is set inside the guest, so the copy keeps it: restore warns, and does not start the copy or set it to autostart (`dcvm doctor --fix` leaves autostart off too). Change the IP inside the guest before starting it. The same applies to `dcvm backup import <package> <new_vm_name>` when that record exists on the importing host (for example, export and import on the same host); it also skips the SSH key setup prompt then. Export packages do not include the record, so a static-IP VM imported on another host is started normally and keeps its old IP.

## Where backups are stored
- Default path: `$DATACENTER_BASE/backups`
- File naming: `<vm>-<YYYYMMDD>_<HHMMSS>` and `<vm>-disk-<YYYYMMDD>_<HHMMSS>.qcow2(.gz)`

## Tips
- dcvm keeps the 5 most recent backups per VM; delete others with `dcvm backup delete <vm>`.
- `dcvm doctor` shows which builds your backups need and whether they are on this host.
- Store backups on a separate disk for safety.
- Test your restore process periodically.
