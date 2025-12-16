#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../utils/common.sh"

load_dcvm_config

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

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) show_usage; exit 0 ;;
      --iso|-o) ISO_PATH="$2"; shift 2 ;;
      -m|--memory) MEMORY="$2"; shift 2 ;;
      -c|--cpus) CPUS="$2"; shift 2 ;;
      -d|--disk) DISK_SIZE="$2"; shift 2 ;;
      --os-variant) OS_VARIANT="$2"; shift 2 ;;
      --graphics) GRAPHICS="$2"; shift 2 ;;
      --boot) BOOT_ORDER="$2"; shift 2 ;;
      --ip) STATIC_IP="$2"; shift 2 ;;
      --copy-iso) COPY_ISO="true"; shift ;;
      -f|--force) FORCE_MODE=true; shift ;;
      -*) print_warning "Unknown option ignored: $1"; shift ;;
      *)
        if [ -z "$VM_NAME" ]; then VM_NAME="$1"; shift; else shift; fi
        ;;
    esac
  done
}

interactive_prompt_memory() {
    local host_mem=$(free -m | awk '/^Mem:/ {print $2}')
    local max_mem=$((host_mem * 75 / 100))
    while true; do
        read -p "Memory in MB (available: ${host_mem}MB, recommended max: ${max_mem}MB) [2048]: " MEMORY
        MEMORY=${MEMORY:-2048}
        if [[ ! "$MEMORY" =~ ^[0-9]+$ ]]; then
            print_error "Memory must be a number"
            continue
        fi
        if [ "$MEMORY" -lt 512 ]; then
            print_error "Memory must be at least 512MB"
            continue
        fi
        if [ "$MEMORY" -gt "$max_mem" ]; then
            print_warning "Requested ${MEMORY}MB exceeds recommended ${max_mem}MB"
            read -p "Continue anyway? (y/N): " cont
            [[ ! "$cont" =~ ^[Yy]$ ]] && continue
        fi
        break
    done
}

interactive_prompt_cpus() {
    local host_cpus=$(nproc)
    local max_cpus=$((host_cpus > 1 ? host_cpus - 1 : 1))
    while true; do
        read -p "Number of CPUs (available: ${host_cpus}, recommended max: ${max_cpus}) [2]: " CPUS
        CPUS=${CPUS:-2}
        if [[ ! "$CPUS" =~ ^[0-9]+$ ]]; then
            print_error "CPU count must be a number"
            continue
        fi
        if [ "$CPUS" -lt 1 ]; then
            print_error "CPU count must be at least 1"
            continue
        fi
        if [ "$CPUS" -gt "$max_cpus" ]; then
            print_warning "Requested ${CPUS} CPUs exceeds recommended ${max_cpus}"
            read -p "Continue anyway? (y/N): " cont
            [[ ! "$cont" =~ ^[Yy]$ ]] && continue
        fi
        break
    done
}

interactive_prompt_disk() {
    while true; do
        read -p "Disk size (formats: 20G, 512M, 1T) [20G]: " DISK_SIZE
        DISK_SIZE=${DISK_SIZE:-20G}
        if [[ ! "$DISK_SIZE" =~ ^[0-9]+[GMT]$ ]]; then
            print_error "Invalid format. Use number + G/M/T (e.g., 20G, 512M, 1T)"
            continue
        fi
        break
    done
}

interactive_prompt_graphics() {
    echo ""
    echo "Graphics options:"
    echo "  1) VNC (recommended for graphical installers)"
    echo "  2) SPICE (better performance, requires virt-viewer)"
    echo "  3) None (text console only)"
    while true; do
        read -p "Select graphics [1]: " choice
        choice=${choice:-1}
        case "$choice" in
            1) GRAPHICS="vnc"; break ;;
            2) GRAPHICS="spice"; break ;;
            3) GRAPHICS="none"; break ;;
            *) print_error "Please enter 1, 2, or 3" ;;
        esac
    done
}

interactive_prompt_os_variant() {
    echo ""
    echo "OS Variant helps libvirt optimize settings for the guest OS."
    echo "Common variants: ubuntu22.04, ubuntu20.04, debian12, debian11, fedora39, centos9, win10, win11"
    echo "Leave empty for generic settings, or run 'osinfo-query os' for full list."
    read -p "OS variant (optional): " OS_VARIANT
}

