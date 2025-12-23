#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../utils/common.sh"

SSH_PORT_START=${SSH_PORT_START:-2221}
HTTP_PORT_START=${HTTP_PORT_START:-8081}

if ! command -v detect_host_ip &>/dev/null; then
  detect_host_ip() {
    local host_ip=""
    local subnet="${NETWORK_SUBNET:-10.10.10}"
    
    if is_macos; then
      # macOS: use route to find primary interface
      local iface
      iface=$(route -n get default 2>/dev/null | awk '/interface:/ {print $2}')
      if [[ -n "$iface" ]]; then
        host_ip=$(ifconfig "$iface" 2>/dev/null | awk '/inet / && !/127.0.0.1/ {print $2}' | head -1)
      fi
      # Fallback: try common interfaces
      if [[ -z "$host_ip" ]]; then
        for iface in en0 en1 en2; do
          host_ip=$(ifconfig "$iface" 2>/dev/null | awk '/inet / {print $2}' | head -1)
          [[ -n "$host_ip" && ! "$host_ip" =~ ^127\. ]] && break
        done
      fi
    else
      # Linux: use ip command
      for interface in eth0 ens3 ens18 enp0s3 wlan0; do
        host_ip=$(ip addr show "$interface" 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1 | head -1)
        [[ -n "$host_ip" && ! "$host_ip" =~ ^127\. && ! "$host_ip" =~ ^${subnet}\. ]] && break
      done
      [[ -z "$host_ip" ]] && host_ip=$(ip route get 8.8.8.8 2>/dev/null | awk '{print $7; exit}')
    fi
    
    [[ -z "$host_ip" ]] && host_ip="YOUR_HOST_IP"
    echo "$host_ip"
  }
fi

cleanup_port_forwarding() {
  local subnet="${NETWORK_SUBNET:-10.10.10}"
  local subnet_regex="${subnet//./\\.}"
  print_info "Cleaning up existing datacenter port forwarding rules"
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

  print_info "Looking for IP address of $vm_name"
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
        print_info "Attempting network scan as last resort"
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
        print_success "$vm_name IP found and reachable: $ip"
        break
      else
        print_warning "$vm_name IP found but not reachable: $ip (attempt $((attempts + 1)))"
        ip=""
      fi
    else
      [ $attempts -eq 0 ] && print_info "Attempt $((attempts + 1)): Waiting for $vm_name to get valid IP address"
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
  print_info "=== DCVM Port Forwarding Setup ==="
  if ! virsh net-list --all | grep -q "$NETWORK_NAME"; then
    print_error "$NETWORK_NAME network not found"
    print_info "Please run: dcvm status (to initialize the environment)"
    exit 1
  fi
  if ! virsh net-list | grep -q "$NETWORK_NAME.*active"; then
    print_warning "$NETWORK_NAME is not active, attempting to start"
    if virsh net-start "$NETWORK_NAME" >/dev/null 2>&1; then
      print_success "$NETWORK_NAME started"
      sleep 3
    else
      print_error "Failed to start $NETWORK_NAME"
      exit 1
    fi
  fi
  echo 1 >/proc/sys/net/ipv4/ip_forward 2>/dev/null || true
  print_info "Discovering VMs on $NETWORK_NAME"
  VM_LIST=$(virsh list --all | grep -E "(running|shut off)" | awk '{print $2}' | grep -v "^$" | while read vm; do [ -n "$vm" ] && is_vm_in_network "$vm" && echo "$vm"; done)
  if [ -z "$VM_LIST" ]; then
    print_warning "No VMs found using $NETWORK_NAME"
    print_info "Create a VM first: dcvm create my-vm"
    exit 0
  fi
  print_success "Found VMs using $NETWORK_NAME:"
  echo "$VM_LIST" | while read vm; do
    local state=$(get_vm_state "$vm")
    echo "  - $vm ($state)"
  done
  echo ""
  cleanup_port_forwarding
  local HOST_IP=$(detect_host_ip)
  print_info "Host IP detected: $HOST_IP"
  local ssh_port=$SSH_PORT_START http_port=$HTTP_PORT_START
  print_info "Configuring port forwarding for discovered VMs"
  local subnet="${NETWORK_SUBNET:-10.10.10}"
  local subnet_regex="${subnet//./\\.}"
  echo "$VM_LIST" | while read vm; do
    [ -z "$vm" ] && continue
    if ! virsh list | grep -q "$vm.*running"; then
      print_warning "Skipping $vm (not running - start it first)"
      continue
    fi
    local vm_ip=$(get_vm_ip_advanced "$vm")
    if [ -n "$vm_ip" ] && [[ $vm_ip =~ ^${subnet_regex}\.[0-9]+$ ]]; then
      setup_vm_forwarding "$vm" "$vm_ip" "$ssh_port" "$http_port" "$HOST_IP"
      ssh_port=$((ssh_port + 1))
      http_port=$((http_port + 1))
    else
      print_warning "Skipping $vm (no valid IP found or not reachable)"
    fi
  done
  iptables -I FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
  save_mappings_tmp_to_file
  if command_exists iptables-save; then
    create_dir_safe /etc/iptables
    iptables-save >/etc/iptables/rules.v4 2>/dev/null && print_success "iptables rules saved to /etc/iptables/rules.v4"
  fi
  echo ""
  print_success "=== Port forwarding configuration complete! ==="
  echo "Host IP: $HOST_IP"
  echo ""
  if [ -f "$DATACENTER_BASE/port-mappings.txt" ]; then
    echo "VM Access Information:"
    read_port_mappings | while read vm ip ssh_port http_port; do
      [ -n "$vm" ] && echo "\n$vm ($ip):" && echo "  SSH:  ssh -p $ssh_port admin@$HOST_IP" && echo "  HTTP: http://$HOST_IP:$http_port"
    done
    echo ""
  else
    print_warning "No VMs were successfully configured"
  fi
  echo ""
  print_info "Note: Make sure your firewall allows the configured ports"
  print_info "To check current mappings anytime: dcvm network ports show"
}

