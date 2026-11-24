# Networking Guide

This guide explains DCVM networking and how to operate it.

## Overview
- Default libvirt NAT network: name `datacenter-net`, bridge `virbr-dc`, CIDR `10.10.10.0/24`.
- Host IP on the bridge: `10.10.10.1`.
- DHCP range: `10.10.10.10` – `10.10.10.200` (dnsmasq, run by libvirt).
- VMs reach the internet through NAT on the host. Nothing outside the host
  can reach a VM until you [forward a port](#port-forwarding).

See also: [Architecture](architecture.md#networking) ·
[Security](security.md#network-exposure)

## Static IP Configuration

VMs can be configured with static IP addresses during creation. The static IP must be within the network subnet.

### Creating VM with Static IP

**Interactive Mode:**
```bash
dcvm create myvm
# During interactive prompts, select "y" for static IP
# Enter an IP like 10.10.10.50
```

**Force Mode:**
```bash
dcvm create myvm -f -p password123 --ip 10.10.10.50
```

### Static IP Requirements
- IP must be in the configured subnet (default: `10.10.10.0/24`)
- Valid range: `10.10.10.2` - `10.10.10.254`
- `10.10.10.1` is reserved for the gateway
- `10.10.10.255` is the broadcast address
- dcvm reserves the address for the VM's MAC in the network's DHCP
  (`ip-dhcp-host`), so dnsmasq never hands it to another VM, also inside the
  DHCP range; `dcvm delete` removes the reservation. VMs created by older
  versions have no reservation: prefer addresses outside the DHCP range (`.2`-`.9` or
  `.201`-`.254`) for them.

### Custom ISO VMs
For custom ISO installations, static IP is noted during creation but must be configured manually inside the VM during OS installation.

## VNC Management

DCVM allows you to toggle VNC graphics for VMs. This is critical for saving resources (headless mode) or enabling remote desktop access.

### VNC Security

**VNC graphics are only enabled by default for specific OS types (Kali and Debian 13).** Other operating systems use headless mode (`none`) by default.

When VNC is enabled (either by default for those OS types or via `--graphics vnc,listen=127.0.0.1`), **VNC listens on `127.0.0.1` (localhost only)**. This means:
- VNC is only accessible from the host machine
- To access VNC remotely, use SSH tunneling: `ssh -L 5900:localhost:5900 user@host`
- VNC and SPICE get a random password (`dcvm create`, `dcvm create-iso`,
  `dcvm network vnc enable`), whether root or a user sets them up, because
  any local account could otherwise connect to `127.0.0.1`. The create output
  (and `"display_password"` in its JSON) shows it; `dcvm network vnc status
  <vm>` shows it again to root and the VM's owner
- This is a security feature to prevent unauthorized access

### Graphics Mode During Creation

You can set the graphics mode when creating a VM:

```bash
# Force VNC (listening on localhost)
dcvm create myvm -f -p pass123 --graphics vnc,listen=127.0.0.1

# Headless mode (no VNC, console only)
dcvm create myvm -f -p pass123 --graphics none
```

By default, DCVM automatically selects the graphics mode:
- **Kali Linux and Debian 13**: VNC enabled (required for graphical installers)
- **Other cloud images**: Headless mode (console access via `virsh console`)

### VNC Commands

```bash
# Check VNC status (enabled/disabled and port)
dcvm network vnc status <vm_name>

# Enable VNC (requires VM restart)
# Assigns a local listening port (127.0.0.1:590x)
dcvm network vnc enable <vm_name>

# Disable VNC (requires VM restart)
# Converts VM to headless mode (console access only)
dcvm network vnc disable <vm_name>
```

**Note:** Disabling VNC frees up system resources and potential attack surfaces. Use `dcvm console <vm_name>` for text-based access when VNC is disabled.

## Port Forwarding

DCVM provides a robust port forwarding system to expose VM services to the host network.

### Workflow

1.  **Setup/Refresh Rules:**
    Removes dcvm's previous rules, then gives each *running* VM on the dcvm
    network the next pair of host ports, starting at 2221 (to the VM's port
    22) and 8081 (to port 80). Run it again after starting or adding VMs.
    Ports something on the host already listens on are skipped.
    `SSH_PORT_START` and `HTTP_PORT_START` in the environment change the
    starting ports; dcvm uses 79 SSH and 99 HTTP ports from there.
    ```bash
    dcvm network ports setup
    ```

2.  **View Rules:**
    ```bash
    dcvm network ports show
    ```

3.  **Test Connectivity:**
    Checks that each forward's rules exist, that libvirt's nftables rules
    (see below) don't reject them, and that the VM answers on the port. The
    connection is made from the host, so it can't show a firewall in front of
    the host.
    ```bash
    dcvm network ports test
    ```

4.  **Persistence:**
    The table is saved to `$DATACENTER_BASE/port-mappings.txt`, one line per
    VM: `VM_NAME VM_IP SSH_PORT HTTP_PORT`, readable by root only (users see
    their own forwards with `ports show`). `dcvm-boot.service` rebuilds the
    iptables rules from it after a reboot (dcvm also writes
    `/etc/iptables/rules.v4` when `iptables-save` exists). Re-apply it by hand
    after editing it:
    ```bash
    dcvm network ports apply
    ```

### Firewalls

- **libvirt's firewall backend:** dcvm's forwards are iptables rules. Where
  libvirt uses nftables for its networks (the default on Fedora and Arch),
  it rejects forwarded connections to VMs in its own table, and no iptables
  rule can let them through. The installer therefore sets
  `firewall_backend = "iptables"` in `/etc/libvirt/network.conf`, as libvirt
  already does on Debian and Ubuntu. If that setting is lost (for example by
  a libvirt upgrade), `ports test` and `dcvm doctor` say so.
- **Rule order:** libvirt puts its own rules first when it restarts (for
  example after a package update), above the forwards. Run
  `dcvm network ports apply` afterwards; after a reboot `dcvm-boot.service`
  does it.
- **firewalld** (Fedora): libvirt puts the dcvm bridge in its `libvirt`
  zone, which rejects NFS; the installer allows `nfs`, `rpc-bind` and
  `mountd` in it. Forwarded connections pass firewalld without extra rules.

### One VM at a time

`dcvm network ports add <vm>` forwards SSH and HTTP for one VM from the next
free ports in dcvm's ranges (skipping ports something on the host already
listens on); `dcvm network ports remove <vm>` takes them away. Users without
root use these for their own VMs; `setup`, `apply` and `clear` are for admins,
because they touch every VM's forwards.

### Command Reference

| Command | Description |
| :--- | :--- |
| `setup` | Auto-discover VMs and create new rules |
| `show` | Display saved mapping table |
| `rules` | Show active `iptables` rules |
| `apply` | Apply rules from mappings file |
| `clear` | Remove all forwarding rules |
| `test` | Per VM: ping, and for SSH and HTTP that the DNAT and FORWARD rules exist, libvirt's nftables rules don't reject them, and the VM port accepts connections |

## Quick commands

- Show network summary:
```bash
dcvm network show
```

- DHCP lease management:
```bash
dcvm network dhcp show
# Release running DHCP VMs' leases and make them ask again (cuts their link for 5 s)
dcvm network dhcp renew

# Clear one lease: exact VM hostname (any case) or MAC; no network restart
dcvm network dhcp clear <vm_name_or_mac>
# Clear stale/orphaned leases (no network restart)
dcvm network dhcp clear -s
# Clear ALL leases; the network keeps running (asks first)
dcvm network dhcp clear -a
```

  `clear <vm_name_or_mac>` and `clear -s` release the lease in the running
  dnsmasq with `dhcp_release` (package `dnsmasq-utils` on Debian/Ubuntu and
  Fedora, part of `dnsmasq` on Arch) and remove it from libvirt's status file
  (`/var/lib/libvirt/dnsmasq/<bridge>.status`) with `jq`. The installer
  installs both. Without `dhcp_release` or `jq` they fail with an error and
  change nothing. They also fail when the status file cannot be read, another
  cleanup holds the lock for more than 30 seconds, or `dhcp_release` fails.
  When no lease matches, `clear` says so and succeeds. A static DHCP
  reservation (`ip-dhcp-host`) for the MAC is kept; `dcvm delete` removes the
  deleted VM's reservation.

- Service helpers:
```bash
dcvm network status
dcvm network bridge
dcvm network ip-forwarding on|off|show
```

`on` persists it in `/etc/sysctl.d/90-dcvm.conf` and fails, naming the file,
when a sysctl file read later sets it back to 0. `off` removes that file.

Forwarded ports listen on every host interface, and DNAT applies to
connections arriving from other machines, not to the host's own connections:
from the host itself, connect to the VM's IP. `setup`, `apply` and `clear`
delete every rule in the shape dcvm makes (a DNAT to port 22 or 80 of an
address on the dcvm network, and its FORWARD accept), on any host port; other
rules stay.

## Tips
- **Security:** Ensure your host firewall (ufw/iptables) permits traffic on the forwarded ports if you want external access.
- **Persistence:** Run `dcvm network ports apply` after a host reboot or a libvirt restart if forwards stop answering (see [Firewalls](#firewalls)).
