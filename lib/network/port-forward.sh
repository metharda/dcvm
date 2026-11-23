#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../utils/common.sh"

SSH_PORT_START=${SSH_PORT_START:-2221}
HTTP_PORT_START=${HTTP_PORT_START:-8081}

cleanup_port_forwarding() {
  local subnet="${NETWORK_SUBNET:-10.10.10}"
  local subnet_regex="${subnet//./\\.}"
  print_info "Cleaning up existing dcvm port forwarding rules"
  for port in {2220..2299} {8080..8179}; do
    while iptables -t nat -L PREROUTING -n --line-numbers 2>/dev/null | grep -q ":$port "; do
      local line=$(iptables -t nat -L PREROUTING -n --line-numbers | grep ":$port " | head -1 | awk '{print $1}')
      [ -n "$line" ] && iptables -t nat -D PREROUTING "$line" 2>/dev/null || break
    done
  done
  while iptables -L FORWARD -n --line-numbers 2>/dev/null | grep -q "${subnet_regex}\."; do
    local line=$(iptables -L FORWARD -n --line-numbers | grep "${subnet_regex}\." | head -1 | awk '{print $1}')
    [ -n "$line" ] && iptables -D FORWARD "$line" 2>/dev/null || break
  done
  print_success "Cleanup completed"
}

get_vm_ip_advanced() {
  local vm_name="$1"
  local ip=""
  local attempts=0
  local subnet="${NETWORK_SUBNET:-10.10.10}"
  local subnet_regex="${subnet//./\\.}"

  print_info "Looking for IP address of $vm_name" >&2
  while [ -z "$ip" ] && [ $attempts -lt 15 ]; do
    ip=$(get_vm_ip "$vm_name" 1)
    if [ "$ip" = "N/A" ] || [ -z "$ip" ]; then
      local mac=$(get_vm_mac "$vm_name")
      if [ -n "$mac" ]; then
        ip=$(ip neigh show | grep "$mac" | grep -oE "${subnet_regex}\.[0-9]+" | head -1)
        [ -z "$ip" ] && ip=$(arp -a | grep "$mac" | grep -oE "${subnet_regex}\.[0-9]+" | head -1)
      fi
    fi
    if [ -z "$ip" ] || [ "$ip" = "N/A" ]; then
      if [ $attempts -eq 10 ]; then
        print_info "Attempting network scan as last resort" >&2
        for i in {100..254}; do
          local test_ip="${subnet}.$i"
          if check_ping "$test_ip"; then
            local test_mac=$(ip neigh show "$test_ip" 2>/dev/null | awk '{print $5}')
            local vm_mac=$(get_vm_mac "$vm_name")
            if [ -n "$test_mac" ] && [ -n "$vm_mac" ] && [ "$test_mac" = "$vm_mac" ]; then
              ip="$test_ip"
              break
            fi
          fi
        done
      fi
    fi
    if [ -n "$ip" ] && [ "$ip" != "N/A" ] && [[ $ip =~ ^${subnet_regex}\.[0-9]+$ ]]; then
      if check_ping "$ip"; then
        print_success "$vm_name IP found and reachable: $ip" >&2
        break
      else
        print_warning "$vm_name IP found but not reachable: $ip (attempt $((attempts + 1)))" >&2
        ip=""
      fi
    else
      [ $attempts -eq 0 ] && print_info "Attempt $((attempts + 1)): Waiting for $vm_name to get valid IP address" >&2
    fi
    [ -z "$ip" ] || [ "$ip" = "N/A" ] && sleep 3
    attempts=$((attempts + 1))
  done
  echo "$ip"
}

setup_vm_forwarding() {
  local vm="$1" vm_ip="$2" ssh_port="$3" http_port="$4" host_ip="$5"
  print_info "Setting up port forwarding for $vm ($vm_ip)"
  if iptables -t nat -I PREROUTING -p tcp --dport "$ssh_port" -j DNAT --to-destination "$vm_ip:22" 2>/dev/null; then
    iptables -I FORWARD -p tcp -d "$vm_ip" --dport 22 -j ACCEPT 2>/dev/null
    print_success "  SSH: $host_ip:$ssh_port -> $vm_ip:22"
  else
    print_error "  Failed to setup SSH forwarding for $vm"
    return 1
  fi
  if iptables -t nat -I PREROUTING -p tcp --dport "$http_port" -j DNAT --to-destination "$vm_ip:80" 2>/dev/null; then
    iptables -I FORWARD -p tcp -d "$vm_ip" --dport 80 -j ACCEPT 2>/dev/null
    print_success "  HTTP: $host_ip:$http_port -> $vm_ip:80"
  else
    print_error "  Failed to setup HTTP forwarding for $vm"
  fi
  [ -n "${MAPPINGS_TMP:-}" ] && echo "$vm $vm_ip $ssh_port $http_port" >>"$MAPPINGS_TMP"
  return 0
}

