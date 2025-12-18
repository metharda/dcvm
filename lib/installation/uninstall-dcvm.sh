#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../utils/common.sh"

CONFIG_FILE="/etc/dcvm-install.conf"

main() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
        print_info "Loaded configuration from $CONFIG_FILE"
    else
        print_error "Configuration file $CONFIG_FILE not found. Using default values"
        DATACENTER_BASE="/srv/datacenter"
        NETWORK_NAME="datacenter-net"
        BRIDGE_NAME="virbr-dc"
        NETWORK_SUBNET="10.10.10"
    fi

    require_confirmation "This will completely remove DCVM and all datacenter VMs"

    print_info "Stopping and removing datacenter storage service"
    systemctl stop datacenter-storage.timer 2>/dev/null || true
    systemctl disable datacenter-storage.timer 2>/dev/null || true
    rm -f /etc/systemd/system/datacenter-storage.service /etc/systemd/system/datacenter-storage.timer
    systemctl daemon-reload

    print_info "Removing datacenter VMs (connected to $NETWORK_NAME)"
    local deleted_count=0
    local vm_name
    for vm_name in $(virsh list --all --name 2>/dev/null); do
        [[ -z "$vm_name" ]] && continue
        if virsh domiflist "$vm_name" 2>/dev/null | grep -q "$NETWORK_NAME"; then
            print_info "Deleting VM: $vm_name"
            virsh destroy "$vm_name" 2>/dev/null || true
            virsh undefine "$vm_name" --remove-all-storage 2>/dev/null || virsh undefine "$vm_name" 2>/dev/null || true
            ((deleted_count++)) || true
        fi
    done
    print_success "Removed $deleted_count datacenter VM(s)"

    print_info "Cleaning up DHCP leases"
    local lease_file="/var/lib/libvirt/dnsmasq/${BRIDGE_NAME}.leases"
    local status_file="/var/lib/libvirt/dnsmasq/${BRIDGE_NAME}.status"
    [[ -f "$lease_file" ]] && > "$lease_file"
    [[ -f "$status_file" ]] && > "$status_file"

    print_info "Removing port forwarding rules"
    local port line
    for port in {2220..2299} {8080..8179}; do
        while iptables -t nat -L PREROUTING -n --line-numbers 2>/dev/null | grep -q ":$port "; do
            line=$(iptables -t nat -L PREROUTING -n --line-numbers | grep ":$port " | head -1 | awk '{print $1}')
            [[ -n "$line" ]] && iptables -t nat -D PREROUTING "$line" 2>/dev/null || break
        done
    done
    while iptables -L FORWARD -n --line-numbers 2>/dev/null | grep -q "${NETWORK_SUBNET}\\."; do
        line=$(iptables -L FORWARD -n --line-numbers | grep "${NETWORK_SUBNET}\\." | head -1 | awk '{print $1}')
        [[ -n "$line" ]] && iptables -D FORWARD "$line" 2>/dev/null || break
    done
    command -v iptables-save >/dev/null 2>&1 && iptables-save > /etc/iptables/rules.v4 2>/dev/null || true

    print_info "Removing datacenter network"
    if virsh net-info "$NETWORK_NAME" >/dev/null 2>&1; then
        virsh net-destroy "$NETWORK_NAME" 2>/dev/null || true
        virsh net-undefine "$NETWORK_NAME" 2>/dev/null || true
        print_success "Removed network $NETWORK_NAME"
    else
        print_info "Network $NETWORK_NAME not found"
    fi

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
    local config_file
    for config_file in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.bash_profile" "$HOME/.profile"; do
        if [[ -f "$config_file" ]]; then
            if grep -q "alias dcvm" "$config_file" 2>/dev/null; then
                print_info "Removing DCVM aliases from $config_file"
                sed -i.bak '/alias dcvm/d' "$config_file" && print_success "Removed aliases from $config_file" || print_warning "Could not remove aliases from $config_file"
            fi

            if grep -q 'dcvm-completion.sh' "$config_file" 2>/dev/null; then
                print_info "Removing dcvm completion source line from $config_file"
                sed -i.bak '/dcvm-completion\.sh/d' "$config_file" && print_success "Removed completion sourcing from $config_file" || print_warning "Could not update $config_file"
            fi
        fi
    done

    print_info "Removing completion scripts"
    if [ -f "/etc/bash_completion.d/dcvm" ]; then
        rm -f "/etc/bash_completion.d/dcvm" && print_success "Removed /etc/bash_completion.d/dcvm" || print_warning "Could not remove /etc/bash_completion.d/dcvm"
    fi
    if [ -f "/usr/local/share/dcvm/dcvm-completion.sh" ]; then
        rm -f "/usr/local/share/dcvm/dcvm-completion.sh" && print_success "Removed /usr/local/share/dcvm/dcvm-completion.sh" || print_warning "Could not remove completion script"
        rmdir "/usr/local/share/dcvm" 2>/dev/null || true
    fi

    print_success "DCVM uninstallation completed successfully"
    print_info "To reinstall, run: sudo bash lib/installation/install-dcvm.sh"

    if [[ -n ${BASH_VERSION-} ]]; then
        complete -r dcvm 2>/dev/null || true
    fi
    if [[ -n ${ZSH_VERSION-} ]]; then
        autoload -Uz bashcompinit 2>/dev/null && bashcompinit
        complete -r dcvm 2>/dev/null || true
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi