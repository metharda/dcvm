#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../utils/common.sh"

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

# A record whose domain is gone (a failed create, or a VM undefined outside dcvm) still holds the name, disk and ports.
delete_leftovers() {
  local vm="$1" names port_file lockfd ip ssh_port http_port
  # dominfo fails while libvirt is down too; only a listing that answers proves the VM gone.
  if ! names=$(virsh list --all --name 2>/dev/null); then
    print_error "libvirt is not answering; nothing of $vm was deleted"
    return 1
  fi
  if grep -qxF -- "$vm" <<<"$names" || [ ! -f "$(registry_file "$vm")" ]; then
    print_error "VM $vm does not exist"
    return 1
  fi
  port_file=$(get_port_mappings_file)
  exec {lockfd}>>"$port_file.lock"
  flock -w 30 "$lockfd" || {
    print_error "Another port change is running; try again"
    return 1
  }
  read -r _ ip ssh_port http_port < <(awk -v v="$vm" '$1 == v' "$port_file" 2>/dev/null | head -1)
  [ -n "$ip" ] && cleanup_port_forwarding_for_vm "$ip" "$ssh_port" "$http_port" >/dev/null
  drop_port_mapping "$vm"
  exec {lockfd}>&-
  remove_vm_storage_pool "$vm"
  rm -rf "${DATACENTER_BASE:?}/vms/$vm"
  rm -f "$DATACENTER_BASE/config/network/$vm.conf"
  registry_remove "$vm"
  ui_done ok "$vm deleted" "its domain was already gone; record, folder and port forwards removed"
}

