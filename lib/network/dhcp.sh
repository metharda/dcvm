#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../utils/common.sh"

show_current_leases() {
  ui_title "DHCP leases" "$NETWORK_NAME"
  leases_table
  echo ""
}

lease_cleared() {
  case "$1" in
  0) if [ "$DRY_RUN" = true ]; then ui_done skip "DHCP lease of $2 would be released"; else ui_done ok "DHCP lease of $2 released"; fi ;;
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

# Releases each "mac|ip|hostname|reason" line of $1 with cleanup_dhcp_lease; $2 names them.
release_leases() {
  local what="$2" removed_count=0 failed=0 rc mac ip hostname reason shown
  while IFS='|' read -r mac ip hostname reason; do
    [ -n "$mac$hostname" ] || continue
    rc=0
    if [ "$DRY_RUN" = true ]; then
      cleanup_dhcp_lease "$mac" "$hostname" >/dev/null || rc=$?
    else
      cleanup_dhcp_lease "$mac" "$hostname" || rc=$?
    fi
    # The hostname is the guest's choice: no escape sequences into the admin's terminal.
    shown="${reason:+$reason, }${hostname:-no hostname}, ${mac:-no MAC}"
    shown=${shown//[[:cntrl:]]/?}
    case "$rc" in
    0)
      if [ "$DRY_RUN" = true ]; then
        would "release ${ip//[[:cntrl:]]/?}: $shown"
      else
        ui_step ok "${ip//[[:cntrl:]]/?}" "$shown"
      fi
      removed_count=$((removed_count + 1))
      ;;
    2)
      ui_step warn "${ip//[[:cntrl:]]/?}" "not released: $shown"
      failed=$((failed + 1))
      ;;
    esac
  done <<<"$1"

  if [ "$DRY_RUN" = true ] && [ "$removed_count" -gt 0 ]; then
    ui_done skip "$(plural "$removed_count" "$what") would be released"
    echo ""
    [ "$failed" -eq 0 ]
    return
  elif [ "$failed" -gt 0 ]; then
    ui_done warn "Released $removed_count of $(plural "$((removed_count + failed))" "$what")" "see the errors above"
    echo ""
    return 1
  elif [ $removed_count -gt 0 ]; then
    ui_done ok "Removed $(plural "$removed_count" "$what")"
  else
    echo -e "  ${DIM}No ${what}s found${NC}"
  fi
  echo ""
}

status_file_readable() {
  if ! command_exists jq; then
    print_error "jq not available; cannot read $1 (install jq)"
    return 1
  fi
  if [ -s "$1" ] && ! jq -e 'type == "array"' "$1" >/dev/null 2>&1; then
    print_error "Could not parse $1; left unchanged"
    return 1
  fi
}

confirm_release() {
  [ "$DRY_RUN" = true ] && return 0
  if [ -t 0 ]; then
    confirm_action "$1"
  else
    print_error "Cannot prompt for confirmation: stdin is not a terminal (non-interactive mode)"
    return 1
  fi
}

# One by one in the running dnsmasq: restarting the network would detach
# every running VM's tap from the bridge.
clear_all_leases() {
  confirm_release "Release every DHCP lease on $NETWORK_NAME?" || return 1
  ui_quiet
  local status_file="${DNSMASQ_DIR:-/var/lib/libvirt/dnsmasq}/${BRIDGE_NAME}.status" leases=""
  status_file_readable "$status_file" || return 1
  [ -s "$status_file" ] && leases=$(jq -r '.[] | [(."mac-address" // ""), (."ip-address" // ""), (.hostname // "")] | join("|")' "$status_file")
  echo ""
  release_leases "$leases" "DHCP lease"
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
  no_args "dcvm network dhcp cleanup" "$@"
  ui_quiet
  ui_title "Stale DHCP leases" "$NETWORK_NAME"
  local stale
  status_file_readable "${DNSMASQ_DIR:-/var/lib/libvirt/dnsmasq}/${BRIDGE_NAME}.status" || return 1
  if ! stale=$(stale_leases); then
    print_error "Could not list the VMs' MAC addresses (is libvirt running?); no lease released"
    return 1
  fi
  release_leases "$stale" "stale lease"
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
      [ -z "$target" ] || no_args "dcvm network dhcp clear <vm-name|mac-address|--all|--stale>" "$1"
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
    print_error "Usage: dcvm network dhcp clear <vm-name|mac-address|--all|--stale> [--dry-run]"
    return 1
  fi
}

