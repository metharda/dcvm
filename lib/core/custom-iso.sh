#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../utils/common.sh"

VM_NAME=""
ISO_PATH=""
MEMORY=""
CPUS=""
DISK_SIZE=""
OS_VARIANT=""
GRAPHICS=""
BOOT_ORDER=""
STATIC_IP=""
COPY_ISO=""
FORCE_MODE=false

show_usage() {
  ui_help <<EOF
dcvm create-iso - a VM that boots an installer ISO

Usage: dcvm create <name> -o <file.iso> [options]
       dcvm create-iso <name> --iso <file.iso> [options]

Options:
  --iso <path>                 Installer ISO (asked if missing)
  -m, --memory <MB>            Memory (asked if missing)
  -c, --cpus <N>               vCPUs (asked if missing)
  -d, --disk <SIZE>            Disk size, e.g. 20G (asked if missing)
  --os-variant <name>          libosinfo variant, e.g. debian12
  --graphics <vnc|spice|none>  Installer display (default vnc, on 127.0.0.1)
  --boot <order>               Boot order (default cdrom,hd)
  --ip <address>               Static IP to configure in the installer
  --copy-iso                   Copy the ISO next to the VM's disk
  --ttl <90m|2h|3d>            Delete the VM after this long
  -f, --force                  No questions: 2048 MB, 2 vCPUs, 20G disk unless given
  -h, --help                   Show this help

You install the OS yourself over VNC or the console.

Examples:
  dcvm create web -o /srv/iso/debian-13.iso
  dcvm create-iso arch --iso /srv/iso/arch.iso --graphics none
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
    -h | --help)
      show_usage
      exit 0
      ;;
    --iso | -o)
      ISO_PATH="$2"
      shift 2
      ;;
    -m | --memory)
      MEMORY="$2"
      shift 2
      ;;
    -c | --cpus)
      CPUS="$2"
      shift 2
      ;;
    -d | --disk)
      DISK_SIZE="$2"
      shift 2
      ;;
    --os-variant)
      OS_VARIANT="$2"
      shift 2
      ;;
    --graphics)
      GRAPHICS="$2"
      shift 2
      ;;
    --boot)
      BOOT_ORDER="$2"
      shift 2
      ;;
    --ip)
      STATIC_IP="$2"
      shift 2
      ;;
    --copy-iso)
      COPY_ISO="true"
      shift
      ;;
    -f | --force)
      FORCE_MODE=true
      shift
      ;;
    --ttl)
      TTL="$2"
      shift 2
      ;;
    -*)
      print_warning "Unknown option ignored: $1"
      shift
      ;;
    *)
      if [ -z "$VM_NAME" ]; then
        VM_NAME="$1"
        shift
      else shift; fi
      ;;
    esac
  done
}

interactive_prompt_memory() { interactive_prompt_memory_common "MEMORY"; }
interactive_prompt_cpus() { interactive_prompt_cpus_common "CPUS"; }
interactive_prompt_disk() { interactive_prompt_disk_common "DISK_SIZE"; }

interactive_prompt_graphics() {
  cat <<-EOF
	
	Graphics options:
	  1) VNC (recommended for graphical installers)
	  2) SPICE (better performance, requires virt-viewer)
	  3) None (text console only)
	EOF
  while true; do
    read -p "Select graphics [1]: " choice || exit 1
    choice=${choice:-1}
    case "$choice" in
    1)
      GRAPHICS="vnc"
      break
      ;;
    2)
      GRAPHICS="spice"
      break
      ;;
    3)
      GRAPHICS="none"
      break
      ;;
    *) print_error "Please enter 1, 2, or 3" ;;
    esac
  done
}

interactive_prompt_os_variant() {
  cat <<-EOF
	
	OS Variant helps libvirt optimize settings for the guest OS.
	Common variants: ubuntu22.04, ubuntu20.04, debian12, debian11, fedora39, centos9, win10, win11
	Leave empty for generic settings, or run 'osinfo-query os' for full list.
	EOF
  read -p "OS variant (optional): " OS_VARIANT || exit 1
}

interactive_prompt_boot_order() {
  cat <<-EOF
	
	Boot order determines which device boots first.
	  cdrom,hd = CD-ROM first, then hard disk (default for install)
	  hd,cdrom = Hard disk first, then CD-ROM
	EOF
  read -p "Boot order [cdrom,hd]: " BOOT_ORDER || exit 1
  BOOT_ORDER=${BOOT_ORDER:-cdrom,hd}
}

