#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../utils/common.sh"

cleanup_port_forwarding_for_vm() {
	local vm_ip="$1"
	local ssh_port="$2"
	local http_port="$3"

	print_info "Cleaning up port forwarding rules"

	if [ -n "$ssh_port" ] && [ -n "$http_port" ]; then
		iptables -t nat -D PREROUTING -p tcp --dport "$ssh_port" -j DNAT --to-destination "$vm_ip:22" 2>/dev/null && print_info "Removed SSH port rule $ssh_port" || true
		iptables -t nat -D PREROUTING -p tcp --dport "$http_port" -j DNAT --to-destination "$vm_ip:80" 2>/dev/null && print_info "Removed HTTP port rule $http_port" || true
		iptables -D FORWARD -p tcp -d "$vm_ip" --dport 22 -j ACCEPT 2>/dev/null || true
		iptables -D FORWARD -p tcp -d "$vm_ip" --dport 80 -j ACCEPT 2>/dev/null || true
	else
		print_info "Searching and removing all rules with IP $vm_ip"
		local nat_rules=$(iptables -t nat -L PREROUTING -n --line-numbers | grep "$vm_ip" | awk '{print $1}' | tac)
		for rule_num in $nat_rules; do
			iptables -t nat -D PREROUTING "$rule_num" 2>/dev/null && print_info "Removed NAT rule $rule_num" || true
		done

		local forward_rules=$(iptables -L FORWARD -n --line-numbers | grep "$vm_ip" | awk '{print $1}' | tac)
		for rule_num in $forward_rules; do
			iptables -D FORWARD "$rule_num" 2>/dev/null && print_info "Removed FORWARD rule $rule_num" || true
		done
	fi

	command_exists iptables-save && iptables-save > /etc/iptables/rules.v4 2>/dev/null
}

cleanup_dhcp_lease() {
	local mac_address="$1"
	local vm_name="$2"
	local lease_file="/var/lib/libvirt/dnsmasq/${BRIDGE_NAME}.leases"
	local status_file="/var/lib/libvirt/dnsmasq/${BRIDGE_NAME}.status"

	[ -z "$mac_address" ] && [ -z "$vm_name" ] && return

	print_info "Clearing DHCP lease for MAC: ${mac_address:-unknown}, VM: ${vm_name:-unknown}"

	local removed=0

	if [ -f "$lease_file" ] && [ -n "$mac_address" ]; then
		local before
		before=$(wc -l < "$lease_file")
		local escaped_mac
		escaped_mac=$(printf '%s\n' "$mac_address" | sed 's/[]\^$.*\/[]/\\&/g')
		sed -i "/${escaped_mac}/Id" "$lease_file"
		local after
		after=$(wc -l < "$lease_file")
		removed=$((before - after))
	fi

	if [ -f "$lease_file" ] && [ -n "$vm_name" ]; then
		local before
		before=$(wc -l < "$lease_file")
		local escaped_name
		escaped_name=$(printf '%s\n' "$vm_name" | sed 's/[]\^$.*\/[]/\\&/g')
		sed -i "/${escaped_name}/Id" "$lease_file"
		local after
		after=$(wc -l < "$lease_file")
		removed=$((removed + before - after))
	fi

	if [ -f "$status_file" ]; then
		if [ -n "$mac_address" ]; then
			local escaped_mac
			escaped_mac=$(printf '%s\n' "$mac_address" | sed 's/[]\^$.*\/[]/\\&/g')
			sed -i "/${escaped_mac}/Id" "$status_file"
		fi
		if [ -n "$vm_name" ]; then
			local escaped_name
			escaped_name=$(printf '%s\n' "$vm_name" | sed 's/[]\^$.*\/[]/\\&/g')
			sed -i "/${escaped_name}/Id" "$status_file"
		fi
	fi

	[ $removed -gt 0 ] && print_info "Removed $removed lease(s)" || print_info "No matching lease found in files"

	local dnsmasq_pid=$(ps aux | grep "dnsmasq.*${BRIDGE_NAME}" | grep -v grep | awk '{print $2}' | head -1)
	[ -n "$dnsmasq_pid" ] && kill -HUP "$dnsmasq_pid" 2>/dev/null && print_info "DHCP service refreshed"
}

