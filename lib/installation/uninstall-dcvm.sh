#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../utils/common.sh"

CONFIG_FILE="/etc/dcvm-install.conf"

vm_on_network() {
  virsh domiflist "$1" 2>/dev/null | awk -v n="$2" 'NR > 2 && $3 == n { f = 1 } END { exit !f }'
}

# rm -rf runs on a path from a config file: only a folder with dcvm's layout.
removable_data_dir() {
  local base
  base=$(realpath -m -- "$1" 2>/dev/null) || return 1
  [[ "$base" == /?* ]] || return 1
  case " / /bin /boot /dev /etc /home /lib /lib64 /media /mnt /opt /proc /root /run /sbin /srv /sys /tmp /usr /usr/local /var /var/lib " in
  *" $base "*) return 1 ;;
  esac
  [ -d "$base/vms" ] && [ -d "$base/storage" ] && echo "$base"
}

domains_using_dir() {
  local vm used=()
  for vm in $(virsh list --all --name 2>/dev/null); do
    virsh domblklist "$vm" --details 2>/dev/null | awk -v d="${1%/}/" 'index($4, d) == 1 { f = 1 } END { exit !f }' && used+=("$vm")
  done
  echo "${used[*]}"
}

main() {
  if [ "${1:-}" = --help ]; then
    echo "Usage: dcvm uninstall     Delete every dcvm VM, all backups, the network, the services and dcvm itself (asks first)"
    exit 0
  fi
  require_root
  if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
  else
    print_warning "$CONFIG_FILE not found; using the default paths"
    DATACENTER_BASE="/srv/datacenter"
    NETWORK_NAME="datacenter-net"
    BRIDGE_NAME="virbr-dc"
    NETWORK_SUBNET="10.10.10"
  fi

  ui_title "Uninstall dcvm" "VMs, network, $DATACENTER_BASE, the command and its settings"
  require_confirmation "Deletes every dcvm VM with its disk, all backups in $DATACENTER_BASE, the network and dcvm itself."
  echo ""

  systemctl disable --now datacenter-storage.timer dcvm-boot.service dcvm.socket dcvm-reaper.timer 2>/dev/null || true
  rm -f $DCVM_UNITS /etc/sysctl.d/90-dcvm.conf
  systemctl daemon-reload 2>/dev/null || true
  groupdel "$DCVM_ADMIN_GROUP" 2>/dev/null
  groupdel "$DCVM_USER_GROUP" 2>/dev/null
  ui_step ok "Services" "timers, boot service, socket and the dcvm groups removed"

  local deleted_count=0 vm_name
  for vm_name in $(virsh list --all --name 2>/dev/null); do
    [[ -z "$vm_name" ]] && continue
    if vm_on_network "$vm_name" "$NETWORK_NAME"; then
      virsh destroy "$vm_name" >/dev/null 2>&1 || true
      virsh undefine "$vm_name" --nvram >/dev/null 2>&1 || virsh undefine "$vm_name" >/dev/null 2>&1 || true
      deleted_count=$((deleted_count + 1))
    fi
  done
  rm -rf /var/lib/dcvm/vms /run/dcvm
  ui_step ok "VMs" "$deleted_count deleted"

  local status_file="/var/lib/libvirt/dnsmasq/${BRIDGE_NAME}.status"
  [[ -f "$status_file" ]] && printf '[]\n' >"$status_file"

  cleanup_port_forwarding >/dev/null
  save_iptables_rules
  ui_step ok "Port forwards" "rules removed"

  # Before the network goes: the zone is looked up by its bridge.
  if command_exists firewall-cmd && systemctl is-active --quiet firewalld 2>/dev/null; then
    local zone services=(--remove-service=nfs --remove-service=rpc-bind --remove-service=mountd)
    zone=$(firewall-cmd --get-zone-of-interface="$BRIDGE_NAME" 2>/dev/null) || zone=libvirt
    # The host's default zone may serve NFS to more than dcvm's VMs.
    if [ "$zone" = "$(firewall-cmd --get-default-zone 2>/dev/null)" ]; then
      ui_step skip "firewalld" "NFS left allowed in the default zone $zone"
    else
      firewall-cmd -q --zone="$zone" "${services[@]}" 2>/dev/null
      firewall-cmd -q --permanent --zone="$zone" "${services[@]}" 2>/dev/null
      ui_step ok "firewalld" "NFS no longer allowed in zone $zone"
    fi
  fi

  if virsh net-info "$NETWORK_NAME" >/dev/null 2>&1; then
    virsh net-destroy "$NETWORK_NAME" >/dev/null 2>&1 || true
    virsh net-undefine "$NETWORK_NAME" >/dev/null 2>&1 || true
    ui_step ok "Network" "$NETWORK_NAME removed"
  else
    ui_step skip "Network" "$NETWORK_NAME not found"
  fi

  local share="$DATACENTER_BASE/nfs-share" tmp
  if awk -v p="$share" '$1 == p { f = 1 } END { exit !f }' /etc/exports 2>/dev/null && tmp=$(mktemp); then
    awk -v p="$share" '$1 != p' /etc/exports >"$tmp" && cat "$tmp" >/etc/exports
    rm -f "$tmp"
    command_exists exportfs && exportfs -ra 2>/dev/null
    ui_step ok "NFS share" "removed from /etc/exports"
  fi

  local pool path
  while read -r pool; do
    [ -n "$pool" ] || continue
    path=$(virsh pool-dumpxml "$pool" 2>/dev/null | sed -n 's:.*<path>\(.*\)</path>.*:\1:p' | head -1)
    [[ -n "$path" && "$path/" == "${DATACENTER_BASE%/}/"* ]] || continue
    virsh pool-destroy "$pool" >/dev/null 2>&1 || true
    virsh pool-undefine "$pool" >/dev/null 2>&1 && ui_step ok "Storage pool" "$pool removed"
  done < <(virsh pool-list --all --name 2>/dev/null)

  local data_dir in_use
  in_use=$(domains_using_dir "$DATACENTER_BASE")
  if [ ! -d "$DATACENTER_BASE" ]; then
    ui_step skip "Data" "$DATACENTER_BASE not found"
  elif [ -n "$in_use" ] || ! virsh list --all --name >/dev/null 2>&1; then
    # Deleting disks of VMs that still exist (a failed undefine, or libvirt not answering) loses them for good.
    ui_step warn "Data" "$DATACENTER_BASE left in place: still used by ${in_use:-VMs libvirt could not list}"
  elif data_dir=$(removable_data_dir "$DATACENTER_BASE"); then
    rm -rf "$data_dir"
    ui_step ok "Data" "$data_dir removed"
  else
    ui_step warn "Data" "$DATACENTER_BASE left in place: not a dcvm folder (no vms/ and storage/); delete it yourself"
  fi
  id -u "$NFS_SQUASH_USER" >/dev/null 2>&1 && userdel "$NFS_SQUASH_USER" 2>/dev/null && ui_step ok "NFS user" "$NFS_SQUASH_USER removed"

  rm -f /usr/local/bin/dcvm /etc/dcvm-install.conf /var/log/datacenter-startup.log /etc/bash_completion.d/dcvm /usr/local/share/dcvm/dcvm-completion.sh
  rm -rf /usr/local/lib/dcvm
  rmdir /usr/local/share/dcvm 2>/dev/null || true
  ui_step ok "dcvm" "command, libraries, settings, completion and log removed"

  local cleaned
  cleaned=$(remove_shell_lines "$DCVM_ALIAS_LINE|dcvm-completion\.sh" | sort -u | tr '\n' ' ')
  [[ -n "$cleaned" ]] && ui_step ok "Shell config" "dcvm lines removed from ${cleaned% } (backup: .bak)"

  ui_done ok "dcvm uninstalled" "the installer's one-liner installs it again"
  echo ""

  if [[ -n ${BASH_VERSION-} ]]; then
    complete -r dcvm 2>/dev/null || true
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