save_mappings_tmp_to_file() {
  if [ -n "${MAPPINGS_TMP:-}" ] && [ -f "$MAPPINGS_TMP" ]; then
    create_dir_safe "$DATACENTER_BASE"
    local map_file="$DATACENTER_BASE/port-mappings.txt"
    {
      echo "# VM_NAME VM_IP SSH_PORT HTTP_PORT"
      cat "$MAPPINGS_TMP"
    } >"$map_file.new" && mv -f "$map_file.new" "$map_file"
    rm -f "$MAPPINGS_TMP"
    print_success "Port mappings saved to $map_file"
  fi
}

cmd_setup() {
  ui_quiet
  if ! virsh net-list --all | grep -q "$NETWORK_NAME"; then
    print_error "$NETWORK_NAME network not found"
    echo "Run the dcvm installer to create it."
    exit 1
  fi
  if ! virsh net-list | grep -q "$NETWORK_NAME.*active"; then
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
  local ssh_port=$SSH_PORT_START http_port=$HTTP_PORT_START
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
    if [ -n "$vm_ip" ] && [[ $vm_ip =~ ^${subnet_regex}\.[0-9]+$ ]]; then
      if setup_vm_forwarding "$vm" "$vm_ip" "$ssh_port" "$http_port" "$HOST_IP"; then
        count=$((count + 1))
      fi
      ssh_port=$((ssh_port + 1))
      http_port=$((http_port + 1))
    else
      skipped+=("$vm|no reachable IP yet; try again once it has booted")
    fi
  done 3<<<"$VM_LIST"
  iptables -I FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
  save_mappings_tmp_to_file
  command_exists iptables-save && create_dir_safe "${IPTABLES_RULES_FILE%/*}"
  save_iptables_rules
  if [ "$count" -gt 0 ]; then
    {
      printf 'VM\tIP\tSSH\tHTTP\n'
      read_port_mappings | while read -r vm ip sp hp; do
        [ -n "$vm" ] && printf '%s\t%s\t%s\t%s\n' "$vm" "$ip" "ssh -p $sp $(get_vm_username "$vm")@$HOST_IP" "http://$HOST_IP:$hp"
      done
    } | ui_table
  fi
  local item
  for item in "${skipped[@]}"; do
    ui_step skip "${item%%|*}" "${item#*|}"
  done
  if [ "$count" -gt 0 ]; then
    ui_done ok "$(plural "$count" VM) forwarded" "saved to $DATACENTER_BASE/port-mappings.txt"
    echo -e "  ${DIM}From other machines, allow TCP $SSH_PORT_START-$((ssh_port - 1)) and $HTTP_PORT_START-$((http_port - 1)) in the host firewall.${NC}"
  else
    ui_done warn "No VMs were forwarded"
  fi
  echo ""
}

cmd_show() {
  local map_file=$(get_port_mappings_file)
  if [ -n "$(read_port_mappings 2>/dev/null)" ]; then
    ui_title "Port forwards" "saved in $map_file"
    {
      printf 'VM\tIP\tSSH PORT\tHTTP PORT\n'
      read_port_mappings | while read -r vm ip ssh_port http_port; do
        [ -n "$vm" ] && vm_visible "$vm" && printf '%s\t%s\t%s\t%s\n' "$vm" "$ip" "$ssh_port" "$http_port"
      done
    } | ui_table
    echo ""
  else
    print_warning "No saved port mappings. Run: dcvm network ports setup"
  fi
}

