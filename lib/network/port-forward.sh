#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../utils/common.sh"

SSH_PORT_START=${SSH_PORT_START:-2221}
HTTP_PORT_START=${HTTP_PORT_START:-8081}
SSH_PORT_END=$((SSH_PORT_START + 78))
HTTP_PORT_END=$((HTTP_PORT_START + 98))

get_vm_ip_advanced() {
  local vm_name="$1" ip="" attempts=0
  print_info "Looking for IP address of $vm_name" >&2
  # Host-side records only: neighbour and ARP entries are whatever the guest announces.
  while [ $attempts -lt 15 ]; do
    ip=$(get_vm_ip_trusted "$vm_name") && check_ping "$ip" && break
    ip=""
    [ $attempts -eq 0 ] && print_info "Attempt 1: Waiting for $vm_name to get valid IP address" >&2
    sleep 3
    attempts=$((attempts + 1))
  done
  [ -n "$ip" ] && print_success "$vm_name IP found and reachable: $ip" >&2
  echo "$ip"
}

setup_vm_forwarding() {
  local vm="$1" vm_ip="$2" ssh_port="$3" http_port="$4" host_ip="$5"
  print_info "Setting up port forwarding for $vm ($vm_ip)"
  # Only traffic to this host: routed traffic (VM egress, docker, VPNs) to the same port is never rewritten.
  local match=(! -i "$BRIDGE_NAME" -p tcp -m addrtype --dst-type LOCAL)
  if iptables -w -t nat -I PREROUTING "${match[@]}" --dport "$ssh_port" -j DNAT --to-destination "$vm_ip:22" 2>/dev/null &&
    iptables -w -I FORWARD -p tcp -d "$vm_ip" --dport 22 -m conntrack --ctstate DNAT -j ACCEPT 2>/dev/null &&
    iptables -w -t nat -I PREROUTING "${match[@]}" --dport "$http_port" -j DNAT --to-destination "$vm_ip:80" 2>/dev/null &&
    iptables -w -I FORWARD -p tcp -d "$vm_ip" --dport 80 -m conntrack --ctstate DNAT -j ACCEPT 2>/dev/null; then
    print_success "  SSH: $host_ip:$ssh_port -> $vm_ip:22"
    print_success "  HTTP: $host_ip:$http_port -> $vm_ip:80"
  else
    print_error "  Failed to set up port forwarding for $vm"
    cleanup_port_forwarding_for_vm "$vm_ip" "$ssh_port" "$http_port" >/dev/null
    return 1
  fi
  [ -n "${MAPPINGS_TMP:-}" ] && echo "$vm $vm_ip $ssh_port $http_port" >>"$MAPPINGS_TMP"
  return 0
}

free_port() {
  local port rules
  rules=$(iptables -w -t nat -S PREROUTING 2>/dev/null)
  for ((port = $1; port <= $2; port++)); do
    awk -v c="$3" -v p="$port" '!/^#/ && $c == p { f = 1 } END { exit !f }' "$4" 2>/dev/null && continue
    grep -q -- "--dport $port " <<<"$rules" && continue
    ss -Hltn "sport = :$port" 2>/dev/null | grep -q . && continue
    echo "$port"
    return 0
  done
  return 1
}

allow_related() {
  iptables -w -C FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -w -I FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
}

save_mappings_tmp_to_file() {
  if [ -n "${MAPPINGS_TMP:-}" ] && [ -f "$MAPPINGS_TMP" ]; then
    create_dir_safe "$DATACENTER_BASE"
    local map_file="$DATACENTER_BASE/port-mappings.txt"
    (umask 077 && {
      echo "# VM_NAME VM_IP SSH_PORT HTTP_PORT"
      cat "$MAPPINGS_TMP"
    } >"$map_file.new") && mv -f "$map_file.new" "$map_file"
    rm -f "$MAPPINGS_TMP"
    print_success "Port mappings saved to $map_file"
  fi
}