interactive_prompt_copy_iso() {
  [ "$(caller_role)" = root ] || return 0
  echo ""
  read -p "Copy ISO to VM directory? (y/N): " copy_choice || exit 1
  if [[ "$copy_choice" =~ ^[Yy]$ ]]; then
    COPY_ISO="true"
  else
    COPY_ISO="false"
  fi
}

interactive_prompt_static_ip() {
  local subnet="${NETWORK_SUBNET:-10.10.10}"
  echo ""
  print_info "Static IP Configuration (manual setup required in VM)"
  echo "  Network subnet: ${subnet}.0/24"
  echo "  Gateway: ${subnet}.1"
  echo "  Valid range: ${subnet}.2 - ${subnet}.254"
  echo ""

  while true; do
    read -p "Use static IP? (y/N, default: DHCP): " use_static || exit 1
    use_static=${use_static:-n}

    if [[ "$use_static" =~ ^[Nn]$ ]]; then
      STATIC_IP=""
      print_info "Using DHCP - configure network in VM after installation"
      break
    elif [[ "$use_static" =~ ^[Yy]$ ]]; then
      while true; do
        read -p "Enter static IP (e.g., ${subnet}.50): " STATIC_IP || exit 1
        if [ -z "$STATIC_IP" ]; then
          print_error "IP address cannot be empty"
          continue
        fi
        if validate_ip_in_subnet "$STATIC_IP"; then
          print_success "Static IP set to: $STATIC_IP (configure manually in VM)"
          break 2
        fi
      done
    else
      print_error "Please enter 'y' for static IP or 'n' for DHCP"
    fi
  done
}

validate_vm_not_exists() {
  if virsh list --all --name 2>/dev/null | grep -qx "$VM_NAME"; then
    print_error "VM '$VM_NAME' already exists"
    echo "Use: dcvm delete $VM_NAME (to delete it first)"
    exit 1
  fi
}

prompt_iso_path() {
  if [ -z "$ISO_PATH" ]; then
    if [ "$(caller_role)" != root ]; then
      print_error "Pass the ISO as a file: dcvm create-iso $VM_NAME --iso <file.iso>"
      exit 1
    fi
    echo ""
    read -p "Enter path to ISO file: " ISO_PATH || exit 1
  fi
  if [ "$(caller_role)" != root ] && [ "$ISO_PATH" != "$DATACENTER_BASE/vms/$VM_NAME/installer.iso" ]; then
    print_error "Pass the ISO as a file: dcvm create-iso $VM_NAME --iso <file.iso>"
    exit 1
  fi
  if [ ! -f "$ISO_PATH" ]; then
    print_error "ISO file not found: $ISO_PATH"
    exit 1
  fi
}

show_iso_header() {
  ui_title "New VM from an ISO" "$VM_NAME ${SYM_DOT} $(basename "$ISO_PATH")"
}

collect_vm_options() {
  [ -z "$MEMORY" ] && interactive_prompt_memory
  [ -z "$CPUS" ] && interactive_prompt_cpus
  [ -z "$DISK_SIZE" ] && interactive_prompt_disk
  [ -z "$GRAPHICS" ] && interactive_prompt_graphics
  [ -z "$OS_VARIANT" ] && interactive_prompt_os_variant
  [ -z "$BOOT_ORDER" ] && interactive_prompt_boot_order
  [ -z "$COPY_ISO" ] && interactive_prompt_copy_iso
  [ -z "$STATIC_IP" ] && interactive_prompt_static_ip
}

show_vm_summary() {
  local rows=(
    "$(printf '%-11s%s' ISO "$(basename "$ISO_PATH")$([ "$COPY_ISO" = true ] && echo " (copied)")")"
    "$(printf '%-11s%s' Resources "$CPUS vCPU, $MEMORY MB RAM, $DISK_SIZE disk")"
    "$(printf '%-11s%s' Display "$GRAPHICS")"
    "$(printf '%-11s%s' OS "${OS_VARIANT:-generic}")"
    "$(printf '%-11s%s' Boot "$BOOT_ORDER")"
  )
  [ -n "$STATIC_IP" ] && rows+=("$(printf '%-11s%s' Address "$STATIC_IP (set it in the installer)")")
  ui_box "$VM_NAME" "${rows[@]}"
  echo ""
}

