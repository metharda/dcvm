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

stop_vms() {
  local target="$1"

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
    virsh list --all
    echo ""
    echo "VMs using $NETWORK_NAME:"
    list_datacenter_vms
    ;;
  "setup-forwarding")
    echo "Setting up port forwarding... (deprecated: use 'dcvm network ports setup')"
    "$SCRIPTS_PATH/../network/port-forward.sh" setup
    ;;
  "network")
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
    ;;
  "clear-leases")
    "$SCRIPTS_PATH/../network/dhcp.sh" clear-all
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

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
