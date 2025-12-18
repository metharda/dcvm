#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../utils/common.sh"

show_current_leases() {
  echo "Current DHCP leases:"
  virsh net-dhcp-leases "$NETWORK_NAME" 2>/dev/null || echo "No leases found"
  echo ""
}

reload_dnsmasq() {
  local dnsmasq_pid=$(ps aux | grep "dnsmasq.*${BRIDGE_NAME}" | grep -v grep | awk '{print $2}' | head -1)
  if [ -n "$dnsmasq_pid" ]; then
    kill -HUP "$dnsmasq_pid" 2>/dev/null && print_success "DHCP service reloaded" || print_error "Failed to signal dnsmasq"
  else
    print_info "dnsmasq process not found for bridge ${BRIDGE_NAME}"
  fi
}

clear_lease_by_mac() {
  local mac_address="$1"
  [ -z "$mac_address" ] && print_error "MAC address required" && return 1

  print_info "Clearing lease for MAC: $mac_address"

  local lease_file="/var/lib/libvirt/dnsmasq/${BRIDGE_NAME}.leases"
  local status_file="/var/lib/libvirt/dnsmasq/${BRIDGE_NAME}.status"

  [ -f "$lease_file" ] && sed -i "/$mac_address/d" "$lease_file" && echo "Removed from lease file"
  [ -f "$status_file" ] && sed -i "/$mac_address/d" "$status_file" && echo "Removed from status file"

  reload_dnsmasq
}

clear_all_leases() {
  print_info "Clearing ALL DHCP leases for $NETWORK_NAME"

  local lease_file="/var/lib/libvirt/dnsmasq/${BRIDGE_NAME}.leases"
  local status_file="/var/lib/libvirt/dnsmasq/${BRIDGE_NAME}.status"
  local pid_file="/var/lib/libvirt/dnsmasq/${BRIDGE_NAME}.pid"

  [ -f "$lease_file" ] && > "$lease_file" && echo "Cleared lease file"
  [ -f "$status_file" ] && > "$status_file" && echo "Cleared status file"
  [ -f "$pid_file" ] && rm -f "$pid_file"

  reload_dnsmasq
  print_info "Restarting network to refresh libvirt cache..."
  virsh net-destroy "$NETWORK_NAME" 2>/dev/null && sleep 1 && virsh net-start "$NETWORK_NAME" 2>/dev/null && print_success "Network restarted" || print_warning "Network restart failed"
}

clear_vm_lease() {
  local vm_name="$1"
  [ -z "$vm_name" ] && print_error "VM name required" && return 1

  print_info "Clearing leases for VM: $vm_name"

  local mac_address=$(get_vm_mac "$vm_name" 2>/dev/null)
  if [ -z "$mac_address" ]; then
    mac_address=$(virsh net-dhcp-leases "$NETWORK_NAME" 2>/dev/null | grep -i "$vm_name" | awk '{print $3}' | head -1)
  fi

  if [ -n "$mac_address" ]; then
    print_info "Found MAC address: $mac_address"
    clear_lease_by_mac "$mac_address"
    print_info "Updating network to refresh lease status..."
    virsh net-update "$NETWORK_NAME" delete ip-dhcp-host "<host mac='$mac_address'/>" --live --config 2>/dev/null || true
    virsh net-destroy "$NETWORK_NAME" 2>/dev/null && sleep 1 && virsh net-start "$NETWORK_NAME" 2>/dev/null && print_success "Network restarted" || print_warning "Network restart not needed or failed"
  else
    print_warning "No MAC address found. Searching lease files for '$vm_name'..."
    local lease_file="/var/lib/libvirt/dnsmasq/${BRIDGE_NAME}.leases"
    local status_file="/var/lib/libvirt/dnsmasq/${BRIDGE_NAME}.status"
    local found=false
    if [ -f "$lease_file" ]; then
      if grep -qi "$vm_name" "$lease_file"; then
        print_info "Found '$vm_name' in lease file"; sed -i "/$vm_name/Id" "$lease_file"; found=true
      fi
    fi
    if [ -f "$status_file" ]; then
      if grep -qi "$vm_name" "$status_file"; then
        print_info "Found '$vm_name' in status file"; sed -i "/$vm_name/Id" "$status_file"; found=true
      fi
    fi
    if [ "$found" = true ]; then
      print_success "Cleared leases containing '$vm_name'"; reload_dnsmasq
      print_info "Restarting network to refresh libvirt cache..."
      virsh net-destroy "$NETWORK_NAME" 2>/dev/null && sleep 1 && virsh net-start "$NETWORK_NAME" 2>/dev/null && print_success "Network restarted" || print_warning "Network restart not needed or failed"
    else
      print_warning "No leases found for '$vm_name'"; return 0
    fi
  fi
}

