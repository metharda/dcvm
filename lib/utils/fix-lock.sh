#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

VM_NAME=""
VERBOSE=false
EXIT_CODE=0

print_verbose() {
  [ "$VERBOSE" = true ] && echo -e "  ${DIM}${SYM_INFO} $1${NC}"
  return 0
}

phase_done() {
  if [ "$step_errors" -gt "$PHASE_ERRORS" ]; then
    ui_step warn "$1" "$2 ($((step_errors - PHASE_ERRORS)) problem(s) above)"
  else
    ui_step ok "$1" "$2"
  fi
  PHASE_ERRORS=$step_errors
}

# ISO installs ($3 false) keep their installer and their disk bus: Windows has no virtio driver.
clean_definition() {
  python3 -I -S - "$@" <<'PY'
import sys, xml.etree.ElementTree as ET
path, disk, cloud, qcow2 = sys.argv[1], sys.argv[2], sys.argv[3] == "true", sys.argv[4] == "qcow2"
for _, (prefix, uri) in ET.iterparse(path, events=["start-ns"]):
    ET.register_namespace(prefix, uri)
tree = ET.parse(path)
devices = tree.getroot().find("devices")
if devices is None:
    sys.exit(1)
done = []
# CD-ROMs stay: on a cloud VM it is the cloud-init seed, and without it cloud-init disables itself.
for d in devices.findall("disk"):
    src = d.find("source")
    if d.get("device", "disk") != "disk" or src is None or src.get("file") != disk:
        continue
    drv = d.find("driver")
    if drv is not None and "cache" in drv.attrib:
        del drv.attrib["cache"]
        done.append("cache setting removed")
    if qcow2 and drv is not None and drv.get("name") == "qemu" and drv.get("type") != "qcow2":
        drv.set("type", "qcow2")
        done.append("disk read as qcow2")
    tgt = d.find("target")
    if cloud and tgt is not None and (tgt.get("dev"), tgt.get("bus")) != ("vda", "virtio"):
        tgt.attrib = {"dev": "vda", "bus": "virtio"}
        addr = d.find("address")
        if addr is not None:
            d.remove(addr)
        done.append("disk on virtio")
if done:
    tree.write(path)
print(", ".join(done))
PY
}

