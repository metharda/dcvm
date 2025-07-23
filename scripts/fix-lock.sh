#!/bin/bash

VM_NAME="$1"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

print_info() {
	echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
	echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
	echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
	echo -e "${RED}[ERROR]${NC} $1"
}

if [ -z "$VM_NAME" ]; then
	echo "Usage: $0 <vm_name>"
	echo "       $0 --all    # Fix locks for all VMs"
	exit 1
fi

fix_vm_locks() {
	local vm_name="$1"

	echo "=== QEMU Lock Fix for $vm_name ==="

	print_info "[1/8] Getting VM configuration..."

	if ! virsh list --all | grep -q " $vm_name "; then
		print_error "VM '$vm_name' not found"
		return 1
	fi

	VM_DISK_PATH=$(virsh domblklist "$vm_name" --details 2>/dev/null | grep "disk" | grep "file" | awk '{print $4}' | head -1)

	if [ -z "$VM_DISK_PATH" ]; then
		print_error "Could not find disk path for VM $vm_name"
		return 1
	fi

	print_info "VM disk path: $VM_DISK_PATH"

	print_info "[2/8] Force stopping VM and related processes..."

	virsh destroy "$vm_name" 2>/dev/null || true
	sleep 3

	pgrep -f "qemu.*$vm_name" | xargs -r kill -9 2>/dev/null || true
	sleep 2

	if [ -f "$VM_DISK_PATH" ]; then
		lsof "$VM_DISK_PATH" 2>/dev/null | awk 'NR>1 {print $2}' | xargs -r kill -9 2>/dev/null || true
	fi
	sleep 2

	print_info "[3/8] Clearing libvirt lock files..."

	local lock_dirs=(
		"/var/lib/libvirt/qemu"
		"/run/libvirt/qemu"
		"/var/run/libvirt/qemu"
		"/tmp"
	)

	for lock_dir in "${lock_dirs[@]}"; do
		if [ -d "$lock_dir" ]; then
			find "$lock_dir" -name "*${vm_name}*" \( -name "*.lock" -o -name "*.pid" \) -delete 2>/dev/null || true
		fi
	done

	print_info "[4/8] Clearing QEMU image locks..."

	local disk_dir=$(dirname "$VM_DISK_PATH")
	find "$disk_dir" -name "*.lock" -delete 2>/dev/null || true

	local vm_basename=$(basename "$vm_name")
	rm -f /dev/shm/qemu_"$vm_basename"_* 2>/dev/null || true

	if command -v qemu-img >/dev/null 2>&1; then
		print_info "Force unlocking disk image with qemu-img..."
		qemu-img info "$VM_DISK_PATH" >/dev/null 2>&1 || true
	fi

	if [ -f "$VM_DISK_PATH" ]; then
		fuser -k "$VM_DISK_PATH" 2>/dev/null || true
		sleep 2

		python3 -c "
import fcntl
try:
    with open('$VM_DISK_PATH', 'r+b') as f:
        fcntl.flock(f.fileno(), fcntl.LOCK_UN)
except:
    pass
" 2>/dev/null || true
	fi

	print_info "[5/8] Fixing file permissions and ownership..."

	if [ -f "$VM_DISK_PATH" ]; then
		if id -u libvirt-qemu >/dev/null 2>&1; then
			chown libvirt-qemu:kvm "$VM_DISK_PATH" 2>/dev/null || chown root:root "$VM_DISK_PATH"
		elif id -u qemu >/dev/null 2>&1; then
			chown qemu:qemu "$VM_DISK_PATH" 2>/dev/null || chown root:root "$VM_DISK_PATH"
		else
			chown root:root "$VM_DISK_PATH"
		fi

		chmod 660 "$VM_DISK_PATH"
		print_success "Fixed permissions for $VM_DISK_PATH"
	fi

	print_info "[6/8] Cleaning VM configuration..."

	local temp_xml=$(mktemp)
	if virsh dumpxml "$vm_name" >"$temp_xml" 2>/dev/null; then
		sed -i '/<disk type="file" device="cdrom"/,/<\/disk>/d' "$temp_xml"
		sed -i '/<disk.*device="cdrom"/,/<\/disk>/d' "$temp_xml"

		sed -i '/<controller type="ide"/,/<\/controller>/d' "$temp_xml"

		sed -i "s|<source file='[^']*'/>|<source file='$VM_DISK_PATH'/>|g" "$temp_xml"

		sed -i '/<driver.*cache=/s/cache="[^"]*"//g' "$temp_xml"

		sed -i 's/<driver name="qemu"[^>]*>/<driver name="qemu" type="qcow2">/g' "$temp_xml"

		if virsh define "$temp_xml" >/dev/null 2>&1; then
			print_success "VM configuration cleaned and redefined"
		else
			print_warning "Could not redefine VM configuration"
		fi
	fi
	rm -f "$temp_xml"

	print_info "[7/8] Restarting libvirtd service..."
	if systemctl restart libvirtd 2>/dev/null || service libvirtd restart 2>/dev/null; then
		print_success "libvirtd restarted successfully"
	else
		print_warning "Could not restart libvirtd automatically"
	fi

	sleep 5

	local wait_count=0
	while ! virsh list >/dev/null 2>&1 && [ $wait_count -lt 10 ]; do
		sleep 2
		wait_count=$((wait_count + 1))
	done

	print_info "[8/8] Final verification..."

	if virsh list --all | grep -q " $vm_name "; then
		print_success "VM is properly defined in libvirt"
	else
		print_error "VM not found after cleanup"
		return 1
	fi

	if [ -f "$VM_DISK_PATH" ] && [ -r "$VM_DISK_PATH" ]; then
		print_success "Disk file is accessible"
	else
		print_error "Disk file is not accessible"
		return 1
	fi

	echo ""
	print_success "=== Lock Fix Complete for $vm_name ==="
	echo ""
	echo "You can now try:"
	echo "  dcvm start $vm_name"
	echo "  virsh start $vm_name"
	echo ""

	return 0
}

if [ "$VM_NAME" = "--all" ]; then
	print_info "Fixing locks for all VMs..."

	VM_LIST=$(virsh list --all --name | grep -v "^$")

	if [ -z "$VM_LIST" ]; then
		print_warning "No VMs found"
		exit 0
	fi

	for vm in $VM_LIST; do
		fix_vm_locks "$vm"
		echo ""
	done

	print_success "Lock fix completed for all VMs"
else
	fix_vm_locks "$VM_NAME"
fi
