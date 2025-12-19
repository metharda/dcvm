#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../utils/common.sh"

show_port_status() {
  echo "=== Datacenter VM Port Status ==="
  echo ""

  local port_file=$(get_port_mappings_file)
  if [ -f "$port_file" ]; then
    echo "Current port mappings:"
    printf "%-15s  %-15s %-8s  %-8s\n" "VM_NAME" "VM_IP" "SSH_PORT" "HTTP_PORT"
    echo "------------------------------------------------"
    read_port_mappings | while read vm ip ssh_port http_port; do
      [ -n "$vm" ] && printf "%-15s  %-15s %-8s  %-8s\n" "$vm" "$ip" "$ssh_port" "$http_port"
    done
    echo ""
  else
    print_warning "No port mappings file found"
    print_info "Run: dcvm network ports setup"
    echo ""
  fi

  echo "VM Status:"
  printf "%-15s: %s\n" "VM_NAME" "STATE"
  echo "-------------------------"
  virsh list --all | grep -E "(running|shut off)" | while read line; do
    vm=$(echo "$line" | awk '{print $2}')
    state=$(echo "$line" | awk '{print $3" "$4}' | sed 's/ *$//')
    if [ -n "$vm" ] && [ "$vm" != "Name" ]; then
      if is_vm_in_network "$vm"; then
        printf "%-15s: %s\n" "$vm" "$state"
      fi
    fi
  done
  echo ""

  echo "Active port forwarding rules:"
  nat_rules=$(iptables -t nat -L PREROUTING -n --line-numbers | grep -E "(222[0-9]|808[0-9])")
  if [ -n "$nat_rules" ]; then
    echo "$nat_rules" | while read line; do
      echo "  $line"
    done
  else
    echo "  No datacenter port forwarding rules found"
  fi
  echo ""

  echo "Connectivity test:"
  printf "%-15s: %-4s  %-4s  %-4s\n" "VM_NAME" "Ping" "SSH" "HTTP"
  echo "-------------------------------------"
  if [ -f "$port_file" ]; then
    read_port_mappings | while read vm ip ssh_port http_port; do
      if [ -n "$vm" ]; then
        ping_status=$(check_ping "$ip" && echo "✓" || echo "✗")
        ssh_status=$(check_port_connectivity "127.0.0.1" "$ssh_port" && echo "✓" || echo "✗")
        http_status=$(check_port_connectivity "127.0.0.1" "$http_port" && echo "✓" || echo "✗")
        printf "%-15s: %-4s  %-4s  %-4s\n" "$vm" "$ping_status" "$ssh_status" "$http_status"
      fi
    done
  else
    echo "No port mappings available for testing"
  fi
  echo ""
  echo "Legend: ✓ = accessible, ✗ = not accessible"
}

show_enhanced_console() {
  echo "=== VM Access Information ==="
  echo ""

  local port_file=$(get_port_mappings_file)
  if [ -f "$port_file" ]; then
    echo "SSH Access:"
    read_port_mappings | while read vm ip ssh_port http_port; do
      [ -n "$vm" ] && echo "  ssh $vm" && echo "    or: ssh -p $ssh_port admin@$(get_host_ip)"
    done
    echo ""

    echo "HTTP Access:"
    read_port_mappings | while read vm ip ssh_port http_port; do
      [ -n "$vm" ] && echo "  $vm: http://$(get_host_ip):$http_port"
    done
    echo ""

    echo "Console Access:"
    read_port_mappings | while read vm ip ssh_port http_port; do
      [ -n "$vm" ] && echo "  virsh console $vm  (Press Ctrl+] to exit)"
    done
  else
    print_warning "No port mappings found. Run: dcvm network ports setup"
  fi
  echo ""
  echo "Default login: admin / admin123"
}

