#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../utils/common.sh"

load_dcvm_config
require_root
check_dependencies virsh virt-install qemu-img

show_usage() {
  cat <<EOF
Create VM from custom ISO
Usage: dcvm create-iso <vm_name> --iso <path> [options]

Options:
  --iso <path>                  Path to installer ISO (required)
  -m, --memory <MB>             Memory in MB (default: 2048)
  -c, --cpus <N>                CPU count (default: 2)
  -d, --disk <SIZE>             Disk size (default: 20G; formats: 10G, 512M, 1T)
  --os-variant <name>           libosinfo variant (e.g., ubuntu22.04, debian12)
  --graphics <vnc|none>         Graphics for installer (default: vnc)
  --boot <order>                Boot order (default: cdrom,hd)
  -h, --help                    Show this help

Notes:
  - For graphical installers, keep --graphics vnc (default). Connect: virsh vncdisplay <vm>
  - Network will be attached to '${NETWORK_NAME}' with virtio model.
EOF
}

VM_NAME=""
ISO_PATH=""
MEMORY=2048
CPUS=2
DISK_SIZE="20G"
OS_VARIANT=""
GRAPHICS="vnc"
BOOT_ORDER="cdrom,hd"

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) show_usage; exit 0 ;;
      --iso) ISO_PATH="$2"; shift 2 ;;
      -m|--memory) MEMORY="$2"; shift 2 ;;
      -c|--cpus) CPUS="$2"; shift 2 ;;
      -d|--disk) DISK_SIZE="$2"; shift 2 ;;
      --os-variant) OS_VARIANT="$2"; shift 2 ;;
      --graphics) GRAPHICS="$2"; shift 2 ;;
      --boot) BOOT_ORDER="$2"; shift 2 ;;
      -*) echo "Unknown option: $1"; show_usage; exit 1 ;;
      *)
        if [ -z "$VM_NAME" ]; then VM_NAME="$1"; shift; else echo "Unexpected arg: $1"; show_usage; exit 1; fi
        ;;
    esac
  done
}

parse_args "$@"

if [ -z "$VM_NAME" ]; then show_usage; exit 1; fi
if [ -z "$ISO_PATH" ]; then echo "--iso is required"; show_usage; exit 1; fi
if [ ! -f "$ISO_PATH" ]; then print_error "ISO not found: $ISO_PATH"; exit 1; fi
if check_vm_exists "$VM_NAME"; then print_error "VM '$VM_NAME' already exists"; exit 1; fi

validate_disk_size "$DISK_SIZE" || { print_error "Invalid disk size: $DISK_SIZE"; exit 1; }

VM_DIR="$DATACENTER_BASE/vms/$VM_NAME"
DISK_PATH="$VM_DIR/$VM_NAME.qcow2"

create_dir_safe "$VM_DIR" || { print_error "Failed to create VM dir"; exit 1; }

print_info "Creating disk: $DISK_PATH ($DISK_SIZE)"
qemu-img create -f qcow2 "$DISK_PATH" "$DISK_SIZE" >/dev/null 2>&1 || { print_error "qemu-img create failed"; exit 1; }

EXTRA_OS_VARIANT=()
[ -n "$OS_VARIANT" ] && EXTRA_OS_VARIANT=(--os-variant "$OS_VARIANT")

print_info "Starting installer from ISO"
virt-install \
  --name "$VM_NAME" \
  --memory "$MEMORY" --vcpus "$CPUS" \
  --disk path="$DISK_PATH",format=qcow2,bus=virtio \
  --network network="$NETWORK_NAME",model=virtio \
  --cdrom "$ISO_PATH" \
  --graphics "$GRAPHICS" \
  --boot "$BOOT_ORDER" \
  "${EXTRA_OS_VARIANT[@]}" \
  --noautoconsole || { print_error "virt-install failed"; exit 1; }

print_success "Installer launched for VM '$VM_NAME'"
echo ""
echo "Connect to installer UI:"
echo "  VNC: virsh vncdisplay $VM_NAME"
echo "  Console (if supported by ISO): virsh console $VM_NAME"
echo ""
print_info "After installation completes, you can set up port forwarding:"
echo "  dcvm network ports setup"