cleanup_stale_leases() {
  print_info "Cleaning up stale/expired leases and non-existent VM leases"
  local current_time=$(date +%s)
  local temp_file="/tmp/dhcp_leases_clean"
  local lease_file="/var/lib/libvirt/dnsmasq/${BRIDGE_NAME}.leases"
  local removed_count=0
  local -a macs_to_remove=()
  local existing_vms=$(virsh list --all --name 2>/dev/null | grep -v '^$')
  if [ -f "$lease_file" ]; then
    while IFS=' ' read -r timestamp mac ip hostname client_id; do
      if [ -n "$timestamp" ] && [ "$timestamp" != "duid" ]; then
        local keep_lease=false
        if [ "$timestamp" -gt "$current_time" ]; then
          if [ -n "$hostname" ] && [ "$hostname" != "*" ] && [ "$hostname" != "-" ]; then
            if echo "$existing_vms" | grep -qx "$hostname"; then
              keep_lease=true
            else
              print_info "Removing lease for non-existent VM: $hostname ($ip, $mac)"; macs_to_remove+=("$mac"); ((removed_count++))
            fi
          else
            keep_lease=true
          fi
        else
          print_info "Removing expired lease: $ip (${hostname:-unknown}, $mac)"; macs_to_remove+=("$mac"); ((removed_count++))
        fi
        if [ "$keep_lease" = true ]; then
          echo "$timestamp $mac $ip $hostname $client_id" >> "$temp_file"
        fi
      fi
    done < "$lease_file"
    if [ -f "$temp_file" ]; then
      mv "$temp_file" "$lease_file"; print_success "Cleaned lease file (removed $removed_count lease(s))"
    else
      > "$lease_file"; print_info "No valid leases found, cleared lease file"
    fi
  fi
  local status_file="/var/lib/libvirt/dnsmasq/${BRIDGE_NAME}.status"
  if [ -f "$status_file" ]; then
    local temp_status="/tmp/dhcp_status_clean"
    while IFS= read -r line; do
      local keep_line=true
      for mac in "${macs_to_remove[@]}"; do
        if echo "$line" | grep -q "$mac"; then keep_line=false; break; fi
      done
      if [ "$keep_line" = true ] && echo "$line" | grep -q '"hostname"'; then
        local hostname=$(echo "$line" | grep -oP '"hostname":\s*"\K[^"]+')
        if [ -n "$hostname" ] && [ "$hostname" != "-" ]; then
          if ! echo "$existing_vms" | grep -qx "$hostname"; then keep_line=false; fi
        fi
      fi
      if [ "$keep_line" = true ]; then echo "$line" >> "$temp_status"; fi
    done < "$status_file"
    [ -f "$temp_status" ] && mv "$temp_status" "$status_file"
  fi
  reload_dnsmasq
  if [ $removed_count -gt 0 ]; then
    print_info "Restarting network to refresh libvirt cache..."
    virsh net-destroy "$NETWORK_NAME" 2>/dev/null && sleep 1 && virsh net-start "$NETWORK_NAME" 2>/dev/null && print_success "Network restarted" || print_warning "Network restart not needed or failed"
  fi
}

force_renew_all() {
  print_info "Forcing DHCP renewal for all running VMs"
  local running_vms=$(virsh list | grep running | awk '{print $2}' | while read vm; do is_vm_in_network "$vm" && echo "$vm"; done)
  if [ -n "$running_vms" ]; then
    echo "Found running VMs: $running_vms"; clear_all_leases; sleep 5
    echo "$running_vms" | while read vm; do
      if [ -n "$vm" ]; then
        print_info "Forcing DHCP renewal on $vm"
        local ssh_port=$(read_port_mappings | grep "^$vm " | awk '{print $3}')
        if [ -n "$ssh_port" ]; then
          timeout 10 ssh -o ConnectTimeout=3 -p "$ssh_port" admin@$(get_host_ip) "sudo dhclient -r enp1s0; sudo dhclient enp1s0" 2>/dev/null &
        fi
      fi
    done
    print_success "DHCP renewal initiated. Wait 30 seconds and check leases"
  else
    print_info "No running VMs found using $NETWORK_NAME"
  fi
}

show_lease_files() {
  echo "DHCP lease files location:"
  echo "/var/lib/libvirt/dnsmasq/${BRIDGE_NAME}.leases"
  echo "/var/lib/libvirt/dnsmasq/${BRIDGE_NAME}.status"
  echo ""
  echo "Lease file contents:"
  local lease_file="/var/lib/libvirt/dnsmasq/${BRIDGE_NAME}.leases"
  [ -f "$lease_file" ] && cat "$lease_file" || echo "Lease file not found"
  echo ""
  echo "Status file contents:"
  local status_file="/var/lib/libvirt/dnsmasq/${BRIDGE_NAME}.status"
  [ -f "$status_file" ] && cat "$status_file" || echo "Status file not found"
}

dhcp_help() {
  cat <<EOF
DCVM DHCP Management

Usage: dcvm network dhcp <command> [options]

Commands:
  show              Show current DHCP leases
  clear-all         Clear ALL DHCP leases (requires confirmation)
  clear-vm <name>   Clear lease for specific VM
  clear-mac <mac>   Clear lease by MAC address
  cleanup           Clean stale and orphaned leases
  renew             Force DHCP renewal for all running VMs
  files             Show DHCP lease file contents and locations
  help              Show this help

Examples:
  dcvm network dhcp show
  dcvm network dhcp clear-vm datacenter-vm1
  dcvm network dhcp clear-mac 52:54:00:xx
  dcvm network dhcp cleanup
  dcvm network dhcp clear-all
  dcvm network dhcp renew
EOF
}

main() {
  load_dcvm_config
  require_root
  check_dependencies virsh

  local subcmd="${1:-help}"
  case "$subcmd" in
    show) shift; show_current_leases "$@" ;;
    clear-all) shift; clear_all_leases "$@" ;;
    clear-vm) shift; clear_vm_lease "$@" ;;
    clear-mac) shift; clear_lease_by_mac "$@" ;;
    cleanup) shift; cleanup_stale_leases "$@" ;;
    renew) shift; force_renew_all "$@" ;;
    files) shift; show_lease_files "$@" ;;
    help|--help|-h) dhcp_help ;;
    *) print_error "Unknown command: $subcmd"; echo "Use: dcvm network dhcp help"; exit 1 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
