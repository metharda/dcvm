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
  cat <<EOF
Create VM from Custom ISO (Interactive Mode)
Usage: dcvm create <vm_name> -o /path/to/file.iso [options]
   Or: dcvm create-iso <vm_name> --iso <path> [options]

Options:
  --iso <path>                  Path to installer ISO (required)
  -m, --memory <MB>             Memory in MB (default: interactive)
  -c, --cpus <N>                CPU count (default: interactive)
  -d, --disk <SIZE>             Disk size (default: interactive; formats: 10G, 512M, 1T)
  --os-variant <name>           libosinfo variant (e.g., ubuntu22.04, debian12)
  --graphics <vnc|spice|none>   Graphics for installer (default: vnc)
  --boot <order>                Boot order (default: cdrom,hd)
  --ip <address>                Set static IP after installation (manual config required)
  --copy-iso                    Copy ISO to VM directory (default: use original path)
  -h, --help                    Show this help

NOTE: Force mode (-f) is NOT supported for ISO installations.
      Interactive prompts will ask for any missing required options.

Examples:
  dcvm create myvm -o /path/to/ubuntu.iso
  dcvm create myvm -o /path/to/debian.iso -m 4096 -c 4
  dcvm create-iso myvm --iso /path/to/arch.iso --graphics none
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
    read -p "Select graphics [1]: " choice
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
  read -p "OS variant (optional): " OS_VARIANT
}

interactive_prompt_boot_order() {
  cat <<-EOF
	
	Boot order determines which device boots first.
	  cdrom,hd = CD-ROM first, then hard disk (default for install)
	  hd,cdrom = Hard disk first, then CD-ROM
	EOF
  read -p "Boot order [cdrom,hd]: " BOOT_ORDER
  BOOT_ORDER=${BOOT_ORDER:-cdrom,hd}
}

interactive_prompt_copy_iso() {
  echo ""
  read -p "Copy ISO to VM directory? (y/N): " copy_choice
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
    read -p "Use static IP? (y/N, default: DHCP): " use_static
    use_static=${use_static:-n}

    if [[ "$use_static" =~ ^[Nn]$ ]]; then
      STATIC_IP=""
      print_info "Using DHCP - configure network in VM after installation"
      break
    elif [[ "$use_static" =~ ^[Yy]$ ]]; then
      while true; do
        read -p "Enter static IP (e.g., ${subnet}.50): " STATIC_IP
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
    echo ""
    read -p "Enter path to ISO file: " ISO_PATH
  fi
  if [ ! -f "$ISO_PATH" ]; then
    print_error "ISO file not found: $ISO_PATH"
    exit 1
  fi
}

show_iso_header() {
  cat <<EOF

==================================================
Custom ISO VM Creation
==================================================

VM Name: $VM_NAME
ISO: $ISO_PATH

EOF
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
  cat <<EOF

==================================================
VM Configuration Summary
==================================================
  Name:       $VM_NAME
  ISO:        $(basename "$ISO_PATH")
  Memory:     ${MEMORY}MB
  CPUs:       $CPUS
  Disk:       $DISK_SIZE
  Graphics:   $GRAPHICS
  OS Variant: ${OS_VARIANT:-generic}
  Boot Order: $BOOT_ORDER
  Copy ISO:   $COPY_ISO
EOF
  [ -n "$STATIC_IP" ] && echo "  Static IP:  $STATIC_IP (manual config)"
  echo ""
}

confirm_creation() {
  read -p "Create VM with these settings? (Y/n): " confirm
  confirm=${confirm:-y}
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    print_info "Cancelled."
    exit 0
  fi
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
  mkdir -p "$VM_DIR" || {
    print_error "Failed to create VM directory"
    exit 1
  }
}

copy_iso_if_needed() {
  INSTALL_ISO="$ISO_PATH"
  if [ "$COPY_ISO" = "true" ]; then
    local iso_name
    iso_name=$(basename "$ISO_PATH")
    INSTALL_ISO="$VM_DIR/$iso_name"
    print_info "Copying ISO to VM directory..."
    cp "$ISO_PATH" "$INSTALL_ISO" || {
      print_error "Failed to copy ISO"
      exit 1
    }
    print_success "ISO copied to: $INSTALL_ISO"
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
    print_warning "ISO is in a restricted directory that libvirt may not access"
    print_info "Path: $iso_realpath"
    echo ""

    if [ "$COPY_ISO" != "true" ]; then
      print_info "The ISO will be copied to the VM directory to avoid permission issues"
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
  print_info "Creating disk: $DISK_PATH ($DISK_SIZE)"
  qemu-img create -f qcow2 "$DISK_PATH" "$DISK_SIZE" >/dev/null 2>&1 || {
    print_error "qemu-img create failed"
    exit 1
  }
}

build_virt_install_opts() {
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
    # VNC listens on 127.0.0.1 for security - use SSH tunnel for remote access
    VIRT_INSTALL_OPTS+=(--graphics "$GRAPHICS,listen=127.0.0.1")
  fi
  [ -n "$OS_VARIANT" ] && VIRT_INSTALL_OPTS+=(--os-variant "$OS_VARIANT")
}

run_virt_install() {
  cat <<EOF
[INFO] Starting installer from ISO
  VM: $VM_NAME
  Memory: ${MEMORY}MB, CPUs: $CPUS
  Disk: $DISK_SIZE
  Graphics: $GRAPHICS
EOF

  virt-install "${VIRT_INSTALL_OPTS[@]}" || {
    print_error "virt-install failed"
    exit 1
  }
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
  print_success "Installer launched for VM '$VM_NAME'"
  echo ""
  echo "Connect to installer UI:"
  if [ "$GRAPHICS" = "none" ]; then
    echo "  Console: virsh console $VM_NAME"
  else
    echo "  VNC: virsh vncdisplay $VM_NAME"
    echo "  Or use a VNC client to connect to the host"
  fi
  echo ""
  if [ -n "$STATIC_IP" ]; then
    local subnet="${NETWORK_SUBNET:-10.10.10}"
    cat <<EOF
Network configuration for VM:
  IP Address: $STATIC_IP/24
  Gateway: ${subnet}.1
  DNS: 8.8.8.8, 8.8.4.4

EOF
  fi
  cat <<EOF
After installation completes:
  1. Configure network inside the VM
  2. Run: dcvm network ports setup
EOF
}

main() {
  load_dcvm_config
  parse_args "$@"

  if [ "$FORCE_MODE" = true ]; then
    echo ""
    print_error "Force mode (-f) is not supported for custom ISO installations."
    print_info "Custom ISO installations require interactive setup for graphics, OS variant, and other options."
    print_info "Remove the -f flag and run again."
    exit 1
  fi

  if [ -z "$VM_NAME" ]; then
    show_usage
    exit 1
  fi

  prompt_iso_path
  validate_vm_not_exists
  show_iso_header
  collect_vm_options
  show_vm_summary
  confirm_creation
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
