#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../utils/common.sh"

show_enhanced_console() {
  local host
  host=$(get_host_ip)
  if [ -z "$(read_port_mappings 2>/dev/null)" ]; then
    print_warning "No port mappings yet. Run: dcvm network ports setup"
    return 0
  fi
  ui_title "Access" "from other machines, through host $host"
  {
    printf 'VM\tSSH\tHTTP\tCONSOLE\n'
    read_port_mappings | while read -r vm ip ssh_port http_port; do
      [ -n "$vm" ] && printf '%s\t%s\t%s\t%s\n' "$vm" "ssh -p $ssh_port $(get_vm_username "$vm")@$host" "http://$host:$http_port" "dcvm console $vm"
    done
  } | ui_table
  echo -e "  ${DIM}Exit a console with Ctrl+]${NC}"
  echo ""
}

vms_in_state() {
  virsh list --all --name 2>/dev/null | while read -r vm; do
    [ -n "$vm" ] && is_vm_in_network "$vm" || continue
    case " $* " in *" $(get_vm_state "$vm") "*) echo "$vm" ;; esac
  done
}

run_on_vms() {
  local title="$1" action="$2" label="$3" vms="$4" vm ok=0 n
  n=$(grep -c . <<<"$vms" || true)
  ui_title "$title" "$(plural "$n" VM)"
  while read -r vm; do
    [ -n "$vm" ] || continue
    if [ "$action" = start ] && ! prepare_vm_disk "$vm" "$vm"; then
      ui_step fail "$vm" "not started (base image, see above)"
      continue
    fi
    if virsh "$action" "$vm" >/dev/null 2>&1; then
      ui_step ok "$vm" "$label"
      ok=$((ok + 1))
    else
      ui_step fail "$vm" "virsh $action failed"
      [ "$action" = start ] && explain_failure "$vm"
    fi
  done <<<"$vms"
  return $((n - ok > 0))
}

# Restarts a running VM. When its disk has to change (see prepare_vm_disk),
# it shuts down and starts again instead of rebooting in place, as the disk
# only changes while the VM is off; if it does not shut down within 90 s, it
# reboots in place and keeps its disk as it is.
restart_vm() {
  local vm="$1" i
  if vm_disk_outdated "$vm"; then
    virsh shutdown "$vm" >/dev/null 2>&1
    for ((i = 0; i < 45; i++)); do
      [ "$(get_vm_state "$vm")" = "shut off" ] && break
      sleep 2
    done
    if [ "$(get_vm_state "$vm")" = "shut off" ]; then
      prepare_vm_disk "$vm" "$vm" || return 1
      virsh start "$vm" >/dev/null 2>&1
      return
    fi
    ui_step warn "$vm" "did not shut down in 90s; rebooting without moving its base image"
  fi
  virsh reboot "$vm" >/dev/null 2>&1
}

explain_failure() {
  "$SCRIPT_DIR/../utils/doctor.sh" --quiet --fast --only host,network,vms --vm "$1" || true
}

not_found() {
  print_error "VM '$1' does not exist"
  local vms
  vms=$(list_datacenter_vm_names | paste -sd, - | sed 's/,/, /g')
  echo -e "  ${DIM}dcvm VMs: ${vms:-none}${NC}"
}

start_vms() {
  local target="$1"

  if [ "$target" = "all" ] || [ -z "$target" ]; then
    local vms
    vms=$(vms_in_state "shut off")
    if [ -z "$vms" ]; then
      echo ""
      echo -e "  ${DIM}All dcvm VMs are already running.${NC}"
      echo ""
      return 0
    fi
    run_on_vms "Starting VMs" start "started" "$vms"
    echo -e "  ${DIM}They boot in under a minute; then dcvm network ports setup makes them reachable from other machines.${NC}"
    echo ""
  else
    if ! check_vm_exists "$target"; then
      not_found "$target"
      return 1
    fi

    if virsh list | grep -q " $target .*running"; then
      echo -e "${DIM}${SYM_DOT}${NC} $target is already running"
    elif virsh list --all | grep -q " $target .*shut"; then
      prepare_vm_disk "$target" || return 1
      if virsh start "$target" >/dev/null; then
        print_success "$target started"
        echo -e "  ${DIM}It boots in under a minute; then dcvm network ports setup makes it reachable from other machines.${NC}"
      else
        print_error "Failed to start VM '$target'"
        explain_failure "$target"
        return 1
      fi
    else
      print_warning "VM '$target' is in unknown state"
    fi
  fi
}

stop_vms() {
  local target="$1"

  if [ "$target" = "all" ] || [ -z "$target" ]; then
    local vms
    vms=$(vms_in_state running)
    if [ -z "$vms" ]; then
      echo ""
      echo -e "  ${DIM}No dcvm VMs are running.${NC}"
      echo ""
      return 0
    fi
    run_on_vms "Stopping VMs" shutdown "shutting down" "$vms"
    echo -e "  ${DIM}A clean shutdown takes a few seconds; dcvm list shows when they are off.${NC}"
    echo ""
  else
    if ! check_vm_exists "$target"; then
      not_found "$target"
      return 1
    fi

    if virsh list | grep -q " $target .*running"; then
      if virsh shutdown "$target" >/dev/null; then
        print_success "$target is shutting down"
      else
        print_error "Failed to stop VM '$target'"
      fi
    else
      echo -e "${DIM}${SYM_DOT}${NC} $target is not running"
    fi
  fi
}

