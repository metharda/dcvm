#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../utils/common.sh"

CONFIG_FILE="/etc/dcvm-install.conf"

main() {
  if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
  else
    print_warning "$CONFIG_FILE not found; using the default paths"
    DATACENTER_BASE="/srv/datacenter"
    NETWORK_NAME="datacenter-net"
    BRIDGE_NAME="virbr-dc"
    NETWORK_SUBNET="10.10.10"
  fi

  ui_title "Uninstall dcvm" "VMs, network, $DATACENTER_BASE, the command and its settings"
  require_confirmation "Deletes every dcvm VM with its disk, all backups in $DATACENTER_BASE, the network and dcvm itself."
  echo ""

  systemctl disable --now datacenter-storage.timer dcvm-boot.service 2>/dev/null || true
  rm -f $DCVM_UNITS /etc/sysctl.d/90-dcvm.conf
  systemctl daemon-reload 2>/dev/null || true
  ui_step ok "Services" "storage timer and boot service removed"

  local deleted_count=0 vm_name
  for vm_name in $(virsh list --all --name 2>/dev/null); do
    [[ -z "$vm_name" ]] && continue
    if virsh domiflist "$vm_name" 2>/dev/null | grep -q "$NETWORK_NAME"; then
      virsh destroy "$vm_name" >/dev/null 2>&1 || true
      virsh undefine "$vm_name" --remove-all-storage >/dev/null 2>&1 || virsh undefine "$vm_name" >/dev/null 2>&1 || true
      deleted_count=$((deleted_count + 1))
    fi
  done
  ui_step ok "VMs" "$deleted_count deleted"

  local lease_file="/var/lib/libvirt/dnsmasq/${BRIDGE_NAME}.leases"
  local status_file="/var/lib/libvirt/dnsmasq/${BRIDGE_NAME}.status"
  [[ -f "$lease_file" ]] && : >"$lease_file"
  [[ -f "$status_file" ]] && : >"$status_file"

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
  save_iptables_rules
  ui_step ok "Port forwards" "rules removed"

  if virsh net-info "$NETWORK_NAME" >/dev/null 2>&1; then
    virsh net-destroy "$NETWORK_NAME" >/dev/null 2>&1 || true
    virsh net-undefine "$NETWORK_NAME" >/dev/null 2>&1 || true
    ui_step ok "Network" "$NETWORK_NAME removed"
  else
    ui_step skip "Network" "$NETWORK_NAME not found"
  fi

  if [ -d "$DATACENTER_BASE" ]; then
    rm -rf "$DATACENTER_BASE"
    ui_step ok "Data" "$DATACENTER_BASE removed"
  else
    ui_step skip "Data" "$DATACENTER_BASE not found"
  fi

  rm -f /usr/local/bin/dcvm /etc/dcvm-install.conf /var/log/datacenter-startup.log /etc/bash_completion.d/dcvm /usr/local/share/dcvm/dcvm-completion.sh
  rm -rf /usr/local/lib/dcvm
  rmdir /usr/local/share/dcvm 2>/dev/null || true
  ui_step ok "dcvm" "command, libraries, settings, completion and log removed"

  local cleaned
  cleaned=$(remove_shell_lines "$DCVM_ALIAS_LINE|dcvm-completion\.sh" | sort -u | tr '\n' ' ')
  [[ -n "$cleaned" ]] && ui_step ok "Shell config" "dcvm lines removed from ${cleaned% } (backup: .bak)"

  ui_done ok "dcvm uninstalled" "the installer's one-liner installs it again"
  echo ""

  if [[ -n ${BASH_VERSION-} ]]; then
    complete -r dcvm 2>/dev/null || true
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
