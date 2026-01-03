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

restart_network() {
  print_info "Restarting network to refresh libvirt cache..."
  virsh net-destroy "$NETWORK_NAME" 2>/dev/null && sleep 1 && virsh net-start "$NETWORK_NAME" 2>/dev/null && print_success "Network restarted" || print_warning "Network restart failed"
}

is_mac_address() {
  local input="$1"
  [[ "$input" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]
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
  if [ -t 0 ]; then
    read -p "Clear ALL DHCP leases for $NETWORK_NAME? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      print_info "Cancelled"
      return 0
    fi
  else
    print_error "Cannot prompt for confirmation: stdin is not a terminal (non-interactive mode)"
    return 1
  fi

  print_info "Clearing ALL DHCP leases for $NETWORK_NAME"

  local lease_file="/var/lib/libvirt/dnsmasq/${BRIDGE_NAME}.leases"
  local status_file="/var/lib/libvirt/dnsmasq/${BRIDGE_NAME}.status"
  local pid_file="/var/lib/libvirt/dnsmasq/${BRIDGE_NAME}.pid"

  [ -f "$lease_file" ] && >"$lease_file" && echo "Cleared lease file"
  [ -f "$status_file" ] && >"$status_file" && echo "Cleared status file"
  [ -f "$pid_file" ] && rm -f "$pid_file"

  reload_dnsmasq
  restart_network
}

clear_vm_lease() {
  local vm_name="$1"
  [ -z "$vm_name" ] && print_error "VM name required" && return 1

  if [[ ! "$vm_name" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    print_error "Invalid VM name format"
    return 1
  fi

  print_info "Clearing leases for VM: $vm_name"

  local mac_address=$(get_vm_mac "$vm_name" 2>/dev/null)
  if [ -z "$mac_address" ]; then
    mac_address=$(virsh net-dhcp-leases "$NETWORK_NAME" 2>/dev/null | grep -i "$vm_name" | awk '{print $3}' | head -1)
  fi

  if [ -n "$mac_address" ]; then
    print_info "Found MAC address: $mac_address"
    clear_lease_by_mac "$mac_address"
    virsh net-update "$NETWORK_NAME" delete ip-dhcp-host "<host mac='$mac_address'/>" --live --config 2>/dev/null || true
    restart_network
  else
    print_warning "No MAC address found. Searching lease files for '$vm_name'..."
    local lease_file="/var/lib/libvirt/dnsmasq/${BRIDGE_NAME}.leases"
    local status_file="/var/lib/libvirt/dnsmasq/${BRIDGE_NAME}.status"
    local found=false
    local safe_name
    safe_name=$(printf '%s\n' "$vm_name" | sed 's/[[\.*^$()+?{|]/\\&/g')
    if [ -f "$lease_file" ] && grep -qi "$vm_name" "$lease_file"; then
      sed -i "/$safe_name/Id" "$lease_file"
      found=true
    fi
    if [ -f "$status_file" ] && grep -qi "$vm_name" "$status_file"; then
      sed -i "/$safe_name/Id" "$status_file"
      found=true
    fi
    if [ "$found" = true ]; then
      print_success "Cleared leases containing '$vm_name'"
      reload_dnsmasq
      restart_network
    else
      print_warning "No leases found for '$vm_name'"
    fi
  fi
}

clear_stale_leases() {
  print_info "Cleaning up stale/expired leases and orphaned VM leases"
  local current_time=$(date +%s)
  local temp_file=$(mktemp)
  local lease_file="/var/lib/libvirt/dnsmasq/${BRIDGE_NAME}.leases"
  local removed_count=0
  local -a macs_to_remove=()
  local existing_vms=$(virsh list --all --name 2>/dev/null | grep -v '^$')
  local active_macs=$(virsh net-dhcp-leases "$NETWORK_NAME" 2>/dev/null | awk 'NR>2 {print $3}' | sort -u)

  if [ -f "$lease_file" ] && [ -s "$lease_file" ]; then
    while IFS=' ' read -r timestamp mac ip hostname client_id rest; do
      [ -z "$timestamp" ] && continue
      [[ "$timestamp" == "duid" ]] && continue

      local keep_lease=false
      local reason=""

      if [ "$timestamp" -le "$current_time" ] 2>/dev/null; then
        reason="expired"
      elif [ -n "$hostname" ] && [ "$hostname" != "*" ] && [ "$hostname" != "-" ]; then
        if echo "$existing_vms" | grep -qx "$hostname"; then
          keep_lease=true
        else
          reason="orphaned (VM '$hostname' doesn't exist)"
        fi
      else
        if echo "$active_macs" | grep -qix "$mac"; then
          keep_lease=true
        else
          reason="stale (no active lease)"
        fi
      fi

      if [ "$keep_lease" = true ]; then
        echo "$timestamp $mac $ip $hostname $client_id $rest" >>"$temp_file"
      else
        print_info "Removing $reason lease: $ip (${hostname:-unknown}, $mac)"
        macs_to_remove+=("$mac")
        ((removed_count++))
      fi
    done <"$lease_file"

    if [ -s "$temp_file" ]; then
      mv "$temp_file" "$lease_file"
    else
      >"$lease_file"
    fi
    rm -f "$temp_file" 2>/dev/null
  else
    rm -f "$temp_file" 2>/dev/null
  fi

  local status_file="/var/lib/libvirt/dnsmasq/${BRIDGE_NAME}.status"
  if [ -f "$status_file" ] && [ ${#macs_to_remove[@]} -gt 0 ]; then
    for mac in "${macs_to_remove[@]}"; do
      sed -i "/$mac/d" "$status_file"
    done
  fi

  if [ $removed_count -gt 0 ]; then
    print_success "Removed $removed_count stale/orphaned lease(s)"
    reload_dnsmasq
    restart_network
  else
    print_info "No stale leases found"
  fi
}

clear_lease() {
  local target=""
  local all_flag=false
  local stale_flag=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
    -a | --all)
      all_flag=true
      shift
      ;;
    -s | --stale)
      stale_flag=true
      shift
      ;;
    -*)
      print_error "Unknown option: $1"
      return 1
      ;;
    *)
      target="$1"
      shift
      ;;
    esac
  done

  if [ "$all_flag" = true ] && [ "$stale_flag" = true ]; then
    print_error "Cannot use both --all and --stale flags together"
    return 1
  elif [ "$all_flag" = true ]; then
    clear_all_leases
  elif [ "$stale_flag" = true ]; then
    clear_stale_leases
  elif [ -n "$target" ]; then
    if is_mac_address "$target"; then
      clear_lease_by_mac "$target"
      restart_network
    else
      clear_vm_lease "$target"
    fi
  else
    print_error "Usage: dcvm network dhcp clear <vm-name|mac-address>"
    print_info "       dcvm network dhcp clear -a, --all    (clear all leases)"
    print_info "       dcvm network dhcp clear -s, --stale  (clear stale/orphaned leases)"
    return 1
  fi
}

force_renew_all() {
  print_info "Forcing DHCP renewal for all running VMs"
  local running_vms=$(virsh list | grep running | awk '{print $2}' | while read vm; do is_vm_in_network "$vm" && echo "$vm"; done)
  if [ -n "$running_vms" ]; then
    echo "Found running VMs: $running_vms"
    clear_all_leases
    sleep 5
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
  show                         Show current DHCP leases
  clear <vm-name|mac>          Clear lease for specific VM or MAC address
  clear -a, --all              Clear ALL DHCP leases (requires confirmation)
  clear -s, --stale            Clear stale/expired/orphaned leases
  renew                        Force DHCP renewal for all running VMs
  files                        Show DHCP lease file contents and locations
  help                         Show this help

Examples:
  dcvm network dhcp show
  dcvm network dhcp clear kali-test
  dcvm network dhcp clear 52:54:00:ab:cd:ef
  dcvm network dhcp clear -s
  dcvm network dhcp clear -a
  dcvm network dhcp renew
EOF
}

main() {
  load_dcvm_config
  require_root
  check_dependencies virsh

  local subcmd="${1:-help}"
  case "$subcmd" in
  show)
    shift
    show_current_leases "$@"
    ;;
  clear)
    shift
    clear_lease "$@"
    ;;
  renew)
    shift
    force_renew_all "$@"
    ;;
  files)
    shift
    show_lease_files "$@"
    ;;
  help | --help | -h) dhcp_help ;;
  *)
    print_error "Unknown command: $subcmd"
    echo "Use: dcvm network dhcp help"
    exit 1
    ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

