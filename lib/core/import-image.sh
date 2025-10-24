#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../utils/common.sh"

load_dcvm_config
require_root
check_dependencies virsh qemu-img

show_usage() {
  cat <<EOF
Import VM from image file (qcow2/raw)
Usage: dcvm import-image <vm_name> --image <path> [--format qcow2|raw] [--os-variant <name>] [--attach-cidata]

Options:
  --image <path>                Path to disk image (required)
  --format <fmt>                Image format: qcow2 or raw (auto-detected if omitted)
  --os-variant <name>           libosinfo variant (e.g., ubuntu22.04, debian12)
  --attach-cidata               Create and attach empty cloud-init seed ISO (cidata)
  -m, --memory <MB>             Memory in MB (default: 4096)
  -c, --cpus <N>                CPU count (default: 4)
  -h, --help                    Show this help

Notes:
  - Useful for importing Packer-produced images (e.g., GitHub Actions runner-images).
  - Network will be '${NETWORK_NAME}' with virtio model.
EOF
}

VM_NAME=""; IMAGE_PATH=""; IMAGE_FMT=""; OS_VARIANT=""; ATTACH_CIDATA=false
MEMORY=4096; CPUS=4

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) show_usage; exit 0 ;;
      --image) IMAGE_PATH="$2"; shift 2 ;;
      --format) IMAGE_FMT="$2"; shift 2 ;;
      --os-variant) OS_VARIANT="$2"; shift 2 ;;
      --attach-cidata) ATTACH_CIDATA=true; shift ;;
      -m|--memory) MEMORY="$2"; shift 2 ;;
      -c|--cpus) CPUS="$2"; shift 2 ;;
      -*) echo "Unknown option: $1"; show_usage; exit 1 ;;
      *) if [ -z "$VM_NAME" ]; then VM_NAME="$1"; shift; else echo "Unexpected arg: $1"; show_usage; exit 1; fi ;;
    esac
  done
}

parse_args "$@"

[ -z "$VM_NAME" ] && { show_usage; exit 1; }
[ -z "$IMAGE_PATH" ] && { echo "--image is required"; show_usage; exit 1; }
[ ! -f "$IMAGE_PATH" ] && { print_error "Image not found: $IMAGE_PATH"; exit 1; }
check_vm_exists "$VM_NAME" && { print_error "VM '$VM_NAME' already exists"; exit 1; }

if [ -z "$IMAGE_FMT" ]; then
  case "$IMAGE_PATH" in
    *.qcow2|*.qcow2.gz) IMAGE_FMT="qcow2" ;;
    *.img|*.raw) IMAGE_FMT="raw" ;;
    *) IMAGE_FMT="qcow2" ;;
  esac
fi

VM_DIR="$DATACENTER_BASE/vms/$VM_NAME"
DISK_PATH="$VM_DIR/$VM_NAME.qcow2"
create_dir_safe "$VM_DIR" || { print_error "Failed to create VM dir"; exit 1; }

if [[ "$IMAGE_PATH" =~ \.gz$ ]]; then
  print_info "Decompressing image"
  gunzip -c "$IMAGE_PATH" > "$DISK_PATH" || { print_error "Decompression failed"; exit 1; }
else
  if [ "$IMAGE_FMT" = "qcow2" ]; then
    print_info "Converting/copying qcow2 image"
    qemu-img convert -O qcow2 "$IMAGE_PATH" "$DISK_PATH" || { print_error "qemu-img convert failed"; exit 1; }
  else
    print_info "Converting raw image to qcow2"
    qemu-img convert -O qcow2 "$IMAGE_PATH" "$DISK_PATH" || { print_error "qemu-img convert failed"; exit 1; }
  fi
fi

SEED_ARGS=()
if [ "$ATTACH_CIDATA" = true ]; then
  mkdir -p "$VM_DIR/cloud-init"
  genisoimage -output "$VM_DIR/cloud-init.iso" -volid cidata -joliet -rock "$VM_DIR/cloud-init" >/dev/null 2>&1 || true
  [ -f "$VM_DIR/cloud-init.iso" ] && SEED_ARGS+=(--disk path="$VM_DIR/cloud-init.iso",device=cdrom)
fi

EXTRA_OS_VARIANT=()
[ -n "$OS_VARIANT" ] && EXTRA_OS_VARIANT=(--os-variant "$OS_VARIANT")

print_info "Defining and starting VM"
virt-install \
  --name "$VM_NAME" \
  --memory "$MEMORY" --vcpus "$CPUS" \
  --disk path="$DISK_PATH",format=qcow2,bus=virtio \
  ${SEED_ARGS[@]+${SEED_ARGS[@]}} \
  --network network="$NETWORK_NAME",model=virtio \
  --import \
  "${EXTRA_OS_VARIANT[@]}" \
  --noautoconsole || { print_error "virt-install failed"; exit 1; }

print_success "Imported image as VM '$VM_NAME'"
echo ""; echo "Network ports için: dcvm network ports setup"
