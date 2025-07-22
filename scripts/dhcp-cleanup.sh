#!/bin/bash

echo "=== DHCP Lease Cleanup Tool ==="
echo ""

# Show current leases
show_current_leases() {
    echo "Current DHCP leases:"
    virsh net-dhcp-leases datacenter-net 2>/dev/null || echo "No leases found"
    echo ""
}

# Method 1: Clear specific lease by MAC address
clear_lease_by_mac() {
    local mac_address=$1
    if [ -z "$mac_address" ]; then
        echo "Usage: clear_lease_by_mac <mac_address>"
        return 1
    fi
    
    echo "Clearing lease for MAC: $mac_address"
    
    # Remove from dnsmasq lease file
    if [ -f /var/lib/libvirt/dnsmasq/virbr-dc.leases ]; then
        sed -i "/$mac_address/d" /var/lib/libvirt/dnsmasq/virbr-dc.leases
        echo "Removed from lease file"
    fi
    
    # Remove from status file
    if [ -f /var/lib/libvirt/dnsmasq/virbr-dc.status ]; then
        sed -i "/$mac_address/d" /var/lib/libvirt/dnsmasq/virbr-dc.status
        echo "Removed from status file"
    fi
    
    # Restart network to apply changes
    virsh net-destroy datacenter-net
    sleep 2
    virsh net-start datacenter-net
    echo "Network restarted"
}

# Method 2: Clear all DHCP leases
clear_all_leases() {
    echo "Clearing ALL DHCP leases for datacenter-net..."
    
    # Stop the network
    virsh net-destroy datacenter-net 2>/dev/null || true
    
    # Clear lease files
    if [ -f /var/lib/libvirt/dnsmasq/virbr-dc.leases ]; then
        > /var/lib/libvirt/dnsmasq/virbr-dc.leases
        echo "Cleared lease file"
    fi
    
    if [ -f /var/lib/libvirt/dnsmasq/virbr-dc.status ]; then
        > /var/lib/libvirt/dnsmasq/virbr-dc.status
        echo "Cleared status file"
    fi
    
    # Remove any PID files
    rm -f /var/lib/libvirt/dnsmasq/virbr-dc.pid
    
    # Restart the network
    virsh net-start datacenter-net
    echo "Network restarted with clean lease table"
}

# Method 3: Clear leases for specific VM
clear_vm_lease() {
    local vm_name=$1
    if [ -z "$vm_name" ]; then
        echo "Usage: clear_vm_lease <vm_name>"
        return 1
    fi
    
    echo "Clearing leases for VM: $vm_name"
    
    # Get MAC address of the VM
    mac_address=$(virsh domiflist "$vm_name" 2>/dev/null | grep datacenter-net | awk '{print $5}')
    
    if [ -n "$mac_address" ]; then
        echo "Found MAC address: $mac_address"
        clear_lease_by_mac "$mac_address"
    else
        echo "Could not find MAC address for VM: $vm_name"
        return 1
    fi
}

# Method 4: Clean up stale/expired leases
cleanup_stale_leases() {
    echo "Cleaning up stale/expired leases..."
    
    current_time=$(date +%s)
    temp_file="/tmp/dhcp_leases_clean"
    
    if [ -f /var/lib/libvirt/dnsmasq/virbr-dc.leases ]; then
        # Read lease file and keep only valid leases
        while IFS=' ' read -r timestamp mac ip hostname client_id; do
            if [ -n "$timestamp" ] && [ "$timestamp" != "duid" ]; then
                # Check if lease is still valid (not expired)
                if [ "$timestamp" -gt "$current_time" ]; then
                    echo "$timestamp $mac $ip $hostname $client_id" >> "$temp_file"
                else
                    echo "Removing expired lease: $ip ($hostname)"
                fi
            fi
        done < /var/lib/libvirt/dnsmasq/virbr-dc.leases
        
        # Replace lease file with cleaned version
        if [ -f "$temp_file" ]; then
            mv "$temp_file" /var/lib/libvirt/dnsmasq/virbr-dc.leases
            echo "Cleaned lease file"
        else
            > /var/lib/libvirt/dnsmasq/virbr-dc.leases
            echo "No valid leases found, cleared lease file"
        fi
    fi
    
    # Restart network
    virsh net-destroy datacenter-net
    sleep 2
    virsh net-start datacenter-net
    echo "Network restarted"
}