# Reads force_renew_all's $pending, also from its traps.
relink_pending() {
  local vm mac
  while read -r vm mac; do
    [ -n "$vm" ] || continue
    virsh domif-setlink "$vm" "$mac" up >/dev/null 2>&1 || ui_step fail "$vm" "link left down: virsh domif-setlink $vm $mac up"
  done <<<"$pending"
}

# A link cut of over 4 s (NetworkManager ignores shorter ones) makes the
# guest's DHCP client ask again; nothing in the guest is needed.
force_renew_all() {
  no_args "dcvm network dhcp renew" "$@"
  local running_vms vm mac pending="" left i
  local status_file="${DNSMASQ_DIR:-/var/lib/libvirt/dnsmasq}/${BRIDGE_NAME}.status"
  running_vms=$(virsh list --name 2>/dev/null | while read -r vm; do [ -n "$vm" ] && is_vm_in_network "$vm" && echo "$vm"; done)
  if [ -z "$running_vms" ]; then
    echo ""
    echo -e "  ${DIM}No running VMs on $NETWORK_NAME${NC}"
    echo ""
    return 0
  fi
  ui_title "DHCP renewal" "$(echo $running_vms)"
  confirm_release "Release the leases of these VMs and cut their links for 5 s?" || return 1
  ui_quiet
  status_file_readable "$status_file" || return 1
  if [ "$DRY_RUN" = true ]; then
    while read -r vm; do
      mac=$(get_vm_mac "$vm" | head -1)
      if [ -f "${DATACENTER_BASE:-/srv/datacenter}/config/network/$vm.conf" ]; then
        ui_step skip "$vm" "static IP, no DHCP"
      elif [ -n "$mac" ]; then
        would "cut the link of $vm (${mac,,}) for 5 s and release its lease"
      else
        ui_step warn "$vm" "could not cut its link; it has no MAC on $NETWORK_NAME"
      fi
    done <<<"$running_vms"
    echo ""
    return 0
  fi
  # Interrupted (Ctrl-C in the 5 s), the links cut so far come back up.
  trap relink_pending EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  # Only the leases of VMs whose link is cut: any other VM would not ask again.
  while read -r vm; do
    mac=$(get_vm_mac "$vm" | head -1)
    if [ -f "${DATACENTER_BASE:-/srv/datacenter}/config/network/$vm.conf" ]; then
      ui_step skip "$vm" "static IP, no DHCP"
    elif [ -n "$mac" ] && virsh domif-setlink "$vm" "$mac" down >/dev/null 2>&1; then
      pending+="$vm ${mac,,}"$'\n'
      cleanup_dhcp_lease "${mac,,}" "" || [ $? = 1 ] || ui_step warn "$vm" "old lease not released; it may keep its address"
    else
      ui_step warn "$vm" "could not cut its link; it asks again at its next DHCP renewal"
    fi
  done <<<"$running_vms"
  [ -n "$pending" ] && sleep 5
  relink_pending
  trap - EXIT INT TERM HUP
  [ -n "$pending" ] || return 0
  for i in $(seq 30); do
    left=""
    while read -r vm mac; do
      [ -n "$vm" ] || continue
      if jq -e --arg m "$mac" 'any(.[]; (."mac-address" // "" | ascii_downcase) == $m)' "$status_file" >/dev/null 2>&1; then
        ui_step ok "$vm" "renewed: $(jq -r --arg m "$mac" 'first(.[] | select((."mac-address" // "" | ascii_downcase) == $m))."ip-address"' "$status_file")"
      else
        left+="$vm $mac"$'\n'
      fi
    done <<<"$pending"
    pending=$left
    [ -n "$pending" ] && [ "$i" -lt 30 ] || break
    sleep 1
  done
  while read -r vm mac; do
    [ -n "$vm" ] && ui_step warn "$vm" "no new lease after 30 s; if it has no address: dcvm restart $vm"
  done <<<"$pending"
  echo ""
  [ -z "$pending" ]
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
  clear --all, -a      Release every lease; the network keeps running (asks first)
  renew                Release running DHCP VMs' leases, cut their links for 5 s so they ask again
  files                Lease file location and contents
  help                 Show this help

Options:
  -n, --dry-run        With clear, cleanup or renew: show what would change, change nothing (never asks)

Examples:
  dcvm network dhcp show
  dcvm network dhcp clear web
  dcvm network dhcp cleanup --dry-run
  dcvm network dhcp cleanup
EOF
}

main() {
  case "${1:-}" in help | --help | -h)
    dhcp_help
    exit 0
    ;;
  esac
  parse_dry_run "$@"
  set -- "${ARGS[@]}"
  load_dcvm_config
  require_root
  check_dependencies virsh
  dry_run_title

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