start_vms() {
  local target="$1"

  if is_macos; then
    start_vms_macos "$target"
    return $?
  fi

  if [ "$target" = "all" ] || [ -z "$target" ]; then
    echo "Starting all datacenter VMs..."

    stopped_vms=$(virsh list --all | grep -E "shut off" | while read line; do
      vm=$(echo "$line" | awk '{print $2}')
      [ -n "$vm" ] && is_vm_in_network "$vm" && echo "$vm"
    done)

    if [ -n "$stopped_vms" ]; then
      echo "$stopped_vms" | while read vm; do
        [ -n "$vm" ] && echo "Starting $vm..." && virsh start "$vm"
      done
      print_success "VM startup completed"
      print_info "Wait 30-60 seconds, then run: dcvm network ports setup"
    else
      print_info "No stopped VMs found or all VMs already running"
    fi
  else
    if ! check_vm_exists "$target"; then
      print_error "VM '$target' does not exist"
      echo ""
      echo "Available VMs:"
      list_all_vms
      return 1
    fi

    if virsh list | grep -q " $target .*running"; then
      print_info "VM '$target' is already running"
    elif virsh list --all | grep -q " $target .*shut"; then
      echo "Starting VM '$target'..."
      if virsh start "$target"; then
        print_success "VM '$target' started successfully"
        print_info "Wait 30-60 seconds for full boot, then run: dcvm network ports setup"
      else
        print_error "Failed to start VM '$target'"
      fi
    else
      print_warning "VM '$target' is in unknown state"
    fi
  fi
}

