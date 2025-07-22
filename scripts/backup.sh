#!/bin/bash

# DCVM Backup & Restore Script
# Usage: dcvm backup <vm_name>
# Usage: dcvm restore <vm_name> [backup_date]

# Configuration
BACKUP_DIR="/srv/datacenter/backups"
LOG_FILE="/var/log/dcvm-backup.log"
DATE=$(date +%Y%m%d_%H%M%S)
KEEP_BACKUPS=5  # Number of backups to retain per VM
SHUTDOWN_TIMEOUT=60  # Seconds to wait for VM shutdown
COMPRESSION_ENABLED=true  # Enable/disable compression

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

# Logging function
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
}

# Check if VM exists
check_vm_exists() {
    local vm_name="$1"
    
    if ! virsh list --all 2>/dev/null | grep -q " $vm_name "; then
        return 1
    fi
    return 0
}

# Get VM state
get_vm_state() {
    local vm_name="$1"
    virsh domstate "$vm_name" 2>/dev/null
}

# Wait for VM to reach desired state
wait_for_vm_state() {
    local vm_name="$1"
    local desired_state="$2"
    local timeout="$3"
    local count=0
    
    while [ $count -lt $timeout ]; do
        local current_state=$(get_vm_state "$vm_name")
        if [ "$current_state" = "$desired_state" ]; then
            return 0
        fi
        sleep 1
        count=$((count + 1))
    done
    return 1
}

# Get disk path for VM
get_vm_disk_path() {
    local vm_name="$1"
    virsh domblklist "$vm_name" --details 2>/dev/null | grep "disk" | grep "file" | awk '{print $4}' | head -1
}

# Get file size in human readable format
get_file_size() {
    local file_path="$1"
    if [ -f "$file_path" ]; then
        du -h "$file_path" | cut -f1
    else
        echo "0"
    fi
}

# Cleanup old backups
cleanup_old_backups() {
    local vm_name="$1"
    
    print_info "Cleaning up old backups (keeping $KEEP_BACKUPS most recent)..."
    
    # Clean disk backups
    local disk_backups=$(ls -t "$BACKUP_DIR"/${vm_name}-disk-*.qcow2 2>/dev/null | tail -n +$((KEEP_BACKUPS + 1)))
    if [ -n "$disk_backups" ]; then
        echo "$disk_backups" | xargs rm -f
        log "INFO" "Removed old disk backups for $vm_name"
    fi
    
    # Clean config backups
    local config_backups=$(ls -t "$BACKUP_DIR"/${vm_name}-config-*.xml 2>/dev/null | tail -n +$((KEEP_BACKUPS + 1)))
    if [ -n "$config_backups" ]; then
        echo "$config_backups" | xargs rm -f
        log "INFO" "Removed old config backups for $vm_name"
    fi
    
    print_success "Cleanup completed"
}