cmd_setup() {
  ui_quiet
  lock_port_mappings || exit 1
  if ! virsh net-info "$NETWORK_NAME" >/dev/null 2>&1; then
    print_error "$NETWORK_NAME network not found"
    echo "Run the dcvm installer to create it."
    exit 1
  fi
  if ! virsh net-list --name | grep -qxF "$NETWORK_NAME"; then
    print_warning "$NETWORK_NAME is not active, starting it"
    if virsh net-start "$NETWORK_NAME" >/dev/null 2>&1; then
      sleep 3
    else
      print_error "Failed to start $NETWORK_NAME"
      exit 1
    fi
  fi
  echo 1 >/proc/sys/net/ipv4/ip_forward 2>/dev/null || true
  VM_LIST=""
  while read -r vm; do
    [ -n "$vm" ] && is_vm_in_network "$vm" && VM_LIST="${VM_LIST}${vm}"$'\n'
  done < <(virsh list --all | grep -E "(running|shut off)" | awk '{print $2}' | grep -v "^$")
  VM_LIST=$(echo "$VM_LIST" | grep -v "^$")
  if [ -z "$VM_LIST" ]; then
    print_warning "No VMs on $NETWORK_NAME yet. Create one: dcvm create my-vm"
    exit 0
  fi
  cleanup_port_forwarding
  local HOST_IP=$(detect_host_ip)
  ui_title "Port forwarding" "host $HOST_IP ${SYM_DOT} $NETWORK_NAME"
  local ssh_port http_port
  local subnet="${NETWORK_SUBNET:-10.10.10}"
  local subnet_regex="${subnet//./\\.}"
  local skipped=() count=0
  MAPPINGS_TMP=$(mktemp)
  while read -r vm <&3; do
    [ -z "$vm" ] && continue
    if ! virsh list | grep -q "$vm.*running"; then
      skipped+=("$vm|not running, start it first")
      continue
    fi
    local vm_ip=$(get_vm_ip_advanced "$vm")
    if ! [[ $vm_ip =~ ^${subnet_regex}\.[0-9]+$ ]]; then
      skipped+=("$vm|no reachable IP yet; try again once it has booted")
    elif ip_held_by_other_vm "$vm_ip" "$vm"; then
      skipped+=("$vm|$vm_ip is leased to another VM; check the address set inside $vm")
    elif ! ssh_port=$(free_port "$SSH_PORT_START" "$SSH_PORT_END" 3 "$MAPPINGS_TMP") ||
      ! http_port=$(free_port "$HTTP_PORT_START" "$HTTP_PORT_END" 4 "$MAPPINGS_TMP"); then
      skipped+=("$vm|no free ports left in $SSH_PORT_START-$SSH_PORT_END, $HTTP_PORT_START-$HTTP_PORT_END")
    elif setup_vm_forwarding "$vm" "$vm_ip" "$ssh_port" "$http_port" "$HOST_IP"; then
      count=$((count + 1))
    else
      skipped+=("$vm|could not add the rules")
    fi
  done 3<<<"$VM_LIST"
  allow_related
  save_mappings_tmp_to_file
  command_exists iptables-save && create_dir_safe "${IPTABLES_RULES_FILE%/*}"
  save_iptables_rules
  if [ "$count" -gt 0 ]; then
    {
      printf 'VM\tIP\tSSH\tHTTP\n'
      read_port_mappings | while read -r vm ip sp hp; do
        [ -n "$vm" ] && printf '%s\t%s\t%s\t%s\n' "$vm" "$ip" "ssh -p $sp $(vm_login "$vm" | grep . || echo '<user>')@$HOST_IP" "http://$HOST_IP:$hp"
      done
    } | ui_table
  fi
  local item
  for item in "${skipped[@]}"; do
    ui_step skip "${item%%|*}" "${item#*|}"
  done
  if [ "$count" -gt 0 ]; then
    ui_done ok "$(plural "$count" VM) forwarded" "saved to $DATACENTER_BASE/port-mappings.txt"
    echo -e "  ${DIM}From other machines, allow TCP $SSH_PORT_START-$SSH_PORT_END and $HTTP_PORT_START-$HTTP_PORT_END in the host firewall.${NC}"
  else
    ui_done warn "No VMs were forwarded"
  fi
  echo ""
}

cmd_show() {
  local map_file=$(get_port_mappings_file) rows
  rows=$(read_port_mappings 2>/dev/null | while read -r vm ip ssh_port http_port; do
    vm_visible "$vm" && printf '%s\t%s\t%s\t%s\n' "$vm" "$ip" "$ssh_port" "$http_port"
  done)
  if [ -n "$rows" ]; then
    ui_title "Port forwards" "saved in $map_file"
    printf 'VM\tIP\tSSH PORT\tHTTP PORT\n%s\n' "$rows" | ui_table
    echo ""
  else
    print_warning "No saved port mappings. Run: dcvm network ports add <vm>"
  fi
}

