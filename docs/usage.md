# Usage Guide

Complete guide for using DCVM to manage virtual machines.

## Command Structure

```bash
dcvm <command> [options] [arguments]
```

## Virtual Machine Management

### Creating a VM

VM names must be 3-64 characters: letters, numbers, `_` and `-`.

#### Interactive Mode (Default)
```bash
dcvm create myvm
```

The wizard will prompt you for:
- Operating system (Debian 11/12/13, Ubuntu 20.04/22.04/24.04, Arch Linux, Kali Linux, Fedora 44)
- Username (default: depends on OS, e.g. ubuntu)
- Password
- Root access settings
- SSH key setup
- Static IP configuration
- Memory allocation
- CPU count
- Disk size

#### Force Mode (Non-Interactive)
```bash
dcvm create myvm -f -p password123
```

Uses default values for all unspecified options. Without a terminal (a script
or an agent run by a user), dcvm never asks: a missing value is an error that
names the option, and the password can come from `DCVM_PASSWORD`.

```bash
dcvm create t1 --ttl 2h --wait --json    # deleted after 2 hours; returns once SSH accepts connections
```

- `--ttl 90m|2h|3d` deletes the VM when the time is up (checked every 5
  minutes by `dcvm-reaper.timer`).
- `--wait` returns only once the VM answers on SSH.
- `--json` prints one JSON object per VM on stdout (`name`, `state`, `ip`,
  `user`, `expires`, `ready`); progress goes to stderr.

#### Custom Configuration
```bash
dcvm create myvm \
  -u admin \
  -p securepass123 \
  -m 4096 \
  -c 4 \
  -d 50G \
  -o 5 \
  --enable-root \
  -k nginx,mysql-server
```

**Options:**
- `-u, --username`: VM username (default: depends on OS, e.g., 'ubuntu', 'debian'). 3-32 characters, starting with a letter or `_`; `admin`, `administrator`, `sysadmin`, `user` and `guest` are reserved. `root` configures root login (root access on, one password from `-p`, SSH key in `/root/.ssh`; `-r` must be omitted or equal `-p`)
- `-p, --password`: User password (required in force mode). 4-128 characters with no line breaks (`\n`, `\r`, U+0085, U+2028, U+2029); every other character is taken literally. The user and root passwords are set once, at first boot, so a password changed later inside the VM with `passwd` is kept.
- `-m, --memory`: Memory in MB (default: 2048)
- `-c, --cpus`: Number of CPUs (default: 2)
- `-d, --disk`: Disk size (default: 30G)
- `-o, --os`: OS choice (1=Debian13, 2=Debian12, 3=Debian11, 4=Ubuntu24.04, 5=Ubuntu22.04, 6=Ubuntu20.04, 7=ArchLinux, 8=KaliLinux, 9=Fedora44)
- `--ip`: Static IP address (e.g., 10.10.10.50) - uses DHCP if not specified

Note about multiple VMs and `--ip`:

- When creating multiple VMs in a single command (e.g. `dcvm create vm1,vm2,vm3 --ip 10.10.10.50 -f -p pass`), DCVM will auto-assign incremental IPs starting from the provided base IP:
  - vm1 → 10.10.10.50
  - vm2 → 10.10.10.51
  - vm3 → 10.10.10.52
- If the auto-increment would exceed `.254`, DCVM uses a fallback algorithm that assigns descending addresses from the base so addresses remain within the valid `.2-.254` range. Example:
  - Base `10.10.10.254` for 3 VMs → 254, 253, 252