delete_single_vm() {
  local VM_NAME="$1"

  if ! safe_vm_name "$VM_NAME"; then
    print_error "Invalid VM name: $VM_NAME"
    return 1
  fi
  if [ "$(registry_get "$VM_NAME" protected)" = 1 ]; then
    print_error "$VM_NAME is protected: dcvm unprotect $VM_NAME first"
    return 1
  fi
  if ! check_vm_exists "$VM_NAME"; then
    delete_leftovers "$VM_NAME"
    return
  fi
  if ! is_vm_in_network "$VM_NAME" && [ ! -f "$(registry_file "$VM_NAME")" ]; then
    print_error "$VM_NAME is not a dcvm VM (not on $NETWORK_NAME); remove it with virsh if you mean to"
    return 1
  fi

  ui_quiet
  ui_title "Deleting $VM_NAME"

  local MAC_ADDRESS=$(get_vm_mac "$VM_NAME")
  local VM_DISK_PATH=$(get_vm_disk_path "$VM_NAME")
  local VM_IP="" SSH_PORT="" HTTP_PORT="" lockfd

  local port_file=$(get_port_mappings_file)
  exec {lockfd}>>"$port_file.lock"
  flock -w 30 "$lockfd" || {
    print_error "Another port change is running; try again"
    return 1
  }
  # The address the rules were made for, not what the VM has now: a guest can take another VM's.
  if [ -f "$port_file" ]; then
    read -r _ VM_IP SSH_PORT HTTP_PORT < <(awk -v v="$VM_NAME" '$1 == v' "$port_file" | head -1)
  fi
  [ -n "$VM_IP" ] || VM_IP=$(get_vm_ip_trusted "$VM_NAME") || VM_IP=""

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
  local dhcp_rc=0
  cleanup_dhcp_lease "$MAC_ADDRESS" "$VM_NAME" || dhcp_rc=$?
  case "$dhcp_rc" in
  0) ui_step ok "DHCP lease" "released${VM_IP:+ ($VM_IP)}" ;;
  1) ui_step skip "DHCP lease" "none found" ;;
  *) ui_step warn "DHCP lease" "not released (see the error above)" ;;
  esac

  drop_port_mapping "$VM_NAME"
  exec {lockfd}>&-

  virsh autostart "$VM_NAME" --disable >/dev/null 2>&1 || true

  # Not --remove-all-storage: an attached ISO may be a shared file of root's.
  # --nvram: libvirt refuses to undefine a UEFI VM that keeps its variables.
  local undefine_err
  if undefine_err=$(virsh undefine "$VM_NAME" --nvram 2>&1) || undefine_err=$(virsh undefine "$VM_NAME" 2>&1); then
    [ -n "$VM_DISK_PATH" ] && [ -f "$VM_DISK_PATH" ] && rm -f "$VM_DISK_PATH"
  else
    print_error "libvirt would not remove $VM_NAME, so its disk is kept: $undefine_err"
    return 1
  fi

  remove_vm_storage_pool "$VM_NAME"

  [ -d "$DATACENTER_BASE/vms/$VM_NAME" ] && rm -rf "$DATACENTER_BASE/vms/$VM_NAME"

  local removed="$DATACENTER_BASE/vms/$VM_NAME"
  if [ -f "$DATACENTER_BASE/config/network/${VM_NAME}.conf" ]; then
    rm -f "$DATACENTER_BASE/config/network/${VM_NAME}.conf" && removed+=" and static IP record"
  fi
  ui_step ok "Disk and files" "$removed"

  if [ "$(caller_role)" = root ] && [ -f ~/.ssh/config ] && grep -q "^Host $VM_NAME$" ~/.ssh/config; then
    sed -i "/^Host $VM_NAME$/,/^Host /{ /^Host $VM_NAME$/d; /^Host /!d; }" ~/.ssh/config
    sed -i "/^Host $VM_NAME$/,/^$/{d;}" ~/.ssh/config
    ui_step ok "SSH config" "Host $VM_NAME entry removed"
  fi

  local left=()
  if check_vm_exists "$VM_NAME"; then
    left+=("VM still exists in libvirt")
  else
    registry_remove "$VM_NAME"
  fi
  sleep 2
  local leases dhcp_check
  leases=$(virsh net-dhcp-leases "$NETWORK_NAME" 2>/dev/null)
  dhcp_check=$(filter_lease_lines "$VM_NAME" 6 <<<"$leases")
  [ -n "$MAC_ADDRESS" ] && dhcp_check+=$(filter_lease_lines "$MAC_ADDRESS" 3 <<<"$leases")
  [ -n "$dhcp_check" ] && left+=("DHCP leases still exist")
  [ "$dhcp_rc" = 2 ] && [ -z "$dhcp_check" ] && left+=("DHCP lease may stay in dnsmasq until it expires")
  [ -n "$VM_DISK_PATH" ] && [ -f "$VM_DISK_PATH" ] && left+=("Disk file still exists")

  if [ ${#left[@]} -eq 0 ]; then
    ui_done ok "$VM_NAME deleted" "No DHCP leases found, no VM or disk left"
  else
    echo ""
    local item
    for item in "${left[@]}"; do print_warning "$item"; done
    if [ -n "$dhcp_check" ]; then
      echo -e "  ${DIM}They expire on their own; to remove stale leases now: dcvm network dhcp cleanup${NC}"
    elif [ "$dhcp_rc" != 2 ]; then
      echo -e "  ${DIM}No DHCP leases found${NC}"
    fi
  fi

  ! check_vm_exists "$VM_NAME"
}
delete_all_vms() {
  local vms vm count failed=0 names
  # Without libvirt every VM looks gone, and the sweeps below would take their folders and rules.
  if ! virsh list --all --name >/dev/null 2>&1; then
    print_error "libvirt is not answering; nothing was deleted"
    return 1
  fi
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
  read -r -p "  Type 'yes' to continue: " confirm || no_input
  [ "$confirm" != "yes" ] && echo "  Cancelled." && return 0
  code=$(shuf -i 1000-9999 -n 1)
  read -r -p "  Type $code to confirm: " confirm || no_input
  [ "$confirm" != "$code" ] && echo "  Cancelled." && return 0

  while read -r vm <&3; do
    if ! (delete_single_vm "$vm"); then
      failed=$((failed + 1))
      print_error "Failed to delete $vm"
    fi
  done 3<<<"$vms"

  if ! names=$(virsh list --all --name 2>/dev/null); then
    ui_done warn "libvirt stopped answering" "shared DHCP state, port forwards and leftover folders are kept"
    return 1
  fi
  # Shared state only once no VM is left: a refused (protected) or failed VM keeps its lease, mapping and rules.
  if [ "$failed" -eq 0 ] && [ -z "$(list_datacenter_vm_names)" ]; then
    local status_file="${DNSMASQ_DIR:-/var/lib/libvirt/dnsmasq}/${BRIDGE_NAME}.status"
    # Leave an empty JSON array so jq-based readers see valid JSON (libvirt also accepts 0 bytes).
    [ -f "$status_file" ] && printf '[]\n' >"$status_file"
    local port_file ip ssh_port http_port lockfd
    port_file=$(get_port_mappings_file)
    exec {lockfd}>>"$port_file.lock"
    flock -w 30 "$lockfd" || print_warning "Another port change is running; clearing the port mappings anyway"
    while read -r _ ip ssh_port http_port; do
      [ -n "$ip" ] && cleanup_port_forwarding_for_vm "$ip" "$ssh_port" "$http_port" >/dev/null
    done < <(read_port_mappings 2>/dev/null)
    [ -f "$port_file" ] && echo "# VM_NAME VM_IP SSH_PORT HTTP_PORT" >"$port_file"
    save_iptables_rules
    exec {lockfd}>&-
  fi
  # A VM that was refused (protected) or failed keeps its folder and disk.
  local dir base
  for dir in "$DATACENTER_BASE"/vms/*/; do
    base=$(basename "$dir")
    [ -d "$dir" ] && ! grep -qxF -- "$base" <<<"$names" && [ "$(registry_get "$base" state)" != creating ] &&
      [ "$(registry_get "$base" protected)" != 1 ] && rm -rf "$dir"
  done

  if [ "$failed" -eq 0 ] && [ -z "$(list_datacenter_vms)" ]; then
    ui_done ok "All $(plural "$count" VM) deleted" "DHCP status, port mappings and forward rules cleared"
  else
    ui_done warn "$((count - failed)) of $count VMs deleted" "dcvm list shows what is left"
    return 1
  fi
}

main() {
  if wants_help "$@"; then
    ui_help <<EOF
dcvm delete - delete a VM with its disk, DHCP lease, port forwards and static IP

Usage:
  dcvm delete <vm> [--yes]    One VM, without asking; users without a terminal must add --yes
  dcvm delete --all           Every dcvm VM (asks twice; admins only)

Backups are kept. A protected VM is refused until: dcvm unprotect <vm>
EOF
    exit 0
  fi
  load_dcvm_config
  local args=() a
  for a in "$@"; do
    [ "$a" = --yes ] || [ "$a" = -y ] || args+=("$a")
  done
  if [ ${#args[@]} -ne 1 ] || [[ "${args[0]}" == -* && "${args[0]}" != --all && "${args[0]}" != -a ]]; then
    print_error "Usage: dcvm delete <vm> [--yes] | --all"
    exit 1
  fi

  case "${args[0]}" in
  --all | -a)
    delete_all_vms
    ;;
  *)
    delete_single_vm "${args[0]}"
    ;;
  esac
  local rc=$?

  prune_builds >/dev/null

  local remaining
  remaining=$(list_datacenter_vms | awk -F': ' '{ gsub(/^ +| +$/, "", $1); printf "%s%s (%s)", sep, $1, $2; sep = ", " }')
  echo -e "  ${DIM}Remaining VMs: ${remaining:-none}${NC}"
  echo ""
  return "$rc"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