interactive_prompt_boot_order() {
    echo ""
    echo "Boot order determines which device boots first."
    echo "  cdrom,hd = CD-ROM first, then hard disk (default for install)"
    echo "  hd,cdrom = Hard disk first, then CD-ROM"
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
    echo ""
    read -p "Set a static IP for this VM? (configure manually in VM) (y/N): " ip_choice
    if [[ "$ip_choice" =~ ^[Yy]$ ]]; then
        local subnet="${NETWORK_SUBNET:-10.10.10}"
        while true; do
            read -p "Static IP address (e.g., ${subnet}.50): " STATIC_IP
            if [[ "$STATIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                break
            fi
            print_error "Invalid IP format. Use: x.x.x.x"
        done
    fi
}

parse_args "$@"

if [ "$FORCE_MODE" = true ]; then
    echo ""
    print_warning "Force mode (-f) is not supported for ISO installations."
    print_info "ISO installations require interactive setup for graphics, OS variant, and other options."
    echo ""
fi

if [ -z "$VM_NAME" ]; then
    show_usage
    exit 1
fi

if [ -z "$ISO_PATH" ]; then
    echo ""
    read -p "Enter path to ISO file: " ISO_PATH
fi
if [ ! -f "$ISO_PATH" ]; then
    print_error "ISO file not found: $ISO_PATH"
    exit 1
fi

if virsh list --all --name 2>/dev/null | grep -qx "$VM_NAME"; then
    print_error "VM '$VM_NAME' already exists"
    echo "Use: dcvm delete $VM_NAME (to delete it first)"
    exit 1
fi

echo ""
echo "=================================================="
echo "Custom ISO VM Creation"
echo "=================================================="
echo ""
echo "VM Name: $VM_NAME"
echo "ISO: $ISO_PATH"
echo ""

[ -z "$MEMORY" ] && interactive_prompt_memory
[ -z "$CPUS" ] && interactive_prompt_cpus
[ -z "$DISK_SIZE" ] && interactive_prompt_disk
[ -z "$GRAPHICS" ] && interactive_prompt_graphics
[ -z "$OS_VARIANT" ] && interactive_prompt_os_variant
[ -z "$BOOT_ORDER" ] && interactive_prompt_boot_order
[ -z "$COPY_ISO" ] && interactive_prompt_copy_iso
[ -z "$STATIC_IP" ] && interactive_prompt_static_ip

echo ""
echo "=================================================="
echo "VM Configuration Summary"
echo "=================================================="
echo "  Name:       $VM_NAME"
echo "  ISO:        $(basename "$ISO_PATH")"
echo "  Memory:     ${MEMORY}MB"
echo "  CPUs:       $CPUS"
echo "  Disk:       $DISK_SIZE"
echo "  Graphics:   $GRAPHICS"
echo "  OS Variant: ${OS_VARIANT:-generic}"
echo "  Boot Order: $BOOT_ORDER"
echo "  Copy ISO:   $COPY_ISO"
[ -n "$STATIC_IP" ] && echo "  Static IP:  $STATIC_IP"
echo ""

read -p "Create VM with these settings? (Y/n): " confirm
confirm=${confirm:-y}
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    print_info "Cancelled."
    exit 0
fi

require_root

for cmd in virsh virt-install qemu-img; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        print_error "Required command not found: $cmd"
        exit 1
    fi
done

VM_DIR="$DATACENTER_BASE/vms/$VM_NAME"
DISK_PATH="$VM_DIR/${VM_NAME}-disk.qcow2"

mkdir -p "$VM_DIR" || { print_error "Failed to create VM directory"; exit 1; }

INSTALL_ISO="$ISO_PATH"
if [ "$COPY_ISO" = "true" ]; then
    iso_name=$(basename "$ISO_PATH")
    INSTALL_ISO="$VM_DIR/$iso_name"
    print_info "Copying ISO to VM directory..."
    cp "$ISO_PATH" "$INSTALL_ISO" || { print_error "Failed to copy ISO"; exit 1; }
    print_success "ISO copied to: $INSTALL_ISO"
fi

iso_size=$(stat -c%s "$INSTALL_ISO" 2>/dev/null || echo 0)
if [ "$iso_size" -lt 52428800 ]; then
    print_warning "ISO file is smaller than expected ($(($iso_size / 1048576))MB). It may not be a valid installer ISO."
fi

print_info "Creating disk: $DISK_PATH ($DISK_SIZE)"
qemu-img create -f qcow2 "$DISK_PATH" "$DISK_SIZE" >/dev/null 2>&1 || { print_error "qemu-img create failed"; exit 1; }


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
    VIRT_INSTALL_OPTS+=(--graphics "$GRAPHICS,listen=0.0.0.0")
fi

[ -n "$OS_VARIANT" ] && VIRT_INSTALL_OPTS+=(--os-variant "$OS_VARIANT")

print_info "Starting installer from ISO"
print_info "  VM: $VM_NAME"
print_info "  Memory: ${MEMORY}MB, CPUs: $CPUS"
print_info "  Disk: $DISK_SIZE"
print_info "  Graphics: $GRAPHICS"

virt-install "${VIRT_INSTALL_OPTS[@]}" || { print_error "virt-install failed"; exit 1; }

cat > "$VM_DIR/vm-info.txt" <<EOF
VM_NAME=$VM_NAME
CREATED=$(date '+%Y-%m-%d %H:%M:%S')
ISO=$INSTALL_ISO
MEMORY=$MEMORY
CPUS=$CPUS
DISK_SIZE=$DISK_SIZE
STATIC_IP=$STATIC_IP
NETWORK=$NETWORK_NAME
EOF

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
    echo "Network configuration for VM:"
    echo "  IP Address: $STATIC_IP/24"
    echo "  Gateway: ${subnet}.1"
    echo "  DNS: 8.8.8.8, 8.8.4.4"
    echo ""
fi
print_info "After installation completes:"
echo "  1. Configure network inside the VM"
echo "  2. Run: dcvm network ports setup"
