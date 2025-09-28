#!/bin/bash

if [ -f /etc/dcvm-install.conf ]; then
	source /etc/dcvm-install.conf
else
	echo "[ERROR] /etc/dcvm-install.conf not found!"
	exit 1
fi

DATACENTER_BASE="${DATACENTER_BASE:-/srv/datacenter}"
NETWORK_NAME="${NETWORK_NAME:-datacenter-net}"
BRIDGE_NAME="${BRIDGE_NAME:-virbr-dc}"

echo "=== DHCP Lease Cleanup Tool ==="
echo ""

show_current_leases() {
	echo "Current DHCP leases:"
	virsh net-dhcp-leases $NETWORK_NAME 2>/dev/null || echo "No leases found"
	echo ""
}

clear_lease_by_mac() {
	local mac_address=$1
	if [ -z "$mac_address" ]; then
		echo "Usage: clear_lease_by_mac <mac_address>"
		return 1
	fi

	echo "Clearing lease for MAC: $mac_address"

	if [ -f /var/lib/libvirt/dnsmasq/virbr-dc.leases ]; then
		sed -i "/$mac_address/d" /var/lib/libvirt/dnsmasq/virbr-dc.leases
		echo "Removed from lease file"
	fi

	if [ -f /var/lib/libvirt/dnsmasq/virbr-dc.status ]; then
		sed -i "/$mac_address/d" /var/lib/libvirt/dnsmasq/virbr-dc.status
		echo "Removed from status file"
	fi

	# Reload dnsmasq gracefully instead of restarting the libvirt network
	dnsmasq_pid=$(ps aux | grep "dnsmasq.*${BRIDGE_NAME}" | grep -v grep | awk '{print $2}' | head -1)
	if [ -n "$dnsmasq_pid" ]; then
		kill -HUP "$dnsmasq_pid" 2>/dev/null && echo "DHCP service (dnsmasq) reloaded" || echo "Failed to signal dnsmasq"
	else
		echo "dnsmasq process not found for bridge ${BRIDGE_NAME}; leases cleaned on disk"
	fi
}

clear_all_leases() {
	echo "Clearing ALL DHCP leases for $NETWORK_NAME..."

	if [ -f /var/lib/libvirt/dnsmasq/$BRIDGE_NAME.leases ]; then
		>/var/lib/libvirt/dnsmasq/$BRIDGE_NAME.leases
		echo "Cleared lease file"
	fi

	if [ -f /var/lib/libvirt/dnsmasq/$BRIDGE_NAME.status ]; then
		>/var/lib/libvirt/dnsmasq/$BRIDGE_NAME.status
		echo "Cleared status file"
	fi

	rm -f /var/lib/libvirt/dnsmasq/$BRIDGE_NAME.pid

	dnsmasq_pid=$(ps aux | grep "dnsmasq.*${BRIDGE_NAME}" | grep -v grep | awk '{print $2}' | head -1)
	if [ -n "$dnsmasq_pid" ]; then
		kill -HUP "$dnsmasq_pid" 2>/dev/null && echo "DHCP service (dnsmasq) reloaded" || echo "Failed to signal dnsmasq"
	else
		echo "dnsmasq process not found for bridge ${BRIDGE_NAME}; leases cleared on disk"
	fi
}

clear_vm_lease() {
	local vm_name=$1
	if [ -z "$vm_name" ]; then
		echo "Usage: clear_vm_lease <vm_name>"
		return 1
	fi

	echo "Clearing leases for VM: $vm_name"

	mac_address=$(virsh domiflist "$vm_name" 2>/dev/null | grep $NETWORK_NAME | awk '{print $5}')

	if [ -n "$mac_address" ]; then
		echo "Found MAC address: $mac_address"
		clear_lease_by_mac "$mac_address"
	else
		echo "Could not find MAC address for VM: $vm_name"
		return 1
	fi
}

cleanup_stale_leases() {
	echo "Cleaning up stale/expired leases..."

	current_time=$(date +%s)
	temp_file="/tmp/dhcp_leases_clean"

	if [ -f /var/lib/libvirt/dnsmasq/$BRIDGE_NAME.leases ]; then
		while IFS=' ' read -r timestamp mac ip hostname client_id; do
			if [ -n "$timestamp" ] && [ "$timestamp" != "duid" ]; then
				if [ "$timestamp" -gt "$current_time" ]; then
					echo "$timestamp $mac $ip $hostname $client_id" >>"$temp_file"
				else
					echo "Removing expired lease: $ip ($hostname)"
				fi
			fi
		done </var/lib/libvirt/dnsmasq/$BRIDGE_NAME.leases

		if [ -f "$temp_file" ]; then
			mv "$temp_file" /var/lib/libvirt/dnsmasq/$BRIDGE_NAME.leases
			echo "Cleaned lease file"
		else
			>/var/lib/libvirt/dnsmasq/$BRIDGE_NAME.leases
			echo "No valid leases found, cleared lease file"
		fi
	fi

	dnsmasq_pid=$(ps aux | grep "dnsmasq.*${BRIDGE_NAME}" | grep -v grep | awk '{print $2}' | head -1)
	if [ -n "$dnsmasq_pid" ]; then
		kill -HUP "$dnsmasq_pid" 2>/dev/null && echo "DHCP service (dnsmasq) reloaded" || echo "Failed to signal dnsmasq"
	else
		echo "dnsmasq process not found for bridge ${BRIDGE_NAME}; leases cleaned on disk"
	fi
}

force_renew_all() {
	echo "Forcing DHCP renewal for all running VMs..."

	running_vms=$(virsh list | grep running | awk '{print $2}' | while read vm; do
		if virsh domiflist "$vm" 2>/dev/null | grep -q $NETWORK_NAME; then
			echo "$vm"
		fi
	done)

	if [ -n "$running_vms" ]; then
		echo "Found running VMs: $running_vms"

		clear_all_leases

		sleep 5

		echo "$running_vms" | while read vm; do
			if [ -n "$vm" ]; then
				echo "Forcing DHCP renewal on $vm..."
				ssh_port=$(grep "^$vm " $DATACENTER_BASE/port-mappings.txt 2>/dev/null | awk '{print $3}')
				if [ -n "$ssh_port" ]; then
					timeout 10 ssh -o ConnectTimeout=3 -p "$ssh_port" admin@10.8.8.223 "sudo dhclient -r enp1s0; sudo dhclient enp1s0" 2>/dev/null &
				fi
			fi
		done

		echo "DHCP renewal initiated. Wait 30 seconds and check with: virsh net-dhcp-leases $NETWORK_NAME"
	else
		echo "No running VMs found using $NETWORK_NAME"
	fi
}

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
	echo "  $0 show                          # Show current leases"
	echo "  $0 clear-vm datacenter-vm1       # Clear lease for specific VM"
	echo "  $0 clear-mac 52:54:00:12:34:56   # Clear lease for MAC address"
	echo "  $0 cleanup                       # Remove expired leases only"
	echo "  $0 clear-all                     # Clear all leases (dangerous!)"
	echo ""
	show_current_leases
	;;
esac
