# Base images

How dcvm keeps the cloud images that VM disks are built on, how it moves VMs
onto newer builds without breaking them, and how restore and import find the
right base on any host. New in 0.9.9.

- [Why this matters](#why-this-matters)
- [Builds](#builds)
- [When a newer build arrives](#when-a-newer-build-arrives)
- [Backups](#backups)
- [Restore and import](#restore-and-import)
- [Export](#export)
- [Upgrading from 0.9.8 or earlier](#upgrading-from-098-or-earlier)
- [Keeping VMs up to date](#keeping-vms-up-to-date)
- [Limits](#limits)
- [Commands](#commands)

See also: [Backups](backups.md) · [dcvm doctor](doctor.md) ·
[Architecture](architecture.md#base-images)

## Why this matters

A dcvm VM disk is a qcow2 *overlay*: it holds only the blocks the VM changed.
Every other block (the kernel, most of `/usr`, the file system structures the
VM never wrote to) is read from the cloud image it was created on. That is
why creating a VM takes seconds and a fresh disk is a few hundred MB.

It also means a disk is only valid on top of **that exact build**. Ubuntu,
Debian and Arch publish a new build of each image every few weeks under the
same file name. Up to 0.9.8, `dcvm template download --force` deleted the old
file and saved the newest build in its place. Running VMs kept the deleted
file open and carried on, but at their next boot they combined their own
blocks with blocks of a different build: a disk that never existed. ext4
reported errors, the VM hung at boot, and backups made from it had the same
problem.

0.9.9 handles base images the way OpenStack, LXD and Vagrant do:

- every build is kept unchanged and identified by its content,
- disks point at the build they were made on, never at a name that moves,
- a build is deleted only once nothing uses it,
- and dcvm moves VMs onto newer builds itself, safely.

## Builds

Each image you download is kept as an immutable build in
`$DATACENTER_BASE/storage/templates/builds/`:

```
storage/templates/
├── ubuntu-24.04-server-cloudimg-amd64.img                  ← the current build, for new VMs
└── builds/
    ├── ubuntu-24.04-server-cloudimg-amd64-04e8f2461a16.img  ← same file (hardlink), so no extra space
    ├── ubuntu-24.04-server-cloudimg-amd64-04e8f2461a16.sums
    ├── ubuntu-24.04-server-cloudimg-amd64-6e7016f2c9f4.img  ← an older build, still in use
    └── ubuntu-24.04-server-cloudimg-amd64-6e7016f2c9f4.sums
```

- The name ends in the first 12 characters of the build's SHA-256, so the
  same name always means the same content.
- The `.sums` file records the image name, the full SHA-256 and SHA-512, and
  when the build was added. The checksums let dcvm find the build again in
  the publisher's archive.
- `templates/<image>` is the current build: new VMs are created on it. It is
  a hardlink to its build file, so it costs no extra space.
- A VM disk refers to the build file. You can see it with
  `qemu-img info -U $DATACENTER_BASE/vms/<vm>/<vm>-disk.qcow2`:

  ```
  backing file: /srv/datacenter/storage/templates/builds/ubuntu-24.04-server-cloudimg-amd64-04e8f2461a16.img
  ```

Because the disk names a file that never changes, a newer download cannot
change what a VM sees, not even if the host reboots before dcvm gets to
move the VM.

**Reference counting.** A build is deleted automatically as soon as no VM
disk, no backup record and no template uses it. dcvm checks after a VM is
deleted, after backups are deleted or rotated out, after a VM moved to a
newer build, and on `dcvm doctor --fix`. While any disk or backup from before
0.9.9 exists, no build is deleted at all: those do not record which build
they need (see [Upgrading](#upgrading-from-098-or-earlier)).

## When a newer build arrives

```bash
dcvm template download ubuntu-24.04-server-cloudimg-amd64.img -f   # one image
dcvm template download -a -f                                       # every image
```

1. The current file is recorded as a build first, so nothing loses its base.
2. The newest build is downloaded. The file in `templates/` is replaced only
   when the download succeeded and passed its checksum; a failed download
   leaves everything as it was.
3. If the mirror still has the same build, nothing else happens:

   ```
     ✓ Ubuntu 24.04    592.5 MB in 62s, 9.56 MB/s · 3 mirrors via aria2c · sha256 verified
     · VMs             the mirror has no newer build; nothing to move
   ```

4. Otherwise every VM on an older build of that image moves onto the new
   one: **stopped VMs right away**, **running VMs the next time dcvm stops,
   restarts or backs them up**. Old builds that nothing uses anymore are
   deleted.

   ```
     ✓ Ubuntu 24.04    592.5 MB in 63s, 9.40 MB/s · 3 mirrors via aria2c · sha256 verified
     · deneme          running; moves to the new build at its next start (or: dcvm restart deneme)
     ✓ deneme2         moved to the current build ubuntu-24.04-server-cloudimg-amd64-04e8f2461a16.img (4s)
   ```

`--restart` also moves the running VMs now: dcvm asks for each one, shuts it
down, moves it and starts it again.

**How a move works.** dcvm uses qemu-img's *safe rebase*: it reads the old
and the new build, and copies every block where they differ into the VM's own
disk. Afterwards the disk points at the new build and the VM sees exactly
the same contents as before. The move runs on a copy of the disk, which is
checked and then swapped in, so a power cut or a full disk in the middle
cannot damage the VM. A move takes a few seconds.

**When running VMs move.** A disk can only change while its VM is off, so
dcvm moves a VM whenever it has it off anyway:

| You run | What happens |
| :------ | :----------- |
| `dcvm start <vm>` | The disk is moved, then the VM starts |
| `dcvm restart <vm>` | A clean shutdown, the move, and a start, instead of a reboot in place. If the VM does not shut down within 90 seconds, it reboots in place and moves later |
| `dcvm backup create <vm>` | The disk is moved while the VM is off for the backup, so the backup is on the new build too |
| A VM started outside dcvm (`virsh start`, host reboot) | It runs on its old build, which stays on disk; dcvm moves it the next time it has it off |

## Backups

Every backup records the build its disk is on in a `base` file in its folder:

```
image=ubuntu-24.04-server-cloudimg-amd64.img
build=/srv/datacenter/storage/templates/builds/ubuntu-24.04-server-cloudimg-amd64-04e8f2461a16.img
sha256=04e8f2461a16…
sha512=…
```

The backed-up disk is not changed later: backups are compressed, and moving
them would mean unpacking and repacking each one. Instead, a backup keeps
its build on disk until the backup itself is deleted or rotated out (dcvm
keeps the newest 5 per VM), and the VM moves onto the current build when the
backup is restored.

Two more safety checks run before a backup shuts the VM down:

- **Free space.** If the backup folder has less free space than the size of
  the VM's disk, the backup stops and the VM keeps running.
- **Still booting.** A VM that started less than 90 seconds ago is still
  booting and would ignore the shutdown request; the backup waits until it
  has booted. If a VM does not shut down within 60 seconds, the backup asks
  (on a terminal) before forcing it off.

## Restore and import

Before anything of an existing VM is touched, restore and import unpack the
disk into a staging file and look for the build it was made on:

1. **On this host**, by its SHA-256. On the host a backup was made on, this
   always succeeds: the build is kept while the backup exists.
2. **In the publisher's archive**, by its checksum. Ubuntu keeps every
   release build in `release-<date>/` folders, Debian in dated folders, Arch
   in `v<version>/` folders; dcvm looks through the newest 60 and downloads
   exactly that build, verified against its checksum.
3. **No template of that image on this host:** the current build is
   downloaded and installed first, then as above.
4. **Nowhere:** restore stops and explains. The existing VM is untouched.

Once the build is found, the disk is pointed at it and then moved onto the
**current build installed on this host**. A restored VM always ends up on the
current build, and dcvm never replaces the base you already have.

A restore of a backup with a record, on the same host:

```
  ✓ Unpacked disk   2.2 GB in 10s
  ✓ Base image      ubuntu-24.04-server-cloudimg-amd64-04e8f2461a16.img, on this host
```

**Backups from before 0.9.9** have no record. dcvm then checks the disk
against every build of its image on this host with a read-only file system
check (`fsck` in preen mode on each ext4 file system, `btrfs check` on
btrfs), on a throwaway copy. The build the disk reads cleanly on is used. A
disk on the wrong build often still has a clean `/` but a broken `/boot`,
which is why every file system is checked:

```
  ✓ Unpacked disk   679 MB in 4s
  ✓ Base image      ubuntu-24.04-server-cloudimg-amd64-6e7016f2c9f4.img, matched by a file system check (backup from before 0.9.9)
  ✓ Base image      moved to the current build ubuntu-24.04-server-cloudimg-amd64-04e8f2461a16.img (7s)
```

**`--base <file>`** names the build directly, for example a build you copied
over from another host:

```bash
dcvm backup restore <vm> <backup_date> --base /path/to/original-build.img
```

## Export

```bash
dcvm backup export <vm> [<backup_date>] [<dir>]          # thin (default)
dcvm backup export <vm> [<backup_date>] [<dir>] --full   # standalone
```

- **Thin** (default): the overlay disk, the VM definition, the cloud-init seed
  and the `base` record. Small, and the importing host finds the build as
  described in [Restore and import](#restore-and-import).
- **`--full`**: the disk is flattened onto its base into one standalone,
  compressed qcow2 file that needs no template at all. Larger (the whole
  used disk), but it restores on any host, including when the original build
  is gone from the archive. Use it for Kali VMs and for long-term archives.

The manifest in the package says which kind it is (`disk=thin` or
`disk=full`). Both remove `authorized_keys` from the disk and the seed.

## Upgrading from 0.9.8 or earlier

VMs created before 0.9.9 point at `templates/<image>` itself, and their
backups have no record. After updating, run:

```bash
dcvm doctor          # shows what needs attention
dcvm doctor --fix    # repairs what it can
```

For each old VM, dcvm decides whether `templates/<image>` is still the build
the VM was made on:

- **The template is older than the VM's disk:** it is. dcvm pins the disk to
  that build, a metadata-only change. A running VM is pinned the next time
  dcvm starts it.
- **The template was replaced after the VM was created**, and the VM is
  still running: its QEMU process still holds the original file open.
  `dcvm doctor --fix` saves it into `builds/` from there and pins the VM to
  it at its next start. Do this before the VM stops, or the original is gone.
- **The template was replaced and the VM was restarted since:** the VM is
  probably broken (hung at boot, no address). Restore a backup; restore finds
  the build a backup fits with the file system check.

dcvm does the same pinning by itself the first time it starts, restarts or
backs up an old VM, and `template download -f` pins stopped old VMs before it
replaces their image. It refuses to replace an image that a running old VM
uses directly: stop the VM first.

## Keeping VMs up to date

Moving a VM onto a newer build does **not** update the software inside it:
the safe rebase keeps the VM's view of its disk exactly as it was. What
moving buys is that the old build can be deleted. New VMs start from the
newest build.

Software inside a VM is updated by its own package manager:

- New VMs install pending updates on their first boot (cloud-init
  `package_upgrade`).
- Debian VMs get `unattended-upgrades`, which installs security updates
  automatically; Ubuntu cloud images have it already.
- On Arch and Kali, update by hand (`pacman -Syu`, `apt full-upgrade`).

## Limits

- **Disks grow when they move.** The blocks where two builds differ are
  copied into the VM's disk. Moving between two Ubuntu builds a few months
  apart took a 679 MB disk to 2.2 GB. Thin exports of such a VM are larger
  too; a VM created on the current build stays small.
- **Daily builds are not archived.** dcvm's mirror lists use release builds,
  which the publishers keep. A disk built on a daily build (older dcvm
  versions listed Ubuntu's `noble/current/` daily image first) can only find
  its base on its own host or with `--base`.
- **Kali** images are converted locally from the published archive, so the
  qcow2 file has no published checksum: their build can only come from the
  host or `--base`. Export Kali VMs with `--full`.
- **A VM started outside dcvm** stays on its old build until dcvm next has
  it off. That is safe (the old build stays), it only keeps the old build on
  disk longer.

## Commands

| Command | Effect |
| :------ | :----- |
| `dcvm template download <image> -f` | Newest build; VMs move onto it |
| `dcvm template download -a -f [--restart]` | Every image; `--restart` moves running VMs now |
| `dcvm template status` | Current builds, sizes, integrity |
| `dcvm restart <vm>` | Moves a running VM now (shutdown, move, start) |
| `dcvm backup restore <vm> [<date>] [--base <file>]` | Finds the build, then moves onto the current one |
| `dcvm backup export <vm> [<date>] [<dir>] [--full]` | Thin with a base record, or standalone |
| `dcvm doctor [--fix]` | Each VM's build, backups' builds, kept builds and why (see [dcvm doctor](doctor.md)) |
