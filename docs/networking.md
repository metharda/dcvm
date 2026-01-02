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

## VNC Management

DCVM allows you to toggle VNC graphics for VMs. usage is critical for saving resources (headless mode) or enabling remote desktop access.

### Commands

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
    Automatically discovers running VMs and creates forwarding rules (typically starting at port 2221/8081).
    ```bash
    dcvm network ports setup
    ```

2.  **View Rules:**
    ```bash
    dcvm network ports show
    ```

3.  **Test Connectivity:**
    Verifies that the forwarded ports are actually reachable.
    ```bash
    dcvm network ports test
    ```

4.  **Persistence:**
    Rules are saved to `$DATACENTER_BASE/port-mappings.txt`. You can manually edit this file and re-apply:
    ```bash
    dcvm network ports apply
    ```

### Command Reference

| Command | Description |
| :--- | :--- |
| `setup` | Auto-discover VMs and create new rules |
| `show` | Display saved mapping table |
| `rules` | Show active `iptables` rules |
| `apply` | Apply rules from mappings file |
| `clear` | Remove all forwarding rules |
| `test` | functionality check (Ping/SSH/HTTP) |

## Quick commands

- Show network summary:
```bash
dcvm network show
```

- DHCP lease management:
```bash
dcvm network dhcp show
# Force renewal for all VMs
dcvm network dhcp renew

# Clear specific lease
dcvm network dhcp clear <vm_name_or_mac>
# Clear stale/orphaned leases
dcvm network dhcp clear -s
```

- Service helpers:
```bash
dcvm network status
dcvm network bridge
dcvm network ip-forwarding on|off|show
```

## Tips
- **Security:** Ensure your host firewall (ufw/iptables) permits traffic on the forwarded ports if you want external access.
- **Persistence:** Run `dcvm network ports apply` after a host reboot if rules are missing.