cmd_add() {
  local vm="${1:-}" map_file line ip ssh_port http_port host_ip
  if [ -z "$vm" ] || ! check_vm_exists "$vm" || ! is_vm_in_network "$vm"; then
    print_error "Usage: dcvm network ports add <your vm>"
    return 1
  fi
  map_file=$(get_port_mappings_file)
  lock_port_mappings || return 1
  line=$(read_port_mappings 2>/dev/null | awk -v v="$vm" '$1 == v' | head -1)
  if [ -n "$line" ]; then
    read -r _ ip ssh_port http_port <<<"$line"
    ui_done ok "$vm is already forwarded" "SSH $ssh_port, HTTP $http_port"
    return 0
  fi
  if [ "$(get_vm_state "$vm")" != running ]; then
    print_error "$vm is not running; start it first: dcvm start $vm"
    return 1
  fi
  ip=$(get_vm_ip_trusted "$vm")
  valid_vm_ip "$ip" || {
    print_error "$vm has no address yet; wait for it to boot"
    return 1
  }
  if ip_held_by_other_vm "$ip" "$vm"; then
    print_error "$ip is leased to another VM; check the address set inside $vm"
    return 1
  fi
  if ! ssh_port=$(free_port "$SSH_PORT_START" "$SSH_PORT_END" 3 "$map_file") ||
    ! http_port=$(free_port "$HTTP_PORT_START" "$HTTP_PORT_END" 4 "$map_file"); then
    print_error "No free ports left in dcvm's ranges ($SSH_PORT_START-$SSH_PORT_END, $HTTP_PORT_START-$HTTP_PORT_END)"
    return 1
  fi
  host_ip=$(detect_host_ip)
  setup_vm_forwarding "$vm" "$ip" "$ssh_port" "$http_port" "$host_ip" >/dev/null || return 1
  [ -s "$map_file" ] || echo "# VM_NAME VM_IP SSH_PORT HTTP_PORT" >"$map_file"
  chmod 600 "$map_file"
  echo "$vm $ip $ssh_port $http_port" >>"$map_file"
  allow_related
  save_iptables_rules
  ui_done ok "$vm forwarded" "ssh -p $ssh_port $(vm_login "$vm" | grep . || echo '<user>')@$host_ip, http://$host_ip:$http_port"
}

cmd_remove() {
  local vm="${1:-}" line ip ssh_port http_port
  if [ -z "$vm" ] || ! is_vm_in_network "$vm"; then
    print_error "Usage: dcvm network ports remove <your vm>"
    return 1
  fi
  lock_port_mappings || return 1
  line=$(read_port_mappings 2>/dev/null | awk -v v="$vm" '$1 == v' | head -1)
  if [ -z "$line" ]; then
    ui_done ok "$vm has no port forwards"
    return 0
  fi
  read -r _ ip ssh_port http_port <<<"$line"
  cleanup_port_forwarding_for_vm "$ip" "$ssh_port" "$http_port" >/dev/null
  drop_port_mapping "$vm"
  ui_done ok "$vm's port forwards removed" "SSH $ssh_port, HTTP $http_port"
}

cmd_rules() {
  local rules
  rules=$(iptables -w -t nat -S PREROUTING 2>/dev/null | awk '/-j DNAT/ { p = "any"; d = ""; for (i = 1; i <= NF; i++) { if ($i == "--dport") p = $(i + 1); if ($i == "--to-destination") d = $(i + 1) } print p "\t" d }')
  ui_title "Port forward rules" "iptables nat PREROUTING"
  if [ -n "$rules" ]; then
    printf 'HOST PORT\tDESTINATION\n%s\n' "$rules" | ui_table
  else
    echo -e "  ${DIM}none (dcvm network ports setup or apply)${NC}"
  fi
  echo ""
}

cmd_clear() {
  ui_quiet
  lock_port_mappings || exit 1
  cleanup_port_forwarding
  save_iptables_rules
  ui_done ok "Port forward rules removed" "the saved mappings stay; dcvm network ports apply restores them"
  echo ""
}