confirm_creation() {
  confirm_action "Create it?" y || exit 0
  echo ""
}

check_iso_dependencies() {
  require_root
  for cmd in virsh virt-install qemu-img; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      print_error "Required command not found: $cmd"
      exit 1
    fi
  done
}

prepare_vm_directory() {
  VM_DIR="$DATACENTER_BASE/vms/$VM_NAME"
  DISK_PATH="$VM_DIR/${VM_NAME}-disk.qcow2"
  mkdir -p "$VM_DIR" && chmod 711 "$VM_DIR" || {
    print_error "Failed to create VM directory"
    exit 1
  }
}

copy_iso_if_needed() {
  INSTALL_ISO="$ISO_PATH"
  if [ "$COPY_ISO" = "true" ]; then
    INSTALL_ISO="$VM_DIR/installer.iso"
    ui_run "Copying ISO" sh -c 'umask 077 && cp -- "$1" "$2"' _ "$ISO_PATH" "$INSTALL_ISO" || {
      ui_step fail "ISO" "copy failed"
      exit 1
    }
    ui_step ok "ISO" "copied to $INSTALL_ISO (${UI_RUN_SECS}s)"
  fi
}

validate_iso_size() {
  local iso_size
  iso_size=$(stat -c%s "$INSTALL_ISO" 2>/dev/null || stat -f%z "$INSTALL_ISO" 2>/dev/null || echo 0)
  if [ "$iso_size" -lt 10485760 ]; then
    print_warning "ISO file is smaller than expected ($(($iso_size / 1048576))MB). It may not be a valid installer ISO."
    print_info "Some netinstall ISOs can be small, but verify the file is correct before continuing."
  fi
}

check_iso_accessibility() {
  local check_path="${ISO_PATH:-$INSTALL_ISO}"
  local iso_realpath
  iso_realpath=$(realpath "$check_path" 2>/dev/null || echo "$check_path")
  if [[ "$iso_realpath" =~ ^/root/ ]] || [[ "$iso_realpath" =~ ^/home/[^/]+/ ]]; then
    if [ "$COPY_ISO" != "true" ]; then
      ui_step warn "ISO" "in a home folder libvirt cannot read; copying it next to the disk"
      COPY_ISO="true"
      copy_iso_if_needed
    fi
  fi

  if [ ! -r "$INSTALL_ISO" ]; then
    print_error "ISO file is not readable: $INSTALL_ISO"
    exit 1
  fi
}

create_vm_disk() {
  (umask 077 && qemu-img create -f qcow2 "$DISK_PATH" "$DISK_SIZE") >/dev/null 2>&1 || {
    ui_step fail "Disk" "qemu-img create failed"
    exit 1
  }
  ui_step ok "Disk" "$DISK_SIZE, $DISK_PATH"
}

# --boot and --graphics reach virt-install's option parser: free text can name host files.
validate_iso_options() {
  GRAPHICS=${GRAPHICS:-vnc} BOOT_ORDER=${BOOT_ORDER:-cdrom,hd}
  case "$GRAPHICS" in none | vnc | spice) ;; *)
    print_error "Graphics must be none, vnc or spice"
    exit 1
    ;;
  esac
  case "$BOOT_ORDER" in cdrom,hd | hd,cdrom | cdrom | hd) ;; *)
    print_error "Boot order must be cdrom,hd or hd,cdrom"
    exit 1
    ;;
  esac
  if [[ ! "$OS_VARIANT" =~ ^[A-Za-z0-9._-]{0,64}$ ]]; then
    print_error "Invalid OS variant: $OS_VARIANT"
    exit 1
  fi
  if [ -n "$STATIC_IP" ] && ! valid_vm_ip "$STATIC_IP"; then
    print_error "Invalid static IP: $STATIC_IP"
    exit 1
  fi
}

