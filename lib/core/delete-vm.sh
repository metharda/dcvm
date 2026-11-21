#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../utils/common.sh"

cleanup_port_forwarding_for_vm() {
  local vm_ip="$1"
  local ssh_port="$2"
  local http_port="$3"

  print_info "Cleaning up port forwarding rules"

  if [ -n "$ssh_port" ] && [ -n "$http_port" ]; then
    iptables -t nat -D PREROUTING -p tcp --dport "$ssh_port" -j DNAT --to-destination "$vm_ip:22" 2>/dev/null && print_info "Removed SSH port rule $ssh_port" || true
    iptables -t nat -D PREROUTING -p tcp --dport "$http_port" -j DNAT --to-destination "$vm_ip:80" 2>/dev/null && print_info "Removed HTTP port rule $http_port" || true
    iptables -D FORWARD -p tcp -d "$vm_ip" --dport 22 -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -p tcp -d "$vm_ip" --dport 80 -j ACCEPT 2>/dev/null || true
  else
    print_info "Searching and removing all rules with IP $vm_ip"
    local nat_rules=$(iptables -t nat -L PREROUTING -n --line-numbers | grep "$vm_ip" | awk '{print $1}' | tac)
    for rule_num in $nat_rules; do
      iptables -t nat -D PREROUTING "$rule_num" 2>/dev/null && print_info "Removed NAT rule $rule_num" || true
    done

    local forward_rules=$(iptables -L FORWARD -n --line-numbers | grep "$vm_ip" | awk '{print $1}' | tac)
    for rule_num in $forward_rules; do
      iptables -D FORWARD "$rule_num" 2>/dev/null && print_info "Removed FORWARD rule $rule_num" || true
    done
  fi

  save_iptables_rules
}

remove_vm_storage_pool() {
  local vm_dir="$DATACENTER_BASE/vms/$1" pool path
  while read -r pool; do
    [ -n "$pool" ] || continue
    path=$(virsh pool-dumpxml "$pool" 2>/dev/null | sed -n 's:.*<path>\(.*\)</path>.*:\1:p' | head -1)
    [ "${path%/}" = "$vm_dir" ] || continue
    virsh pool-destroy "$pool" >/dev/null 2>&1 || true
    if virsh pool-undefine "$pool" >/dev/null 2>&1; then
      print_info "Removed storage pool $pool"
    else
      print_warning "Could not undefine storage pool $pool"
    fi
  done < <(virsh pool-list --all --name 2>/dev/null)
  return 0
}

