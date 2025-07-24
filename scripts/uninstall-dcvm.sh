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

CONFIG_FILE="/etc/dcvm-install.conf"

if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
    print_info "Loaded configuration from $CONFIG_FILE"
else
    print_error "Configuration file $CONFIG_FILE not found. Using default base directory."
    DATACENTER_BASE="/srv/datacenter"
fi

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

print_info "Removing configuration file..."
if [ -f "/etc/dcvm-install.conf" ]; then
	rm -f "/etc/dcvm-install.conf"
	print_info "Removed /etc/dcvm-install.conf"
else
	print_info "/etc/dcvm-install.conf not found"
fi

print_info "Removing dcvm command alias..."
find /root/.bashrc /home/*/.bashrc -type f 2>/dev/null | while read -r bashrc; do
    sed -i '/alias dcvm=/d' "$bashrc" 2>/dev/null || true
    print_info "Removed alias from $bashrc"
done

print_info "Unsetting dcvm alias from the current shell..."
unalias dcvm 2>/dev/null || true

print_info "Sourcing .bashrc files to update PATH..."
source /root/.bashrc 2>/dev/null || true
for user_home in /home/*/; do
    if [[ -d "$user_home" ]]; then
        user_bashrc="${user_home}.bashrc"
        source "$user_bashrc" 2>/dev/null || true
    fi

done

print_info "Uninstallation completed successfully."