cmd_show() {
  local map_file=$(get_port_mappings_file)
  if [ -f "$map_file" ]; then
    echo "Current port mappings (from $map_file):"
    printf "%-15s  %-15s %-8s  %-8s\n" "VM_NAME" "VM_IP" "SSH" "HTTP"
    echo "------------------------------------------------"
    read_port_mappings | while read vm ip ssh_port http_port; do
      [ -n "$vm" ] && printf "%-15s  %-15s %-8s  %-8s\n" "$vm" "$ip" "$ssh_port" "$http_port"
    done
  else
    print_warning "No saved port mappings file found"
  fi
}

cmd_rules() {
  echo "Active port forwarding rules (iptables):"
  local nat_rules=$(iptables -t nat -L PREROUTING -n --line-numbers | grep -E "(222[0-9]|808[0-9])")
  [ -n "$nat_rules" ] && echo "$nat_rules" || echo "No datacenter port forwarding rules found"
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
    echo "Connectivity test:"
    printf "%-15s: %-4s  %-4s  %-4s\n" "VM_NAME" "Ping" "SSH" "HTTP"
    echo "-------------------------------------"
    read_port_mappings | while read vm ip ssh_port http_port; do
      if [ -n "$vm" ]; then
        ping_status=$(check_ping "$ip" && echo "✓" || echo "✗")
        ssh_status=$(check_port_connectivity "127.0.0.1" "$ssh_port" && echo "✓" || echo "✗")
        http_status=$(check_port_connectivity "127.0.0.1" "$http_port" && echo "✓" || echo "✗")
        printf "%-15s: %-4s  %-4s  %-4s\n" "$vm" "$ping_status" "$ssh_status" "$http_status"
      fi
    done
  else
    print_warning "No port mappings available for testing"
  fi
}

cmd_help() {
  cat <<EOF
DCVM Port Forwarding

Usage: dcvm network ports <command>

Commands:
  setup        Discover VMs and create port forwarding + save mapping
  show         Show saved port mappings table
  rules        Show active port forwarding rules
  apply        Apply saved mappings file to forwarding rules
  clear        Remove existing forwarding rules
  test         Check connectivity for SSH/HTTP against localhost ports
  help         Show this help

Examples:
  dcvm network ports setup
  dcvm network ports show
  dcvm network ports apply
  dcvm network ports clear
  dcvm network ports test
$(if is_macos; then echo "
Note (macOS):
  Port forwarding on macOS is handled via QEMU hostfwd options.
  The 'setup' command shows current mappings from VM configurations.
  Use 'dcvm stop <vm>' and 'dcvm start <vm>' to apply changes."; fi)
EOF
}

main() {
  load_dcvm_config
  
  if is_macos; then
    main_macos "$@"
    return $?
  fi
  
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

main_macos() {
  local subcmd="${1:-help}"
  
  case "$subcmd" in
  setup)
    cmd_setup_macos
    ;;
  show)
    cmd_show_macos
    ;;
  rules)
    cmd_rules_macos
    ;;
  apply)
    print_info "On macOS, port forwarding is configured per-VM via QEMU hostfwd"
    print_info "To change port mappings, edit the VM config and restart the VM"
    ;;
  clear)
    print_info "On macOS, port forwarding is tied to QEMU processes"
    print_info "Stop the VM to release its ports: dcvm stop <vm_name>"
    ;;
  test)
    cmd_test_macos
    ;;
  help | --help | -h) cmd_help ;;
  *)
    print_error "Unknown command: $subcmd"
    echo "Use: dcvm network ports help"
    exit 1
    ;;
  esac
}

