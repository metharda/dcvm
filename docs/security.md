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
| Keeping VM passwords out of plain-text files, logs and the terminal | Local root on the host: root (and `dcvm-admin`) can read every VM disk |
| Keeping VMs off the LAN unless you forward a port | Isolating VMs from each other: all VMs share one bridge and can reach each other |
| Not leaking SSH access when a backup is exported to another host | Attacks from inside a guest against QEMU/KVM (libvirt's own sandboxing applies) |
| Making the installer reviewable before it runs | Untrusted guests attacking other guests on the shared bridge |
| Members of the `dcvm` group: no path to root, to other users' VMs, backups or secrets, or to host files they can't read (since 0.9.10) | Denial of service by a user within their quota |

Root and `dcvm-admin` members administer the host. Members of `dcvm` are
treated as untrusted: see [Users without root](#users-without-root).

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

**SSH keys.** Unless you pass `--without-ssh-key`, dcvm adds the creator's
public key to the VM user's `authorized_keys`: for root, `~/.ssh/id_rsa.pub`
(a 4096-bit RSA key pair without a passphrase is created first if there is
none); for a user, their own key, created as ed25519 if they have none.
Anyone who can use root's private key can log in to every VM root created.

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
`127.0.0.1` only. Reach it through an SSH tunnel. VNC and SPICE always get a
random password (VNC allows 8 characters), also when root sets them up, since
any local account can connect to `127.0.0.1`; it is set through the
environment, never on a command line, and `dcvm network vnc status <vm>`
shows it.

## Network exposure

- **NAT by default.** VMs sit on a private libvirt NAT network
  (`10.10.10.0/24`). They can reach out; nothing outside the host can reach
  them until you forward a port.
- **Port forwards listen on every host interface.** `dcvm network ports
  setup` adds a DNAT rule without an interface match for each running VM
  (SSH from 2221, HTTP from 8081). If the host has a public address, those
  ports are reachable from the internet, where password SSH logins are
  allowed. Restrict them with your firewall, or do not run `ports setup` on
  such a host and use the VM IPs from the host itself or over a VPN. The
  matching `FORWARD` rules accept only that forwarded (DNATed) traffic, not
  other traffic routed to a VM's ports 22 and 80.
- **dcvm owns two port ranges.** `ports setup`, `ports apply` and
  `ports clear` delete every `PREROUTING` rule on host ports 2220-2299 and
  8080-8179, and every `FORWARD` rule that mentions the dcvm subnet, before
  adding their own. Don't use those ranges for other NAT rules on a dcvm
  host.
- **VMs are not isolated from each other.** They share one bridge and can
  reach each other on every port.
- **NFS share (optional).** If you answer `y` to the installer's NFS
  question, `$DATACENTER_BASE/nfs-share` is exported read-write to the dcvm
  subnet only (`10.10.10.0/24` by default) with `all_squash`: every user of
  every VM, root included, reads and writes as the unprivileged `dcvm-nfs`
  account. No VM can create a root-owned or setuid-root file, or a device
  node, on the host. The folder is mode `700` and owned by `dcvm-nfs`, so
  local users on the host can't open it (root can). Every VM can read, change
  and delete every file in it, so don't put anything private there.
  The export uses `subtree_check`: without it, root in a VM that forges an NFS
  file handle could reach any file on the same host file system as
  `dcvm-nfs`. Before 1.0 it used `no_subtree_check`; `dcvm doctor` reports
  that and `--fix` rewrites the line. Putting the share on a file system of
  its own (a separate partition or LVM volume mounted at
  `$DATACENTER_BASE/nfs-share`) is stronger still.
  Before 0.9.9.1 the export used `no_root_squash` and the folder was `1777`:
  root in any VM could leave a setuid-root program there that any local user
  on the host could run. `dcvm doctor` reports such an export as a failure,
  and `sudo dcvm doctor --fix` converts it, moving setuid and device files
  out of the share into `$DATACENTER_BASE/quarantine/`. If anything was moved
  and VMs were used by people you don't fully trust, treat the host as
  possibly compromised.

## Images, installer and updates

- **Cloud images** are downloaded over HTTPS from the official project
  servers and well-known mirrors listed in `lib/utils/mirror-manager.sh`.
  Each download must be at least 100 MB and must match the checksum its
  publisher lists next to it: `SHA256SUMS` or `SHA512SUMS` in the same folder,
  or `<file>.SHA256`, taken only from the official server (the first mirror
  listed; the official servers publish them for all nine images), so no
  mirror can vouch for its own file. A download that doesn't match is
  discarded and the next mirror is tried; if the official server gives no
  checksum (it is down, for example), the download is refused. GPG
  signatures are not checked, so a checksum file only proves the download is
  intact and is the one that server lists, not who built it. curl refuses a
  redirect from HTTPS to plain HTTP; aria2c has no such option, so a mirror
  that redirects to HTTP is left out when the mirrors are tested, and the
  checksum catches one that does it later. Before an image becomes a
  template (Kali: after its conversion to qcow2), it must be a plain qcow2
  with no backing file or external data file, since every VM's disk is
  backed by it.
- **Installer ISOs** are attached read-only as raw images, so neither QEMU
  nor libvirt reads them as qcow2 or VMDK. An ISO a user hands to
  `create-iso` is refused if it starts with a disk-image header (qcow2, QED,
  VMDK, VHDX, VHD).
- **The installer** runs as root. The README's
  [review-first install](../README.md#quick-start) downloads it to a file so
  you can read it before running it; it then fetches the rest of dcvm from the
  same repository over HTTPS (curl refuses a redirect to plain HTTP, wget
  follows no redirect), every file from the one commit the branch
  pointed to when it started. It installs from the folder it sits in only
  when that is a dcvm checkout (`lib/installation/install-dcvm.sh` next to
  the `dcvm` script) that no other user can change: owned by root or the
  `sudo` caller, with nothing in it and no folder above it up to `/`
  writable by group or others. Otherwise, a copy run from `/tmp` or through
  `bash -c` for example, it ignores the files around it and downloads.
- **`dcvm self-update`** downloads the files from GitHub (`metharda/dcvm`,
  `main`, or `DCVM_REPO_SLUG` / `DCVM_REPO_BRANCH`) over HTTPS, like the
  installer, with no signature check, all from one commit, into a staging folder, and replaces
  the installed files in one swap only when every file arrived. It refuses a
  version older than the installed one unless you pass `--force`. Every installed file is owned by root
  with fixed modes, never inherited from the folder (on Debian, `/usr/local`
  can be group `staff`). The version it replaced is kept in
  `/var/lib/dcvm/backups` for `--revert` (the last 3).
- **Files on the host.** VM folders are mode `711` and their disks,
  cloud-init seeds and copied installer ISOs `600`: the seed holds the
  password hash, and any Tailscale key or MySQL password. QEMU still opens
  them, because libvirt hands them to its own user when a VM starts.
  `$DATACENTER_BASE/backups` is mode `700`. `dcvm doctor` reports looser
  permissions on hosts set up before 0.9.9.1, and `--fix` closes them.

## Backups and exports

- Backups in `$DATACENTER_BASE/backups` are full copies of the VM disk
  overlay and contain everything in the guest (password hashes, keys, data).
  Protect them like the VMs. The saved VM configuration (mode `600`) keeps
  the VNC/SPICE password, so a restored VM's console is as closed as before;
  an exported package leaves it out.
- **Export removes SSH access and secrets.** `dcvm backup export` deletes
  `/root/.ssh/authorized_keys` and `/home/*/.ssh/authorized_keys` from the
  exported disk (needs `guestfish` from libguestfs-tools; dcvm warns if it is
  missing), and the package carries only the seed's `meta-data` and
  `network-config`: `user-data` holds the password hash and any Tailscale key
  or MySQL password, and stays on the host. Run `dcvm backup ssh-setup <vm>`
  after import to add a key.
- **Imports and restores treat the backup as untrusted.** An archive may
  contain only plain files (no links or devices), and its file names must
  give a valid VM name and backup date. The disk must be a plain qcow2 image:
  no external data file, no other format (such as a VMDK pointing at a host
  disk), no `json:` or network backing, and its base must resolve to a build in
  `templates/builds/` (or a template, for backups from before 0.9.9). The
  base record's image name and checksums are checked before use. The VM
  definition is rebuilt from an allowlist: one disk (the restored one),
  network interfaces without scripts, pty serial ports, graphics on
  127.0.0.1; host devices, shared folders, `qemu:commandline`, security
  labels, kernel and initrd paths, file-backed memory or audio and any other
  element dcvm doesn't know are dropped.
- **Restored copies get new identities.** `dcvm backup restore <vm> <date>
  <new_name>` gives the copy new MAC addresses and, with `virt-customize`, a
  new hostname, machine-id and SSH host keys, so two VMs don't share host keys.

## Users without root

Since 0.9.10 members of the `dcvm` group run dcvm without sudo (see
[Users and agents](users.md)). The boundary:

- **One way in.** Users reach root only through `/run/dcvm/dcvm.sock` (mode
  0660, group `dcvm`). The root side identifies them with `SO_PEERCRED`, so
  nothing the client sends can claim another identity, and it starts from a
  clean environment: variables like `DATACENTER_BASE` or `COLUMNS` from the
  caller never reach root.
- **Allowlisted requests.** Each command a user may run is parsed by the
  server: VM names must be valid and owned by the caller, options are checked
  one by one (free text that reaches libvirt, such as `--graphics
  vnc,listen=0.0.0.0` or `--boot loader=…`, is refused), keywords like `all`
  and `latest` can't be VM names, and anything not listed is refused.
- **No paths into root.** Files a user passes (an ISO, an export target) are
  opened by the client with the user's own permissions and handed over as
  descriptors; root never opens a path a user chose. Prompts that would ask
  for a path refuse it for users.
- **Secrets.** Passwords and Tailscale keys travel inside the request and
  reach the script through a pipe; they never appear in a command line,
  `/proc/*/cmdline`, the audit log or the journal. The user's own SSH key is
  used for their VMs, never root's.
- **Isolation between users.** Users see and change only their own VMs and
  backups; backups carry their owner, so a reused VM name gets nothing of the
  previous owner's. `fix-lock` doesn't restart libvirt for users. Every
  VNC/SPICE display has a random password that only root and the VM's owner
  can read. Disks and cloud-init seeds of every VM are readable by root only;
  seeds are created that way, never readable by others even for a moment.
- **Limits.** Quotas cap each user's VMs, vCPUs, memory and disk
  (`/etc/dcvm/limits.conf`).
- **Audit.** Every request is logged with its caller and decision
  (`/var/log/dcvm/audit.log`).
- **What still connects users:** VMs share one bridge and can reach each
  other, and a guest can set any address on it, including another VM's.
  dcvm refuses a static `--ip` or a port forward to an address another VM
  holds, but it can't stop a guest's own network settings. That refusal
  tells a user an address is taken, which their own VM can already see by
  scanning the bridge. For port
  forwards, deletes and the storage check dcvm takes a VM's address only
  from host-side records (its port mapping, its DHCP lease by MAC or its
  static IP), never from what the guest agent reports. The optional NFS
  share is one folder for every VM. Don't enable
  the share on a host whose users don't trust each other. `dcvm-admin` is
  root-equivalent by design; so are the `libvirt`, `disk` and `docker` groups,
  which `dcvm doctor` warns about.

## Hardening checklist

For a host on a shared or public network:

1. Firewall the forwarded ports (2221+, 8081+) to the addresses that need
   them, or skip `dcvm network ports setup`.
2. Leave the NFS share off unless you need it; it is exported to the VM
   subnet only and squashed, but every VM can change every file in it.
3. Create VMs with `--disable-root` and SSH keys, and turn password logins
   off inside the guest (`PasswordAuthentication no`).
4. Pass passwords from variables or interactive prompts, not literally on the
   command line.
5. Use short-lived Tailscale auth keys.
6. Keep `$DATACENTER_BASE/backups` and exported packages on storage only you
   can read.
