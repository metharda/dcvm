#!/bin/bash

get_vm_ip() {
    local vm_name=$1
    local ip=""
    local attempts=0
    
    echo "Looking for IP address of $vm_name..."
    
    while [ -z "$ip" ] && [ $attempts -lt 10 ]; do
        # Method 1: Try agent source
        ip=$(virsh domifaddr "$vm_name" --source agent 2>/dev/null | awk '/ipv4/ {print $4}' | cut -d'/' -f1 | grep '^10\.10\.10\.' | head -1)
        
        # Method 2: Try lease source
        if [ -z "$ip" ]; then
            ip=$(virsh domifaddr "$vm_name" --source lease 2>/dev/null | awk '/ipv4/ {print $4}' | cut -d'/' -f1 | grep '^10\.10\.10\.' | head -1)
        fi
        
        # Method 3: Try DHCP leases
        if [ -z "$ip" ]; then
            ip=$(virsh net-dhcp-leases datacenter-net 2>/dev/null | grep "$vm_name" | awk '{print $5}' | cut -d'/' -f1 | grep '^10\.10\.10\.' | head -1)
        fi
        
        # Method 4: Try MAC address lookup
        if [ -z "$ip" ]; then
            mac=$(virsh domiflist "$vm_name" | grep datacenter-net | awk '{print $5}')
            if [ -n "$mac" ]; then
                ip=$(virsh net-dhcp-leases datacenter-net | grep "$mac" | awk '{print $5}' | cut -d'/' -f1 | grep '^10\.10\.10\.' | head -1)
            fi
        fi
        
        # Method 5: Try ARP table
        if [ -z "$ip" ]; then
            mac=$(virsh domiflist "$vm_name" | grep datacenter-net | awk '{print $5}')
            if [ -n "$mac" ]; then
                ip=$(arp -a | grep "$mac" | grep -oE '10\.10\.10\.[0-9]+' | head -1)
            fi
        fi
        
        # Validate IP format and reachability
        if [ -n "$ip" ] && [[ $ip =~ ^10\.10\.10\.[0-9]+$ ]]; then
            # Test if IP is reachable
            if ping -c 1 -W 2 "$ip" >/dev/null 2>&1; then
                echo "$vm_name IP found and reachable: $ip"
                break
            else
                echo "$vm_name IP found but not reachable: $ip (attempt $((attempts+1)))"
                ip=""
            fi
        else
            if [ $attempts -eq 0 ]; then
                echo "Attempt $((attempts+1)): Waiting for $vm_name to get valid IP address..."
            fi
        fi
        
        sleep 5
        attempts=$((attempts+1))
    done
    
    echo "$ip"
}

cleanup_port_forwarding() {
    echo "Cleaning up all existing datacenter port forwarding rules..."
    
    # Clean up NAT rules (ports 2220-2299 for SSH, 8080-8179 for HTTP)
    for port in {2220..2299} {8080..8179}; do
        while iptables -t nat -L PREROUTING -n --line-numbers 2>/dev/null | grep -q ":$port "; do
            line=$(iptables -t nat -L PREROUTING -n --line-numbers | grep ":$port " | head -1 | awk '{print $1}')
            iptables -t nat -D PREROUTING $line 2>/dev/null || break
        done
    done
    
    # Clean up FORWARD rules for datacenter subnet
    while iptables -L FORWARD -n --line-numbers 2>/dev/null | grep -q "10\.10\.10\."; do
        line=$(iptables -L FORWARD -n --line-numbers | grep "10\.10\.10\." | head -1 | awk '{print $1}')
        iptables -D FORWARD $line 2>/dev/null || break
    done
}

# Wait for VMs to boot and initialize

# Get all VMs connected to datacenter-net
echo "Discovering VMs on datacenter-net..."
VM_LIST=$(virsh list --all | grep -E "(running|shut off)" | awk '{print $2}' | grep -v "^$" | while read vm; do
    # Check if VM uses datacenter-net
    if virsh domiflist "$vm" 2>/dev/null | grep -q "datacenter-net"; then
        echo "$vm"
    fi
done)

if [ -z "$VM_LIST" ]; then
    echo "No VMs found using datacenter-net"
    exit 1
fi

echo "Found VMs using datacenter-net:"
echo "$VM_LIST"
echo ""

