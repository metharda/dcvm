#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../utils/common.sh"

CONFIG_FILE="/etc/dcvm-install.conf"

if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
    print_info "Loaded configuration from $CONFIG_FILE"
else
    print_error "Configuration file $CONFIG_FILE not found. Using default base directory"
    DATACENTER_BASE="/srv/datacenter"
fi

require_confirmation "This will completely remove DCVM and all VMs"

print_info "Stopping and removing datacenter storage service"
systemctl stop datacenter-storage.timer 2>/dev/null || true
systemctl disable datacenter-storage.timer 2>/dev/null || true
rm -f /etc/systemd/system/datacenter-storage.service /etc/systemd/system/datacenter-storage.timer
systemctl daemon-reload

print_info "Removing all VMs"
virsh list --all --name | while read -r vm_name; do
	[[ -n "$vm_name" ]] && print_info "Deleting VM: $vm_name" && virsh destroy "$vm_name" 2>/dev/null && virsh undefine "$vm_name" --remove-all-storage 2>/dev/null || true
done

print_info "Removing datacenter network"
virsh net-list --all --name | grep "datacenter-net" | while read -r net_name; do
	[[ -n "$net_name" ]] && print_info "Deleting network: $net_name" && virsh net-destroy "$net_name" 2>/dev/null && virsh net-undefine "$net_name" 2>/dev/null || true
done

print_info "Removing all datacenter directories"
[ -d "$DATACENTER_BASE" ] && rm -rf "$DATACENTER_BASE" && print_success "Removed $DATACENTER_BASE" || print_info "$DATACENTER_BASE not found"

print_info "Removing DCVM command and libraries"
[ -f "/usr/local/bin/dcvm" ] && rm -f "/usr/local/bin/dcvm" && print_success "Removed /usr/local/bin/dcvm" || print_info "/usr/local/bin/dcvm not found"
[ -d "/usr/local/lib/dcvm" ] && rm -rf "/usr/local/lib/dcvm" && print_success "Removed /usr/local/lib/dcvm" || print_info "/usr/local/lib/dcvm not found"

print_info "Removing configuration file"
[ -f "/etc/dcvm-install.conf" ] && rm -f "/etc/dcvm-install.conf" && print_success "Removed /etc/dcvm-install.conf" || print_info "/etc/dcvm-install.conf not found"

print_info "Removing log file"
[ -f "/var/log/datacenter-startup.log" ] && rm -f "/var/log/datacenter-startup.log" && print_success "Removed /var/log/datacenter-startup.log" || print_info "/var/log/datacenter-startup.log not found"

print_info "Checking for old DCVM aliases in shell configurations"
for config_file in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.bash_profile" "$HOME/.profile"; do
	if [[ -f "$config_file" ]]; then
		if grep -q "alias dcvm" "$config_file" 2>/dev/null; then
			print_info "Removing DCVM aliases from $config_file"
			sed -i.bak '/alias dcvm/d' "$config_file" && print_success "Removed aliases from $config_file" || print_warning "Could not remove aliases from $config_file"
		fi
	fi
done

print_success "DCVM uninstallation completed successfully"
print_info "To reinstall, run: sudo bash lib/installation/install-dcvm.sh"
