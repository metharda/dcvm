#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../utils/common.sh"

network_state() {
  virsh net-list 2>/dev/null | grep -q " $NETWORK_NAME .*active" && echo active || echo inactive
}

network_kv() {
  local subnet="${NETWORK_SUBNET:-10.10.10}" autostart fwd
  autostart=$(virsh net-info "$NETWORK_NAME" 2>/dev/null | awk -F': *' '/^Autostart/ { print tolower($2) }')
  fwd=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)
  ui_kv "Subnet" "$subnet.0/24, gateway $subnet.1, DHCP $subnet.10-$subnet.200" \
    "Bridge" "$BRIDGE_NAME$(ip -br link show "$BRIDGE_NAME" >/dev/null 2>&1 || echo " (missing)")" \
    "Autostart" "${autostart:-unknown}" \
    "Forwarding" "$([ "$fwd" = 1 ] && echo on || echo "off (dcvm network ip-forwarding on)")"
}

network_title() {
  local state
  state=$(network_state)
  if ! virsh net-info "$NETWORK_NAME" >/dev/null 2>&1; then
    ui_title "Network" "$NETWORK_NAME not found"
    print_error "$NETWORK_NAME does not exist; re-run the installer with --network-only"
    return 1
  fi
  ui_title "Network" "$NETWORK_NAME ${SYM_DOT} $([ "$state" = active ] && echo "${SYM_RUN} active" || echo "${SYM_STOP} inactive")"
}

cmd_show() {
  network_title || return 1
  network_kv

  ui_section "DHCP leases"
  leases_table

  local static_dir="${DATACENTER_BASE:-/srv/datacenter}/config/network" f rows=""
  for f in "$static_dir"/*.conf; do
    [ -f "$f" ] || continue
    rows+=$(awk -F= -v vm="$(basename "$f" .conf)" '{ gsub(/"/, "", $2); v[$1] = $2 } END { printf "%s\t%s\t%s\t%s\n", vm, v["IP"], v["ASSIGNED_AT"], (v["SOURCE"] ? v["SOURCE"] : "static") }' "$f")$'\n'
  done
  ui_section "Static IPs"
  if [ -n "$rows" ]; then
    printf 'VM\tIP\tASSIGNED\tSOURCE\n%s' "$rows" | ui_table
  else
    echo -e "  ${DIM}none${NC}"
  fi

  local port_file rules
  port_file=$(get_port_mappings_file)
  rules=$(iptables -t nat -S PREROUTING 2>/dev/null | grep -cE -- '--dport (22[2-9][0-9]|8[01][0-9][0-9]) .*-j DNAT' || true)
  ui_section "Port forwards" "$([ "$rules" -gt 0 ] && echo "$(plural "$rules" "DNAT rule") active")"
  if [ -f "$port_file" ] && [ -n "$(read_port_mappings)" ]; then
    {
      printf 'VM\tIP\tSSH PORT\tHTTP PORT\tPING\tSSH\tHTTP\n'
      read_port_mappings | while read -r vm ip ssh_port http_port; do
        [ -n "$vm" ] || continue
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$vm" "$ip" "$ssh_port" "$http_port" \
          "$(check_ping "$ip" && echo "$SYM_OK" || echo "$SYM_FAIL")" \
          "$(check_port_forward "$ssh_port" "$ip" 22 && echo "$SYM_OK" || echo "$SYM_FAIL")" \
          "$(check_port_forward "$http_port" "$ip" 80 && echo "$SYM_OK" || echo "$SYM_FAIL")"
      done
    } | ui_table
    echo -e "  ${DIM}$SYM_OK rules in place and the VM port answers ${SYM_DOT} saved in $port_file${NC}"
  else
    echo -e "  ${DIM}none (dcvm network ports setup)${NC}"
  fi
  echo ""
}

cmd_status() {
  network_title || return 1
  network_kv
  local addr
  addr=$(ip -br addr show "$BRIDGE_NAME" 2>/dev/null | awk '{ $1 = ""; $2 = ""; sub(/^ +/, ""); print }')
  ui_kv "Address" "${addr:-none}"
  echo ""
}

cmd_start() {
  if virsh net-start "$NETWORK_NAME" >/dev/null 2>&1; then
    ui_done ok "$NETWORK_NAME started"
  else
    ui_done fail "$NETWORK_NAME did not start" "$(network_state)"
    return 1
  fi
  echo ""
}
cmd_stop() {
  if virsh net-destroy "$NETWORK_NAME" >/dev/null 2>&1; then
    ui_done ok "$NETWORK_NAME stopped" "VMs on it have no network until it starts again"
  else
    ui_done fail "$NETWORK_NAME did not stop" "$(network_state)"
    return 1
  fi
  echo ""
}
cmd_restart() {
  virsh net-destroy "$NETWORK_NAME" >/dev/null 2>&1 || true
  sleep 1
  if virsh net-start "$NETWORK_NAME" >/dev/null 2>&1; then
    ui_done ok "$NETWORK_NAME restarted" "running VMs reconnect on their next DHCP renewal"
  else
    ui_done fail "$NETWORK_NAME did not start again" "dcvm network start"
    return 1
  fi
  echo ""
}

cmd_leases() {
  ui_title "DHCP leases" "$NETWORK_NAME"
  leases_table
  ui_section "Lease files"
  local f
  for f in "/var/lib/libvirt/dnsmasq/${BRIDGE_NAME}.leases" "/var/lib/libvirt/dnsmasq/${BRIDGE_NAME}.status"; do
    ui_kv "${f##*.}" "$f $([ -f "$f" ] && echo "($(wc -l <"$f") lines)" || echo "(not found)")"
  done
  echo ""
}

cmd_bridge() {
  ui_title "Bridge" "$BRIDGE_NAME"
  local addr pid
  addr=$(ip -br addr show "$BRIDGE_NAME" 2>/dev/null | awk '{ $1 = ""; sub(/^ +/, ""); print }')
  pid=$(pgrep -f "dnsmasq.*/${NETWORK_NAME}.conf" | head -1 || true)
  ui_kv "Address" "${addr:-bridge not found}" "dnsmasq" "${pid:+running, pid $pid}${pid:-not running}"
  ui_section "Routes"
  ip route show | sed 's/^/  /'
  echo ""
}

