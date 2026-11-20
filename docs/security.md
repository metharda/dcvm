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
> **Force mode (`-f`) always turns root login on**, with the user's password
> unless you pass `-r`. There is no flag to turn it off in force mode. Create
> the VM interactively and answer `n` to the root question, or disable it
> inside the guest (`PermitRootLogin no` in `/etc/ssh/sshd_config`, then
> `passwd -l root`).

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
  question, `$DATACENTER_BASE/nfs-share` is exported to `*` with `rw` and
  `no_root_squash`. Any machine that can reach the host's NFS port can mount
  it read-write as root. Leave it off (the default), or change the export in
  `/etc/exports` to `10.10.10.0/24` and firewall port 2049 from outside.

## Images, installer and updates

- **Cloud images** are downloaded over HTTPS from the official project
  servers and well-known mirrors listed in `lib/utils/mirror-manager.sh`.
  dcvm checks that a download is at least 100 MB; it does not verify
  checksums or signatures (the checksum table in `create-vm.sh` is empty).
  If that matters to you, download the image yourself, check it against the
  distribution's published checksums, and place it in
  `$DATACENTER_BASE/storage/templates/` under the file name dcvm expects
  (`dcvm template list`).
- **The installer** runs as root. The README's
  [review-first install](../README.md#quick-start) downloads it to a file so
  you can read it before running it; it then fetches the rest of dcvm from the
  same repository and branch over HTTPS.
- **`dcvm self-update`** downloads the files from GitHub (`metharda/dcvm`,
  `main`, or `DCVM_REPO_SLUG` / `DCVM_REPO_BRANCH`) over HTTPS, with no
  signature check, and keeps a copy of the previous version in
  `/var/lib/dcvm/backups` for `--revert`.

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
2. Leave the NFS share off, or limit its export to `10.10.10.0/24`.
3. Create VMs with SSH keys and turn password logins off inside the guest
   (`PasswordAuthentication no`), and turn root login off if you used force
   mode.
4. Pass passwords from variables or interactive prompts, not literally on the
   command line.
5. Use short-lived Tailscale auth keys.
6. Keep `$DATACENTER_BASE/backups` and exported packages on storage only you
   can read.
