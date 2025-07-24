#!/bin/bash
if [ -f /etc/dcvm-install.conf ]; then
	source /etc/dcvm-install.conf
else
	echo "${RED:-}[ERROR]${NC:-} /etc/dcvm-install.conf bulunamadı!"
	exit 1
fi

DATACENTER_BASE="${DATACENTER_BASE:-/srv/datacenter}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() {
	echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
	echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
	echo -e "${RED}[ERROR]${NC} $1"
}

print_success() {
	echo -e "${GREEN}[SUCCESS]${NC} $1"
}

delete_single_vm() {
	local VM_NAME="$1"

	print_status "Starting deletion of VM: $VM_NAME"

	if ! virsh list --all | grep -q " $VM_NAME "; then
		print_error "VM $VM_NAME does not exist"
		return 1
	fi

	local VM_IP=""
	local SSH_PORT=""
	local HTTP_PORT=""
	local MAC_ADDRESS=""
	local VM_DISK_PATH=""

	print_status "Gathering VM information..."

	MAC_ADDRESS=$(virsh domiflist "$VM_NAME" 2>/dev/null | grep datacenter-net | awk '{print $5}')
	if [ -n "$MAC_ADDRESS" ]; then
		print_status "Found MAC address: $MAC_ADDRESS"
	fi

	VM_DISK_PATH=$(virsh domblklist "$VM_NAME" 2>/dev/null | grep -v "Target" | grep -v "^$" | awk '{print $2}' | head -1)
	if [ -n "$VM_DISK_PATH" ]; then
		print_status "Found disk path: $VM_DISK_PATH"
	fi

	print_status "Detecting VM IP address..."
	VM_IP=$(virsh domifaddr "$VM_NAME" --source agent 2>/dev/null | awk '/ipv4/ {print $4}' | cut -d'/' -f1 | grep '^10\.10\.10\.' | head -1)
	if [ -z "$VM_IP" ]; then
		VM_IP=$(virsh domifaddr "$VM_NAME" --source lease 2>/dev/null | awk '/ipv4/ {print $4}' | cut -d'/' -f1 | grep '^10\.10\.10\.' | head -1)
	fi
	if [ -z "$VM_IP" ]; then
		VM_IP=$(virsh net-dhcp-leases datacenter-net 2>/dev/null | grep "$VM_NAME" | awk '{print $5}' | cut -d'/' -f1 | grep '^10\.10\.10\.' | head -1)
	fi
	if [ -z "$VM_IP" ] && [ -n "$MAC_ADDRESS" ]; then
		VM_IP=$(virsh net-dhcp-leases datacenter-net 2>/dev/null | grep "$MAC_ADDRESS" | awk '{print $5}' | cut -d'/' -f1 | grep '^10\.10\.10\.' | head -1)
	fi

	if [ -f "$DATACENTER_BASE/port-mappings.txt" ]; then
		mapping_line=$(grep "^$VM_NAME " "$DATACENTER_BASE/port-mappings.txt")
		if [ -n "$mapping_line" ]; then
			VM_IP_FROM_FILE=$(echo "$mapping_line" | awk '{print $2}')
			SSH_PORT=$(echo "$mapping_line" | awk '{print $3}')
			HTTP_PORT=$(echo "$mapping_line" | awk '{print $4}')
			if [ -z "$VM_IP" ]; then
				VM_IP=$VM_IP_FROM_FILE
			fi
			print_status "Found port mappings: SSH=$SSH_PORT, HTTP=$HTTP_PORT, IP=$VM_IP"
		fi
	fi

	if virsh list | grep -q " $VM_NAME "; then
		print_status "Stopping VM $VM_NAME..."
		virsh shutdown "$VM_NAME"
		sleep 10

		if virsh list | grep -q " $VM_NAME "; then
			print_warning "Force stopping VM $VM_NAME..."
			virsh destroy "$VM_NAME"
			sleep 2
		fi
	fi

	print_status "Cleaning up port forwarding rules..."
	if [ -n "$VM_IP" ]; then
		print_status "Removing port forwarding rules for IP: $VM_IP"

		if [ -n "$SSH_PORT" ] && [ -n "$HTTP_PORT" ]; then
			iptables -t nat -D PREROUTING -p tcp --dport $SSH_PORT -j DNAT --to-destination $VM_IP:22 2>/dev/null && print_status "Removed SSH port rule $SSH_PORT" || true
			iptables -t nat -D PREROUTING -p tcp --dport $HTTP_PORT -j DNAT --to-destination $VM_IP:80 2>/dev/null && print_status "Removed HTTP port rule $HTTP_PORT" || true
			iptables -D FORWARD -p tcp -d $VM_IP --dport 22 -j ACCEPT 2>/dev/null || true
			iptables -D FORWARD -p tcp -d $VM_IP --dport 80 -j ACCEPT 2>/dev/null || true
		else
			print_status "Searching and removing all rules with IP $VM_IP..."
			nat_rules_to_remove=$(iptables -t nat -L PREROUTING -n --line-numbers | grep "$VM_IP" | awk '{print $1}' | tac)
			for rule_num in $nat_rules_to_remove; do
				iptables -t nat -D PREROUTING $rule_num 2>/dev/null && print_status "Removed NAT rule $rule_num" || true
			done

			forward_rules_to_remove=$(iptables -L FORWARD -n --line-numbers | grep "$VM_IP" | awk '{print $1}' | tac)
			for rule_num in $forward_rules_to_remove; do
				iptables -D FORWARD $rule_num 2>/dev/null && print_status "Removed FORWARD rule $rule_num" || true
			done
		fi

		if command -v iptables-save >/dev/null 2>&1; then
			iptables-save >/etc/iptables/rules.v4 2>/dev/null && print_status "iptables rules saved" || print_warning "Could not save iptables rules"
		fi
	else
		print_warning "Could not determine VM IP, checking for any rules with VM name..."
		nat_rules_vm=$(iptables -t nat -L PREROUTING -n --line-numbers | grep "$VM_NAME" | awk '{print $1}' | tac)
		for rule_num in $nat_rules_vm; do
			iptables -t nat -D PREROUTING $rule_num 2>/dev/null && print_status "Removed NAT rule $rule_num (by VM name)" || true
		done
	fi

	print_status "Clearing DHCP lease records..."

	if [ -n "$MAC_ADDRESS" ]; then
		print_status "Removing DHCP lease for MAC: $MAC_ADDRESS"

		if [ -f /var/lib/libvirt/dnsmasq/virbr-dc.leases ]; then
			lease_count_before=$(wc -l </var/lib/libvirt/dnsmasq/virbr-dc.leases)
			sed -i "/$MAC_ADDRESS/d" /var/lib/libvirt/dnsmasq/virbr-dc.leases
			lease_count_after=$(wc -l </var/lib/libvirt/dnsmasq/virbr-dc.leases)
			removed_leases=$((lease_count_before - lease_count_after))
			if [ $removed_leases -gt 0 ]; then
				print_status "Removed $removed_leases lease(s) from lease file"
			fi
		fi

		if [ -f /var/lib/libvirt/dnsmasq/virbr-dc.status ]; then
			sed -i "/$MAC_ADDRESS/d" /var/lib/libvirt/dnsmasq/virbr-dc.status
			print_status "Removed from status file"
		fi
	fi

	if [ -n "$VM_NAME" ]; then
		print_status "Removing DHCP lease for VM name: $VM_NAME"

		if [ -f /var/lib/libvirt/dnsmasq/virbr-dc.leases ]; then
			sed -i "/$VM_NAME/d" /var/lib/libvirt/dnsmasq/virbr-dc.leases
		fi

		if [ -f /var/lib/libvirt/dnsmasq/virbr-dc.status ]; then
			sed -i "/$VM_NAME/d" /var/lib/libvirt/dnsmasq/virbr-dc.status
		fi
	fi

	if [ -n "$VM_IP" ]; then
		print_status "Removing DHCP lease for IP: $VM_IP"

		if [ -f /var/lib/libvirt/dnsmasq/virbr-dc.leases ]; then
			sed -i "/$VM_IP/d" /var/lib/libvirt/dnsmasq/virbr-dc.leases
		fi

		if [ -f /var/lib/libvirt/dnsmasq/virbr-dc.status ]; then
			sed -i "/$VM_IP/d" /var/lib/libvirt/dnsmasq/virbr-dc.status
		fi
	fi

	for lease_file in /var/lib/dhcp/dhcpd.leases /var/lib/libvirt/dnsmasq/*.leases; do
		if [ -f "$lease_file" ] && [ "$lease_file" != "/var/lib/libvirt/dnsmasq/virbr-dc.leases" ]; then
			if [ -n "$MAC_ADDRESS" ]; then
				sed -i "/$MAC_ADDRESS/d" "$lease_file" 2>/dev/null && print_status "Cleaned $lease_file" || true
			fi
			if [ -n "$VM_NAME" ]; then
				sed -i "/$VM_NAME/d" "$lease_file" 2>/dev/null || true
			fi
		fi
	done

	if [ -f "$DATACENTER_BASE/port-mappings.txt" ]; then
		sed -i "/^$VM_NAME /d" "$DATACENTER_BASE/port-mappings.txt"
		print_status "Removed $VM_NAME from port mappings file"
	fi

	virsh autostart "$VM_NAME" --disable 2>/dev/null && print_status "Disabled autostart" || true

	print_status "Removing VM definition and storage..."
	if virsh undefine "$VM_NAME" --remove-all-storage 2>/dev/null; then
		print_status "VM undefined with storage removal"
	else
		print_warning "Standard undefine failed, trying manual cleanup..."
		virsh undefine "$VM_NAME" 2>/dev/null && print_status "VM undefined (without automatic storage removal)" || print_warning "Could not undefine VM"

		if [ -n "$VM_DISK_PATH" ] && [ -f "$VM_DISK_PATH" ]; then
			print_status "Manually removing disk: $VM_DISK_PATH"
			rm -f "$VM_DISK_PATH" && print_status "Disk file removed" || print_warning "Could not remove disk file"
		fi
	fi

	if [ -d "$DATACENTER_BASE/vms/$VM_NAME" ]; then
		print_status "Removing VM directory..."
		rm -rf "$DATACENTER_BASE/vms/$VM_NAME" && print_status "VM directory removed" || print_warning "Could not remove VM directory"
	fi

	if [ -f ~/.ssh/config ]; then
		sed -i "/^Host $VM_NAME$/,/^Host /{ /^Host $VM_NAME$/d; /^Host /!d; }" ~/.ssh/config
		sed -i "/^Host $VM_NAME$/,/^$/{d;}" ~/.ssh/config
		print_status "Removed SSH config entry for $VM_NAME"
	fi

	if [ -d /etc/systemd/system ]; then
		for service_file in /etc/systemd/system/*$VM_NAME*.service; do
			if [ -f "$service_file" ]; then
				systemctl stop "$(basename "$service_file")" 2>/dev/null || true
				systemctl disable "$(basename "$service_file")" 2>/dev/null || true
				rm -f "$service_file"
				print_status "Removed systemd service: $(basename "$service_file")"
			fi
		done
		systemctl daemon-reload 2>/dev/null || true
	fi

	print_status "Refreshing DHCP leases..."
	dnsmasq_pid=$(ps aux | grep "dnsmasq.*virbr-dc" | grep -v grep | awk '{print $2}' | head -1)
	if [ -n "$dnsmasq_pid" ]; then
		kill -HUP "$dnsmasq_pid" 2>/dev/null && print_status "DHCP service refreshed" || print_status "DHCP refresh attempted"
	else
		print_status "DHCP lease files cleaned (network configuration preserved)"
	fi

	if command -v iptables-save >/dev/null 2>&1; then
		iptables-save >/etc/iptables/rules.v4 2>/dev/null && print_status "iptables rules saved" || print_warning "Could not save iptables rules"
	fi

	print_status "Restarting network to ensure stability..."
	if virsh net-destroy datacenter-net >/dev/null 2>&1 && virsh net-start datacenter-net >/dev/null 2>&1; then
		print_status "Network restarted successfully"
	else
		print_warning "Failed to restart network. Please check manually."
	fi

	print_success "VM $VM_NAME deleted successfully!"

	echo ""
	print_status "Verification Results:"
	vm_check=$(virsh list --all | grep " $VM_NAME " || echo "")
	if [ -z "$vm_check" ]; then
		print_success "✓ VM completely removed from libvirt"
	else
		print_warning "✗ VM still exists in libvirt: $vm_check"
	fi

	dhcp_check=$(virsh net-dhcp-leases datacenter-net 2>/dev/null | grep -E "$VM_NAME|$MAC_ADDRESS" || echo "")
	if [ -z "$dhcp_check" ]; then
		print_success "✓ No DHCP leases found"
	else
		print_warning "✗ DHCP leases still exist: $dhcp_check"
	fi

	if [ -n "$VM_DISK_PATH" ]; then
		if [ ! -f "$VM_DISK_PATH" ]; then
			print_success "✓ Disk file removed: $VM_DISK_PATH"
		else
			print_warning "✗ Disk file still exists: $VM_DISK_PATH"
		fi
	fi

	return 0
}

delete_all_vms() {
	print_warning "======================================="
	print_warning "        DANGER: DELETE ALL VMs"
	print_warning "======================================="
	echo ""

	datacenter_vms=$(virsh list --all | grep -E "(running|shut off)" | while read line; do
		vm=$(echo "$line" | awk '{print $2}')
		if [ -n "$vm" ] && [ "$vm" != "Name" ]; then
			if virsh domiflist "$vm" 2>/dev/null | grep -q "datacenter-net"; then
				echo "$vm"
			fi
		fi
	done)

	if [ -z "$datacenter_vms" ]; then
		print_status "No datacenter VMs found to delete."
		return 0
	fi

	echo "The following VMs will be PERMANENTLY DELETED:"
	echo "$datacenter_vms" | while read vm; do
		if [ -n "$vm" ]; then
			state=$(virsh list --all | grep " $vm " | awk '{print $3}')
			printf "  %-20s [%s]\n" "$vm" "$state"
		fi
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

	echo -n "Are you absolutely sure you want to delete ALL VMs? (type 'yes' to continue): "
	read -r confirm1
	if [ "$confirm1" != "yes" ]; then
		print_status "Operation cancelled."
		return 0
	fi

	vm_count=$(echo "$datacenter_vms" | wc -l)
	echo ""
	print_warning "You are about to delete $vm_count VMs. This cannot be undone!"
	echo -n "Type 'DELETE ALL $vm_count VMs' to confirm: "
	read -r confirm2
	if [ "$confirm2" != "DELETE ALL $vm_count VMs" ]; then
		print_status "Operation cancelled."
		return 0
	fi

	random_num=$(shuf -i 1000-9999 -n 1)
	echo ""
	print_warning "Final confirmation required."
	echo -n "Type the number '$random_num' to proceed: "
	read -r confirm3
	if [ "$confirm3" != "$random_num" ]; then
		print_status "Operation cancelled."
		return 0
	fi

	echo ""
	echo ""

	print_status "Starting mass deletion of $vm_count VMs..."

	deleted_count=0
	failed_count=0

	echo "$datacenter_vms" | while read vm; do
		if [ -n "$vm" ]; then
			echo ""
			print_status "Deleting VM $((deleted_count + 1))/$vm_count: $vm"
			if delete_single_vm "$vm"; then
				deleted_count=$((deleted_count + 1))
				print_success "Successfully deleted: $vm"
			else
				failed_count=$((failed_count + 1))
				print_error "Failed to delete: $vm"
			fi
			echo "----------------------------------------"
		fi
	done

	print_status "Performing final cleanup..."

	print_status "Clearing all DHCP leases (preserving network)..."

	if [ -f /var/lib/libvirt/dnsmasq/virbr-dc.leases ]; then
		>/var/lib/libvirt/dnsmasq/virbr-dc.leases
		print_status "Cleared all DHCP leases"
	fi

	if [ -f /var/lib/libvirt/dnsmasq/virbr-dc.status ]; then
		>/var/lib/libvirt/dnsmasq/virbr-dc.status
		print_status "Cleared DHCP status file"
	fi

	dnsmasq_pid=$(ps aux | grep "dnsmasq.*virbr-dc" | grep -v grep | awk '{print $2}' | head -1)
	if [ -n "$dnsmasq_pid" ]; then
		kill -HUP "$dnsmasq_pid" 2>/dev/null && print_status "DHCP service refreshed" || print_status "DHCP refresh attempted"
	else
		print_status "DHCP lease files cleaned (network configuration preserved)"
	fi

	if [ -f "$DATACENTER_BASE/port-mappings.txt" ]; then
		>"$DATACENTER_BASE/port-mappings.txt"
		echo "# VM_NAME    VM_IP          SSH_PORT  HTTP_PORT" >"$DATACENTER_BASE/port-mappings.txt"
		print_status "Cleared port mappings file"
	fi

	print_status "Removing all port forwarding rules..."
	nat_rules=$(iptables -t nat -L PREROUTING -n --line-numbers | grep -E "(222[0-9]|808[0-9])" | awk '{print $1}' | tac)
	for rule_num in $nat_rules; do
		iptables -t nat -D PREROUTING $rule_num 2>/dev/null && print_status "Removed NAT rule $rule_num" || true
	done

	forward_rules=$(iptables -L FORWARD -n --line-numbers | grep -E "10\.10\.10\." | awk '{print $1}' | tac)
	for rule_num in $forward_rules; do
		iptables -D FORWARD $rule_num 2>/dev/null && print_status "Removed FORWARD rule $rule_num" || true
	done

	if command -v iptables-save >/dev/null 2>&1; then
		iptables-save >/etc/iptables/rules.v4 2>/dev/null && print_status "Saved iptables rules" || true
	fi

	if [ -d "$DATACENTER_BASE/vms" ]; then
		print_status "Cleaning up VM directories..."
		find "$DATACENTER_BASE/vms" -maxdepth 1 -type d ! -path "$DATACENTER_BASE/vms" -exec rm -rf {} + 2>/dev/null && print_status "VM directories cleaned" || true
	fi

	echo ""
	print_success "======================================="
	print_success "     MASS DELETION COMPLETED"
	print_success "======================================="
	echo ""
	print_status "Final verification:"
	remaining_vms=$(virsh list --all | grep -E "(running|shut off)" | while read line; do
		vm=$(echo "$line" | awk '{print $2}')
		if [ -n "$vm" ] && [ "$vm" != "Name" ]; then
			if virsh domiflist "$vm" 2>/dev/null | grep -q "datacenter-net"; then
				echo "$vm"
			fi
		fi
	done)

	if [ -z "$remaining_vms" ]; then
		print_success "✓ All datacenter VMs successfully removed"
	else
		print_warning "✗ Some VMs may still exist:"
		echo "$remaining_vms"
	fi

	print_status "DHCP leases: $(virsh net-dhcp-leases datacenter-net 2>/dev/null | wc -l) active leases"
	print_status "Port forwarding rules: $(iptables -t nat -L PREROUTING -n | grep -E "(222[0-9]|808[0-9])" | wc -l) active rules"
}

if [ $# -lt 1 ]; then
	echo "VM Deletion Script"
	echo "Usage: $0 <vm_name|--all>"
	echo ""
	echo "Examples:"
	echo "  $0 datacenter-vm1     # Delete specific VM"
	echo "  $0 web-server         # Delete specific VM"
	echo "  $0 --all              # Delete ALL datacenter VMs (DANGEROUS!)"
	echo ""
	echo "WARNING: The --all option will delete ALL VMs using datacenter-net!"
	exit 1
fi

if [ "$1" = "--all" ]; then
	delete_all_vms
elif [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
	echo "VM Deletion Script"
	echo "Usage: $0 <vm_name|--all>"
	echo ""
	echo "Single VM deletion:"
	echo "  $0 datacenter-vm1     # Delete specific VM with full cleanup"
	echo ""
	echo "Mass deletion (DANGEROUS):"
	echo "  $0 --all              # Delete ALL datacenter VMs"
	echo ""
	echo "This script performs comprehensive cleanup including:"
	echo "  - VM shutdown and removal"
	echo "  - Disk file deletion"
	echo "  - DHCP lease cleanup"
	echo "  - Port forwarding rule removal"
	echo "  - SSH config cleanup"
	echo "  - Directory cleanup"
	echo "  - Network restart"
	exit 0
else
	delete_single_vm "$1"
fi

echo ""
print_status "Remaining datacenter VMs:"
remaining_vms=$(virsh list --all | grep -E "(running|shut off)" | while read line; do
	vm=$(echo "$line" | awk '{print $2}')
	state=$(echo "$line" | awk '{print $3}')
	if [ -n "$vm" ] && [ "$vm" != "Name" ]; then
		if virsh domiflist "$vm" 2>/dev/null | grep -q "datacenter-net"; then
			printf "  %-15s: %s\n" "$vm" "$state"
		fi
	fi
done)

if [ -z "$remaining_vms" ]; then
	print_status "No datacenter VMs remaining"
else
	echo "$remaining_vms"
fi

echo ""