# List available backups for a VM
list_backups() {
    local vm_name="$1"
    
    print_info "Available backups for VM: $vm_name"
    echo ""
    
    # Find all disk backups for this VM
    local backups=($(ls -t "$BACKUP_DIR"/${vm_name}-disk-*.qcow2* 2>/dev/null))
    
    if [ ${#backups[@]} -eq 0 ]; then
        print_warning "No backups found for VM: $vm_name"
        return 1
    fi
    
    echo "Date/Time           Size      Type       Status"
    echo "=================== ========= ========== ========"
    
    for backup in "${backups[@]}"; do
        local basename_backup=$(basename "$backup")
        local date_part=$(echo "$basename_backup" | sed -E "s/${vm_name}-disk-(.*)\.qcow2(\.gz)?/\1/")
        local size=$(get_file_size "$backup")
        local type="qcow2"
        local status="✓"
        
        # Check if compressed
        if [[ "$backup" == *.gz ]]; then
            type="qcow2+gz"
        fi
        
        # Check if corresponding config exists
        local config_file="$BACKUP_DIR/${vm_name}-config-${date_part}.xml"
        if [ ! -f "$config_file" ]; then
            status="⚠ No config"
        fi
        
        # Format date for display
        local formatted_date=$(echo "$date_part" | sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)_\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1-\2-\3 \4:\5:\6/')
        
        printf "%-19s %-9s %-10s %s\n" "$formatted_date" "$size" "$type" "$status"
    done
    
    echo ""
    return 0
}

# Troubleshoot VM startup issues
troubleshoot_vm() {
    local vm_name="$1"
    
    print_info "Troubleshooting VM: $vm_name"
    
    # Check if VM exists
    if ! check_vm_exists "$vm_name"; then
        print_error "VM '$vm_name' does not exist"
        return 1
    fi
    
    # Get VM disk path
    local vm_disk_path=$(get_vm_disk_path "$vm_name")
    if [ -z "$vm_disk_path" ]; then
        print_error "Could not find disk path for VM '$vm_name'"
        return 1
    fi
    
    print_info "VM disk path: $vm_disk_path"
    
    # Check if disk file exists
    if [ ! -f "$vm_disk_path" ]; then
        print_error "Disk file does not exist: $vm_disk_path"
        return 1
    fi
    
    # Check file permissions
    print_info "Current file permissions:"
    ls -la "$vm_disk_path"
    
    # Check processes using the file
    print_info "Checking for processes using the disk file..."
    local using_processes=$(lsof "$vm_disk_path" 2>/dev/null || fuser "$vm_disk_path" 2>/dev/null || echo "none")
    if [ "$using_processes" != "none" ]; then
        print_warning "Processes using the disk file:"
        echo "$using_processes"
        print_info "Attempting to stop conflicting processes..."
        
        # Try to stop any running VMs with this name first
        virsh destroy "$vm_name" 2>/dev/null || true
        sleep 2
        
        # Check again
        using_processes=$(lsof "$vm_disk_path" 2>/dev/null || fuser "$vm_disk_path" 2>/dev/null || echo "none")
        if [ "$using_processes" != "none" ]; then
            print_error "Still have processes using the file after cleanup"
            return 1
        fi
    else
        print_success "No processes are using the disk file"
    fi
    
    # Fix permissions and ownership
    print_info "Fixing file permissions and ownership..."
    
    # Set proper ownership
    if id -u libvirt-qemu >/dev/null 2>&1; then
        chown libvirt-qemu:kvm "$vm_disk_path" 2>/dev/null || chown root:root "$vm_disk_path"
        print_info "Set ownership to libvirt-qemu:kvm"
    elif id -u qemu >/dev/null 2>&1; then
        chown qemu:qemu "$vm_disk_path" 2>/dev/null || chown root:root "$vm_disk_path"
        print_info "Set ownership to qemu:qemu"
    else
        chown root:root "$vm_disk_path"
        print_info "Set ownership to root:root"
    fi
    
    # Set proper permissions
    chmod 660 "$vm_disk_path"
    print_info "Set permissions to 660"
    
    # Restore SELinux context if needed
    if command -v restorecon >/dev/null 2>&1 && [ -f /selinux/enforce ]; then
        restorecon "$vm_disk_path" 2>/dev/null && print_info "Restored SELinux context" || true
    fi
    
    # Show final permissions
    print_info "Final file permissions:"
    ls -la "$vm_disk_path"
    
    # Try to start the VM
    print_info "Attempting to start VM..."
    if virsh start "$vm_name" >/dev/null 2>&1; then
        print_success "VM started successfully"
        return 0
    else
        print_error "VM still failed to start"
        print_info "Last few lines of libvirt log:"
        tail -10 /var/log/libvirt/qemu/"$vm_name".log 2>/dev/null || echo "Log file not found"
        return 1
    fi
}
get_latest_backup() {
    local vm_name="$1"
    
    local latest_backup=$(ls -t "$BACKUP_DIR"/${vm_name}-disk-*.qcow2* 2>/dev/null | head -1)
    if [ -n "$latest_backup" ]; then
        local basename_backup=$(basename "$latest_backup")
        echo "$basename_backup" | sed -E "s/${vm_name}-disk-(.*)\.qcow2(\.gz)?/\1/"
    fi
}

# Restore VM from backup - COMPLETELY REWRITTEN FOR RELIABILITY
restore_vm() {
    local vm_name="$1"
    local backup_date="$2"
    local force_restore="$3"
    
    print_info "Starting restore for VM: $vm_name"
    log "INFO" "Starting restore for VM: $vm_name"
    
    # If no backup date specified, use latest
    if [ -z "$backup_date" ]; then
        backup_date=$(get_latest_backup "$vm_name")
        if [ -z "$backup_date" ]; then
            print_error "No backups found for VM: $vm_name"
            log "ERROR" "No backups found for VM: $vm_name"
            return 1
        fi
        print_info "Using latest backup: $backup_date"
    fi
    
    # Find backup files
    local disk_backup=""
    local config_backup="$BACKUP_DIR/${vm_name}-config-${backup_date}.xml"
    local is_compressed=false
    
    # Check for compressed or uncompressed disk backup
    if [ -f "$BACKUP_DIR/${vm_name}-disk-${backup_date}.qcow2.gz" ]; then
        disk_backup="$BACKUP_DIR/${vm_name}-disk-${backup_date}.qcow2.gz"
        is_compressed=true
        print_info "Found compressed backup: $(basename "$disk_backup")"
    elif [ -f "$BACKUP_DIR/${vm_name}-disk-${backup_date}.qcow2" ]; then
        disk_backup="$BACKUP_DIR/${vm_name}-disk-${backup_date}.qcow2"
        is_compressed=false
        print_info "Found uncompressed backup: $(basename "$disk_backup")"
    else
        print_error "Backup not found for date: $backup_date"
        print_info "Available backups:"
        list_backups "$vm_name"
        return 1
    fi
    
    if [ ! -f "$config_backup" ]; then
        print_error "Configuration backup not found: $config_backup"
        return 1
    fi
    
    print_info "Found backup files:"
    print_info "  Disk: $(basename "$disk_backup") ($(get_file_size "$disk_backup"))"
    print_info "  Config: $(basename "$config_backup")"
    
    # Check if VM currently exists
    if check_vm_exists "$vm_name"; then
        local vm_state=$(get_vm_state "$vm_name")
        print_warning "VM '$vm_name' already exists (state: $vm_state)"
        
        if [ "$force_restore" != "true" ]; then
            echo ""
            print_warning "This will COMPLETELY REPLACE the existing VM!"
            print_warning "All current data in the VM will be LOST!"
            echo ""
            read -p "Are you sure you want to continue? (type 'yes' to confirm): " confirm
            
            if [ "$confirm" != "yes" ]; then
                print_info "Restore cancelled by user"
                return 0
            fi
        fi
        
        # Stop VM if running
        if [ "$vm_state" = "running" ]; then
            print_info "Stopping existing VM..."
            virsh shutdown "$vm_name" >/dev/null 2>&1
            
            if ! wait_for_vm_state "$vm_name" "shut off" "$SHUTDOWN_TIMEOUT"; then
                print_warning "Graceful shutdown failed, forcing stop..."
                virsh destroy "$vm_name" >/dev/null 2>&1
                sleep 5
            fi
        fi
        
        # Undefine existing VM
        print_info "Removing existing VM definition..."
        virsh undefine "$vm_name" --remove-all-storage >/dev/null 2>&1 || true
    fi
    
    # Get VM directory path
    local vm_dir="/srv/datacenter/vms/$vm_name"
    local vm_disk_path="$vm_dir/${vm_name}-disk.qcow2"
    
    # Create VM directory
    print_info "Preparing VM directory..."
    if ! mkdir -p "$vm_dir"; then
        print_error "Failed to create VM directory: $vm_dir"
        return 1
    fi
    
    # Handle backup restoration based on compression
    if [ "$is_compressed" = true ]; then
        print_info "Decompressing backup directly to destination..."
        
        # Test the compressed file first
        if ! gunzip -t "$disk_backup" >/dev/null 2>&1; then
            print_error "Compressed backup file is corrupted: $disk_backup"
            return 1
        fi
        
        # Decompress directly to destination with progress
        local original_size=$(stat -f%z "$disk_backup" 2>/dev/null || stat -c%s "$disk_backup" 2>/dev/null || echo "unknown")
        print_info "Decompressing $original_size bytes..."
        
        if gunzip -c "$disk_backup" > "$vm_disk_path" 2>/dev/null; then
            # Verify the decompressed file
            if [ -f "$vm_disk_path" ] && [ -s "$vm_disk_path" ]; then
                local restored_size=$(get_file_size "$vm_disk_path")
                print_success "Backup decompressed and restored ($restored_size)"
            else
                print_error "Decompressed file is empty or missing"
                rm -f "$vm_disk_path"
                return 1
            fi
        else
            print_error "Failed to decompress backup"
            rm -f "$vm_disk_path"
            return 1
        fi
    else
        print_info "Copying uncompressed backup..."
        
        if cp "$disk_backup" "$vm_disk_path"; then
            local restored_size=$(get_file_size "$vm_disk_path")
            print_success "Backup copied successfully ($restored_size)"
        else
            print_error "Failed to copy backup file"
            return 1
        fi
    fi
    
    # Verify the restored disk file
    if [ ! -f "$vm_disk_path" ] || [ ! -s "$vm_disk_path" ]; then
        print_error "Restored disk file is missing or empty: $vm_disk_path"
        return 1
    fi
    
    # Fix file permissions and ownership
    print_info "Setting correct permissions and ownership..."
    
    # Set proper ownership (libvirt-qemu:kvm or qemu:qemu depending on system)
    if id -u libvirt-qemu >/dev/null 2>&1; then
        chown libvirt-qemu:kvm "$vm_disk_path" 2>/dev/null || chown root:root "$vm_disk_path"
    elif id -u qemu >/dev/null 2>&1; then
        chown qemu:qemu "$vm_disk_path" 2>/dev/null || chown root:root "$vm_disk_path"
    else
        chown root:root "$vm_disk_path"
    fi
    
    # Set proper permissions (readable/writable by owner and group)
    chmod 660 "$vm_disk_path"
    
    # Restore SELinux context if SELinux is enabled
    if command -v restorecon >/dev/null 2>&1 && [ -f /selinux/enforce ]; then
        restorecon "$vm_disk_path" 2>/dev/null || true
    fi
    
    print_success "File permissions and ownership set"
    
    # Restore VM configuration
    print_info "Restoring VM configuration..."
    
    # Create temporary config file with updated disk path
    local temp_config=$(mktemp)
    
    # Update disk path in config to point to restored location
    if sed "s|<source file='[^']*'/>|<source file='$vm_disk_path'/>|g" "$config_backup" > "$temp_config"; then
        if virsh define "$temp_config" >/dev/null 2>&1; then
            print_success "VM configuration restored"
            log "INFO" "VM configuration restored for $vm_name"
        else
            print_error "Failed to define VM from configuration"
            cat "$temp_config"
            rm -f "$temp_config"
            return 1
        fi
    else
        print_error "Failed to update configuration file"
        rm -f "$temp_config"
        return 1
    fi
    
    rm -f "$temp_config"
    
    # Set VM to autostart
    if virsh autostart "$vm_name" >/dev/null 2>&1; then
        print_success "VM autostart enabled"
    else
        print_warning "Failed to enable VM autostart (VM may still work)"
    fi
    
    # Final verification
    if check_vm_exists "$vm_name"; then
        print_success "VM successfully restored and defined in libvirt"
    else
        print_error "VM restore completed but VM not found in libvirt"
        return 1
    fi
    
    # Show restore summary
    echo ""
    echo "=================================================="
    print_success "Restore completed for VM: $vm_name"
    echo "=================================================="
    echo "Restored from backup:"
    echo "  Date: $backup_date"
    echo "  Source: $(basename "$disk_backup")"
    echo "  Compression: $([ "$is_compressed" = true ] && echo "Yes" || echo "No")"
    echo "  VM Directory: $vm_dir"
    echo "  Disk Size: $(get_file_size "$vm_disk_path")"
    echo ""
    echo "VM Status: $(get_vm_state "$vm_name")"
    echo ""
    echo "Next steps:"
    echo "  Start VM: virsh start $vm_name"
    echo "  Console:  virsh console $vm_name"
    echo "  Or use:   dcvm start $vm_name"
    echo ""
    
    log "SUCCESS" "Restore completed successfully for VM: $vm_name from backup: $backup_date"
    return 0
}

compress_backup() {
    local file_path="$1"
    local vm_name="$2"
    
    if [ "$COMPRESSION_ENABLED" = true ]; then
        print_info "Compressing backup..."
        local compressed_file="${file_path}.gz"
        
        if gzip "$file_path"; then
            local original_size=$(get_file_size "$file_path")
            local compressed_size=$(get_file_size "$compressed_file")
            print_success "Compression completed (${compressed_size})"
            log "INFO" "Compressed backup for $vm_name: $original_size -> $compressed_size"
            echo "$compressed_file"
        else
            print_error "Compression failed, keeping uncompressed backup"
            log "ERROR" "Failed to compress backup for $vm_name"
            echo "$file_path"
        fi
    else
        echo "$file_path"
    fi
}

# Main backup function
backup_vm() {
    local vm_name="$1"
    local was_running=false
    
    print_info "Starting backup for VM: $vm_name"
    log "INFO" "Starting backup for VM: $vm_name"
    
    # Check if VM exists
    if ! check_vm_exists "$vm_name"; then
        print_error "VM '$vm_name' does not exist"
        log "ERROR" "VM '$vm_name' does not exist"
        return 1
    fi
    
    # Get VM disk path
    local vm_disk_path=$(get_vm_disk_path "$vm_name")
    if [ -z "$vm_disk_path" ]; then
        print_error "Could not find disk path for VM '$vm_name'"
        log "ERROR" "Could not find disk path for VM '$vm_name'"
        return 1
    fi
    
    print_info "VM disk path: $vm_disk_path"
    print_info "Disk size: $(get_file_size "$vm_disk_path")"
    
    # Check current VM state
    local vm_state=$(get_vm_state "$vm_name")
    print_info "VM current state: $vm_state"
    
    if [ "$vm_state" = "running" ]; then
        was_running=true
        print_info "Shutting down VM for consistent backup..."
        
        # Attempt graceful shutdown
        if virsh shutdown "$vm_name" >/dev/null 2>&1; then
            print_info "Shutdown command sent, waiting up to ${SHUTDOWN_TIMEOUT}s..."
            
            if wait_for_vm_state "$vm_name" "shut off" "$SHUTDOWN_TIMEOUT"; then
                print_success "VM shut down gracefully"
                log "INFO" "VM $vm_name shut down gracefully"
            else
                print_warning "Graceful shutdown timeout, forcing shutdown..."
                virsh destroy "$vm_name" >/dev/null 2>&1
                sleep 5
                log "WARNING" "Forced shutdown of VM $vm_name"
            fi
        else
            print_error "Failed to send shutdown command"
            log "ERROR" "Failed to send shutdown command to VM $vm_name"
            return 1
        fi
    fi
    
    # Create backup directory if it doesn't exist
    if ! mkdir -p "$BACKUP_DIR"; then
        print_error "Failed to create backup directory: $BACKUP_DIR"
        log "ERROR" "Failed to create backup directory: $BACKUP_DIR"
        return 1
    fi
    
    # Define backup file paths
    local disk_backup="$BACKUP_DIR/${vm_name}-disk-$DATE.qcow2"
    local config_backup="$BACKUP_DIR/${vm_name}-config-$DATE.xml"
    
    # Backup VM disk
    print_info "Backing up VM disk..."
    if cp "$vm_disk_path" "$disk_backup"; then
        local disk_size=$(get_file_size "$disk_backup")
        print_success "Disk backup completed ($disk_size)"
        log "INFO" "Disk backup completed for $vm_name: $disk_size"
        
        # Compress if enabled
        disk_backup=$(compress_backup "$disk_backup" "$vm_name")
    else
        print_error "Failed to backup VM disk"
        log "ERROR" "Failed to backup VM disk for $vm_name"
        
        # Start VM if it was running before backup
        if [ "$was_running" = true ]; then
            print_info "Restarting VM..."
            virsh start "$vm_name" >/dev/null 2>&1
        fi
        return 1
    fi
    
    # Backup VM configuration
    print_info "Backing up VM configuration..."
    if virsh dumpxml "$vm_name" > "$config_backup" 2>/dev/null; then
        print_success "Configuration backup completed"
        log "INFO" "Configuration backup completed for $vm_name"
    else
        print_error "Failed to backup VM configuration"
        log "ERROR" "Failed to backup VM configuration for $vm_name"
    fi
    
    # Restart VM if it was running
    if [ "$was_running" = true ]; then
        print_info "Restarting VM..."
        if virsh start "$vm_name" >/dev/null 2>&1; then
            print_success "VM restarted successfully"
            log "INFO" "VM $vm_name restarted successfully"
        else
            print_error "Failed to restart VM"
            log "ERROR" "Failed to restart VM $vm_name"
        fi
    fi
    
    # Cleanup old backups
    cleanup_old_backups "$vm_name"
    
    # Show backup summary
    echo ""
    echo "=================================================="
    print_success "Backup completed for VM: $vm_name"
    echo "=================================================="
    echo "Backup files created:"
    echo "  Disk: $(basename "$disk_backup")"
    echo "  Config: $(basename "$config_backup")"
    echo "  Location: $BACKUP_DIR"
    echo "  Timestamp: $DATE"
    if [ "$COMPRESSION_ENABLED" = true ]; then
        echo "  Compression: Enabled"
    fi
    echo ""
    
    log "SUCCESS" "Backup completed successfully for VM: $vm_name"
    return 0
}

# Usage information
if [ $# -lt 1 ]; then
    echo "VM Backup & Restore Script"
    echo "Usage: dcvm backup <vm_name>"
    echo "       dcvm restore <vm_name> [backup_date]"
    echo "       dcvm list-backups <vm_name>"
    echo "       dcvm troubleshoot <vm_name>"
    echo ""
    echo "Examples:"
    echo "  dcvm backup datacenter-vm1              # Create backup"
    echo "  dcvm restore datacenter-vm1             # Restore from latest backup"
    echo "  dcvm restore datacenter-vm1 20250722_143052  # Restore from specific backup"
    echo "  dcvm list-backups datacenter-vm1        # List available backups"
    echo "  dcvm troubleshoot vm1                   # Fix VM startup issues"
    echo ""
    echo "Options:"
    echo "  Backups are stored in: $BACKUP_DIR"
    echo "  Retention: $KEEP_BACKUPS backups per VM"
    echo "  Compression: $([ "$COMPRESSION_ENABLED" = true ] && echo "Enabled" || echo "Disabled")"
    echo ""
    echo "⚠️  WARNING: Restore will COMPLETELY REPLACE the existing VM!"
    exit 1
fi

OPERATION="$1"
VM_NAME="$2"

# Handle different operations
case "$OPERATION" in
    "backup")
        if [ -z "$VM_NAME" ]; then
            print_error "VM name required for backup operation"
            exit 1
        fi
        ;;
    "restore")
        if [ -z "$VM_NAME" ]; then
            print_error "VM name required for restore operation"
            exit 1
        fi
        BACKUP_DATE="$3"
        ;;
    "list-backups")
        if [ -z "$VM_NAME" ]; then
            print_error "VM name required for list-backups operation"
            exit 1
        fi
        ;;
    "troubleshoot")
        if [ -z "$VM_NAME" ]; then
            print_error "VM name required for troubleshoot operation"
            exit 1
        fi
        ;;
    *)
        print_error "Unknown operation: $OPERATION"
        echo "Valid operations: backup, restore, list-backups"
        exit 1
        ;;
esac

# Check if required commands exist
for cmd in virsh cp gzip gunzip; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        print_error "Required command not found: $cmd"
        exit 1
    fi
done

# Check if log directory exists
LOG_DIR=$(dirname "$LOG_FILE")
if [ ! -d "$LOG_DIR" ]; then
    mkdir -p "$LOG_DIR" 2>/dev/null || {
        print_warning "Cannot create log directory, logging to stdout only"
        LOG_FILE="/dev/null"
    }
fi

# Execute operation
case "$OPERATION" in
    "backup")
        backup_vm "$VM_NAME"
        exit $?
        ;;
    "restore")
        restore_vm "$VM_NAME" "$BACKUP_DATE"
        exit $?
        ;;
    "list-backups")
        list_backups "$VM_NAME"
        exit $?
        ;;
    "troubleshoot")
        troubleshoot_vm "$VM_NAME"
        exit $?
        ;;
esac