restart_vms() {
  local target="$1"

  if [ "$target" = "all" ] || [ -z "$target" ]; then
    local running stopped rc=0
    running=$(vms_in_state running)
    stopped=$(vms_in_state "shut off")
    if [ -z "$running$stopped" ]; then
      echo ""
      echo -e "  No dcvm VMs yet. Create one: ${CYAN}dcvm create myvm${NC}"
      echo ""
      return 0
    fi
    ui_title "Restarting VMs"
    local vm
    while read -r vm; do
      [ -n "$vm" ] || continue
      if restart_vm "$vm"; then ui_step ok "$vm" "restarting"; else ui_step fail "$vm" "restart failed" && rc=1; fi
    done <<<"$running"
    while read -r vm; do
      [ -n "$vm" ] || continue
      if prepare_vm_disk "$vm" "$vm" && virsh start "$vm" >/dev/null 2>&1; then ui_step ok "$vm" "was off, started"; else ui_step fail "$vm" "not started" && rc=1; fi
    done <<<"$stopped"
    echo -e "  ${DIM}They boot in under a minute; then dcvm network ports setup makes them reachable from other machines.${NC}"
    echo ""
    return $rc
  else
    if ! check_vm_exists "$target"; then
      not_found "$target"
      return 1
    fi

    if virsh list | grep -q " $target .*running"; then
      if restart_vm "$target"; then
        print_success "$target is restarting"
      else
        print_error "Failed to restart VM '$target'"
        explain_failure "$target"
      fi
    elif virsh list --all | grep -q " $target .*shut"; then
      prepare_vm_disk "$target" || return 1
      if virsh start "$target" >/dev/null; then
        print_success "$target was stopped; started it"
      else
        print_error "Failed to start VM '$target'"
      fi
    else
      print_warning "VM '$target' is in unknown state"
    fi
  fi
}

show_vm_table() {
  local vm state ip vcpu mem total=0 running=0 others=0
  local rows
  rows=$(
    printf 'NAME\tSTATE\tIP\tVCPU\tMEMORY\n'
    while read -r vm; do
      [ -n "$vm" ] && is_vm_in_network "$vm" || continue
      state=$(get_vm_state "$vm")
      ip=""
      if [ "$state" = running ]; then
        ip=$(get_vm_ip "$vm") || ip=""
      fi
      read -r vcpu mem < <(virsh dominfo "$vm" 2>/dev/null | awk '/^CPU\(s\)/ { c = $2 } /^Max memory/ { m = $3 } END { print c, int(m / 1024) }')
      printf '%s\t%s\t%s\t%s\t%s MB\n' "$vm" "$state" "$ip" "$vcpu" "$mem"
    done < <(virsh list --all --name 2>/dev/null)
  )
  total=$(($(echo "$rows" | grep -c .) - 1))
  running=$(echo "$rows" | awk -F'\t' 'NR > 1 && $2 == "running"' | grep -c . || true)
  others=$(($(virsh list --all --name 2>/dev/null | grep -c .) - total))
  echo ""
  if [ "$total" -eq 0 ]; then
    echo -e "  No dcvm VMs yet. Create one: ${CYAN}dcvm create myvm${NC}"
  else
    echo "$rows" | ui_table
    echo ""
    echo -e "  ${DIM}$(plural "$total" VM) on $NETWORK_NAME ${SYM_DOT} $running running$([ "$others" -gt 0 ] && echo " ${SYM_DOT} $(plural "$others" "other libvirt VM") not shown (virsh list --all)")${NC}"
  fi
  echo ""
}

show_enhanced_status() {
  show_vm_table
  if virsh net-list 2>/dev/null | grep -q " $NETWORK_NAME .*active"; then
    ui_step ok "Network" "$NETWORK_NAME active, ${NETWORK_SUBNET:-10.10.10}.0/24, bridge $BRIDGE_NAME"
  else
    ui_step fail "Network" "$NETWORK_NAME is not active (dcvm network start)"
  fi
  local n
  n=$(read_port_mappings 2>/dev/null | grep -c . || true)
  if [ "${n:-0}" -gt 0 ]; then
    ui_step ok "Port forwards" "$(plural "$n" VM) (dcvm network ports show)"
  else
    ui_step skip "Port forwards" "none (dcvm network ports setup)"
  fi
  [ "$(id -u)" -eq 0 ] && "$SCRIPT_DIR/../utils/doctor.sh" --summary
  echo ""
}

main() {
  load_dcvm_config

  case $1 in
  start) start_vms "$2" ;;
  stop) stop_vms "$2" ;;
  restart) restart_vms "$2" ;;
  status) show_enhanced_status ;;
  list) show_vm_table ;;
  console)
    if [ -z "${2:-}" ]; then
      show_enhanced_console
    elif check_vm_exists "$2"; then
      echo -e "${DIM}Connected to $2's serial console. Exit with Ctrl+]${NC}"
      exec virsh console "$2"
    else
      not_found "$2"
      exit 1
    fi
    ;;
  *)
    print_error "Unknown command: $1"
    echo "Run 'dcvm help' for the list of commands"
    exit 1
    ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
