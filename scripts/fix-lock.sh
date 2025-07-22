#!/bin/bash

# QEMU Lock Fix - Comprehensive fix for VM lock issues

VM_NAME="$1"

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

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

    # Step 1: Get VM configuration and disk path
    print_info "[1/8] Getting VM configuration..."
    
    # Check if VM exists
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

    # Step 2: Force stop everything
    print_info "[2/8] Force stopping VM and related processes..."
    
    # Destroy VM (force stop)
    virsh destroy "$vm_name" 2>/dev/null || true
    sleep 3
    
    # Kill any remaining QEMU processes for this VM
    pgrep -f "qemu.*$vm_name" | xargs -r kill -9 2>/dev/null || true
    sleep 2
    
    # Kill any QEMU processes using the disk file
    if [ -f "$VM_DISK_PATH" ]; then
        lsof "$VM_DISK_PATH" 2>/dev/null | awk 'NR>1 {print $2}' | xargs -r kill -9 2>/dev/null || true
    fi
    sleep 2

    # Step 3: Clear libvirt locks
    print_info "[3/8] Clearing libvirt lock files..."
    
    # Remove lock files from various locations
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

    # Step 4: Clear QEMU image locks
    print_info "[4/8] Clearing QEMU image locks..."
    
    # Remove any .lock files near the disk image
    local disk_dir=$(dirname "$VM_DISK_PATH")
    find "$disk_dir" -name "*.lock" -delete 2>/dev/null || true
    
    # Clear any shared memory locks
    local vm_basename=$(basename "$vm_name")
    rm -f /dev/shm/qemu_"$vm_basename"_* 2>/dev/null || true

    # Step 5: Fix file permissions and ownership
    print_info "[5/8] Fixing file permissions and ownership..."
    
    if [ -f "$VM_DISK_PATH" ]; then
        # Set proper ownership
        if id -u libvirt-qemu >/dev/null 2>&1; then
            chown libvirt-qemu:kvm "$VM_DISK_PATH" 2>/dev/null || chown root:root "$VM_DISK_PATH"
        elif id -u qemu >/dev/null 2>&1; then
            chown qemu:qemu "$VM_DISK_PATH" 2>/dev/null || chown root:root "$VM_DISK_PATH"
        else
            chown root:root "$VM_DISK_PATH"
        fi
        
        # Set proper permissions
        chmod 660 "$VM_DISK_PATH"
        print_success "Fixed permissions for $VM_DISK_PATH"
    fi

    # Step 6: Clean VM configuration
    print_info "[6/8] Cleaning VM configuration..."
    
    # Get current VM XML and clean it
    local temp_xml=$(mktemp)
    if virsh dumpxml "$vm_name" > "$temp_xml" 2>/dev/null; then
        # Remove any problematic CD-ROM/ISO attachments
        sed -i '/<disk type="file" device="cdrom"/,/<\/disk>/d' "$temp_xml"
        
        # Ensure correct disk path
        sed -i "s|<source file='[^']*'/>|<source file='$VM_DISK_PATH'/>|g" "$temp_xml"
        
        # Remove any cached disk format info that might cause issues
        sed -i '/<driver.*cache=/s/cache="[^"]*"//g' "$temp_xml"
        
        # Redefine VM with cleaned configuration
        if virsh define "$temp_xml" >/dev/null 2>&1; then
            print_success "VM configuration cleaned and redefined"
        else
            print_warning "Could not redefine VM configuration"
        fi
    fi
    rm -f "$temp_xml"

    # Step 7: Restart libvirtd to clear all cached locks
    print_info "[7/8] Restarting libvirtd service..."
    if systemctl restart libvirtd 2>/dev/null || service libvirtd restart 2>/dev/null; then
        print_success "libvirtd restarted successfully"
    else
        print_warning "Could not restart libvirtd automatically"
    fi
    
    # Wait for libvirtd to fully restart
    sleep 5
    
    # Wait for libvirtd to be ready
    local wait_count=0
    while ! virsh list >/dev/null 2>&1 && [ $wait_count -lt 10 ]; do
        sleep 2
        wait_count=$((wait_count + 1))
    done

    # Step 8: Final verification
    print_info "[8/8] Final verification..."
    
    # Check if VM is properly defined
    if virsh list --all | grep -q " $vm_name "; then
        print_success "VM is properly defined in libvirt"
    else
        print_error "VM not found after cleanup"
        return 1
    fi
    
    # Check disk file accessibility
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

# Main logic
if [ "$VM_NAME" = "--all" ]; then
    print_info "Fixing locks for all VMs..."
    
    # Get all VMs
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