cmd_apply() {
  ui_quiet
  local map_file=$(get_port_mappings_file)
  if [ ! -f "$map_file" ]; then
    print_error "No saved mappings ($map_file). Run: dcvm network ports setup"
    exit 1
  fi
  lock_port_mappings || exit 1
  echo 1 >/proc/sys/net/ipv4/ip_forward 2>/dev/null || true
  cleanup_port_forwarding
  local HOST_IP=$(detect_host_ip) count=0
  ui_title "Port forwarding" "from $map_file"
  while read -r vm ip ssh_port http_port; do
    [[ "$vm" =~ ^#|^$ ]] && continue
    if ! valid_vm_ip "$ip"; then
      ui_step fail "$vm" "invalid address $ip in $map_file; dcvm network ports add $vm"
      continue
    fi
    if setup_vm_forwarding "$vm" "$ip" "$ssh_port" "$http_port" "$HOST_IP"; then
      ui_step ok "$vm" "$ssh_port $SYM_ARROW $ip:22, $http_port $SYM_ARROW $ip:80"
      count=$((count + 1))
    else
      ui_step fail "$vm" "could not add the rules"
    fi
  done <"$map_file"
  allow_related
  save_iptables_rules
  ui_done ok "$(plural "$count" VM) forwarded" "dcvm network ports test checks them"
  echo ""
}

cmd_test() {
  if [ -n "$(read_port_mappings 2>/dev/null)" ]; then
    ui_title "Port forward check"
    {
      printf 'VM\tPING\tSSH\tHTTP\n'
      read_port_mappings | while read -r vm ip ssh_port http_port; do
        if [ -n "$vm" ]; then
          ping_status=$(check_ping "$ip" && echo "$SYM_OK" || echo "$SYM_FAIL")
          ssh_status=$(check_port_forward "$ssh_port" "$ip" 22 && echo "$SYM_OK" || echo "$SYM_FAIL")
          http_status=$(check_port_forward "$http_port" "$ip" 80 && echo "$SYM_OK" || echo "$SYM_FAIL")
          printf '%s\t%s\t%s\t%s\n' "$vm" "$ping_status" "$ssh_status" "$http_status"
        fi
      done
    } | ui_table
    libvirt_nft_rejects_forwards && print_error "libvirt's nftables rules reject forwarded connections to $BRIDGE_NAME: set firewall_backend = \"iptables\" in /etc/libvirt/network.conf, restart libvirt, then dcvm network ports apply"
    echo -e "  ${DIM}$SYM_OK rules in place, not blocked by libvirt, and the VM port answers this host (other machines are not tried), $SYM_FAIL not reachable${NC}"
    echo ""
  else
    print_warning "No port mappings to test. Run: dcvm network ports setup"
  fi
}

cmd_help() {
  ui_help <<EOF
dcvm network ports - forward host ports to VMs

Usage: dcvm network ports <command>

Commands:
  setup   Find running VMs, forward SSH ($SSH_PORT_START+) and HTTP ($HTTP_PORT_START+), save the mapping
  show    Saved mappings
  add <vm>     Forward SSH and HTTP for one VM (users: their own VMs)
  remove <vm>  Remove one VM's forwards
  test    Check each forward: rules in place and the VM port answers
  rules   Active DNAT rules
  apply   Recreate the rules from the saved mappings (after a reboot)
  clear   Remove the rules; the saved mappings stay
  help    Show this help

Examples:
  dcvm network ports setup
  dcvm network ports test
EOF
}

main() {
  case "${1:-}" in help | --help | -h)
    cmd_help
    exit 0
    ;;
  esac
  load_dcvm_config
  require_root
  check_dependencies iptables virsh

  local subcmd="${1:-help}"
  case "$subcmd" in
  setup)
    shift
    cmd_setup "$@"
    ;;
  show)
    shift
    cmd_show "$@"
    ;;
  add)
    shift
    cmd_add "$@"
    ;;
  remove)
    shift
    cmd_remove "$@"
    ;;
  rules)
    shift
    cmd_rules "$@"
    ;;
  apply)
    shift
    cmd_apply "$@"
    ;;
  clear)
    shift
    cmd_clear "$@"
    ;;
  test)
    shift
    cmd_test "$@"
    ;;
  help | --help | -h) cmd_help ;;
  *)
    print_error "Unknown command: $subcmd"
    echo "Use: dcvm network ports help"
    exit 1
    ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
