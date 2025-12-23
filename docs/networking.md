# Networking Guide

This guide explains DCVM networking and how to operate it.

## Overview

DCVM uses different networking approaches depending on the platform:

### Linux Networking
- Default libvirt NAT network: name `datacenter-net`, bridge `virbr-dc`, CIDR `10.10.10.0/24`.
- Host IP on the bridge: `10.10.10.1`.
- DHCP range: `10.10.10.10` – `10.10.10.100`.
- Port forwarding via iptables NAT rules.

### macOS Networking
- QEMU user-mode networking (SLIRP) with NAT to host.
- Guest sees internal network `10.0.2.0/24` with gateway `10.0.2.2`.
- Port forwarding via QEMU's `hostfwd` option.
- No bridging or root privileges required.
- Each VM gets unique ports mapped to `localhost` (e.g., SSH on 2222, HTTP on 8080).

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
- Avoid IPs in the DHCP range if possible

### Custom ISO VMs
For custom ISO installations, static IP is noted during creation but must be configured manually inside the VM during OS installation.

## Quick commands

### Linux Port Forwarding

- Show network summary:
```bash
dcvm network
# or
dcvm network show
```

- Port forwarding management:
```bash
# Create/refresh typical forwards (SSH/HTTP per VM)
sudo dcvm network ports setup
# Show mappings and active rules
dcvm network ports show
# Re-apply rules from mappings file
sudo dcvm network ports apply
# Clear all forwarding rules
sudo dcvm network ports clear
# Connectivity tests
dcvm network ports test
```

- DHCP lease management:
```bash
dcvm network dhcp show
sudo dcvm network dhcp renew
sudo dcvm network dhcp cleanup
sudo dcvm network dhcp clear-vm <vm>
sudo dcvm network dhcp clear-mac <mac>
```

- Service helpers:
```bash
dcvm network status
dcvm network bridge
dcvm network ip-forwarding on|off|show
```

### macOS Port Forwarding

On macOS, port forwarding is configured per-VM during creation and managed via QEMU's `hostfwd` option.

```bash
# Show current port mappings
dcvm network ports show

# View setup information
dcvm network ports setup

# View active rules
dcvm network ports rules

# Test connectivity
dcvm network ports test
```

**How macOS Port Forwarding Works:**
- Each VM is assigned unique localhost ports during creation
- Default ports: SSH (2222+), HTTP (8080+)
- Access VMs via: `ssh -p 2222 admin@localhost`
- No root/iptables required - QEMU handles forwarding

**Changing Ports on macOS:**
1. Stop the VM: `dcvm stop myvm`
2. Edit config: `~/.dcvm/config/vms/myvm.conf`
3. Modify `SSH_PORT` and `HTTP_PORT` values
4. Start the VM: `dcvm start myvm`

## Port mapping persistence

### Linux
- Mappings are stored at: `$DATACENTER_BASE/port-mappings.txt`.
- You can edit this file; `apply` recreates iptables rules from it.

### macOS
- Mappings are stored per-VM at: `~/.dcvm/config/vms/<vmname>.conf`
- Port changes require VM restart to take effect.
- Ports are applied via QEMU command line options.

## Tips

### Linux Tips
- Keep SSH forwards unique per VM (e.g., 2222, 2223, ...).
- After reboots, if rules are missing, run `dcvm network ports apply`.
- For external exposure, ensure the host firewall allows forwarded ports.

### macOS Tips
- Default SSH ports start at 2222 and increment for each VM.
- Default HTTP ports start at 8080 and increment for each VM.
- VMs are always accessed via `localhost:<port>`.
- No bridge networking or promiscuous mode required.
- Internet access from VMs works automatically via QEMU user-mode networking.
