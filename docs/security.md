# Security

dcvm is built for labs: a student's or homelab machine, a CTF practice box, a
place to try things. It makes VMs easy to reach and log in to. This page lists
what it protects, what it deliberately leaves open, and how to tighten a host
that is reachable from untrusted networks.

- [Threat model](#threat-model)
- [Credentials](#credentials)
- [Guest defaults](#guest-defaults)
- [Network exposure](#network-exposure)
- [Images, installer and updates](#images-installer-and-updates)
- [Backups and exports](#backups-and-exports)
- [Hardening checklist](#hardening-checklist)

See also: [Architecture](architecture.md) · [Operations](operations.md)

## Threat model

| In scope | Out of scope |
| :------- | :----------- |
| Keeping VM passwords out of plain-text files, logs and the terminal | Local root on the host: dcvm runs as root and root can read every VM disk |
| Keeping VMs off the LAN unless you forward a port | Isolating VMs from each other: all VMs share one bridge and can reach each other |
| Not leaking SSH access when a backup is exported to another host | Untrusted users on the host or a multi-tenant setup |
| Making the installer reviewable before it runs | Attacks from inside a guest against QEMU/KVM (libvirt's own sandboxing applies) |

dcvm assumes the person running it is the host's administrator and that the
VMs belong to them.

## Credentials

**Guest passwords are stored only as hashes.** `dcvm create` turns the user
password (and the root password, when root login is on) into a salted
SHA-512 crypt hash (`openssl passwd -6`) and writes only the hash to the
cloud-init `user-data`. The plain password never appears in a guest shell
command, the YAML, or dcvm's output; the interactive summary prints `****`.
Passwords are applied once, at first boot, so changing a password later
inside the VM with `passwd` sticks.

Exceptions to know about:

| What | Where it ends up | Exposure |
| :--- | :--------------- | :------- |
| `-p` on the command line | Your shell history and the host's process list while `dcvm create` runs | Pass it from a variable (`-p "$VM_PASSWORD"`) or use interactive mode, which reads it without echo |
| `-k mysql-server` / `default-mysql-server` | The SQL that sets the database passwords is base64-encoded (not encrypted) in `user-data`; the guest writes it to `/root/dcvm-mysql-init.sql` (mode 0600) and deletes it after running it | Anyone who can read the VM's seed (`cloud-init/user-data` or `cloud-init.iso`) can decode the password |
| `--tailscale-authkey` | Plain text in `user-data` (`tailscale up --authkey=...`) | Use a one-off, short-lived or ephemeral auth key |

The VM's `cloud-init/` folder is created with mode 700 (root only).
`cloud-init.iso`, built from it, stays in the VM folder because QEMU has to
read it; it contains the same `user-data`.

**SSH keys.** Unless you pass `--without-ssh-key`, dcvm adds the host root
user's `~/.ssh/id_rsa.pub` to the VM user's `authorized_keys`, creating a
4096-bit RSA key pair without a passphrase first if there is none. Anyone who
can use that private key can log in to every dcvm VM on the host.

## Guest defaults

Every cloud-image VM gets:

- an `sshd_config` with `PasswordAuthentication yes` and
  `PubkeyAuthentication yes`;
- passwordless `sudo` for the VM user (`NOPASSWD:ALL`);
- `PermitRootLogin yes` and a root password when root access is on.

> [!WARNING]
> **Force mode (`-f`) turns root login on by default**, with the user's
> password unless you pass `-r`. Pass `--disable-root` to keep root login off
> (`PermitRootLogin no`, root password locked), or answer `n` to the root
> question in interactive mode.

VNC, when enabled (by default only for Kali and Debian 13, or with
`--graphics vnc,listen=127.0.0.1` / `dcvm network vnc enable`), listens on
`127.0.0.1` only. Reach it through an SSH tunnel.

## Network exposure

- **NAT by default.** VMs sit on a private libvirt NAT network
  (`10.10.10.0/24`). They can reach out; nothing outside the host can reach
  them until you forward a port.
- **Port forwards listen on every host interface.** `dcvm network ports
  setup` adds a DNAT rule without an interface match for each running VM
  (SSH from 2221, HTTP from 8081). If the host has a public address, those
  ports are reachable from the internet, where password SSH logins are
  allowed. Restrict them with your firewall, or do not run `ports setup` on
  such a host and use the VM IPs from the host itself or over a VPN.
- **dcvm owns two port ranges.** `ports setup`, `ports apply` and
  `ports clear` delete every `PREROUTING` rule on host ports 2220-2299 and
  8080-8179, and every `FORWARD` rule that mentions the dcvm subnet, before
  adding their own. Don't use those ranges for other NAT rules on a dcvm
  host.
- **VMs are not isolated from each other.** They share one bridge and can
  reach each other on every port.
- **NFS share (optional).** If you answer `y` to the installer's NFS
  question, `$DATACENTER_BASE/nfs-share` is exported read-write to the dcvm
  subnet only (`10.10.10.0/24` by default) with `no_root_squash`, so root in
  any VM is root on the share. Machines outside the subnet can't mount it.
  The folder has mode `1777`: every VM user (and every local user on the
  host) can write to it, and the sticky bit stops them deleting each other's
  files. Don't put anything private there.
  Hosts installed before 0.9.8 exported it to `*` (any host); re-running the
  installer and answering `y` again replaces that line in `/etc/exports`.

## Images, installer and updates

- **Cloud images** are downloaded over HTTPS from the official project
  servers and well-known mirrors listed in `lib/utils/mirror-manager.sh`.
  Each download must be at least 100 MB and must match the checksum its
  publisher lists next to it: `SHA256SUMS` or `SHA512SUMS` in the same folder,
  or `<file>.SHA256`, looked up on the mirror it came from and on the other
  mirrors that serve the same file name (the official servers publish them
  for all eight images). A download that matches no published checksum is
  discarded and the next mirror is tried. If no mirror publishes a checksum,
  dcvm keeps the file and prints `download not verified`. GPG signatures are
  not checked, so a checksum file only proves the download is intact and is
  the one that server lists, not who built it.
- **The installer** runs as root. The README's
  [review-first install](../README.md#quick-start) downloads it to a file so
  you can read it before running it; it then fetches the rest of dcvm from the
  same repository and branch over HTTPS.
- **`dcvm self-update`** downloads the files from GitHub (`metharda/dcvm`,
  `main`, or `DCVM_REPO_SLUG` / `DCVM_REPO_BRANCH`) over HTTPS, with no
  signature check, and keeps the version it replaced in
  `/var/lib/dcvm/backups` for `--revert` (the last 3).

## Backups and exports

- Backups in `$DATACENTER_BASE/backups` are full copies of the VM disk
  overlay and contain everything in the guest (password hashes, keys, data).
  Protect them like the VMs.
- **Export removes SSH access.** `dcvm backup export` deletes
  `/root/.ssh/authorized_keys` and `/home/*/.ssh/authorized_keys` from the
  exported disk (needs `guestfish` from libguestfs-tools; dcvm warns if it is
  missing) and strips `ssh_authorized_keys` from the packaged cloud-init seed,
  so a package handed to someone else does not carry your key. Run
  `dcvm backup ssh-setup <vm>` after import to add a key.
- **Restored copies get new identities.** `dcvm backup restore <vm> <date>
  <new_name>` gives the copy new MAC addresses and, with `virt-customize`, a
  new hostname, machine-id and SSH host keys, so two VMs don't share host keys.

## Hardening checklist

For a host on a shared or public network:

1. Firewall the forwarded ports (2221+, 8081+) to the addresses that need
   them, or skip `dcvm network ports setup`.
2. Leave the NFS share off unless you need it; it is exported to the VM
   subnet only, but every VM's root can write to it.
3. Create VMs with `--disable-root` and SSH keys, and turn password logins
   off inside the guest (`PasswordAuthentication no`).
4. Pass passwords from variables or interactive prompts, not literally on the
   command line.
5. Use short-lived Tailscale auth keys.
6. Keep `$DATACENTER_BASE/backups` and exported packages on storage only you
   can read.