# Clean up existing rules
cleanup_port_forwarding

# Get host IP (you can modify this if needed)
HOST_IP="10.8.8.223"

# Initialize port counters
SSH_PORT_START=2221
HTTP_PORT_START=8081
ssh_port=$SSH_PORT_START
http_port=$HTTP_PORT_START

# Arrays to store VM info
declare -A vm_ips
declare -A vm_ssh_ports  
declare -A vm_http_ports

echo "Configuring port forwarding for discovered VMs..."

# Process each VM
for vm in $VM_LIST; do
    # Skip if VM is not running
    if ! virsh list | grep -q "$vm.*running"; then
        echo "Skipping $vm (not running)"
        continue
    fi
    
    vm_ip=$(get_vm_ip "$vm")
    
    if [ -n "$vm_ip" ] && [[ $vm_ip =~ ^10\.10\.10\.[0-9]+$ ]]; then
        echo "Setting up port forwarding for $vm ($vm_ip)..."
        
        # Store VM info
        vm_ips[$vm]=$vm_ip
        vm_ssh_ports[$vm]=$ssh_port
        vm_http_ports[$vm]=$http_port
        
        # Configure SSH port forwarding
        iptables -t nat -I PREROUTING -p tcp --dport $ssh_port -j DNAT --to-destination $vm_ip:22
        iptables -I FORWARD -p tcp -d $vm_ip --dport 22 -j ACCEPT
        
        # Configure HTTP port forwarding  
        iptables -t nat -I PREROUTING -p tcp --dport $http_port -j DNAT --to-destination $vm_ip:80
        iptables -I FORWARD -p tcp -d $vm_ip --dport 80 -j ACCEPT
        
        echo "  $vm: SSH=$ssh_port, HTTP=$http_port"
        
        # Increment ports for next VM
        ssh_port=$((ssh_port + 1))
        http_port=$((http_port + 1))
    else
        echo "Skipping $vm (no valid IP found)"
    fi
done

# Allow forwarding for established connections
iptables -I FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT

# Display summary
echo ""
echo "=== Port forwarding configured successfully! ==="
echo "Host IP: $HOST_IP"
echo ""

for vm in $VM_LIST; do
    if [ -n "${vm_ips[$vm]}" ]; then
        echo "$vm (${vm_ips[$vm]}):"
        echo "  SSH: ssh -p ${vm_ssh_ports[$vm]} admin@$HOST_IP"
        echo "  HTTP: http://$HOST_IP:${vm_http_ports[$vm]}"
        echo ""
    fi
done

# Save iptables rules
iptables-save > /etc/iptables/rules.v4
echo "iptables rules saved to /etc/iptables/rules.v4"

# Update SSH config
echo "Updating SSH configuration..."
# Backup existing config
if [ -f ~/.ssh/config ]; then
    cp ~/.ssh/config ~/.ssh/config.backup.$(date +%s)
fi

# Remove all datacenter VM entries
for vm in $VM_LIST; do
    sed -i "/^Host $vm$/,/^$/d" ~/.ssh/config 2>/dev/null || true
done

# Add new entries
for vm in $VM_LIST; do
    if [ -n "${vm_ips[$vm]}" ]; then
        cat >> ~/.ssh/config << EOF

Host $vm
    HostName $HOST_IP
    Port ${vm_ssh_ports[$vm]}
    User admin
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
EOF
    fi
done

echo ""
echo "SSH configuration updated. You can now use:"
for vm in $VM_LIST; do
    if [ -n "${vm_ips[$vm]}" ]; then
        echo "  ssh $vm"
    fi
done

echo ""

# Create or update port mapping file for reference
cat > /srv/datacenter/port-mappings.txt << EOF
# Datacenter VM Port Mappings - Generated $(date)
# Format: VM_NAME VM_IP SSH_PORT HTTP_PORT

EOF

for vm in $VM_LIST; do
    if [ -n "${vm_ips[$vm]}" ]; then
        echo "$vm ${vm_ips[$vm]} ${vm_ssh_ports[$vm]} ${vm_http_ports[$vm]}" >> /srv/datacenter/port-mappings.txt
    fi
done

echo "Port mappings saved to /srv/datacenter/port-mappings.txt"