Be careful to choose a base IP with enough free addresses in your subnet. If DCVM cannot compute a safe address for a VM, creation will fail and you should pick a different base IP or use DHCP.
- `--enable-root`: Enable root login. Force mode (`-f`) enables root login even without this flag, with the user's password unless `-r` is given
- `--disable-root`: Keep root login off (`PermitRootLogin no`, root password locked), also in force mode. Can't be combined with `-u root`, `--enable-root` or `-r`
- `-r, --root-password`: Set root password (enables root access; same rules as `-p`)
- `-k, --packages`: Comma-separated package list (supports `tailscale` for VPN). Names must start with a letter or number and may contain letters, numbers, `@`, `.`, `_`, `+` and `-`. Each package is installed separately, so one unavailable name does not block the rest; failures are logged in the guest to `/var/log/dcvm-packages.log`. See [Service setup for `-k` packages](#service-setup-for--k-packages).
- `--tailscale-authkey`: Tailscale auth key for automatic VPN connection (also installs Tailscale if not in `-k`)
- `--with-ssh-key`: Enable SSH key authentication
- `--without-ssh-key`: Disable SSH key (password only)
- `--graphics`: Graphics mode - `vnc`, `vnc,listen=127.0.0.1`, or `none` (default: auto based on OS)
- `-f, --force`: Force mode (no prompts)

### Creating a VM from Custom ISO

For installing operating systems not available via cloud-init (Windows, Arch Linux, custom distros, etc.):

#### Interactive ISO Mode
```bash
dcvm create myvm -o /path/to/installer.iso
# or
dcvm create-iso myvm --iso /path/to/installer.iso
```

The wizard will prompt you for:
- Memory allocation
- CPU count
- Disk size
- Graphics type (VNC, SPICE, or none)
- OS variant (for libvirt optimization)
- Boot order
- Static IP (optional)

The summary before "Create it?" shows the login user dcvm will use for
`ssh`/`exec`/`cp`; the wizard doesn't ask for it, so pass `-u <user>` if the
installed OS has one you want dcvm to use. `--uefi` and `--ttl` are options
only.

#### ISO Mode with Options
```bash
dcvm create-iso archvm --iso /path/to/archlinux.iso \
  -m 4096 \
  -c 4 \
  -d 50G \
  --graphics vnc \
  --os-variant archlinux \
  --uefi
```

**ISO Options:**
- `--iso`: Path to installer ISO (`-o` on `dcvm create`; root is asked for it if missing)
- `-m, --memory`: Memory in MB (default 2048)
- `-c, --cpus`: Number of CPUs (default 2)
- `-d, --disk`: Disk size, e.g. 20G (default 20G)
- `--graphics`: vnc, spice, or none (default: vnc, on 127.0.0.1)
- `--os-variant`: libosinfo variant (e.g., ubuntu24.04, win11, archlinux);
  detected from the ISO when left out, generic if unknown. dcvm sets no disk
  bus or network model: virt-install picks devices the OS variant has
  drivers for (virtio for a recognized Linux, older emulated devices such as
  IDE or SATA and e1000 for Windows or an unknown ISO)
- `--boot`: Boot order (default: hd,cdrom)
- `--uefi`: UEFI firmware instead of BIOS (needs OVMF: `ovmf`, or
  `edk2-ovmf` on Fedora and Arch)
- `--ip`: Static IP you set in the installer; refused if another VM has it
- `-u, --username`: The login user the installed OS has, so `dcvm ssh`,
  `exec` and `cp` work
- `--ttl`, `--wait`, `--json`, `-f`: as for `dcvm create`. `-f` answers
  every question with the defaults; `--wait` waits up to 30 minutes for SSH
- `--copy-iso`: Copy ISO to VM directory (root; users' ISOs are always copied)

**How the ISO boots:** the VM boots its disk first and falls back to the ISO
while the disk is empty. The installer runs on first boot, and when it
reboots, the VM keeps running and boots the installed OS. The ISO stays
attached until the VM is deleted; backups and restored copies leave it out.

**Connecting to Installer:**
```bash
dcvm network vnc status myvm   # VNC port (and password for users)
dcvm console myvm              # for --graphics none, if the ISO uses a serial console
```

**Unattended ISOs (agents):** an ISO that installs itself, such as an
Ubuntu autoinstall or a custom image with SSH and your public key baked in,
works without a terminal:

```bash
dcvm create-iso runner --iso ./runner.iso -u runner --uefi --ttl 4h --wait --json
dcvm exec runner -- 'uname -a'
```

`-p`, `-k`, `-r`, `--enable-root` and `--tailscale-authkey` configure cloud
images and are refused with an ISO. Secrets in the environment
(`DCVM_PASSWORD` and the others) are ignored for an ISO create.

### Listing VMs

```bash
dcvm list
```

Shows the VMs on the dcvm network as a table (state, IP, vCPU, memory). Other
libvirt VMs on the host are counted, not listed; use `virsh list --all` for
those.

### Checking VM Status

```bash
dcvm status
```

Shows the same table as `dcvm list`, plus whether the dcvm network is active
and how many VMs have port forwards. It takes no VM name.

### Starting a VM

```bash
dcvm start myvm
```

### Stopping a VM

```bash
dcvm stop myvm
```

`dcvm start`, `stop` and `restart` without a VM name act on every dcvm VM
(for a user, every VM of theirs), without asking.

### Restarting a VM

```bash
dcvm restart myvm
```

### Connecting to VM Console

```bash
dcvm console myvm
```

**Tip**: Press `Ctrl+]` to exit the console. Log in with the user and
password you set at create time.

Without a VM name, `dcvm console` prints SSH, HTTP and console hints for the
VMs in the port mappings file.

### Deleting a VM

```bash
dcvm delete myvm
dcvm delete --all    # every dcvm VM; asks you to type yes and a random number
```

> [!WARNING]
> `dcvm delete <vm>` does not ask for confirmation. It stops the VM and removes
> its disk, cloud-init files, DHCP lease and reservation, port forwards and
> static IP record. Backups are kept. If libvirt refuses to remove the VM
> (for example, because it has snapshots), the VM stays defined and stopped
> with its disk, without its forwards and lease, and delete exits 1 with
> libvirt's reason.

## Network Management

### View Network Information

```bash
dcvm network
```

Shows:
- Network configuration
- Bridge status
- VM IP addresses
- DHCP leases

### Setup Port Forwarding

```bash
dcvm network ports setup
```

Forwards a host port to each running VM's SSH (from 2221) and HTTP (from
8081) port. See [Networking](networking.md#port-forwarding).

### Clean DHCP Leases

```bash
dcvm network dhcp cleanup
```

Removes stale DHCP lease entries without restarting the network (same as
`dcvm network dhcp clear -s`). Needs `jq` and `dhcp_release`; see
[Networking](networking.md).

### VNC Management

Manage VNC graphics for VMs (useful for custom ISO installations):

```bash
# Check VNC status
dcvm network vnc status myvm

# Disable VNC (frees up port for other VMs)
dcvm network vnc disable myvm

# Enable VNC
dcvm network vnc enable myvm
```

**When to disable VNC:**
- After completing OS installation from ISO
- When you only need SSH/console access
- To conserve VNC ports for other VMs

**Note:** Disabling/enabling VNC requires the VM to be stopped. The command will offer to stop it automatically.

## Storage and Backup

### Backup a VM

```bash
dcvm backup create myvm
```

Shuts the VM down, copies its disk and configuration to
`$DATACENTER_BASE/backups`, and starts it again if it was running. The 5 most recent backups of
each VM are kept.

### Restore a VM

```bash
dcvm restore myvm
```

Restores VM from the latest backup.

```bash
dcvm backup restore myvm <backup_date> myvm-copy
dcvm backup restore myvm latest myvm-copy
```

Restores a backup as a new VM named `myvm-copy` and leaves `myvm` as is. `backup_date` is `YYYYMMDD_HHMMSS`, `dd.mm.yyyy[-N]`, the `<vm>-dd.mm.yyyy[-N]` ID from `backup list`, `latest` or `''`. See [backups.md](backups.md#restore) for what changes in the copy.

### Base images and `dcvm doctor`

```bash
dcvm template download ubuntu-24.04-server-cloudimg-amd64.img -f   # newest build; VMs move onto it
dcvm template download -a -f --restart   # all images; restart running VMs to move them now
dcvm doctor                              # host, network, VMs, base images, backups, storage
dcvm doctor --fix                        # repair what is safe
dcvm doctor --quiet                      # only problems; exit 1 if any
```

A re-download never breaks VMs: each VM disk refers to an immutable build in
`storage/templates/builds/`. Stopped VMs move onto the new build right away,
running ones the next time dcvm stops, restarts or backs them up. See
[Base images](base-images.md) and [dcvm doctor](doctor.md).

### Storage check

```bash
dcvm storage           # same as storage-cleanup
dcvm storage-cleanup   # also run hourly by datacenter-storage.timer
```

Connects over SSH to each running dcvm VM and prints its root file system
usage (also logged to `/var/log/datacenter-storage.log`). Over 85% full, it
gzips old logs and moves old `/tmp` files and logs to the NFS share. See
[Operations](operations.md#logs-and-monitoring). For disk use on the host,
run `du -sh /srv/datacenter/*`.

## SSH Access

### Using SSH Keys (Recommended)

If SSH key was configured during VM creation:

```bash
ssh ubuntu@<vm-ip> # or debian@<vm-ip>, etc.
```

### Using Password

```bash
ssh ubuntu@<vm-ip>
# Enter password when prompted
```

### With dcvm ssh

```bash
dcvm ssh web                           # log in with your own key
dcvm exec web -- 'uname -a'            # run a command; exits with its status
dcvm info web --json                   # state, IP, login user, owner
```

dcvm finds the address and login user itself and keeps the VMs' host keys in
`~/.ssh/dcvm_known_hosts`.

### Finding VM IP Address

```bash
dcvm status            # IP column of the VM table
dcvm info web          # one VM
dcvm network           # DHCP leases, static IPs and port mappings
```

## File Transfer

### Using dcvm cp

```bash
dcvm cp ./app web:/home/ubuntu/app     # to the VM (folders too)
dcvm cp web:/var/log/syslog .          # from the VM
```

### Using SCP

```bash
# Copy to VM
scp file.txt ubuntu@<vm-ip>:/home/ubuntu/

# Copy from VM
scp ubuntu@<vm-ip>:/path/to/file.txt ./
```

### Using SFTP

```bash
sftp ubuntu@<vm-ip>
```

### Using Shared NFS

If you enabled the NFS share when installing (the installer asks; the default
is no), VMs mount `$DATACENTER_BASE/nfs-share` at `/mnt/shared`. Every user
of every VM reads and writes there as one unprivileged account (`dcvm-nfs`),
so any VM can change or delete any file in it. On the host the folder
belongs to `dcvm-nfs` with mode 700, so no other host user can read it. Read [Security](security.md#network-exposure) before
enabling it.

```bash
# On host
sudo cp /srv/datacenter/nfs-share/file.txt .

# On VM
ls /mnt/shared/
```

## Package Installation

### During VM Creation

```bash
dcvm create webserver -f -p pass123 -k nginx,php,mysql-server
```

### Service setup for `-k` packages

Besides installing the package, dcvm sets up a service only for these exact
names. Names that only contain them, such as `nginx-extras`,
`libapache2-mod-php` or `python3-docker`, are installed as typed with no
setup.

| `-k` name | Setup |
| --- | --- |
| `nginx` | Enables and starts nginx and writes a welcome `index.html` (`/var/www/html`; `/usr/share/nginx/html` on Arch Linux) |
| `apache2` (also `apache` on Arch Linux) | Enables and starts Apache (`apache2`; package `apache`, service `httpd` on Arch Linux) and writes a welcome `index.html` (`/var/www/html`; `/srv/http` on Arch Linux) |
| `docker`, `docker.io` | Enables and starts Docker and adds the VM user to the `docker` group |
| `mysql-server`, `default-mysql-server` | Installs the database server below and sets the database passwords |

Database server installed:

| OS | `-k mysql-server` | `-k default-mysql-server` |
| --- | --- | --- |
| Ubuntu 20.04/22.04/24.04 | MySQL (`mysql-server`, service `mysql`) | `default-mysql-server` (MySQL, service `mysql`) |
| Debian 11/12/13, Kali Linux | MariaDB (`mariadb-server`, service `mariadb`) | `default-mysql-server` (MariaDB, service `mariadb`) |
| Arch Linux | MariaDB (`mariadb`, service `mariadb`) | MariaDB (`mariadb`, service `mariadb`) |
| Fedora 44 | MariaDB (`mariadb-server`, service `mariadb`) | MariaDB (`mariadb-server`, service `mariadb`) |

Database accounts:

- The database `root@localhost` gets the VM password (`-p`). With MariaDB it
  also keeps its passwordless login from the system root account
  (`sudo mariadb`); with MySQL it uses the password only.
- Unless the username is `root`, a database user with the VM username and
  password is created with all privileges.

### After VM Creation

Connect to VM and use apt:

```bash
ssh ubuntu@<vm-ip>
sudo apt update
sudo apt install package-name
```

## Common Operations

### Create a Web Server VM

```bash
dcvm create webserver \
  -f -p securepass \
  -m 2048 -c 2 -d 30G \
  -k nginx,php,mysql-server
```

### Create a Database Server VM

```bash
dcvm create dbserver \
  -f -p securepass \
  -m 4096 -c 4 -d 100G \
  -k mysql-server
```

### Create a Docker Host VM

```bash
dcvm create dockerhost \
  -f -p securepass \
  -m 8192 -c 4 -d 200G \
  -k docker.io
```

### Create a VM with Tailscale VPN

```bash
# Interactive - will prompt for auth key
dcvm create vpn-server -k tailscale

# Force mode - install only (manual connect later)
dcvm create vpn-server \
  -f -p securepass \
  -k tailscale

# Force mode - auto-connect with auth key
dcvm create vpn-server \
  -f -p securepass \
  -k tailscale,nginx \
  --tailscale-authkey tskey-auth-xxxxx

# Force mode - authkey alone (auto-installs tailscale)
dcvm create vpn-server \
  -f -p securepass \
  --tailscale-authkey tskey-auth-xxxxx
```

After VM creation with Tailscale:
- **Auto-connect**: VM will automatically join your Tailscale network
- **Manual connect**: SSH into the VM and run `sudo tailscale up`
- **Check status**: Run `tailscale status` inside the VM
- **Get Tailscale IP**: Run `tailscale ip` inside the VM

## Tips and Best Practices

### 1. Resource Allocation
- Don't allocate all host resources to VMs
- Leave at least 1 CPU and 25% RAM for the host
- Monitor host resource usage

### 2. Backups
- Backup VMs regularly
- Test restore procedures
- Keep backups on separate storage

### 3. Security
- Use strong passwords
- Enable SSH key authentication
- Disable root login when not needed
- Keep VMs updated

### 4. Networking
- Use port forwarding for external access
- Configure firewall rules as needed
- Monitor network traffic

### 5. Storage
- Clean up old backups regularly
- Monitor disk usage
- Plan for growth

## Troubleshooting

### VM Won't Start

```bash
# Check VM status
dcvm status myvm

# Check system logs
journalctl -xe

# Fix locked resources (force-stops the VM)
dcvm fix-lock myvm
```

### Can't Connect to VM

```bash
# Verify VM is running
dcvm status myvm

# Check network
dcvm network

# Verify SSH service in VM
virsh console myvm
# Then: systemctl status ssh
```

### Out of Space

```bash
# Check disk use
du -sh /srv/datacenter/*

# Delete old backups and unused VMs
dcvm backup delete myvm
dcvm delete old-vm
```

## Advanced Usage

For advanced topics, see:
- [Networking Guide](networking.md)
- [Backup and Restore](backups.md)
- [Operations and troubleshooting](operations.md)
- [Examples](examples/)

## Updating DCVM

### Check for Updates

```bash
dcvm self-update --check
```

### Update to Latest Version

```bash
dcvm self-update
```

### Force Update

```bash
dcvm self-update --force
```

The self-update command:
- compares the installed version with the latest one on GitHub
- saves the installed version in `/var/lib/dcvm/backups` (the last 3 are kept)
- downloads and installs the new files

`dcvm self-update --revert` lists the saved versions and puts the one you pick
back.

## Uninstalling DCVM

To completely remove DCVM from your system:

```bash
dcvm uninstall
```

> [!WARNING]
> **Uninstalling DCVM is destructive and cannot be undone.** `dcvm uninstall` asks for confirmation first, then will:
>
> - **Permanently delete every DCVM VM** (all VMs attached to the dcvm network, `datacenter-net` by default), including their disks under the install directory. Disks or ISOs a VM uses from elsewhere on the host are left in place.
> - **Remove the entire `DATACENTER_BASE` directory** (`rm -rf "$DATACENTER_BASE"`), which includes **all VM backups** stored in `$DATACENTER_BASE/backups`.
> - Remove the dcvm network, port-forwarding rules, DHCP leases, the storage service, the `dcvm` command/libraries, and `/etc/dcvm-install.conf`.
> - Delete `/var/log/datacenter-startup.log`.
> - Remove `alias dcvm` and `dcvm-completion.sh` lines from `~/.bashrc`, `~/.zshrc`, `~/.bash_profile`, and `~/.profile` (leaving `.bak` copies), and remove the bash completion scripts.
>
> To keep a VM, either detach it from the dcvm network before uninstalling (uninstall only deletes VMs attached to it), or save its definition (`virsh dumpxml <vm>`) and copy its disk images off the host. Copy any backups you want out of `$DATACENTER_BASE/backups`.

## Getting Help

```bash
# General help
dcvm help

# Command-specific help
dcvm create --help
dcvm create-iso --help
dcvm self-update --help
```

## Next Steps

- Explore [Examples](examples/)
- Read [Networking Guide](networking.md)
- Learn about [Backup Strategies](backups.md)