build_virt_install_opts() {
  validate_iso_options
  VIRT_INSTALL_OPTS=(
    --name "$VM_NAME"
    --memory "$MEMORY"
    --vcpus "$CPUS"
    --disk "path=$DISK_PATH,format=qcow2,bus=virtio"
    --network "network=$NETWORK_NAME,model=virtio"
    --cdrom "$INSTALL_ISO"
    --boot "$BOOT_ORDER"
    --noautoconsole
  )

  if [ "$GRAPHICS" = "none" ]; then
    VIRT_INSTALL_OPTS+=(--graphics none --console pty,target_type=serial)
  else
    VIRT_INSTALL_OPTS+=(--graphics "$GRAPHICS,listen=127.0.0.1") # VNC listens on 127.0.0.1 for security - use SSH tunnel for remote access
  fi
  VIRT_INSTALL_OPTS+=(--os-variant "${OS_VARIANT:-detect=on,require=off}")
}

run_virt_install() {
  local cmd=(virt-install "${VIRT_INSTALL_OPTS[@]}")
  if [ "$(caller_role)" != root ] && [ "$GRAPHICS" != none ]; then
    VNC_PW=$(vnc_password)
    cmd=(virt_install_with_vnc_password "$VNC_PW" "${cmd[@]}")
  fi
  ui_run "Starting VM" "${cmd[@]}" || {
    ui_step fail "VM" "virt-install failed"
    sed 's/^/    /' "$UI_RUN_LOG" | tail -10
    exit 1
  }
  register_vm "$VM_NAME" "cpus=$CPUS" "memory_mb=$MEMORY" "disk_gb=$(size_gb "$DISK_SIZE")" \
    "expires=${TTL_SECONDS:+$(($(date +%s) + TTL_SECONDS))}"
  ui_step ok "VM" "defined and booting the installer"
  [ -n "${VNC_PW:-}" ] && ui_step ok "VNC" "password $VNC_PW (dcvm network vnc status $VM_NAME shows it again)"
}

save_vm_info() {
  cat >"$VM_DIR/vm-info.txt" <<EOF
VM_NAME=$VM_NAME
CREATED=$(date '+%Y-%m-%d %H:%M:%S')
ISO=$INSTALL_ISO
MEMORY=$MEMORY
CPUS=$CPUS
DISK_SIZE=$DISK_SIZE
STATIC_IP=$STATIC_IP
NETWORK=$NETWORK_NAME
EOF
}

show_post_creation_info() {
  local subnet="${NETWORK_SUBNET:-10.10.10}"
  if [ -n "$STATIC_IP" ]; then
    ui_box "$VM_NAME is running the installer" \
      "$(printf '%-11s%s' Address "$STATIC_IP/24")" \
      "$(printf '%-11s%s' Gateway "$subnet.1")" \
      "$(printf '%-11s%s' DNS "8.8.8.8, 8.8.4.4")"
  else
    ui_box "$VM_NAME is running the installer" "$(printf '%-11s%s' Network "DHCP on $NETWORK_NAME")"
  fi
  if [ "$GRAPHICS" = "none" ]; then
    ui_next "dcvm console $VM_NAME" "the installer, on the serial console" \
      "dcvm network ports setup" "after the install: reach it from other machines"
  else
    ui_next "dcvm network vnc status $VM_NAME" "the VNC port of the installer (127.0.0.1 only)" \
      "dcvm network ports setup" "after the install: reach it from other machines"
  fi
}

main() {
  load_dcvm_config
  parse_args "$@"
  if [ -n "${TTL:-}" ] && ! TTL_SECONDS=$(ttl_seconds "$TTL"); then
    print_error "--ttl must look like 90m, 2h or 3d"
    exit 1
  fi
  [ "${DCVM_ORIGIN:-terminal}" = agent ] && [ ! -t 0 ] && FORCE_MODE=true

  if [ -z "$VM_NAME" ]; then
    show_usage
    exit 1
  fi

  prompt_iso_path
  validate_vm_not_exists
  show_iso_header
  if [ "$FORCE_MODE" = true ]; then
    MEMORY=${MEMORY:-2048} CPUS=${CPUS:-2} DISK_SIZE=${DISK_SIZE:-20G} COPY_ISO=${COPY_ISO:-false}
    show_vm_summary
  else
    collect_vm_options
    show_vm_summary
    confirm_creation
  fi
  within_quota "$CPUS" "$MEMORY" "$(size_gb "$DISK_SIZE")" || exit 1
  check_iso_dependencies
  prepare_vm_directory
  copy_iso_if_needed
  validate_iso_size
  check_iso_accessibility
  create_vm_disk
  build_virt_install_opts
  run_virt_install
  save_vm_info
  show_post_creation_info
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
