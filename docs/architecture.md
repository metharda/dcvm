# Architecture

dcvm is a set of Bash scripts that drive KVM/QEMU through libvirt. There is no
resident daemon: every command is a short-lived script that calls `virsh`,
`virt-install`, `qemu-img`, `iptables` and cloud-init tooling, and keeps its
state in plain files under `DATACENTER_BASE`, `/var/lib/dcvm` and libvirt.
Users without root reach the same scripts through a socket-activated core
(`lib/server/`): see [Users and agents](users.md#how-it-works).

- [Components](#components)
- [Command routing](#command-routing)
- [What `dcvm create` does](#what-dcvm-create-does)
- [Networking](#networking)
- [Backups](#backups)
- [Base images](#base-images)
- [State on the host](#state-on-the-host)
- [Design decisions](#design-decisions)

See also: [Security](security.md) · [Operations](operations.md) ·
[Development](development.md)

## Components

```mermaid
flowchart LR
    user([dcvm CLI]) --> router[dcvm entry point]
    router --> core[lib/core<br/>create, delete, start/stop]
    router --> net[lib/network<br/>network, ports, DHCP]
    router --> storage[lib/storage<br/>backup, storage check]
    router --> inst[lib/installation<br/>install, self-update, uninstall]
    core --> utils[lib/utils/common.sh<br/>shared helpers]
    net --> utils
    storage --> utils
    core --> mirrors[lib/utils/mirror-manager.sh<br/>cloud image download]
    core -->|virt-install, virsh, qemu-img| libvirt[(libvirt + QEMU/KVM)]
    net -->|virsh net-*, iptables| libvirt
    storage -->|virsh, qemu-img, virt-customize| libvirt
    libvirt --> vms[[VMs on datacenter-net]]
```

| Part | Files | Role |
| :--- | :---- | :--- |
| Entry point | `dcvm` | Parses the first word and `exec`s the matching script in `lib/`. Holds the version string. |
| Core | `lib/core/create-vm.sh`, `custom-iso.sh`, `delete-vm.sh`, `vm-manager.sh` | VM creation from cloud images or ISOs, deletion, list/status/start/stop/restart. |
| Network | `lib/network/network-manager.sh`, `port-forward.sh`, `dhcp.sh` | `dcvm network ...`: the libvirt NAT network, iptables port forwards, DHCP lease cleanup, VNC on/off. |
| Storage | `lib/storage/backup.sh`, `storage-manager.sh` | Backups, restore (in place or as a copy), export/import between hosts; the hourly in-guest storage check. |
| Installation | `lib/installation/install-dcvm.sh`, `self-update.sh`, `uninstall-dcvm.sh` | Host setup, updates from GitHub, removal. |
| Utilities | `lib/utils/common.sh`, `mirror-manager.sh`, `fix-lock.sh`, `dcvm-completion.sh`, `test-suite.sh` | Shared helpers and validation, image mirrors, libvirt lock repair, bash completion, the test suite. |

## Command routing

`dcvm <command>` resolves its library directory first: from
`DCVM_LIB_DIR` in `/etc/dcvm-install.conf` if set, otherwise
`/usr/local/lib/dcvm` on an installed host, or `lib/` next to the script in a
clone without a config file. It then `exec`s one script per command:

| Command | Script |
| :------ | :----- |
| `create` | `core/create-vm.sh` (hands off to `custom-iso.sh` when `-o` is an ISO path) |
| `create-iso` | `core/custom-iso.sh` |
| `delete` | `core/delete-vm.sh` |
| `list`, `status`, `start`, `stop`, `restart`, `console` | `core/vm-manager.sh` |
| `network` | `network/network-manager.sh` (delegates `ports` and `dhcp`) |
| `backup`, `restore` | `storage/backup.sh` |
| `storage`, `storage-cleanup` | `storage/storage-manager.sh` |
| `template`, `mirror` | `utils/mirror-manager.sh` |
| `fix-lock` | `utils/fix-lock.sh` |
| `doctor` | `utils/doctor.sh` |
| `info`, `whoami`, `protect`, `unprotect`, `reap`, `user`, `owner` | `core/access.sh` |
| `ssh`, `exec`, `cp` | `core/connect.sh` |
| `self-update`, `update`, `uninstall` | `installation/` |

Every script sources `lib/utils/common.sh` and calls `load_dcvm_config`, which
reads `/etc/dcvm-install.conf` and fills in defaults for `DATACENTER_BASE`,
`NETWORK_NAME`, `BRIDGE_NAME` and `NETWORK_SUBNET`.

## What `dcvm create` does

```mermaid
sequenceDiagram
    participant U as dcvm create web
    participant M as mirror-manager
    participant H as Host files
    participant L as libvirt
    participant G as Guest (first boot)
    U->>U: validate name, user, password, packages, IP
    U->>L: check network is defined and active
    U->>M: template missing? download from fastest mirror
    M->>H: image file in storage/templates
    U->>H: vms/web/cloud-init/{user-data,meta-data,network-config}
    U->>H: cloud-init.iso (volume "cidata")
    U->>H: web-disk.qcow2 (overlay on the template)
    U->>L: virt-install --import, autostart on
    L->>G: boot
    G->>G: cloud-init: user, password hash, SSH key, packages, services
```

1. **Validation.** VM names (3-64 characters of letters, digits, `_`, `-`),
   usernames, passwords, `-k` package names and `--ip` are checked before
   anything is written. A comma-separated name list (`web,db,cache`, root and admins
   only) creates several VMs in force mode, with incrementing static IPs if `--ip` is given.
2. **Template.** Each OS choice maps to one cloud image under
   `$DATACENTER_BASE/storage/templates`. If it is missing,
   `mirror-manager.sh` tests the mirrors for that image and downloads it to a
   temporary file with aria2c from the fastest four at once (curl, one
   mirror at a time, without aria2). It keeps the file only if it is at least 100 MB
   and matches the checksum published next to it (`SHA256SUMS`,
   `SHA512SUMS` or `<file>.SHA256`); otherwise it tries the next mirror. Kali
   ships as a `.tar.xz`, which is checked and then unpacked.
3. **cloud-init seed.** dcvm writes `user-data` (user, SHA-512 password hash,
   optional root hash, SSH key, packages, `sshd_config`, service setup),
   `meta-data` and a netplan-style `network-config` (DHCP, or the static
   address), then packs them into `cloud-init.iso` with
   `genisoimage`/`mkisofs`.
4. **Disk.** `qemu-img create -f qcow2 -b <template>` makes a copy-on-write
   overlay of the requested size, so a new VM takes seconds and only its own
   changes use disk space.
5. **Define and boot.** `virt-install --import` defines the domain with the
   overlay disk, the seed ISO as a CD-ROM, a serial console, the dcvm network
   and graphics `none` (or VNC on `127.0.0.1` for Kali and Debian 13). The VM
   is set to autostart with the host.
6. **First boot.** cloud-init inside the guest creates the user, applies the
   password hashes and SSH key, updates the package index, installs the base
   tools and each `-k` package one by one (a failure is logged to
   `/var/log/dcvm-packages.log` and does not stop the rest), and sets up
   nginx, Apache, MySQL/MariaDB or Docker when asked. This takes 1-3 minutes
   depending on packages and mirror speed.

`dcvm create-iso` (or `dcvm create -o file.iso`) skips cloud-init: it creates
an empty qcow2 disk, attaches the ISO and boots the installer with VNC, SPICE
or a serial console for you to finish by hand.

## Networking

```mermaid
flowchart LR
    client([SSH / HTTP client]) -->|host:2221, host:8081| ipt[iptables<br/>PREROUTING DNAT<br/>FORWARD ACCEPT]
    ipt --> br[virbr-dc 10.10.10.1<br/>dnsmasq DHCP .10-.200]
    br --> vm1[web 10.10.10.50:22,80]
    br --> vm2[db 10.10.10.x:22,80]
    vm1 -->|NAT masquerade| internet((Internet))
```

- **NAT network.** The installer defines a libvirt network
  (`datacenter-net`, bridge `virbr-dc`, `10.10.10.0/24`, host at `.1`) with
  NAT forwarding and a dnsmasq DHCP range of `.10`-`.200`. VMs reach the
  internet through the host; nothing outside the host can reach a VM unless
  you forward a port.
- **Static IPs.** `--ip` writes the address into the guest's
  `network-config`, and a DHCP reservation in the network keeps dnsmasq from
  leasing the address to another VM. The host keeps a record in
  `$DATACENTER_BASE/config/network/<vm>.conf`, which `dcvm network` lists
  and backup restore checks.
- **IP discovery.** `get_vm_ip` asks the guest agent, then the libvirt lease
  table, then the DHCP leases by name and MAC, and finally the static IP
  record.
- **Port forwarding.** `dcvm network ports setup` removes dcvm's old rules,
  then gives each running VM the next free pair of host ports, starting at
  2221 (SSH, to port 22) and 8081 (HTTP, to port 80). Each forward is one
  `PREROUTING` DNAT rule and one `FORWARD` ACCEPT rule. The table is saved to
  `$DATACENTER_BASE/port-mappings.txt` and, when `iptables-save` exists, the
  rules to `/etc/iptables/rules.v4`. `dcvm network ports apply` rebuilds the
  rules from the saved table.
- **DHCP cleanup.** `dcvm delete` and `dcvm network dhcp clear` release a
  lease in the running dnsmasq with `dhcp_release` and remove it from
  libvirt's status file with `jq`, under a lock, so a deleted VM's address is
  free again without restarting the network.

## Backups

```mermaid
flowchart LR
    vm[running VM] -->|virsh shutdown, up to 60 s| off[VM shut off]
    off -->|cp disk, virsh dumpxml| bk[backups/web-YYYYMMDD_HHMMSS/<br/>disk .qcow2.gz + config .xml]
    bk -->|virsh start| vm
    bk -->|restore| same[same VM, disk replaced]
    bk -->|restore as new name| copy[copy: new MACs, hostname,<br/>machine-id, SSH host keys]
    bk -->|export| tar[.tar.gz package<br/>overlay disk + XML,<br/>authorized_keys removed]
```

- **Consistency over uptime.** A backup shuts the VM down (gracefully, forced
  after 60 seconds), copies the disk and the libvirt XML, gzips the disk, and
  starts the VM again if it was running. The guest file system is never
  copied while it is being written.
- **Retention.** The 5 most recent backups of each VM are kept; older ones are
  removed after each new backup.
- **Restore.** Restoring over an existing VM asks for confirmation and
  replaces its disk. Restoring under a new name defines a separate VM with
  new MAC addresses; when `virt-customize` is installed, its hostname,
  `/etc/hosts`, machine-id and SSH host keys are changed offline before first
  boot.
- **Overlays, not full disks.** A backup copies the VM's qcow2 overlay and
  records the base build it sits on (see [Base images](#base-images)).
  Restore finds that build (on the host, else in the image's archive by
  checksum) and moves the restored VM onto the current build.
- **Export/import.** Export packs the overlay, XML and base record into a
  `.tar.gz` (`--full`: one flattened standalone disk instead) and removes
  `authorized_keys` files from the image (with guestfish) and from the
  cloud-init seed. Import runs the same base check as restore.

## Base images

A VM disk is a qcow2 overlay that is only valid on the exact build it was
created on. dcvm keeps every build as an immutable file in
`storage/templates/builds/` (named by its SHA-256, a hardlink to the
download), points disks at that file, and deletes a build only once no VM,
backup or template uses it:

```mermaid
flowchart LR
    dl[template download] -->|hardlink, no copy| b1[builds/ubuntu-…-04e8f246.img]
    tpl[templates/ubuntu-24.04-….img<br/>current build, for new VMs] -.same file.- b1
    b0[builds/ubuntu-…-6e7016f2.img<br/>older build] -->|safe rebase when the VM is off| b1
    vm1[web-disk.qcow2] --> b1
    bk[backup + base record] --> b0
```

When a newer build is downloaded, VMs move onto it with qemu-img's safe
rebase (their view of the disk does not change) whenever dcvm has them off.
Backups record their build, and restore and import find it on the host or in
the publisher's archive by checksum. The full description, including the
upgrade from 0.9.8, is in [Base images](base-images.md).

## State on the host

| Path | Contents |
| :--- | :------- |
| `/etc/dcvm-install.conf` | `DATACENTER_BASE`, `NETWORK_NAME`, `BRIDGE_NAME`, `NETWORK_SUBNET` |
| `/usr/local/bin/dcvm`, `/usr/local/lib/dcvm/` | Installed CLI and libraries |
| `$DATACENTER_BASE/storage/templates/` | Downloaded cloud images: the current build of each, for new VMs |
| `$DATACENTER_BASE/storage/templates/builds/` | Immutable base builds (`<image>-<sha256:12>.<ext>` + `.sums`) that VM disks and backups refer to |
| `$DATACENTER_BASE/vms/<vm>/` | `<vm>-disk.qcow2`, `cloud-init.iso`, `cloud-init/` (mode 700) |
| `$DATACENTER_BASE/config/network/<vm>.conf` | Static IP record |
| `$DATACENTER_BASE/port-mappings.txt` | `VM_NAME VM_IP SSH_PORT HTTP_PORT`, one line per forward |
| `$DATACENTER_BASE/backups/` | Backups and `exports/` |
| `$DATACENTER_BASE/nfs-share/` | Optional NFS share, mounted in guests at `/mnt/shared` |
| `/var/lib/dcvm/backups/` | The versions `dcvm self-update` replaced (last 3), for `--revert` |
| `/var/log/datacenter-startup.log`, `/var/log/dcvm-backup.log`, `/var/log/datacenter-storage.log` | Logs |

libvirt holds the rest: domain definitions, the network, and the DHCP leases
in `/var/lib/libvirt/dnsmasq/<bridge>.status`.

## Design decisions

| Decision | Why | Trade-off |
| :------- | :-- | :-------- |
| Bash modules over libvirt tools | Runs on any Linux host with libvirt, no runtime to install, and every step is a command you can run by hand. VMs stay ordinary libvirt domains, so `virsh` and virt-manager keep working. | The scripts parse command output. |
| A small Python core at the privilege boundary | Users and agents without root need a gate that identifies callers, checks requests and passes files and secrets safely; Python 3 is already on every host (virt-install uses it) and stays readable. It holds policy only; the VM logic stays in Bash. | A second language; the request format is now a contract the client and server share. |
| Cloud images and cloud-init instead of installers | A ready VM in about a minute plus first-boot time, with the user, key and packages already set up. | Only the eight built-in images get this; anything else goes through `create-iso` and a manual install. |
| qcow2 overlays on shared templates | New VMs are instant and small, and so are their backups. | Every disk depends on its base build; dcvm keeps builds immutable and reference-counted, and moving a VM to a newer build copies the blocks that differ into its disk, which then grows by that amount. |
| Password hashes only | The guest password never appears in plain text in the seed or a guest command (see [security.md](security.md)). | The password can't be read back later; reset it inside the VM. |
| Cold backups | A powered-off copy can't be torn mid-write. | The VM is down for the length of the copy. |
| iptables DNAT for access | Works the same on every distro and needs no extra service. | Rules are global and not reloaded at boot unless your distro restores `/etc/iptables/rules.v4`; run `dcvm network ports apply` after a reboot. |
| No resident daemon | Nothing to keep running; libvirt already autostarts the network and VMs. The socket starts one short-lived process per request, which also works for agents in sandboxes where `sudo` is blocked. | Port forwards and IP discovery are refreshed on demand, not continuously; the socket's root process is code to keep secure. |
