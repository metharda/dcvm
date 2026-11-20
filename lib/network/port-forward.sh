#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../utils/common.sh"

SSH_PORT_START=${SSH_PORT_START:-2221}
HTTP_PORT_START=${HTTP_PORT_START:-8081}

if ! command -v detect_host_ip &>/dev/null; then
  detect_host_ip() {
    local host_ip=""
    local subnet="${NETWORK_SUBNET:-10.10.10}"
    for interface in eth0 ens3 ens18 enp0s3 wlan0; do
      host_ip=$(ip addr show "$interface" 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1 | head -1)
      [ -n "$host_ip" ] && [[ ! "$host_ip" =~ ^127\. ]] && [[ ! "$host_ip" =~ ^${subnet}\. ]] && break
    done
    [ -z "$host_ip" ] && host_ip=$(ip route get 8.8.8.8 2>/dev/null | awk '{print $7; exit}')
    [ -z "$host_ip" ] && host_ip="YOUR_HOST_IP"
    echo "$host_ip"
  }
fi

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
  echo "$vm $vm_ip $ssh_port $http_port" >>/tmp/dcvm_port_mappings.tmp
  return 0
}

save_mappings_tmp_to_file() {
  if [ -f /tmp/dcvm_port_mappings.tmp ]; then
    create_dir_safe "$DATACENTER_BASE"
    local map_file="$DATACENTER_BASE/port-mappings.txt"
    echo "# VM_NAME VM_IP SSH_PORT HTTP_PORT" >"$map_file"
    cat /tmp/dcvm_port_mappings.tmp >>"$map_file"
    rm -f /tmp/dcvm_port_mappings.tmp
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
  rm -f /tmp/dcvm_port_mappings.tmp
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
  if command_exists iptables-save; then
    create_dir_safe /etc/iptables
    iptables-save >/etc/iptables/rules.v4 2>/dev/null
  fi
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
  echo ""
  if [ "$count" -gt 0 ]; then
    echo -e "${GREEN}${SYM_OK}${NC} ${BOLD}$count VM$([ "$count" -gt 1 ] && echo s) forwarded${NC}  ${DIM}saved to $DATACENTER_BASE/port-mappings.txt${NC}"
    echo -e "  ${DIM}From other machines, allow TCP $SSH_PORT_START-$((ssh_port - 1)) and $HTTP_PORT_START-$((http_port - 1)) in the host firewall.${NC}"
  else
    print_warning "No VMs were forwarded"
  fi
  echo ""
}

cmd_show() {
  local map_file=$(get_port_mappings_file)
  if [ -f "$map_file" ]; then
    {
      printf 'VM\tIP\tSSH PORT\tHTTP PORT\n'
      read_port_mappings | while read -r vm ip ssh_port http_port; do
        [ -n "$vm" ] && printf '%s\t%s\t%s\t%s\n' "$vm" "$ip" "$ssh_port" "$http_port"
      done
    } | ui_table
    echo -e "  ${DIM}from $map_file${NC}"
  else
    print_warning "No saved port mappings. Run: dcvm network ports setup"
  fi
}

cmd_rules() {
  echo "Active port forwarding rules (iptables):"
  local nat_rules=$(iptables -t nat -L PREROUTING -n --line-numbers | grep -E "(222[0-9]|808[0-9])")
  [ -n "$nat_rules" ] && echo "$nat_rules" || echo "No dcvm port forwarding rules found"
}

cmd_clear() {
  cleanup_port_forwarding
}

cmd_apply() {
  local map_file=$(get_port_mappings_file)
  if [ ! -f "$map_file" ]; then
    print_error "Mappings file not found: $map_file"
    exit 1
  fi
  echo 1 >/proc/sys/net/ipv4/ip_forward 2>/dev/null || true
  cleanup_port_forwarding
  local HOST_IP=$(detect_host_ip)
  while read vm ip ssh_port http_port; do
    [[ "$vm" =~ ^#|^$ ]] && continue
    setup_vm_forwarding "$vm" "$ip" "$ssh_port" "$http_port" "$HOST_IP"
  done <"$map_file"
  iptables -I FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
  print_success "Applied port mappings from $map_file"
}

cmd_test() {
  local map_file=$(get_port_mappings_file)
  if [ -f "$map_file" ]; then
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
  else
    print_warning "No port mappings to test. Run: dcvm network ports setup"
  fi
}

cmd_help() {
  cat <<EOF
dcvm Port Forwarding

Usage: dcvm network ports <command>

Commands:
  setup        Discover VMs and create iptables port forwarding + save mapping
  show         Show saved port mappings table
  rules        Show active iptables NAT rules for forwarding
  apply        Apply saved mappings file to iptables rules
  clear        Remove existing iptables rules for forwarding
  test         Check each forward: the DNAT and FORWARD rules, and that the VM port is open
  help         Show this help

Examples:
  dcvm network ports setup
  dcvm network ports show
  dcvm network ports apply
  dcvm network ports clear
  dcvm network ports test
EOF
}

main() {
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