cmd_ip_forwarding() {
  local action="${1:-show}"
  case "$action" in
  on | enable)
    echo 1 >/proc/sys/net/ipv4/ip_forward || {
      print_error "Failed to enable ip_forward"
      exit 1
    }
    ui_done ok "IP forwarding on" "until reboot; the installer persists it in /etc/sysctl.conf"
    ;;
  off | disable)
    echo 0 >/proc/sys/net/ipv4/ip_forward || {
      print_error "Failed to disable ip_forward"
      exit 1
    }
    ui_done warn "IP forwarding off" "VMs lose internet access and port forwards stop working"
    ;;
  show | *)
    local v
    v=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)
    echo ""
    ui_kv "Forwarding" "$([ "$v" = 1 ] && echo on || echo off) (net.ipv4.ip_forward = $v)"
    ;;
  esac
  echo ""
}

cmd_config() {
  ui_title "Configuration" "/etc/dcvm-install.conf"
  ui_kv "Base" "$DATACENTER_BASE" "Network" "$NETWORK_NAME" "Bridge" "$BRIDGE_NAME" \
    "Subnet" "${NETWORK_SUBNET:-10.10.10}.0/24" "Host IP" "$(get_host_ip)"
  echo ""
}

# Stops a running VM before its graphics are changed (asks first).
stop_for_vnc_change() {
  local vm_name="$1" confirm count=0
  virsh list | grep -q " $vm_name .*running" || return 0
  if [ ! -t 0 ]; then
    print_error "$vm_name is running; stop it first (dcvm stop $vm_name)"
    return 1
  fi
  confirm_action "$vm_name is running and has to stop for this. Stop it now?" || return 1
  virsh shutdown "$vm_name" >/dev/null 2>&1 || true
  while virsh list | grep -q " $vm_name .*running" && [ $count -lt 30 ]; do
    sleep 2
    count=$((count + 1))
  done
  virsh list | grep -q " $vm_name .*running" && virsh destroy "$vm_name" >/dev/null 2>&1
  ui_step ok "Stopped" "$vm_name"
}