fix_vm_locks() {
  local vm_name="$1"
  local step_errors=0

  PHASE_ERRORS=0
  [ "$VERBOSE" = true ] || ui_quiet
  ui_title "Fixing locks on $vm_name" "stops the VM, clears stale locks, restarts libvirtd"

  if ! check_vm_exists "$vm_name"; then
    print_error "VM '$vm_name' not found in libvirt"
    return 1
  fi
  # Other libvirt VMs on the host are not dcvm's to stop, chmod or redefine.
  if ! is_vm_in_network "$vm_name"; then
    print_error "'$vm_name' is not a dcvm VM (not on ${NETWORK_NAME:-datacenter-net})"
    return 1
  fi

  VM_DISK_PATH=$(get_vm_disk_path "$vm_name")

  [ -z "$VM_DISK_PATH" ] && print_error "Could not find disk path for VM $vm_name" && return 1

  print_info "Checking for other VMs referencing the same disk image"
  local conflicts=()
  local all_vms=$(virsh list --all --name 2>/dev/null | grep -v "^$" || true)
  for other in $all_vms; do
    if [ "$other" != "$vm_name" ]; then
      virsh domblklist "$other" --details 2>/dev/null | awk '{print $4}' | grep -Fxq "$VM_DISK_PATH" && conflicts+=("$other (domblklist)")
    fi
  done

  if [ -d /etc/libvirt/qemu ]; then
    local xml_matches=$(grep -l -- "$VM_DISK_PATH" /etc/libvirt/qemu/*.xml 2>/dev/null | xargs -r -n1 basename 2>/dev/null | sed 's/\.xml$//' | grep -v -E "^${vm_name}$" || true)
    if [ -n "$xml_matches" ]; then
      while IFS= read -r vmxml; do
        local already=false
        for c in "${conflicts[@]}"; do [ "$c" = "$vmxml (xml)" ] && already=true; done
        [ "$already" = false ] && conflicts+=("$vmxml (xml)")
      done <<<"$xml_matches"
    fi
  fi

  if [ ${#conflicts[@]} -gt 0 ]; then
    print_error "The disk image is referenced by other VM(s): ${conflicts[*]}"
    echo "  Two VMs on one disk cause write-lock failures. Give one of them its own"
    echo "  disk (clone the image), or stop and undefine the other VM, then retry."
    return 1
  fi

  [ ! -f "$VM_DISK_PATH" ] && print_error "VM disk file does not exist: $VM_DISK_PATH" && return 1

  print_info "VM disk path: $VM_DISK_PATH"
  print_verbose "VM disk size: $(du -h "$VM_DISK_PATH" 2>/dev/null | cut -f1 || echo "unknown")"

  ui_step ok "Disk" "$VM_DISK_PATH, not used by another VM"

  local vm_state=$(get_vm_state "$vm_name")
  print_verbose "Current VM state: $vm_state"

  print_info "Checking processes using VM disk file"
  local qemu_pid disk_users i
  qemu_pid=$(vm_qemu_pid "$vm_name")
  # Any holder but the VM's own QEMU is other work (a backup's qemu-img, say): never stop the VM under it.
  disk_users=$(lsof "$VM_DISK_PATH" 2>/dev/null | awk -v q="$qemu_pid" 'NR>1 && $2 != q {print $1 "(" $2 ")"}' | sort -u | tr '\n' ' ')
  if [ -n "$disk_users" ]; then
    print_error "Still using the disk: $disk_users"
    echo "  Wait for it to finish (or stop it yourself), then run dcvm fix-lock $vm_name again."
    return 1
  fi

  if [ "$vm_state" = "running" ]; then
    print_info "Shutting down $vm_name (forced off after 60 seconds)"
    stop_vm_gracefully "$vm_name"
  fi
  if [ "$(get_vm_state "$vm_name")" != "shut off" ] && ! virsh destroy "$vm_name" >/dev/null 2>&1; then
    print_error "libvirt could not stop $vm_name; its disk was left alone"
    echo "  Try again in a minute, or restart libvirtd, then run dcvm fix-lock $vm_name again."
    return 1
  fi

  # libvirt calls it off, yet a QEMU it lost track of may hold the disk: SIGTERM lets QEMU flush it, SIGKILL would not.
  if qemu_pid=$(vm_qemu_pid "$vm_name"); then
    print_info "Stopping QEMU process $qemu_pid, which libvirt no longer tracks"
    kill -TERM "$qemu_pid" 2>/dev/null
    for ((i = 0; i < 30; i++)); do
      kill -0 "$qemu_pid" 2>/dev/null || break
      sleep 1
    done
    if kill -0 "$qemu_pid" 2>/dev/null; then
      print_error "QEMU process $qemu_pid did not exit within 30 seconds; its disk was left alone"
      return 1
    fi
  fi

  disk_users=$(lsof "$VM_DISK_PATH" 2>/dev/null | awk 'NR>1 {print $1 "(" $2 ")"}' | sort -u | tr '\n' ' ')
  if [ -n "$disk_users" ]; then
    print_error "Still using the disk: $disk_users"
    echo "  Wait for it to finish (or stop it yourself), then run dcvm fix-lock $vm_name again."
    return 1
  fi

  phase_done "Stopped" "VM and its QEMU processes"

  local lock_dirs=("/var/lib/libvirt/qemu" "/run/libvirt/qemu")
  local locks_found=false

  for lock_dir in "${lock_dirs[@]}"; do
    if [ -d "$lock_dir" ]; then
      local found_locks=$(find "$lock_dir" -maxdepth 1 -type f \( -name "${vm_name}.pid" -o -name "${vm_name}.lock" -o -name "${vm_name}.*.lock" \) 2>/dev/null)
      if [ -n "$found_locks" ]; then
        locks_found=true
        print_verbose "Removing locks in $lock_dir:"
        # A here-string, not a pipe: the loop must count step_errors in this shell.
        while read -r lock_file; do
          print_verbose "  Removing: $lock_file"
          rm -f "$lock_file" 2>/dev/null || {
            print_warning "Failed to remove: $lock_file"
            step_errors=$((step_errors + 1))
          }
        done <<<"$found_locks"
      fi
    else
      print_verbose "Lock directory not found: $lock_dir"
    fi
  done

  [ "$locks_found" = false ] && print_verbose "No libvirt lock files found"

  phase_done "libvirt locks" "$([ "$locks_found" = true ] && echo "lock and pid files removed" || echo "none found")"

  # Only this disk's own lock file: other images in the folder may be in use.
  local disk_lock="$VM_DISK_PATH.lock"
  if [ -f "$disk_lock" ]; then
    print_verbose "Removing disk lock: $disk_lock"
    rm -f "$disk_lock" 2>/dev/null || {
      print_warning "Failed to remove disk lock: $disk_lock"
      step_errors=$((step_errors + 1))
    }
  else
    print_verbose "No disk lock file found"
  fi

  if command_exists qemu-img; then
    print_info "Attempting to force unlock with qemu-img"
    qemu-img info "$VM_DISK_PATH" >/dev/null 2>&1 && print_verbose "qemu-img can access the disk" || {
      print_warning "qemu-img cannot access disk - may indicate lock issues"
      step_errors=$((step_errors + 1))
    }

    local qemu_check_output=$(qemu-img check "$VM_DISK_PATH" 2>&1 || true)
    echo "$qemu_check_output" | grep -qi "lock\|busy\|use" && {
      print_warning "qemu-img detected lock issues: $qemu_check_output"
      step_errors=$((step_errors + 1))
    }
  else
    print_warning "qemu-img not available - cannot force unlock disk"
  fi

  phase_done "Image locks" "released, shared memory cleared"

  if [ -f "$VM_DISK_PATH" ]; then
    local current_owner=$(stat -c '%U:%G' "$VM_DISK_PATH" 2>/dev/null || stat -f '%Su:%Sg' "$VM_DISK_PATH" 2>/dev/null || echo "unknown")
    local current_perms=$(stat -c '%a' "$VM_DISK_PATH" 2>/dev/null || stat -f '%A' "$VM_DISK_PATH" 2>/dev/null || echo "unknown")

    print_verbose "Current owner: $current_owner, permissions: $current_perms"

    local target_owner=""
    if id -u libvirt-qemu >/dev/null 2>&1; then
      target_owner="libvirt-qemu:kvm"
      chown libvirt-qemu:kvm "$VM_DISK_PATH" 2>/dev/null || {
        print_warning "Failed to set libvirt-qemu:kvm ownership, falling back to root"
        chown root:root "$VM_DISK_PATH" || {
          print_error "Failed to fix ownership"
          step_errors=$((step_errors + 1))
        }
        target_owner="root:root"
      }
    elif id -u qemu >/dev/null 2>&1; then
      target_owner="qemu:qemu"
      chown qemu:qemu "$VM_DISK_PATH" 2>/dev/null || {
        print_warning "Failed to set qemu:qemu ownership, falling back to root"
        chown root:root "$VM_DISK_PATH" || {
          print_error "Failed to fix ownership"
          step_errors=$((step_errors + 1))
        }
        target_owner="root:root"
      }
    else
      target_owner="root:root"
      chown root:root "$VM_DISK_PATH" || {
        print_error "Failed to fix ownership"
        step_errors=$((step_errors + 1))
      }
    fi

    chmod 600 "$VM_DISK_PATH" 2>/dev/null && print_success "Fixed permissions: $target_owner with 600" || {
      print_error "Failed to set permissions to 600"
      step_errors=$((step_errors + 1))
    }

    local new_owner=$(stat -c '%U:%G' "$VM_DISK_PATH" 2>/dev/null || stat -f '%Su:%Sg' "$VM_DISK_PATH" 2>/dev/null || echo "unknown")
    local new_perms=$(stat -c '%a' "$VM_DISK_PATH" 2>/dev/null || stat -f '%A' "$VM_DISK_PATH" 2>/dev/null || echo "unknown")
    print_verbose "New owner: $new_owner, permissions: $new_perms"

    if command_exists restorecon && selinuxenabled 2>/dev/null; then
      print_info "Restoring SELinux context"
      restorecon "$VM_DISK_PATH" 2>/dev/null && print_verbose "SELinux context restored" || print_warning "Failed to restore SELinux context"
    fi
  else
    print_error "VM disk file not found: $VM_DISK_PATH"
    return 1
  fi

  phase_done "Permissions" "${target_owner:-unchanged}, mode 600"

  local temp_xml changes cloud=false format
  temp_xml=$(mktemp)
  [ -f "${DATACENTER_BASE:-/srv/datacenter}/vms/$vm_name/cloud-init/user-data" ] && cloud=true
  # --security-info keeps VNC passwords, which a redefinition would otherwise drop.
  # Only a disk qemu-img reads as qcow2 may be declared qcow2: a raw one would no longer boot.
  format=$(qemu-img info -U "$VM_DISK_PATH" 2>/dev/null | sed -n 's/^file format: //p')
  if ! virsh dumpxml --security-info "$vm_name" >"$temp_xml" 2>/dev/null || ! changes=$(clean_definition "$temp_xml" "$VM_DISK_PATH" "$cloud" "$format"); then
    print_error "Failed to read the VM's XML configuration"
    step_errors=$((step_errors + 1))
    changes="not changed"
  elif [ -z "$changes" ]; then
    changes="nothing to change"
  elif virsh define --validate "$temp_xml" >/dev/null 2>&1 || virsh define "$temp_xml" >/dev/null 2>&1; then
    changes+=", redefined"
  else
    print_error "Failed to redefine VM configuration ($changes)"
    [ "$VERBOSE" = true ] && print_verbose "Problematic XML content:" && cat "$temp_xml"
    step_errors=$((step_errors + 1))
    changes="not changed"
  fi
  rm -f "$temp_xml"

  phase_done "Definition" "$changes"

  local restart_success=false
  if [ "$(caller_role)" = user ]; then
    phase_done "libvirtd" "not restarted (it serves every user; ask an admin if the VM still won't start)"
  elif systemctl restart libvirtd 2>/dev/null; then
    restart_success=true
    print_success "libvirtd restarted with systemctl"
  elif service libvirtd restart 2>/dev/null; then
    restart_success=true
    print_success "libvirtd restarted with service command"
  else
    print_error "Could not restart libvirtd - manual restart may be required"
    step_errors=$((step_errors + 1))
  fi

  if [ "$restart_success" = true ]; then
    print_info "Waiting for libvirtd to be ready"
    local wait_count=0
    local max_wait=15

    while [ $wait_count -lt $max_wait ]; do
      virsh list >/dev/null 2>&1 && print_verbose "libvirtd is responding after ${wait_count}s" && break
      sleep 2
      wait_count=$((wait_count + 2))
    done

    [ $wait_count -ge $max_wait ] && print_error "libvirtd not responding after ${max_wait}s" && step_errors=$((step_errors + 1))
    phase_done "libvirtd" "restarted and responding"
  fi

  virsh pool-list --all 2>/dev/null | grep -q "default" && print_info "Refreshing storage pools" && virsh pool-refresh default >/dev/null 2>&1 || print_verbose "Could not refresh default storage pool"

  local vm_interfaces=$(virsh domiflist "$vm_name" 2>/dev/null | awk 'NR>2 {print $1}' || true)
  [ -n "$vm_interfaces" ] && print_verbose "VM has network interfaces: $vm_interfaces"

  check_vm_exists "$vm_name" && print_verbose "VM is properly defined in libvirt" || {
    print_error "VM not found in libvirt after cleanup"
    return 1
  }

  if [ ! -f "$VM_DISK_PATH" ]; then
    print_error "VM disk file not found: $VM_DISK_PATH"
    return 1
  elif [ ! -r "$VM_DISK_PATH" ]; then
    print_error "VM disk file not readable: $VM_DISK_PATH"
    return 1
  else
    print_verbose "VM disk file is accessible"
  fi

  virsh dominfo "$vm_name" >/dev/null 2>&1 && print_verbose "VM domain info accessible" || {
    print_warning "Cannot access VM domain info"
    step_errors=$((step_errors + 1))
  }

  if lsof "$VM_DISK_PATH" >/dev/null 2>&1; then
    local remaining_users=$(lsof "$VM_DISK_PATH" 2>/dev/null | awk 'NR>1 {print $1 "(" $2 ")"}' | tr '\n' ' ')
    print_warning "Processes still using disk: $remaining_users"
    step_errors=$((step_errors + 1))
  else
    print_verbose "No processes using VM disk file"
  fi

  phase_done "Checked" "defined, disk readable, no process holds it"
  if [ $step_errors -eq 0 ]; then
    ui_done ok "Locks cleared on $vm_name"
  else
    ui_done warn "Locks cleared on $vm_name with $step_errors problem(s)" "the VM may still start"
  fi
  ui_next "dcvm start $vm_name" "start it" \
    "tail /var/log/libvirt/qemu/$vm_name.log" "QEMU's log if it fails again"

  [ $step_errors -gt 0 ] && return 1 || return 0
}

main() {
  if wants_help "$@"; then
    echo "Usage: dcvm fix-lock <vm> [--verbose] | --all [--yes]    Stop the VM, clear stale disk locks, redefine it (restarts libvirtd for admins)"
    exit 0
  fi
  check_permissions
  check_dependencies virsh lsof
  load_dcvm_config
  VM_NAME="$1"

  [ -z "$VM_NAME" ] && print_error "VM name required. Usage: dcvm fix-lock <vm_name|--all> [--verbose]" && exit 1

  [[ " $* " == *" --verbose "* ]] && VERBOSE=true

  if [ "$VM_NAME" = "--all" ]; then
    if [[ " $* " != *" --yes "* ]]; then
      [ -t 0 ] || {
        print_error "fix-lock --all stops every dcvm VM: add --yes"
        exit 1
      }
      confirm_action "Stop every dcvm VM and clear its locks?" || exit 1
    fi

    VM_LIST=$(virsh list --all --name 2>/dev/null | grep -v "^$" || true)

    [ -z "$VM_LIST" ] && print_warning "No VMs found" && exit 0

    total_vms=0
    failed_vms=0

    for vm in $VM_LIST; do
      # Only dcvm's VMs: other libvirt VMs on the host are not ours to stop.
      is_vm_in_network "$vm" || continue
      total_vms=$((total_vms + 1))
      fix_vm_locks "$vm" || failed_vms=$((failed_vms + 1))
    done

    if [ $failed_vms -gt 0 ]; then
      ui_done warn "$((total_vms - failed_vms)) of $total_vms VMs fixed" "$failed_vms had problems; see above"
      echo ""
      exit 1
    fi
    ui_done ok "Locks cleared on all $total_vms VMs"
    echo ""
    exit 0
  else
    fix_vm_locks "$VM_NAME" && exit 0 || exit 1
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
