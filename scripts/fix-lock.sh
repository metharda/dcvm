#!/bin/bash

# QEMU Lock Fix - Specific fix for the "Failed to get shared write lock" error

VM_NAME="$1"

if [ -z "$VM_NAME" ]; then
    echo "Usage: $0 <vm_name>"
    exit 1
fi

echo "=== QEMU Lock Fix for $VM_NAME ==="

# Step 1: Get VM configuration and disk path
echo "[1/7] Getting VM configuration..."
VM_DISK_PATH=$(virsh domblklist "$VM_NAME" --details 2>/dev/null | grep "disk" | grep "file" | awk '{print $4}' | head -1)

if [ -z "$VM_DISK_PATH" ]; then
    echo "ERROR: Could not find disk path for VM $VM_NAME"
    exit 1
fi

echo "VM disk path: $VM_DISK_PATH"

# Step 2: Stop everything aggressively
echo "[2/7] Stopping all VM processes..."
virsh destroy "$VM_NAME" 2>/dev/null || true
sleep 2

# Kill any remaining QEMU processes
pkill -f "$VM_NAME" 2>/dev/null || true
sleep 2

# Step 3: Check QEMU lock files in /var/lib/libvirt/qemu/
echo "[3/7] Checking QEMU lock directories..."
QEMU_DIR="/var/lib/libvirt/qemu"
if [ -d "$QEMU_DIR" ]; then
    # Remove any lock files for this VM
    find "$QEMU_DIR" -name "*${VM_NAME}*" -type f | grep -E "\.lock|\.pid" | xargs rm -f 2>/dev/null || true
fi

# Step 4: Clear QEMU image locks specifically
echo "[4/7] Clearing QEMU image locks..."

# QEMU stores image locks in memory and in lock files
# Force unlock the image file
if command -v qemu-img >/dev/null 2>&1; then
    # Try to detect if qemu-img can see any locks
    echo "Checking image with qemu-img info..."
    qemu-img info "$VM_DISK_PATH" >/dev/null 2>&1 || echo "Warning: qemu-img reports issues with image"
fi

# Step 5: Completely recreate the disk file to break any locks
echo "[5/7] Creating fresh disk file to break locks..."
TEMP_DISK="${VM_DISK_PATH}.unlocked"

# Copy with dd to ensure a completely fresh inode
dd if="$VM_DISK_PATH" of="$TEMP_DISK" bs=1M status=progress 2>/dev/null || cp "$VM_DISK_PATH" "$TEMP_DISK"

if [ $? -eq 0 ]; then
    # Replace the original
    mv "$TEMP_DISK" "$VM_DISK_PATH"
    echo "Fresh disk file created"
else
    echo "ERROR: Failed to create fresh disk file"
    rm -f "$TEMP_DISK"
    exit 1
fi

# Step 6: Fix VM configuration that might be causing lock issues
echo "[6/7] Checking VM configuration for lock-causing elements..."

# Get current VM XML
VM_XML=$(virsh dumpxml "$VM_NAME" 2>/dev/null)
if [ $? -ne 0 ]; then
    echo "ERROR: Could not get VM configuration"
    exit 1
fi

# Check for problematic configurations
echo "$VM_XML" | grep -q "ide-cd" && echo "Found IDE CD-ROM in configuration"
echo "$VM_XML" | grep -q "readonly='yes'" && echo "Found read-only devices"

# Create a cleaned VM configuration
TEMP_XML=$(mktemp)

# Remove any CD-ROM/ISO attachments that might be causing locks
echo "$VM_XML" | sed '/<disk type="file" device="cdrom"/,/<\/disk>/d' > "$TEMP_XML"

# Update disk path to ensure it's correct
sed -i "s|<source file='[^']*'/>|<source file='$VM_DISK_PATH'/>|g" "$TEMP_XML"

# Redefine VM with cleaned configuration
if virsh define "$TEMP_XML" >/dev/null 2>&1; then
    echo "VM configuration updated (removed potential lock-causing elements)"
else
    echo "Warning: Could not update VM configuration"
fi

rm -f "$TEMP_XML"

# Step 7: Set correct permissions and restart libvirtd
echo "[7/7] Final cleanup and permissions..."

# Set ownership
if id -u libvirt-qemu >/dev/null 2>&1; then
    chown libvirt-qemu:kvm "$VM_DISK_PATH"
elif id -u qemu >/dev/null 2>&1; then
    chown qemu:qemu "$VM_DISK_PATH"
else
    chown root:root "$VM_DISK_PATH"
fi

# Set permissions
chmod 660 "$VM_DISK_PATH"

# Restart libvirtd to clear all cached locks
echo "Restarting libvirtd..."
systemctl restart libvirtd 2>/dev/null || service libvirtd restart 2>/dev/null
sleep 5

# Wait for libvirtd to fully restart
echo "Waiting for libvirtd to stabilize..."
sleep 5

echo "=== Lock Fix Complete ==="
echo ""
echo "Now try: dcvm start $VM_NAME"
echo "Or manually: virsh start $VM_NAME"
echo ""
echo "If it still fails, the disk image may be corrupted."
echo "Check with: qemu-img check $VM_DISK_PATH"