cmd_setup_macos() {
  print_info "=== DCVM Port Forwarding Status (macOS) ==="
  echo ""
  
  local vm_registry="$DATACENTER_BASE/config/vms"
  local map_file="$DATACENTER_BASE/port-mappings.txt"
  
  if [[ ! -d "$vm_registry" ]] || [[ -z "$(ls -A "$vm_registry" 2>/dev/null)" ]]; then
    print_warning "No VMs configured"
    print_info "Create a VM first: dcvm create my-vm"
    return 0
  fi
  
  echo "Current VM Port Mappings:"
  printf "%-20s %-10s %-15s %-15s\n" "VM_NAME" "STATUS" "SSH" "HTTP"
  echo "----------------------------------------------------------------"
  
  # Rebuild port-mappings.txt from VM configs
  echo "# VM_NAME VM_IP SSH_PORT HTTP_PORT" > "$map_file"
  
  for vm_conf in "$vm_registry"/*.conf; do
    [[ -e "$vm_conf" ]] || continue
    [[ -f "$vm_conf" ]] || continue
    source "$vm_conf"
    local vm_name
    vm_name=$(basename "$vm_conf" .conf)
    
    local status="stopped"
    local pid_file="$DATACENTER_BASE/run/${vm_name}.pid"
    if [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
      status="running"
    fi
    
    printf "%-20s %-10s localhost:%-4s localhost:%-4s\n" "$vm_name" "$status" "${SSH_PORT:-N/A}" "${HTTP_PORT:-N/A}"
    echo "$vm_name 127.0.0.1 ${SSH_PORT:-2222} ${HTTP_PORT:-8080}" >> "$map_file"
  done
  
  echo ""
  print_success "Port mappings saved to $map_file"
  echo ""
  echo "Access running VMs:"
  for vm_conf in "$vm_registry"/*.conf; do
    [[ -e "$vm_conf" ]] || continue
    [[ -f "$vm_conf" ]] || continue
    source "$vm_conf"
    local vm_name
    vm_name=$(basename "$vm_conf" .conf)
    local pid_file="$DATACENTER_BASE/run/${vm_name}.pid"
    if [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
      echo "  $vm_name:"
      echo "    SSH:  ssh -p ${SSH_PORT:-2222} ${VM_USERNAME:-admin}@localhost"
      echo "    HTTP: http://localhost:${HTTP_PORT:-8080}"
    fi
  done
}

cmd_show_macos() {
  local map_file="$DATACENTER_BASE/port-mappings.txt"
  local vm_registry="$DATACENTER_BASE/config/vms"
  
  echo "Port Mappings (macOS - QEMU hostfwd):"
  printf "%-20s %-15s %-15s\n" "VM_NAME" "SSH" "HTTP"
  echo "----------------------------------------------------"
  
  for vm_conf in "$vm_registry"/*.conf; do
    [[ -e "$vm_conf" ]] || continue
    [[ -f "$vm_conf" ]] || continue
    source "$vm_conf"
    local vm_name
    vm_name=$(basename "$vm_conf" .conf)
    printf "%-20s localhost:%-4s localhost:%-4s\n" "$vm_name" "${SSH_PORT:-N/A}" "${HTTP_PORT:-N/A}"
  done
}

cmd_rules_macos() {
  echo "Active QEMU processes with port forwarding:"
  echo ""
  
  local vm_registry="$DATACENTER_BASE/config/vms"
  for vm_conf in "$vm_registry"/*.conf; do
    [[ -e "$vm_conf" ]] || continue
    [[ -f "$vm_conf" ]] || continue
    source "$vm_conf"
    local vm_name
    vm_name=$(basename "$vm_conf" .conf)
    local pid_file="$DATACENTER_BASE/run/${vm_name}.pid"
    
    if [[ -f "$pid_file" ]]; then
      local pid
      pid=$(cat "$pid_file")
      if kill -0 "$pid" 2>/dev/null; then
        echo "$vm_name (PID: $pid):"
        echo "  SSH:  tcp::${SSH_PORT:-N/A} -> VM:22"
        echo "  HTTP: tcp::${HTTP_PORT:-N/A} -> VM:80"
      fi
    fi
  done
  
  echo ""
  echo "Note: On macOS, port forwarding is done via QEMU -netdev hostfwd option"
}

cmd_test_macos() {
  local vm_registry="$DATACENTER_BASE/config/vms"
  
  echo "Connectivity test (macOS):"
  printf "%-20s %-10s %-10s\n" "VM_NAME" "SSH" "HTTP"
  echo "----------------------------------------"
  
  for vm_conf in "$vm_registry"/*.conf; do
    [[ -e "$vm_conf" ]] || continue
    [[ -f "$vm_conf" ]] || continue
    source "$vm_conf"
    local vm_name
    vm_name=$(basename "$vm_conf" .conf)
    
    local ssh_status="✗"
    local http_status="✗"
    
    if check_port_connectivity "127.0.0.1" "${SSH_PORT:-2222}"; then
      ssh_status="✓"
    fi
    if check_port_connectivity "127.0.0.1" "${HTTP_PORT:-8080}"; then
      http_status="✓"
    fi
    
    printf "%-20s %-10s %-10s\n" "$vm_name" "$ssh_status" "$http_status"
  done
  
  echo ""
  echo "Legend: ✓ = port responding, ✗ = not responding"
}

main "$@"
