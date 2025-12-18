# Networking Guide

This guide explains DCVM networking and how to operate it.

## Overview
- Default libvirt NAT network: name `datacenter-net`, bridge `virbr-dc`, CIDR `10.10.10.0/24`.
- Host IP on the bridge: `10.10.10.1`.
- DHCP range: `10.10.10.10` – `10.10.10.100`.

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

## Port mapping persistence
- Mappings are stored at: `$DATACENTER_BASE/port-mappings.txt`.
- You can edit this file; `apply` recreates iptables rules from it.

## Tips
- Keep SSH forwards unique per VM (e.g., 2222, 2223, ...).
- After reboots, if rules are missing, run `dcvm network ports apply`.
- For external exposure, ensure the host firewall allows forwarded ports.