cmd_add() {
  local vm="${1:-}" map_file line ip ssh_port="" http_port="" port lockfd host_ip
  if [ -z "$vm" ] || ! check_vm_exists "$vm" || ! is_vm_in_network "$vm"; then
    print_error "Usage: dcvm network ports add <your vm>"
    return 1
  fi
  map_file=$(get_port_mappings_file)
  exec {lockfd}>>"$map_file.lock"
  flock -w 30 "$lockfd" || {
    print_error "Another port change is running; try again"
    return 1
  }
  line=$(read_port_mappings 2>/dev/null | awk -v v="$vm" '$1 == v' | head -1)
  if [ -n "$line" ]; then
    read -r _ ip ssh_port http_port <<<"$line"
    ui_done ok "$vm is already forwarded" "SSH $ssh_port, HTTP $http_port"
    return 0
  fi
  ip=$(get_vm_ip "$vm")
  valid_vm_ip "$ip" || {
    print_error "$vm has no address yet; start it and wait for it to boot"
    return 1
  }
  if ip_held_by_other_vm "$ip" "$vm"; then
    print_error "$ip is leased to another VM; check the address set inside $vm"
    return 1
  fi
  for ((port = SSH_PORT_START; port <= 2299; port++)); do
    read_port_mappings 2>/dev/null | awk -v p="$port" '$3 == p { f = 1 } END { exit !f }' && continue
    ss -Hltn "sport = :$port" 2>/dev/null | grep -q . && continue
    ssh_port=$port
    break
  done
  for ((port = HTTP_PORT_START; port <= 8179; port++)); do
    read_port_mappings 2>/dev/null | awk -v p="$port" '$4 == p { f = 1 } END { exit !f }' && continue
    ss -Hltn "sport = :$port" 2>/dev/null | grep -q . && continue
    http_port=$port
    break
  done
  if [ -z "$ssh_port" ] || [ -z "$http_port" ]; then
    print_error "No free ports left in dcvm's ranges (2221-2299, 8081-8179)"
    return 1
  fi
  host_ip=$(detect_host_ip)
  setup_vm_forwarding "$vm" "$ip" "$ssh_port" "$http_port" "$host_ip" >/dev/null || return 1
  [ -s "$map_file" ] || echo "# VM_NAME VM_IP SSH_PORT HTTP_PORT" >"$map_file"
  echo "$vm $ip $ssh_port $http_port" >>"$map_file"
  iptables -C FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -I FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null
  save_iptables_rules
  ui_done ok "$vm forwarded" "ssh -p $ssh_port $(get_vm_username "$vm")@$host_ip, http://$host_ip:$http_port"
}

cmd_remove() {
  local vm="${1:-}" map_file line ip ssh_port http_port lockfd
  if [ -z "$vm" ] || ! is_vm_in_network "$vm"; then
    print_error "Usage: dcvm network ports remove <your vm>"
    return 1
  fi
  map_file=$(get_port_mappings_file)
  exec {lockfd}>>"$map_file.lock"
  flock -w 30 "$lockfd" || return 1
  line=$(read_port_mappings 2>/dev/null | awk -v v="$vm" '$1 == v' | head -1)
  if [ -z "$line" ]; then
    ui_done ok "$vm has no port forwards"
    return 0
  fi
  read -r _ ip ssh_port http_port <<<"$line"
  cleanup_port_forwarding_for_vm "$ip" "$ssh_port" "$http_port" >/dev/null
  awk -v v="$vm" '$1 != v' "$map_file" >"$map_file.new" && mv -f "$map_file.new" "$map_file"
  ui_done ok "$vm's port forwards removed" "SSH $ssh_port, HTTP $http_port"
}

cmd_rules() {
  local rules
  rules=$(iptables -t nat -S PREROUTING 2>/dev/null | awk '/-j DNAT/ { for (i = 1; i <= NF; i++) { if ($i == "--dport") p = $(i + 1); if ($i == "--to-destination") d = $(i + 1) } print p "\t" d }')
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
  echo 1 >/proc/sys/net/ipv4/ip_forward 2>/dev/null || true
  cleanup_port_forwarding
  local HOST_IP=$(detect_host_ip) count=0
  ui_title "Port forwarding" "from $map_file"
  while read -r vm ip ssh_port http_port; do
    [[ "$vm" =~ ^#|^$ ]] && continue
    if setup_vm_forwarding "$vm" "$ip" "$ssh_port" "$http_port" "$HOST_IP"; then
      ui_step ok "$vm" "$ssh_port $SYM_ARROW $ip:22, $http_port $SYM_ARROW $ip:80"
      count=$((count + 1))
    else
      ui_step fail "$vm" "could not add the rules"
    fi
  done <"$map_file"
  iptables -I FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
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
    echo -e "  ${DIM}$SYM_OK forward rules in place and the VM port answers, $SYM_FAIL not reachable${NC}"
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