cmd_vnc() {
  local action="${1:-}"
  local vm_name="${2:-}"

  if [ -z "$action" ] || [ -z "$vm_name" ]; then
    print_error "Usage: dcvm network vnc <enable|disable|status> <vm_name>"
    exit 1
  fi

  if ! check_vm_exists "$vm_name"; then
    print_error "VM '$vm_name' does not exist"
    return 1
  fi

  local has_vnc tmp_xml
  has_vnc=$(virsh dumpxml "$vm_name" 2>/dev/null | grep -c "<graphics type=" || true)
  case "$action" in
  disable)
    if [ "$has_vnc" -eq 0 ]; then
      ui_done ok "VNC is already off on $vm_name"
      echo ""
      return 0
    fi
    echo ""
    stop_for_vnc_change "$vm_name" || return 1
    tmp_xml="$(mktemp /tmp/remove-graphics-XXXXXX.xml)"
    virsh dumpxml "$vm_name" | sed '/<graphics/,/<\/graphics>/d' | sed '/<video>/,/<\/video>/d' >"$tmp_xml"
    if virsh define "$tmp_xml" >/dev/null 2>&1; then
      rm -f "$tmp_xml"
      ui_done ok "VNC off on $vm_name" "its VNC port is free"
      ui_next "dcvm start $vm_name" "start it again" "dcvm console $vm_name" "serial console"
    else
      rm -f "$tmp_xml"
      print_error "Failed to disable VNC"
      return 1
    fi
    ;;

  enable)
    if [ "$has_vnc" -gt 0 ]; then
      ui_done ok "VNC is already on on $vm_name" "$(virsh vncdisplay "$vm_name" 2>/dev/null || echo "display assigned on start")"
      echo ""
      return 0
    fi
    echo ""
    stop_for_vnc_change "$vm_name" || return 1
    local graphics_xml="<graphics type='vnc' port='-1' autoport='yes' listen='127.0.0.1'><listen type='address' address='127.0.0.1'/></graphics>"
    local video_xml="<video><model type='virtio' heads='1' primary='yes'/></video>"
    tmp_xml="$(mktemp /tmp/add-graphics-XXXXXX.xml)"
    virsh dumpxml "$vm_name" >"$tmp_xml"
    sed -i "s|</devices>|  $graphics_xml\n    $video_xml\n  </devices>|" "$tmp_xml"
    if virsh define "$tmp_xml" >/dev/null 2>&1; then
      rm -f "$tmp_xml"
      ui_done ok "VNC on for $vm_name" "listens on 127.0.0.1 of this host"
      ui_next "dcvm start $vm_name" "start it" "dcvm network vnc status $vm_name" "its VNC port, once running"
    else
      rm -f "$tmp_xml"
      print_error "Failed to enable VNC"
      return 1
    fi
    ;;

  status)
    ui_title "VNC" "$vm_name"
    if [ "$has_vnc" -gt 0 ]; then
      local vnc_display
      vnc_display=$(virsh vncdisplay "$vm_name" 2>/dev/null || true)
      if [[ "$vnc_display" =~ :([0-9]+)$ ]]; then
        local vnc_port=$((5900 + BASH_REMATCH[1]))
        ui_kv "VNC" "on, display $vnc_display, port $vnc_port"
        ui_next "ssh -L $vnc_port:127.0.0.1:$vnc_port root@<host>" "then point a VNC viewer at localhost:$vnc_port"
      else
        ui_kv "VNC" "on; the port is assigned when the VM starts"
        echo ""
      fi
    else
      ui_kv "VNC" "off" "Console" "dcvm console $vm_name"
      echo ""
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
  ui_help <<EOF
dcvm network - the libvirt network, DHCP and port forwards

Usage: dcvm network [command]

Commands:
  show                    Overview: network, leases, static IPs, port forwards (default)
  status                  Network state, bridge and address
  start | stop | restart  Control ${NETWORK_NAME:-datacenter-net}
  leases                  DHCP leases and lease files
  bridge                  Bridge address, dnsmasq and routes
  ip-forwarding [on|off]  Show or set net.ipv4.ip_forward
  config                  Settings from /etc/dcvm-install.conf
  ports <command>         Port forwarding (dcvm network ports help)
  dhcp <command>          DHCP leases (dcvm network dhcp help)
  vnc <action> <vm>       VNC on a VM: enable, disable, status

Examples:
  dcvm network
  dcvm network ports setup
  dcvm network vnc status web
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