start_vms_macos() {
  local target="$1"
  local vm_registry="$DATACENTER_BASE/config/vms"
  
  if [ "$target" = "all" ] || [ -z "$target" ]; then
    echo "Starting all datacenter VMs..."
    local started=0
    
    for vm_conf in "$vm_registry"/*.conf; do
      [[ -e "$vm_conf" ]] || continue
      [[ -f "$vm_conf" ]] || continue
      local vm_name
      vm_name=$(basename "$vm_conf" .conf)
      
      if ! is_vm_running_macos "$vm_name"; then
        echo "Starting $vm_name..."
        if start_single_vm_macos "$vm_name"; then
          started=$((started + 1))
        fi
      else
        print_info "$vm_name is already running"
      fi
    done
    
    if [ $started -gt 0 ]; then
      print_success "Started $started VM(s)"
    else
      print_info "No stopped VMs found or all VMs already running"
    fi
  else
    local vm_conf="$vm_registry/${target}.conf"
    if [[ ! -f "$vm_conf" ]]; then
      print_error "VM '$target' does not exist"
      echo ""
      echo "Available VMs:"
      list_vms_macos
      return 1
    fi
    
    if is_vm_running_macos "$target"; then
      print_info "VM '$target' is already running"
    else
      echo "Starting VM '$target'..."
      if start_single_vm_macos "$target"; then
        print_success "VM '$target' started successfully"
      else
        print_error "Failed to start VM '$target'"
      fi
    fi
  fi
}

is_vm_running_macos() {
  local vm_name="$1"
  local pid_file="$DATACENTER_BASE/run/${vm_name}.pid"
  
  if [[ -f "$pid_file" ]]; then
    local pid
    pid=$(cat "$pid_file")
    if kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
  fi
  return 1
}

start_single_vm_macos() {
  local vm_name="$1"
  local vm_conf="$DATACENTER_BASE/config/vms/${vm_name}.conf"
  
  [[ -f "$vm_conf" ]] || return 1
  source "$vm_conf"
  
  local arch
  arch=$(uname -m)
  local qemu_binary
  local accel
  local machine_type
  
  if [[ "$arch" == "arm64" ]]; then
    qemu_binary="qemu-system-aarch64"
    accel="hvf"
    machine_type="virt"
  else
    qemu_binary="qemu-system-x86_64"
    if sysctl -n kern.hv_support 2>/dev/null | grep -q "1"; then
      accel="hvf"
    else
      accel="tcg"
    fi
    machine_type="q35"
  fi
  
  local vm_dir="$DATACENTER_BASE/vms/$vm_name"
  local pid_file="$DATACENTER_BASE/run/${vm_name}.pid"
  local log_file="$DATACENTER_BASE/logs/${vm_name}.log"
  local monitor_socket="$DATACENTER_BASE/run/${vm_name}.monitor"
  
  # Build QEMU command
  local qemu_cmd=(
    "$qemu_binary"
    -name "$vm_name"
    -machine "$machine_type,accel=$accel"
    -cpu host
    -m "${VM_MEMORY:-2048}"
    -smp "${VM_CPUS:-2}"
    -drive "file=${DISK_PATH},format=qcow2,if=virtio"
    -netdev "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22,hostfwd=tcp::${HTTP_PORT}-:80"
    -device "virtio-net-pci,netdev=net0"
    -display none
    -daemonize
    -pidfile "$pid_file"
    -monitor "unix:$monitor_socket,server,nowait"
    -serial "file:$log_file"
  )
  
  # For ARM64, add UEFI firmware
  if [[ "$arch" == "arm64" ]]; then
    local efi_code="/opt/homebrew/share/qemu/edk2-aarch64-code.fd"
    local efi_vars="$vm_dir/efi-vars.fd"
    if [[ -f "$efi_code" ]] && [[ -f "$efi_vars" ]]; then
      qemu_cmd+=(-drive "if=pflash,format=raw,file=$efi_code,readonly=on")
      qemu_cmd+=(-drive "if=pflash,format=raw,file=$efi_vars")
    fi
  fi
  
  "${qemu_cmd[@]}" 2>>"$log_file"
}

list_vms_macos() {
  local vm_registry="$DATACENTER_BASE/config/vms"
  
  if [[ ! -d "$vm_registry" ]] || [[ -z "$(ls -A "$vm_registry" 2>/dev/null)" ]]; then
    echo "  (No VMs registered)"
    return
  fi
  
  for vm_conf in "$vm_registry"/*.conf; do
    [[ -e "$vm_conf" ]] || continue
    [[ -f "$vm_conf" ]] || continue
    local vm_name
    vm_name=$(basename "$vm_conf" .conf)
    if is_vm_running_macos "$vm_name"; then
      echo "  $vm_name: running"
    else
      echo "  $vm_name: stopped"
    fi
  done
}

stop_vms() {
  local target="$1"

  if is_macos; then
    stop_vms_macos "$target"
    return $?
  fi

  if [ "$target" = "all" ] || [ -z "$target" ]; then
    echo "Stopping all datacenter VMs..."

    running_vms=$(virsh list | grep -E "running" | while read line; do
      vm=$(echo "$line" | awk '{print $2}')
      [ -n "$vm" ] && is_vm_in_network "$vm" && echo "$vm"
    done)

    if [ -n "$running_vms" ]; then
      echo "$running_vms" | while read vm; do
        [ -n "$vm" ] && echo "Stopping $vm..." && virsh shutdown "$vm"
      done
      print_success "Shutdown initiated for all VMs"
    else
      print_info "No running VMs found"
    fi
  else
    if ! check_vm_exists "$target"; then
      print_error "VM '$target' does not exist"
      echo ""
      echo "Available VMs:"
      list_all_vms
      return 1
    fi

    if virsh list | grep -q " $target .*running"; then
      echo "Stopping VM '$target'..."
      if virsh shutdown "$target"; then
        print_success "Shutdown initiated for VM '$target'"
      else
        print_error "Failed to stop VM '$target'"
      fi
    else
      print_info "VM '$target' is not running"
    fi
  fi
}

stop_vms_macos() {
  local target="$1"
  local vm_registry="$DATACENTER_BASE/config/vms"
  
  if [ "$target" = "all" ] || [ -z "$target" ]; then
    echo "Stopping all datacenter VMs..."
    local stopped=0
    
    for vm_conf in "$vm_registry"/*.conf; do
      [[ -e "$vm_conf" ]] || continue
      [[ -f "$vm_conf" ]] || continue
      local vm_name
      vm_name=$(basename "$vm_conf" .conf)
      
      if is_vm_running_macos "$vm_name"; then
        echo "Stopping $vm_name..."
        if stop_single_vm_macos "$vm_name"; then
          stopped=$((stopped + 1))
        fi
      fi
    done
    
    if [ $stopped -gt 0 ]; then
      print_success "Stopped $stopped VM(s)"
    else
      print_info "No running VMs found"
    fi
  else
    local vm_conf="$vm_registry/${target}.conf"
    if [[ ! -f "$vm_conf" ]]; then
      print_error "VM '$target' does not exist"
      echo ""
      echo "Available VMs:"
      list_vms_macos
      return 1
    fi
    
    if is_vm_running_macos "$target"; then
      echo "Stopping VM '$target'..."
      if stop_single_vm_macos "$target"; then
        print_success "VM '$target' stopped"
      else
        print_error "Failed to stop VM '$target'"
      fi
    else
      print_info "VM '$target' is not running"
    fi
  fi
}

stop_single_vm_macos() {
  local vm_name="$1"
  local pid_file="$DATACENTER_BASE/run/${vm_name}.pid"
  local monitor_socket="$DATACENTER_BASE/run/${vm_name}.monitor"
  
  # Try graceful shutdown via QEMU monitor first
  if [[ -S "$monitor_socket" ]]; then
    echo "system_powerdown" | nc -U "$monitor_socket" >/dev/null 2>&1
    sleep 5
  fi
  
  # Check if still running
  if [[ -f "$pid_file" ]]; then
    local pid
    pid=$(cat "$pid_file")
    if kill -0 "$pid" 2>/dev/null; then
      # Force kill if still running
      kill "$pid" 2>/dev/null
      sleep 2
      kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$pid_file"
  fi
  
  return 0
}

restart_vms() {
  local target="$1"

  if [ "$target" = "all" ] || [ -z "$target" ]; then
    echo "Restarting all datacenter VMs..."

    all_vms=$(virsh list --all | grep -E "(running|shut off)" | while read line; do
      vm=$(echo "$line" | awk '{print $2}')
      if [ -n "$vm" ] && [ "$vm" != "Name" ] && is_vm_in_network "$vm"; then
        state=$(echo "$line" | awk '{print $3}')
        echo "$vm:$state"
      fi
    done)

    if [ -n "$all_vms" ]; then
      echo "$all_vms" | while read vm_info; do
        vm=$(echo "$vm_info" | cut -d':' -f1)
        state=$(echo "$vm_info" | cut -d':' -f2)
        if [ -n "$vm" ]; then
          if [ "$state" = "running" ]; then
            echo "Restarting $vm..."
            virsh reboot "$vm"
          else
            echo "Starting $vm..."
            virsh start "$vm"
          fi
        fi
      done
      print_success "Restart completed"
      print_info "Wait 30-60 seconds, then run: dcvm network ports setup"
    else
      print_info "No VMs found"
    fi
  else
    if ! check_vm_exists "$target"; then
      print_error "VM '$target' does not exist"
      echo ""
      echo "Available VMs:"
      list_all_vms
      return 1
    fi

    if virsh list | grep -q " $target .*running"; then
      echo "Restarting VM '$target'..."
      if virsh reboot "$target"; then
        print_success "Restart initiated for VM '$target'"
      else
        print_error "Failed to restart VM '$target'"
      fi
    elif virsh list --all | grep -q " $target .*shut"; then
      echo "VM '$target' is stopped, starting it..."
      if virsh start "$target"; then
        print_success "VM '$target' started"
      else
        print_error "Failed to start VM '$target'"
      fi
    else
      print_warning "VM '$target' is in unknown state"
    fi

    print_info "Wait 30-60 seconds for full boot, then run: dcvm network ports setup"
  fi
}

show_enhanced_status() {
  echo "=== Enhanced VM Status ==="
  echo ""
  
  if is_macos; then
    show_enhanced_status_macos
    return
  fi
  
  echo "All VMs:"
  virsh list --all
  echo ""

  echo "Port forwarding status:"
  port_rules=$(iptables -t nat -L PREROUTING -n --line-numbers | grep -E "(222[0-9]|808[0-9])")
  [ -n "$port_rules" ] && echo "$port_rules" || echo "No datacenter port forwarding rules found"
  echo ""

  echo "Network status:"
  virsh net-list
  echo ""

  echo "VM IP addresses:"
  virsh list --all | grep -E "(running|shut off)" | while read line; do
    vm=$(echo "$line" | awk '{print $2}')
    if [ -n "$vm" ] && [ "$vm" != "Name" ] && is_vm_in_network "$vm"; then
      ip=$(get_vm_ip "$vm")
      [ -n "$ip" ] && printf "%-15s: %s\n" "$vm" "$ip" || printf "%-15s: IP not available\n" "$vm"
    fi
  done
}

show_enhanced_status_macos() {
  local vm_registry="$DATACENTER_BASE/config/vms"
  
  echo "Registered VMs:"
  printf "%-20s %-10s %-10s %-10s\n" "VM_NAME" "STATUS" "SSH_PORT" "HTTP_PORT"
  echo "--------------------------------------------------------"
  
  for vm_conf in "$vm_registry"/*.conf; do
    [[ -e "$vm_conf" ]] || continue
    [[ -f "$vm_conf" ]] || continue
    source "$vm_conf"
    local vm_name
    vm_name=$(basename "$vm_conf" .conf)
    local status="stopped"
    is_vm_running_macos "$vm_name" && status="running"
    printf "%-20s %-10s %-10s %-10s\n" "$vm_name" "$status" "${SSH_PORT:-N/A}" "${HTTP_PORT:-N/A}"
  done
  
  echo ""
  echo "Port Mappings:"
  local map_file="$DATACENTER_BASE/port-mappings.txt"
  if [[ -f "$map_file" ]]; then
    cat "$map_file" | grep -v "^#" | while read vm ip ssh_port http_port; do
      [[ -n "$vm" ]] || continue
      [[ -f "$vm_registry/${vm}.conf" ]] || continue
      echo "  $vm: SSH=localhost:$ssh_port HTTP=localhost:$http_port"
    done
  else
    echo "  No port mappings configured"
  fi
  
  echo ""
  echo "Quick Access:"
  for vm_conf in "$vm_registry"/*.conf; do
    [[ -e "$vm_conf" ]] || continue
    [[ -f "$vm_conf" ]] || continue
    source "$vm_conf"
    local vm_name
    vm_name=$(basename "$vm_conf" .conf)
    if is_vm_running_macos "$vm_name"; then
      echo "  $vm_name: ssh -p ${SSH_PORT:-2222} ${VM_USERNAME:-admin}@localhost"
    fi
  done
}

main() {
  load_dcvm_config

  case $1 in
  "start")
    start_vms "$2"
    ;;
  "stop")
    stop_vms "$2"
    ;;
  "restart")
    restart_vms "$2"
    ;;
  "create")
    [ -z "$2" ] && print_error "VM name required. Usage: dcvm create <vm_name>" && exit 1
    shift
    "$SCRIPTS_PATH/create-vm.sh" "$@"
    ;;
  "delete")
    [ -z "$2" ] && print_error "VM name required. Usage: dcvm delete <vm_name>" && exit 1
    "$SCRIPTS_PATH/delete-vm.sh" "$2"
    ;;
  "backup")
    [ -z "$2" ] && print_error "Backup action required. Usage: dcvm backup {create|restore|list|delete|export|import|troubleshoot}" && exit 1
    shift
    "$SCRIPTS_PATH/backup.sh" "$@"
    ;;
  "status")
    show_enhanced_status
    ;;
  "ports")
    show_port_status
    ;;
  "console")
    show_enhanced_console
    ;;
  "list")
    echo "Available VMs:"
    if is_macos; then
      list_vms_macos
    else
      virsh list --all
      echo ""
      echo "VMs using $NETWORK_NAME:"
      list_datacenter_vms
    fi
    ;;
  "setup-forwarding")
    echo "Setting up port forwarding... (deprecated: use 'dcvm network ports setup')"
    "$SCRIPTS_PATH/../network/port-forward.sh" setup
    ;;
  "network")
    if is_macos; then
      show_network_info_macos
    else
      echo "=== Network Information ==="
      echo ""
      echo "Virtual Networks:"
      virsh net-list
      echo ""
      echo "Datacenter Network Details:"
      virsh net-info "$NETWORK_NAME" 2>/dev/null || echo "$NETWORK_NAME not found"
      echo ""
      echo "=== ALL DHCP LEASES ==="
      echo ""
      echo "Active DHCP Leases (via virsh):"
      dhcp_leases=$(virsh net-dhcp-leases "$NETWORK_NAME" 2>/dev/null)
      [ -n "$dhcp_leases" ] && echo "$dhcp_leases" || echo "No active DHCP leases found via virsh"
      echo ""
      echo "Raw DHCP Lease Files:"
      if [ -f /var/lib/libvirt/dnsmasq/${BRIDGE_NAME}.leases ]; then
        lease_count=$(wc -l </var/lib/libvirt/dnsmasq/${BRIDGE_NAME}.leases)
        echo "Lease file entries: $lease_count"
        if [ "$lease_count" -gt 0 ]; then
          echo "Raw lease file content:"
          cat /var/lib/libvirt/dnsmasq/${BRIDGE_NAME}.leases | while read line; do
            echo "  $line"
          done
        else
          echo "Lease file is empty"
        fi
      else
        echo "Lease file not found: /var/lib/libvirt/dnsmasq/virbr-dc.leases"
      fi
      echo ""
      if [ -f /var/lib/libvirt/dnsmasq/virbr-dc.status ]; then
        status_count=$(wc -l </var/lib/libvirt/dnsmasq/virbr-dc.status)
        echo "Status file entries: $status_count"
        if [ "$status_count" -gt 0 ]; then
          echo "Status file content:"
          cat /var/lib/libvirt/dnsmasq/virbr-dc.status | while read line; do
            echo "  $line"
          done
        else
          echo "Status file is empty"
        fi
      else
        echo "Status file not found: /var/lib/libvirt/dnsmasq/virbr-dc.status"
      fi
      echo ""
      echo "Additional DHCP lease locations:"
      for lease_file in /var/lib/dhcp/dhcpd.leases /var/lib/libvirt/dnsmasq/*.leases; do
        if [ -f "$lease_file" ]; then
          echo "Found: $lease_file"
          [ -s "$lease_file" ] && echo "  (Contains data - $(wc -l <"$lease_file") lines)" || echo "  (Empty file)"
        fi
      done
    fi
    ;;
  "clear-leases")
    if is_macos; then
      print_info "macOS uses QEMU user-mode networking - no DHCP leases to clear"
    else
      "$SCRIPTS_PATH/../network/dhcp.sh" clear-all
    fi
    ;;
  "uninstall")
    require_confirmation "This will completely remove all Datacenter VM files, VMs, networks, and this script."
    "$SCRIPTS_PATH/uninstall-dcvm.sh"
    ;;
  *)
    print_error "Unknown command: $1"
    print_info "Run 'dcvm' without arguments for help"
    exit 1
    ;;
  esac
}

show_network_info_macos() {
  echo "=== Network Information (macOS) ==="
  echo ""
  echo "Network Mode: QEMU User-Mode Networking"
  echo ""
  echo "How it works:"
  echo "  - Each VM has its own isolated network stack"
  echo "  - Port forwarding is done via QEMU hostfwd"
  echo "  - Guest sees 10.0.2.x network internally"
  echo "  - Host accesses VM via localhost:<port>"
  echo ""
  echo "Port Mappings:"
  local map_file="$DATACENTER_BASE/port-mappings.txt"
  if [[ -f "$map_file" ]]; then
    printf "  %-15s %-12s %-12s\n" "VM_NAME" "SSH" "HTTP"
    echo "  -----------------------------------------"
    cat "$map_file" | grep -v "^#" | while read vm ip ssh_port http_port; do
      [[ -n "$vm" ]] && printf "  %-15s localhost:%-4s localhost:%-4s\n" "$vm" "$ssh_port" "$http_port"
    done
  else
    echo "  No port mappings configured"
  fi
  echo ""
  echo "To access VMs:"
  local vm_registry="$DATACENTER_BASE/config/vms"
  for vm_conf in "$vm_registry"/*.conf; do
    [[ -e "$vm_conf" ]] || continue
    [[ -f "$vm_conf" ]] || continue
    source "$vm_conf"
    local vm_name
    vm_name=$(basename "$vm_conf" .conf)
    echo "  $vm_name:"
    echo "    SSH:  ssh -p ${SSH_PORT:-2222} ${VM_USERNAME:-admin}@localhost"
    echo "    HTTP: http://localhost:${HTTP_PORT:-8080}"
  done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