delete_single_vm() {
  local VM_NAME="$1"

  if ! check_vm_exists "$VM_NAME"; then
    print_error "VM $VM_NAME does not exist"
    return 1
  fi

  ui_quiet
  ui_title "Deleting $VM_NAME"

  local MAC_ADDRESS=$(get_vm_mac "$VM_NAME")
  local VM_DISK_PATH=$(get_vm_disk_path "$VM_NAME")
  local VM_IP=$(get_vm_ip "$VM_NAME")
  local SSH_PORT=""
  local HTTP_PORT=""
  [ "$VM_IP" = "N/A" ] && VM_IP=""

  local port_file=$(get_port_mappings_file)
  if [ -f "$port_file" ]; then
    local mapping=$(grep "^$VM_NAME " "$port_file")
    if [ -n "$mapping" ]; then
      [ -z "$VM_IP" ] && VM_IP=$(echo "$mapping" | awk '{print $2}')
      SSH_PORT=$(echo "$mapping" | awk '{print $3}')
      HTTP_PORT=$(echo "$mapping" | awk '{print $4}')
    fi
  fi

  if virsh list | grep -q " $VM_NAME "; then
    stop_vm_gracefully "$VM_NAME" 10
    ui_step ok "Stopped" "shut down"
  fi

  [ -n "$VM_IP" ] && cleanup_port_forwarding_for_vm "$VM_IP" "$SSH_PORT" "$HTTP_PORT"
  if [ -n "$SSH_PORT" ]; then
    ui_step ok "Port forwards" "$SSH_PORT $SYM_ARROW 22, $HTTP_PORT $SYM_ARROW 80 removed"
  fi
  if [ -n "$MAC_ADDRESS" ]; then
    # Saved and live config separately: with both flags, an inactive network
    # fails the whole update and the saved reservation stays.
    virsh net-update "$NETWORK_NAME" delete ip-dhcp-host "<host mac='$MAC_ADDRESS'/>" --config >/dev/null 2>&1 || true
    virsh net-update "$NETWORK_NAME" delete ip-dhcp-host "<host mac='$MAC_ADDRESS'/>" --live >/dev/null 2>&1 || true
  fi
  if [ -n "$MAC_ADDRESS" ] || [ -n "$VM_NAME" ]; then
    if cleanup_dhcp_lease "$MAC_ADDRESS" "$VM_NAME"; then
      ui_step ok "DHCP lease" "released${VM_IP:+ ($VM_IP)}"
    else
      ui_step warn "DHCP lease" "not released (see the error above)"
    fi
  fi

  [ -f "$port_file" ] && sed -i "/^$VM_NAME /d" "$port_file"

  virsh autostart "$VM_NAME" --disable >/dev/null 2>&1 || true

  if ! virsh undefine "$VM_NAME" --remove-all-storage >/dev/null 2>&1; then
    virsh undefine "$VM_NAME" >/dev/null 2>&1 || true
    [ -n "$VM_DISK_PATH" ] && [ -f "$VM_DISK_PATH" ] && rm -f "$VM_DISK_PATH"
  fi

  remove_vm_storage_pool "$VM_NAME"

  [ -d "$DATACENTER_BASE/vms/$VM_NAME" ] && rm -rf "$DATACENTER_BASE/vms/$VM_NAME"

  local removed="$DATACENTER_BASE/vms/$VM_NAME"
  if [ -f "$DATACENTER_BASE/config/network/${VM_NAME}.conf" ]; then
    rm -f "$DATACENTER_BASE/config/network/${VM_NAME}.conf" && removed+=" and static IP record"
  fi
  ui_step ok "Disk and files" "$removed"

  if [ -f ~/.ssh/config ] && grep -q "^Host $VM_NAME$" ~/.ssh/config; then
    sed -i "/^Host $VM_NAME$/,/^Host /{ /^Host $VM_NAME$/d; /^Host /!d; }" ~/.ssh/config
    sed -i "/^Host $VM_NAME$/,/^$/{d;}" ~/.ssh/config
    ui_step ok "SSH config" "Host $VM_NAME entry removed"
  fi

  local left=()
  check_vm_exists "$VM_NAME" && left+=("VM still exists in libvirt")
  sleep 2
  local leases dhcp_check
  leases=$(virsh net-dhcp-leases "$NETWORK_NAME" 2>/dev/null)
  dhcp_check=$(filter_lease_lines "$VM_NAME" 6 <<<"$leases")
  [ -n "$MAC_ADDRESS" ] && dhcp_check+=$(filter_lease_lines "$MAC_ADDRESS" 3 <<<"$leases")
  [ -n "$dhcp_check" ] && left+=("DHCP leases still exist")
  [ -n "$VM_DISK_PATH" ] && [ -f "$VM_DISK_PATH" ] && left+=("Disk file still exists")

  if [ ${#left[@]} -eq 0 ]; then
    ui_done ok "$VM_NAME deleted" "No DHCP leases found, no VM or disk left"
  else
    echo ""
    local item
    for item in "${left[@]}"; do print_warning "$item"; done
    if [ -n "$dhcp_check" ]; then
      echo -e "  ${DIM}They expire on their own; to remove stale leases now: dcvm network dhcp cleanup${NC}"
    else
      echo -e "  ${DIM}No DHCP leases found${NC}"
    fi
  fi

  return 0
}
delete_all_vms() {
  local vms vm count failed=0
  vms=$(list_datacenter_vm_names)
  if [ -z "$vms" ]; then
    echo ""
    echo "  No dcvm VMs to delete."
    return 0
  fi
  count=$(grep -c . <<<"$vms")

  ui_title "Delete all dcvm VMs" "$(plural "$count" VM) on $NETWORK_NAME"
  {
    printf 'NAME\tSTATE\n'
    while read -r vm; do printf '%s\t%s\n' "$vm" "$(get_vm_state "$vm")"; done <<<"$vms"
  } | ui_table
  echo ""
  print_warning "Deletes these VMs with their disks, DHCP leases, port forwards and static IPs. Backups are kept."
  echo ""
  local confirm code
  read -r -p "  Type 'yes' to continue: " confirm
  [ "$confirm" != "yes" ] && echo "  Cancelled." && return 0
  code=$(shuf -i 1000-9999 -n 1)
  read -r -p "  Type $code to confirm: " confirm
  [ "$confirm" != "$code" ] && echo "  Cancelled." && return 0

  while read -r vm <&3; do
    if ! (delete_single_vm "$vm"); then
      failed=$((failed + 1))
      print_error "Failed to delete $vm"
    fi
  done 3<<<"$vms"

  local status_file="${DNSMASQ_DIR:-/var/lib/libvirt/dnsmasq}/${BRIDGE_NAME}.status"
  # libvirt parses this file, so leave an empty JSON array, not 0 bytes.
  [ -f "$status_file" ] && printf '[]\n' >"$status_file"
  local port_file rule_num
  port_file=$(get_port_mappings_file)
  [ -f "$port_file" ] && echo "# VM_NAME VM_IP SSH_PORT HTTP_PORT" >"$port_file"
  for rule_num in $(iptables -t nat -L PREROUTING -n --line-numbers | grep -E "(222[0-9]|808[0-9])" | awk '{print $1}' | tac); do
    iptables -t nat -D PREROUTING "$rule_num" 2>/dev/null || true
  done
  for rule_num in $(iptables -L FORWARD -n --line-numbers | grep -E "${NETWORK_SUBNET//./\\.}\." | awk '{print $1}' | tac); do
    iptables -D FORWARD "$rule_num" 2>/dev/null || true
  done
  save_iptables_rules
  [ -d "$DATACENTER_BASE/vms" ] && find "$DATACENTER_BASE/vms" -maxdepth 1 -type d ! -path "$DATACENTER_BASE/vms" -exec rm -rf {} + 2>/dev/null

  if [ "$failed" -eq 0 ] && [ -z "$(list_datacenter_vms)" ]; then
    ui_done ok "All $(plural "$count" VM) deleted" "DHCP status, port mappings and forward rules cleared"
  else
    ui_done warn "$((count - failed)) of $count VMs deleted" "dcvm list shows what is left"
  fi
}

main() {
  load_dcvm_config
  [ $# -lt 1 ] && print_error "VM name required. Usage: dcvm delete <vm_name|--all>" && exit 1

  case "$1" in
  --all | -a)
    delete_all_vms
    ;;
  *)
    delete_single_vm "$1"
    ;;
  esac

  prune_builds >/dev/null

  local remaining
  remaining=$(list_datacenter_vms | awk -F': ' '{ gsub(/^ +| +$/, "", $1); printf "%s%s (%s)", sep, $1, $2; sep = ", " }')
  echo -e "  ${DIM}Remaining VMs: ${remaining:-none}${NC}"
  echo ""
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
