#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

print_info() {
	echo -e "${GREEN}[INFO]${NC} $1"
}

print_error() {
	echo -e "${RED}[ERROR]${NC} $1"
}

read -p "This will completely remove all installed components. Are you sure? (y/N): " CONFIRM
CONFIRM=${CONFIRM:-n}

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
	print_info "Uninstallation cancelled."
	exit 0
fi

print_info "Removing all VMs..."
virsh list --all --name | while read -r vm_name; do
	if [[ -n "$vm_name" ]]; then
		print_info "Deleting VM: $vm_name"
		virsh destroy "$vm_name" 2>/dev/null || true
		virsh undefine "$vm_name" --remove-all-storage 2>/dev/null || true
	fi

done

print_info "Removing all networks..."
virsh net-list --all --name | while read -r net_name; do
	if [[ -n "$net_name" ]]; then
		print_info "Deleting network: $net_name"
		virsh net-destroy "$net_name" 2>/dev/null || true
		virsh net-undefine "$net_name" 2>/dev/null || true
	fi

done

print_info "Removing all datacenter directories..."
if [ -d "$DATACENTER_BASE" ]; then
	rm -rf "$DATACENTER_BASE"
	print_info "Removed $DATACENTER_BASE"
else
	print_info "$DATACENTER_BASE not found"
fi

print_info "Removing dcvm command alias..."
find /root/.bashrc /home/*/.bashrc -type f 2>/dev/null | while read -r bashrc; do
	sed -i '/alias dcvm=/d' "$bashrc" 2>/dev/null || true
	print_info "Removed alias from $bashrc"
done

print_info "Self-destructing uninstall script..."
rm -- "$0"
print_info "Uninstallation script removed."
print_info "Uninstallation completed successfully."
