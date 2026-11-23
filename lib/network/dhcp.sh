#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../utils/common.sh"

show_current_leases() {
  ui_title "DHCP leases" "$NETWORK_NAME"
  leases_table
  echo ""
}

restart_network() {
  if virsh net-destroy "$NETWORK_NAME" >/dev/null 2>&1 && sleep 1 && virsh net-start "$NETWORK_NAME" >/dev/null 2>&1; then
    ui_step ok "Network" "$NETWORK_NAME restarted"
  else
    ui_step warn "Network" "restart failed (dcvm network start)"
  fi
}

lease_cleared() {
  case "$1" in
  0) ui_done ok "DHCP lease of $2 released" ;;
  1) ui_done skip "No matching DHCP lease found" "for $2; nothing to release" ;;
  *) return 1 ;;
  esac
  echo ""
}

is_mac_address() {
  local input="$1"
  [[ "$input" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]
}

clear_lease_by_mac() {
  local mac_address="$1"
  [ -z "$mac_address" ] && print_error "MAC address required" && return 1
  ui_quiet
  local rc=0
  cleanup_dhcp_lease "$mac_address" "" || rc=$?
  lease_cleared "$rc" "$mac_address"
}

clear_all_leases() {
  if [ -t 0 ]; then
    # Declining must stop renew too, which carries on after this returns 0.
    confirm_action "Release every DHCP lease on $NETWORK_NAME and restart it?" || return 1
  else
    print_error "Cannot prompt for confirmation: stdin is not a terminal (non-interactive mode)"
    return 1
  fi

  local status_file="${DNSMASQ_DIR:-/var/lib/libvirt/dnsmasq}/${BRIDGE_NAME}.status"

  echo ""
  # Leave an empty JSON array so jq-based readers see valid JSON (libvirt also accepts 0 bytes).
  [ -f "$status_file" ] && printf '[]\n' >"$status_file" && ui_step ok "Leases" "cleared $status_file"

  restart_network
  ui_done ok "All DHCP leases cleared" "VMs get an address again on their next DHCP request"
  echo ""
}

clear_vm_lease() {
  local vm_name="$1"
  [ -z "$vm_name" ] && print_error "VM name required" && return 1

  if [[ ! "$vm_name" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    print_error "Invalid VM name format"
    return 1
  fi

  ui_quiet
  local mac_address=$(get_vm_mac "$vm_name" 2>/dev/null)
  if [ -z "$mac_address" ]; then
    mac_address=$(virsh net-dhcp-leases "$NETWORK_NAME" 2>/dev/null | filter_lease_lines "$vm_name" 6 | awk '{print $3}' | head -1)
  fi

  # A static reservation for this MAC is kept; only VM delete removes it.
  local rc=0
  cleanup_dhcp_lease "$mac_address" "$vm_name" || rc=$?
  lease_cleared "$rc" "$vm_name"
}

clear_stale_leases() {
  ui_quiet
  ui_title "Stale DHCP leases" "$NETWORK_NAME"
  local status_file="${DNSMASQ_DIR:-/var/lib/libvirt/dnsmasq}/${BRIDGE_NAME}.status"
  local removed_count=0 failed=0 rc stale mac ip hostname reason

  if ! command_exists jq; then
    print_error "jq not available; cannot read $status_file (install jq)"
    return 1
  fi
  if [ -s "$status_file" ] && ! jq -e 'type == "array"' "$status_file" >/dev/null 2>&1; then
    print_error "Could not parse $status_file; left unchanged"
    return 1
  fi
  if ! stale=$(stale_leases); then
    print_error "Could not list the VMs' MAC addresses (is libvirt running?); no lease released"
    return 1
  fi

  while IFS='|' read -r mac ip hostname reason; do
    [ -n "$mac$hostname" ] || continue
    rc=0
    cleanup_dhcp_lease "$mac" "$hostname" || rc=$?
    case "$rc" in
    0)
      ui_step ok "$ip" "$reason, ${hostname:-no hostname}, ${mac:-no MAC}"
      removed_count=$((removed_count + 1))
      ;;
    2)
      ui_step warn "$ip" "not released: $reason, ${hostname:-no hostname}, ${mac:-no MAC}"
      failed=$((failed + 1))
      ;;
    esac
  done <<<"$stale"

  if [ "$failed" -gt 0 ]; then
    ui_done warn "Released $removed_count of $(plural "$((removed_count + failed))" "stale lease")" "see the errors above"
    echo ""
    return 1
  elif [ $removed_count -gt 0 ]; then
    ui_done ok "Removed $(plural "$removed_count" "stale lease")"
  else
    echo -e "  ${DIM}No stale leases found${NC}"
  fi
  echo ""
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
    else
      clear_vm_lease "$target"
    fi
  else
    print_error "Usage: dcvm network dhcp clear <vm-name|mac-address|--all|--stale>"
    return 1
  fi
}

force_renew_all() {
  local running_vms vm ssh_port
  running_vms=$(virsh list --name 2>/dev/null | while read -r vm; do [ -n "$vm" ] && is_vm_in_network "$vm" && echo "$vm"; done)
  if [ -z "$running_vms" ]; then
    echo ""
    echo -e "  ${DIM}No running VMs on $NETWORK_NAME${NC}"
    echo ""
    return 0
  fi
  ui_title "DHCP renewal" "$(echo $running_vms)"
  clear_all_leases || return 1
  sleep 5
  while read -r vm; do
    [ -n "$vm" ] || continue
    ssh_port=$(read_port_mappings | awk -v v="$vm" '$1 == v { print $3 }')
    if [ -n "$ssh_port" ]; then
      timeout 10 ssh -n -o ConnectTimeout=3 -p "$ssh_port" "$(get_vm_username "$vm")@$(get_host_ip)" "sudo dhclient -r enp1s0; sudo dhclient enp1s0" >/dev/null 2>&1 &
      ui_step ok "$vm" "asked to renew over SSH"
    else
      ui_step skip "$vm" "no port forward; it renews on its own"
    fi
  done <<<"$running_vms"
  echo -e "  ${DIM}Check the new leases in about 30 seconds: dcvm network dhcp show${NC}"
  echo ""
}

show_lease_files() {
  local f="${DNSMASQ_DIR:-/var/lib/libvirt/dnsmasq}/${BRIDGE_NAME}.status"
  ui_section "DHCP lease file" "$f"
  if [ -s "$f" ]; then
    sed 's/^/  /' "$f"
  else
    echo -e "  ${DIM}$([ -f "$f" ] && echo empty || echo "not found")${NC}"
  fi
  echo ""
}

dhcp_help() {
  ui_help <<EOF
dcvm network dhcp - DHCP leases on the dcvm network

Usage: dcvm network dhcp <command>

Commands:
  show                 Current leases
  clear <vm|mac>       Release one lease (exact VM name or MAC); the network keeps running
  clear --stale, -s    Release leases whose MAC belongs to no VM (expired or not)
  cleanup              Same as clear --stale
  clear --all, -a      Release every lease and restart the network (asks first)
  renew                Clear all leases and ask running VMs to renew
  files                Lease file location and contents
  help                 Show this help

Examples:
  dcvm network dhcp show
  dcvm network dhcp clear web
  dcvm network dhcp cleanup
EOF
}

main() {
  case "${1:-}" in help | --help | -h)
    dhcp_help
    exit 0
    ;;
  esac
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
  cleanup)
    shift
    clear_stale_leases "$@"
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
