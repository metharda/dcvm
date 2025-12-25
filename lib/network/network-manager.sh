#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../utils/common.sh"

print_header() { echo -e "\n=== $1 ===\n"; }

cmd_show() {
  print_header "Network Information"
  echo "Virtual Networks:" && virsh net-list || true
  echo ""
  echo "Datacenter Network Details:" && virsh net-info "$NETWORK_NAME" 2>/dev/null || echo "$NETWORK_NAME not found"

  echo ""
  echo "Active DHCP Leases (via virsh):"
  local dhcp_leases
  dhcp_leases=$(virsh net-dhcp-leases "$NETWORK_NAME" 2>/dev/null || true)
  [ -n "${dhcp_leases:-}" ] && echo "$dhcp_leases" || echo "No active DHCP leases found via virsh"

  echo ""
  echo "Static IP assignments (host-recorded):"
  local static_dir="${DATACENTER_BASE:-/srv/datacenter}/config/network"
  if [ -d "$static_dir" ]; then
    local any=false
    printf "  %-20s %-15s %-25s %-8s\n" "VM_NAME" "IP" "ASSIGNED_AT" "SOURCE"
    echo "---------------------------------------------------------------------------"
    for f in "$static_dir"/*.conf; do
      [ -f "$f" ] || continue
      any=true
      vmname=$(basename "$f" .conf)
      ip=$(awk -F'=' '/^IP=/ {gsub(/"/,"",$2); print $2}' "$f" 2>/dev/null || echo "")
      at=$(awk -F'=' '/^ASSIGNED_AT=/ {gsub(/"/,"",$2); print $2}' "$f" 2>/dev/null || echo "")
      src=$(awk -F'=' '/^SOURCE=/ {gsub(/"/,"",$2); print $2}' "$f" 2>/dev/null || echo "static")
      printf "  %-20s %-15s %-25s %-8s\n" "$vmname" "$ip" "$at" "$src"
    done
    $any || echo "  (no host-recorded static IPs)"
  else
    echo "  (no host-recorded static IPs)"
  fi

  echo ""
  echo "Port mappings (saved):"
  local port_file=$(get_port_mappings_file)
  if [ -f "$port_file" ]; then
    printf "%-15s  %-15s %-8s  %-8s\n" "VM_NAME" "VM_IP" "SSH" "HTTP"
    echo "------------------------------------------------"
    read_port_mappings | while read vm ip ssh_port http_port; do
      [ -n "$vm" ] && printf "%-15s  %-15s %-8s  %-8s\n" "$vm" "$ip" "$ssh_port" "$http_port"
    done
  else
    echo "No saved mappings. Run: dcvm network ports setup"
  fi

  echo ""
  echo "Active port forwarding rules (iptables):"
  local nat_rules
  nat_rules=$(iptables -t nat -L PREROUTING -n --line-numbers | grep -E "(222[0-9]|808[0-9])" || true)
  [ -n "${nat_rules:-}" ] && echo "$nat_rules" || echo "No datacenter port forwarding rules found"

  echo ""
  echo "Connectivity test:"
  printf "%-15s: %-4s  %-4s  %-4s\n" "VM_NAME" "Ping" "SSH" "HTTP"
  echo "-------------------------------------"
  if [ -f "$port_file" ]; then
    read_port_mappings | while read vm ip ssh_port http_port; do
      if [ -n "$vm" ]; then
        local ping_status ssh_status http_status
        ping_status=$(check_ping "$ip" && echo "✓" || echo "✗")
        ssh_status=$(check_port_connectivity "127.0.0.1" "$ssh_port" && echo "✓" || echo "✗")
        http_status=$(check_port_connectivity "127.0.0.1" "$http_port" && echo "✓" || echo "✗")
        printf "%-15s: %-4s  %-4s  %-4s\n" "$vm" "$ping_status" "$ssh_status" "$http_status"
      fi
    done
    echo ""
    echo "Legend: ✓ = accessible, ✗ = not accessible"
  else
    echo "No port mappings available for testing"
  fi
}

cmd_status() {
  print_header "Network Status"
  local is_active is_autostart ipfwd
  is_active=$(virsh net-list | grep -q "^.* $NETWORK_NAME .* active" && echo active || echo inactive)
  is_autostart=$(virsh net-info "$NETWORK_NAME" 2>/dev/null | awk -F": *" '/Autostart/ {print tolower($2)}' || echo unknown)
  ipfwd=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)
  echo "Network: $NETWORK_NAME ($is_active), Autostart: $is_autostart, IP forwarding: $ipfwd"
  echo "Bridge: $BRIDGE_NAME"
  ip addr show "$BRIDGE_NAME" 2>/dev/null | sed 's/^/  /' || echo "  Bridge not found"
}

cmd_start() { virsh net-start "$NETWORK_NAME" && print_success "Started $NETWORK_NAME" || print_error "Failed to start $NETWORK_NAME"; }
cmd_stop() { virsh net-destroy "$NETWORK_NAME" && print_success "Stopped $NETWORK_NAME" || print_error "Failed to stop $NETWORK_NAME"; }
cmd_restart() {
  cmd_stop || true
  sleep 1
  cmd_start
}

cmd_leases() {
  print_header "DHCP Leases"
  virsh net-dhcp-leases "$NETWORK_NAME" 2>/dev/null || echo "No leases found"
  echo ""
  echo "Lease Files:"
  for f in "/var/lib/libvirt/dnsmasq/${BRIDGE_NAME}.leases" "/var/lib/libvirt/dnsmasq/${BRIDGE_NAME}.status"; do
    [ -f "$f" ] && echo "  $f ($(wc -l <"$f") lines)" || echo "  $f (not found)"
  done
}

cmd_bridge() {
  print_header "Bridge Details ($BRIDGE_NAME)"
  ip addr show "$BRIDGE_NAME" 2>/dev/null || echo "Bridge not found"
  echo ""
  echo "Routes:"
  ip route show | sed 's/^/  /'
  echo ""
  echo "dnsmasq:"
  ps aux | grep "dnsmasq.*${BRIDGE_NAME}" | grep -v grep || echo "No dnsmasq process for bridge"
}

cmd_ip_forwarding() {
  local action="${1:-show}"
  case "$action" in
  on | enable)
    echo 1 >/proc/sys/net/ipv4/ip_forward || {
      print_error "Failed to enable ip_forward"
      exit 1
    }
    print_success "Enabled net.ipv4.ip_forward (not persisted)"
    ;;
  off | disable)
    echo 0 >/proc/sys/net/ipv4/ip_forward || {
      print_error "Failed to disable ip_forward"
      exit 1
    }
    print_success "Disabled net.ipv4.ip_forward"
    ;;
  show | *)
    local v=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)
    echo "net.ipv4.ip_forward = $v"
    ;;
  esac
}

cmd_config() {
  print_header "Effective Config"
  echo "DATACENTER_BASE: ${DATACENTER_BASE}"
  echo "NETWORK_NAME:    ${NETWORK_NAME}"
  echo "BRIDGE_NAME:     ${BRIDGE_NAME}"
  echo "HOST_IP:         $(get_host_ip)"
}

cmd_vnc() {
  local action="${1:-}"
  local vm_name="${2:-}"

  if [ -z "$action" ]; then
    print_error "Action required. Usage: dcvm network vnc <enable|disable|status> <vm_name>"
    exit 1
  fi

  if [ -z "$vm_name" ]; then
    print_error "VM name required. Usage: dcvm network vnc <enable|disable|status> <vm_name>"
    exit 1
  fi

  if ! check_vm_exists "$vm_name"; then
    print_error "VM '$vm_name' does not exist"
    return 1
  fi

  case "$action" in
  disable)
    local current_graphics=$(virsh dumpxml "$vm_name" 2>/dev/null | grep -c "<graphics type=")
    if [ "$current_graphics" -eq 0 ]; then
      print_info "VNC is already disabled on '$vm_name'"
      return 0
    fi

    local is_running=$(virsh list | grep -c " $vm_name .*running" || echo 0)
    if [ "$is_running" -gt 0 ]; then
      print_warning "VM '$vm_name' is running. It needs to be stopped to disable VNC."
      if [ -t 0 ]; then
        read -r -p "Stop VM now? (y/N): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
          print_info "Stopping VM..."
          virsh shutdown "$vm_name" >/dev/null 2>&1 || true
          local count=0
          while virsh list | grep -q " $vm_name .*running" && [ $count -lt 30 ]; do
            sleep 2
            count=$((count + 1))
          done
          if virsh list | grep -q " $vm_name .*running"; then
            virsh destroy "$vm_name" >/dev/null 2>&1 || true
          fi
        else
          print_info "Cancelled. Stop VM first, then run this command again."
          return 1
        fi
      else
        print_error "Non-interactive session. Please stop VM '$vm_name' first."
        return 1
      fi
    fi
    
    local tmp_xml
    tmp_xml="$(mktemp /tmp/remove-graphics-XXXXXX.xml)"
    virsh dumpxml "$vm_name" | sed '/<graphics/,/<\/graphics>/d' | sed '/<video>/,/<\/video>/d' > "$tmp_xml"
    
    if virsh define "$tmp_xml" >/dev/null 2>&1; then
      rm -f "$tmp_xml"
      print_success "VNC disabled for '$vm_name'"
      print_info "VNC port is now free. Start VM with: dcvm start $vm_name"
      print_info "Access VM via: virsh console $vm_name"
    else
      rm -f "$tmp_xml"
      print_error "Failed to disable VNC"
      return 1
    fi
    ;;

  enable)
    local current_graphics=$(virsh dumpxml "$vm_name" 2>/dev/null | grep -c "<graphics type=")
    if [ "$current_graphics" -gt 0 ]; then
      print_info "VNC is already enabled on '$vm_name'"
      virsh vncdisplay "$vm_name" 2>/dev/null || true
      return 0
    fi

    local is_running=$(virsh list | grep -c " $vm_name .*running" || echo 0)
    if [ "$is_running" -gt 0 ]; then
      print_warning "VM '$vm_name' is running. It needs to be stopped to enable VNC."
      if [ -t 0 ]; then
        read -r -p "Stop VM now? (y/N): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
          print_info "Stopping VM..."
          virsh shutdown "$vm_name" >/dev/null 2>&1 || true
          local count=0
          while virsh list | grep -q " $vm_name .*running" && [ $count -lt 30 ]; do
            sleep 2
            count=$((count + 1))
          done
          if virsh list | grep -q " $vm_name .*running"; then
            virsh destroy "$vm_name" >/dev/null 2>&1 || true
          fi
        else
          print_info "Cancelled. Stop VM first, then run this command again."
          return 1
        fi
      else
        print_error "Non-interactive session. Please stop VM '$vm_name' first."
        return 1
      fi
    fi
    
    local graphics_xml="<graphics type='vnc' port='-1' autoport='yes' listen='127.0.0.1'><listen type='address' address='127.0.0.1'/></graphics>"
    local video_xml="<video><model type='virtio' heads='1' primary='yes'/></video>"
    
    local tmp_xml
    tmp_xml="$(mktemp /tmp/add-graphics-XXXXXX.xml)"
    virsh dumpxml "$vm_name" >"$tmp_xml"
    sed -i "s|</devices>|  $graphics_xml\n    $video_xml\n  </devices>|" "$tmp_xml"

    if virsh define "$tmp_xml" >/dev/null 2>&1; then
      rm -f "$tmp_xml"
      print_success "VNC enabled for '$vm_name'"
      print_info "Start VM with: dcvm start $vm_name"
      print_info "Then access VNC with: virsh vncdisplay $vm_name"
    else
      rm -f "$tmp_xml"
      print_error "Failed to enable VNC"
      return 1
    fi
    ;;

  status)
    local graphics_info=$(virsh dumpxml "$vm_name" 2>/dev/null | grep "<graphics")
    if [ -n "$graphics_info" ]; then
      print_success "VNC is ENABLED on '$vm_name'"
      local vnc_display=$(virsh vncdisplay "$vm_name" 2>/dev/null || true)
      if [ -n "$vnc_display" ]; then
        echo "  VNC Display: $vnc_display"
        local vnc_port=$((5900 + ${vnc_display#:}))
        echo "  VNC Port: $vnc_port"
        echo "  Connect: vncviewer $(hostname -I | awk '{print $1}'):$vnc_port"
      else
        echo "  (VM is not running, VNC port will be assigned on start)"
      fi
    else
      print_info "VNC is DISABLED on '$vm_name'"
      echo "  Access via: virsh console $vm_name"
    fi
    ;;

  *)
    print_error "Unknown action: $action"
    echo "Usage: dcvm network vnc <enable|disable|status> <vm_name>"
    return 1
    ;;
  esac
}

cmd_help() {
  cat <<EOF
DCVM Network Manager

Usage: dcvm network <subcommand> [options]

Subcommands:
  show                 Show network overview (default)
  status               Show concise network/bridge status
  start|stop|restart   Control the libvirt network: ${NETWORK_NAME:-datacenter}
  leases               List current DHCP leases and files
  bridge               Show bridge details, routes, dnsmasq
  ip-forwarding [on|off|show]
                       Get or toggle net.ipv4.ip_forward
  config               Show effective DCVM network config
  ports <cmd>          Manage port forwarding (setup, show, rules, apply, clear, test)
  dhcp <cmd>           Manage DHCP leases (show, clear-all, clear-vm, cleanup)
  vnc <action> <vm>    VNC management (enable, disable, status)
  help                 Show this help

Examples:
  dcvm network                 # same as 'dcvm network show'
  dcvm network status
  dcvm network start
  dcvm network leases
  dcvm network ip-forwarding on
  dcvm network ports setup
  dcvm network dhcp cleanup
  dcvm network vnc status myvm
  dcvm network vnc disable myvm
EOF
}

main() {
  load_dcvm_config
  require_root
  check_dependencies virsh iptables

  local subcmd="${1:-show}"
  shift || true
  case "$subcmd" in
  show | info) cmd_show "$@" ;;
  status) cmd_status "$@" ;;
  start) cmd_start "$@" ;;
  stop) cmd_stop "$@" ;;
  restart) cmd_restart "$@" ;;
  leases) cmd_leases "$@" ;;
  bridge) cmd_bridge "$@" ;;
  ip-forwarding | ipfwd) cmd_ip_forwarding "${1:-show}" ;;
  config) cmd_config "$@" ;;
  help | -h | --help) cmd_help ;;
  ports | dhcp)
    set +e
    if [ "$subcmd" = "ports" ]; then exec "$SCRIPT_DIR/port-forward.sh" "$@"; else exec "$SCRIPT_DIR/dhcp.sh" "$@"; fi
    ;;
  vnc)
    cmd_vnc "$@"
    ;;
  *)
    print_error "Unknown network subcommand: $subcmd"
    echo "Use: dcvm network help"
    exit 1
    ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