delete_single_vm() {
	local VM_NAME="$1"

	print_info "Starting deletion of VM: $VM_NAME"

	if ! check_vm_exists "$VM_NAME"; then
		print_error "VM $VM_NAME does not exist"
		return 1
	fi

	print_info "Gathering VM information"

	local MAC_ADDRESS=$(get_vm_mac "$VM_NAME")
	local VM_DISK_PATH=$(get_vm_disk_path "$VM_NAME")
	local VM_IP=$(get_vm_ip "$VM_NAME")
	local SSH_PORT=""
	local HTTP_PORT=""

	[ -n "$MAC_ADDRESS" ] && print_info "Found MAC address: $MAC_ADDRESS"
	[ -n "$VM_DISK_PATH" ] && print_info "Found disk path: $VM_DISK_PATH"

	local port_file=$(get_port_mappings_file)
	if [ -f "$port_file" ]; then
		local mapping=$(grep "^$VM_NAME " "$port_file")
		if [ -n "$mapping" ]; then
			[ -z "$VM_IP" ] && VM_IP=$(echo "$mapping" | awk '{print $2}')
			SSH_PORT=$(echo "$mapping" | awk '{print $3}')
			HTTP_PORT=$(echo "$mapping" | awk '{print $4}')
			print_info "Found port mappings: SSH=$SSH_PORT, HTTP=$HTTP_PORT, IP=$VM_IP"
		fi
	fi

	if virsh list | grep -q " $VM_NAME "; then
		print_info "Stopping VM $VM_NAME"
		stop_vm_gracefully "$VM_NAME" 10
	fi

	[ -n "$VM_IP" ] && cleanup_port_forwarding_for_vm "$VM_IP" "$SSH_PORT" "$HTTP_PORT"
	if [ -n "$MAC_ADDRESS" ] || [ -n "$VM_NAME" ]; then
		cleanup_dhcp_lease "$MAC_ADDRESS" "$VM_NAME"
		if [ -f "$SCRIPT_DIR/../network/dhcp.sh" ]; then
			bash "$SCRIPT_DIR/../network/dhcp.sh" clear-mac "$MAC_ADDRESS" >/dev/null 2>&1 || true
		fi
	fi

	[ -f "$port_file" ] && sed -i "/^$VM_NAME /d" "$port_file" && print_info "Removed from port mappings"

	virsh autostart "$VM_NAME" --disable 2>/dev/null || true

	print_info "Removing VM definition and storage"
	if virsh undefine "$VM_NAME" --remove-all-storage 2>/dev/null; then
		print_info "VM undefined with storage removal"
	else
		virsh undefine "$VM_NAME" 2>/dev/null || true
		[ -n "$VM_DISK_PATH" ] && [ -f "$VM_DISK_PATH" ] && rm -f "$VM_DISK_PATH" && print_info "Disk file removed"
	fi

	[ -d "$DATACENTER_BASE/vms/$VM_NAME" ] && rm -rf "$DATACENTER_BASE/vms/$VM_NAME" && print_info "VM directory removed"

	if [ -f "$DATACENTER_BASE/config/network/${VM_NAME}.conf" ]; then
		rm -f "$DATACENTER_BASE/config/network/${VM_NAME}.conf" && print_info "Removed host static IP record"
	fi

	if [ -f ~/.ssh/config ]; then
		sed -i "/^Host $VM_NAME$/,/^Host /{ /^Host $VM_NAME$/d; /^Host /!d; }" ~/.ssh/config
		sed -i "/^Host $VM_NAME$/,/^$/{d;}" ~/.ssh/config
		print_info "Removed SSH config entry"
	fi

	if [ -d /etc/systemd/system ]; then
		for service_file in /etc/systemd/system/*$VM_NAME*.service; do
			if [ -f "$service_file" ]; then
				systemctl stop "$(basename "$service_file")" 2>/dev/null || true
				systemctl disable "$(basename "$service_file")" 2>/dev/null || true
				rm -f "$service_file"
				print_info "Removed systemd service: $(basename "$service_file")"
			fi
		done
		systemctl daemon-reload 2>/dev/null || true
	fi

	print_success "VM $VM_NAME deleted successfully!"

	echo ""
	print_info "Verification Results:"
	check_vm_exists "$VM_NAME" && print_warning "✗ VM still exists in libvirt" || print_success "✓ VM completely removed from libvirt"

	sleep 2
	local dhcp_check=$(virsh net-dhcp-leases "$NETWORK_NAME" 2>/dev/null | grep -E "$VM_NAME|$MAC_ADDRESS" || echo "")
	if [ -z "$dhcp_check" ]; then
		print_success "✓ No DHCP leases found"
	else
		print_warning "✗ DHCP leases still exist"
		if [ -f "$SCRIPT_DIR/../network/dhcp.sh" ]; then
			bash "$SCRIPT_DIR/../network/dhcp.sh" clear-vm "$VM_NAME"
			sleep 1
			dhcp_check=$(virsh net-dhcp-leases "$NETWORK_NAME" 2>/dev/null | grep -E "$VM_NAME|$MAC_ADDRESS" || echo "")
			[ -z "$dhcp_check" ] && print_success "✓ DHCP leases cleared" || print_warning "⚠ DHCP leases may persist; try: dcvm network dhcp cleanup"
		fi
	fi

	[ -n "$VM_DISK_PATH" ] && { [ ! -f "$VM_DISK_PATH" ] && print_success "✓ Disk file removed" || print_warning "✗ Disk file still exists"; }

	return 0
}

delete_all_vms() {
	print_warning "======================================="
	print_warning "        DANGER: DELETE ALL VMs"
	print_warning "======================================="
	echo ""

	local datacenter_vms=$(virsh list --all | grep -E "(running|shut off)" | while read line; do
		local vm=$(echo "$line" | awk '{print $2}')
		[ -n "$vm" ] && [ "$vm" != "Name" ] && is_vm_in_network "$vm" && echo "$vm"
	done)

	if [ -z "$datacenter_vms" ]; then
		print_info "No datacenter VMs found to delete"
		return 0
	fi

	echo "The following VMs will be PERMANENTLY DELETED:"
	echo "$datacenter_vms" | while read vm; do
		[ -n "$vm" ] && printf "  %-20s [%s]\n" "$vm" "$(get_vm_state "$vm")"
	done
	echo ""

	print_warning "This action will:"
	echo "  - Stop and delete ALL datacenter VMs"
	echo "  - Remove ALL VM disk files"
	echo "  - Clear ALL DHCP leases"
	echo "  - Remove ALL port forwarding rules"
	echo "  - Delete ALL VM directories"
	echo "  - Remove ALL SSH configurations"
	echo ""

	local vm_count=$(echo "$datacenter_vms" | wc -l)
	
	echo -n "Are you absolutely sure you want to delete ALL VMs? (type 'yes' to continue): "
	read -r confirm1
	[ "$confirm1" != "yes" ] && print_info "Operation cancelled" && return 0

	local random_num=$(shuf -i 1000-9999 -n 1)
	echo ""
	print_warning "Final confirmation required"
	echo -n "Type the number '$random_num' to proceed: "
	read -r confirm3
	[ "$confirm3" != "$random_num" ] && print_info "Operation cancelled" && return 0

	echo ""
	print_info "Starting mass deletion of $vm_count VMs"

	local count=0
	echo "$datacenter_vms" | while read vm; do
		if [ -n "$vm" ]; then
			count=$((count + 1))
			echo ""
			print_info "Deleting VM $count/$vm_count: $vm"
			delete_single_vm "$vm" && print_success "Successfully deleted: $vm" || print_error "Failed to delete: $vm"
			echo "----------------------------------------"
		fi
	done

	print_info "Performing final cleanup"

	local lease_file="/var/lib/libvirt/dnsmasq/${BRIDGE_NAME}.leases"
	local status_file="/var/lib/libvirt/dnsmasq/${BRIDGE_NAME}.status"
	
	[ -f "$lease_file" ] && > "$lease_file" && print_info "Cleared all DHCP leases"
	[ -f "$status_file" ] && > "$status_file" && print_info "Cleared DHCP status file"

	local dnsmasq_pid=$(ps aux | grep "dnsmasq.*${BRIDGE_NAME}" | grep -v grep | awk '{print $2}' | head -1)
	[ -n "$dnsmasq_pid" ] && kill -HUP "$dnsmasq_pid" 2>/dev/null

	local port_file=$(get_port_mappings_file)
	[ -f "$port_file" ] && > "$port_file" && echo "# VM_NAME VM_IP SSH_PORT HTTP_PORT" > "$port_file"

	print_info "Removing all port forwarding rules"
	local nat_rules=$(iptables -t nat -L PREROUTING -n --line-numbers | grep -E "(222[0-9]|808[0-9])" | awk '{print $1}' | tac)
	for rule_num in $nat_rules; do
		iptables -t nat -D PREROUTING "$rule_num" 2>/dev/null || true
	done

	local forward_rules=$(iptables -L FORWARD -n --line-numbers | grep -E "10\.10\.10\." | awk '{print $1}' | tac)
	for rule_num in $forward_rules; do
		iptables -D FORWARD "$rule_num" 2>/dev/null || true
	done

	command_exists iptables-save && iptables-save > /etc/iptables/rules.v4 2>/dev/null

	[ -d "$DATACENTER_BASE/vms" ] && find "$DATACENTER_BASE/vms" -maxdepth 1 -type d ! -path "$DATACENTER_BASE/vms" -exec rm -rf {} + 2>/dev/null

	echo ""
	print_success "MASS DELETION COMPLETED"
	echo ""
	print_info "Final verification:"
	
	local remaining=$(virsh list --all | grep -E "(running|shut off)" | while read line; do
		local vm=$(echo "$line" | awk '{print $2}')
		[ -n "$vm" ] && [ "$vm" != "Name" ] && is_vm_in_network "$vm" && echo "$vm"
	done)

	[ -z "$remaining" ] && print_success "✓ All datacenter VMs successfully removed" || { print_warning "✗ Some VMs may still exist:" && echo "$remaining"; }
}

main() {
	load_dcvm_config
	[ $# -lt 1 ] && print_error "VM name required. Usage: dcvm delete <vm_name|--all>" && exit 1

	case "$1" in
		--all|-a)
			delete_all_vms
			;;
		*)
			delete_single_vm "$1"
			;;
	esac

	echo ""
	print_info "Remaining datacenter VMs:"
	list_datacenter_vms || print_info "No datacenter VMs remaining"
	echo ""
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