# Method 5: Force release all current VM leases and renew
force_renew_all() {
    echo "Forcing DHCP renewal for all running VMs..."
    
    # Get list of running VMs using datacenter-net
    running_vms=$(virsh list | grep running | awk '{print $2}' | while read vm; do
        if virsh domiflist "$vm" 2>/dev/null | grep -q datacenter-net; then
            echo "$vm"
        fi
    done)
    
    if [ -n "$running_vms" ]; then
        echo "Found running VMs: $running_vms"
        
        # Clear all leases
        clear_all_leases
        
        # Wait a moment
        sleep 5
        
        # Force DHCP renewal on each VM
        echo "$running_vms" | while read vm; do
            if [ -n "$vm" ]; then
                echo "Forcing DHCP renewal on $vm..."
                # Try to run dhclient on the VM via SSH if possible
                ssh_port=$(grep "^$vm " /srv/datacenter/port-mappings.txt 2>/dev/null | awk '{print $3}')
                if [ -n "$ssh_port" ]; then
                    timeout 10 ssh -o ConnectTimeout=3 -p "$ssh_port" admin@10.8.8.223 "sudo dhclient -r enp1s0; sudo dhclient enp1s0" 2>/dev/null &
                fi
            fi
        done
        
        echo "DHCP renewal initiated. Wait 30 seconds and check with: virsh net-dhcp-leases datacenter-net"
    else
        echo "No running VMs found using datacenter-net"
    fi
}

# Interactive menu
case "$1" in
    "show")
        show_current_leases
        ;;
    "clear-mac")
        if [ -z "$2" ]; then
            echo "Usage: $0 clear-mac <mac_address>"
            echo "Example: $0 clear-mac 52:54:00:12:34:56"
        else
            show_current_leases
            clear_lease_by_mac "$2"
            echo ""
            show_current_leases
        fi
        ;;
    "clear-vm")
        if [ -z "$2" ]; then
            echo "Usage: $0 clear-vm <vm_name>"
            echo "Example: $0 clear-vm datacenter-vm1"
        else
            show_current_leases
            clear_vm_lease "$2"
            echo ""
            show_current_leases
        fi
        ;;
    "clear-all")
        show_current_leases
        echo "WARNING: This will clear ALL DHCP leases!"
        read -p "Are you sure? (y/N): " confirm
        if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
            clear_all_leases
            echo ""
            show_current_leases
        else
            echo "Cancelled"
        fi
        ;;
    "cleanup")
        show_current_leases
        cleanup_stale_leases
        echo ""
        show_current_leases
        ;;
    "renew")
        show_current_leases
        force_renew_all
        ;;
    "files")
        echo "DHCP lease files location:"
        echo "/var/lib/libvirt/dnsmasq/virbr-dc.leases"
        echo "/var/lib/libvirt/dnsmasq/virbr-dc.status"
        echo ""
        echo "Lease file contents:"
        if [ -f /var/lib/libvirt/dnsmasq/virbr-dc.leases ]; then
            cat /var/lib/libvirt/dnsmasq/virbr-dc.leases
        else
            echo "Lease file not found"
        fi
        echo ""
        echo "Status file contents:"
        if [ -f /var/lib/libvirt/dnsmasq/virbr-dc.status ]; then
            cat /var/lib/libvirt/dnsmasq/virbr-dc.status
        else
            echo "Status file not found"
        fi
        ;;
    *)
        echo "DHCP Lease Cleanup Tool"
        echo ""
        echo "Usage: $0 {command} [options]"
        echo ""
        echo "Commands:"
        echo "  show                    - Show current DHCP leases"
        echo "  clear-mac <mac>         - Clear lease for specific MAC address"
        echo "  clear-vm <vm_name>      - Clear lease for specific VM"
        echo "  clear-all               - Clear ALL DHCP leases (with confirmation)"
        echo "  cleanup                 - Remove only expired/stale leases"
        echo "  renew                   - Force DHCP renewal for all running VMs"
        echo "  files                   - Show lease file contents and locations"
        echo ""
        echo "Examples:"
        echo "  $0 show                           # Show current leases"
        echo "  $0 clear-vm datacenter-vm1       # Clear lease for specific VM"
        echo "  $0 clear-mac 52:54:00:12:34:56   # Clear lease for MAC address"
        echo "  $0 cleanup                       # Remove expired leases only"
        echo "  $0 clear-all                     # Clear all leases (dangerous!)"
        echo ""
        show_current_leases
        ;;
esac
