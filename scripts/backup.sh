#!/bin/bash

BACKUP_DIR="/srv/datacenter/backups"
LOG_FILE="/var/log/dcvm-backup.log"
DATE=$(date +%Y%m%d_%H%M%S)
KEEP_BACKUPS=5
SHUTDOWN_TIMEOUT=60
COMPRESSION_ENABLED=true

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

log() {
	local level="$1"
	shift
	local message="$*"
	local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

	echo "[$timestamp] [$level] $message" >>"$LOG_FILE"
}

check_vm_exists() {
	local vm_name="$1"

	if ! virsh list --all 2>/dev/null | grep -q " $vm_name "; then
		return 1
	fi
	return 0
}

get_vm_state() {
	local vm_name="$1"
	virsh domstate "$vm_name" 2>/dev/null
}

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

get_vm_disk_path() {
	local vm_name="$1"
	virsh domblklist "$vm_name" --details 2>/dev/null | grep "disk" | grep "file" | awk '{print $4}' | head -1
}

get_file_size() {
	local file_path="$1"
	if [ -f "$file_path" ]; then
		du -h "$file_path" | cut -f1
	else
		echo "0"
	fi
}

cleanup_old_backups() {
	local vm_name="$1"

	print_info "Cleaning up old backups (keeping $KEEP_BACKUPS most recent)..."

	local disk_backups=$(ls -t "$BACKUP_DIR"/${vm_name}-disk-*.qcow2 2>/dev/null | tail -n +$((KEEP_BACKUPS + 1)))
	if [ -n "$disk_backups" ]; then
		echo "$disk_backups" | xargs rm -f
		log "INFO" "Removed old disk backups for $vm_name"
	fi

	local config_backups=$(ls -t "$BACKUP_DIR"/${vm_name}-config-*.xml 2>/dev/null | tail -n +$((KEEP_BACKUPS + 1)))
	if [ -n "$config_backups" ]; then
		echo "$config_backups" | xargs rm -f
		log "INFO" "Removed old config backups for $vm_name"
	fi

	print_success "Cleanup completed"
}

list_backups() {
	local vm_name="$1"

	print_info "Available backups for VM: $vm_name"
	echo ""

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

		if [[ "$backup" == *.gz ]]; then
			type="qcow2+gz"
		fi

		local config_file="$BACKUP_DIR/${vm_name}-config-${date_part}.xml"
		if [ ! -f "$config_file" ]; then
			status="⚠ No config"
		fi

		local formatted_date=$(echo "$date_part" | sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)_\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1-\2-\3 \4:\5:\6/')

		printf "%-19s %-9s %-10s %s\n" "$formatted_date" "$size" "$type" "$status"
	done

	echo ""
	return 0
}

troubleshoot_vm() {
	local vm_name="$1"

	print_info "Troubleshooting VM: $vm_name"

	if ! check_vm_exists "$vm_name"; then
		print_error "VM '$vm_name' does not exist"
		return 1
	fi

	local vm_disk_path=$(get_vm_disk_path "$vm_name")
	if [ -z "$vm_disk_path" ]; then
		print_error "Could not find disk path for VM '$vm_name'"
		return 1
	fi

	print_info "VM disk path: $vm_disk_path"

	if [ ! -f "$vm_disk_path" ]; then
		print_error "Disk file does not exist: $vm_disk_path"
		return 1
	fi

	print_info "Performing comprehensive lock and file fix..."

	print_info "Force stopping VM and related processes..."
	virsh destroy "$vm_name" 2>/dev/null || true
	sleep 3

	pgrep -f "qemu.*$vm_name" | xargs -r kill -9 2>/dev/null || true
	sleep 2

	lsof "$vm_disk_path" 2>/dev/null | awk 'NR>1 {print $2}' | xargs -r kill -9 2>/dev/null || true
	sleep 2

	print_info "Clearing libvirt lock files..."
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

	print_info "Clearing QEMU image locks..."
	local disk_dir=$(dirname "$vm_disk_path")
	find "$disk_dir" -name "*.lock" -delete 2>/dev/null || true
	rm -f /dev/shm/qemu_"$(basename "$vm_name")"_* 2>/dev/null || true

	print_info "Fixing file permissions and ownership..."

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

	chmod 660 "$vm_disk_path"
	print_info "Set permissions to 660"

	print_info "Cleaning VM configuration..."
	local temp_xml=$(mktemp)
	if virsh dumpxml "$vm_name" >"$temp_xml" 2>/dev/null; then
		sed -i '/<disk type="file" device="cdrom"/,/<\/disk>/d' "$temp_xml"
		sed -i "s|<source file='[^']*'/>|<source file='$vm_disk_path'/>|g" "$temp_xml"
		sed -i '/<driver.*cache=/s/cache="[^"]*"//g' "$temp_xml"

		if virsh define "$temp_xml" >/dev/null 2>&1; then
			print_success "VM configuration cleaned and redefined"
		else
			print_warning "Could not redefine VM configuration"
		fi
	fi
	rm -f "$temp_xml"

	print_info "Restarting libvirtd service..."
	if systemctl restart libvirtd 2>/dev/null || service libvirtd restart 2>/dev/null; then
		print_success "libvirtd restarted successfully"
	else
		print_warning "Could not restart libvirtd automatically"
	fi

	local wait_count=0
	while ! virsh list >/dev/null 2>&1 && [ $wait_count -lt 15 ]; do
		sleep 2
		wait_count=$((wait_count + 1))
	done

	if command -v restorecon >/dev/null 2>&1 && [ -f /selinux/enforce ]; then
		restorecon "$vm_disk_path" 2>/dev/null && print_info "Restored SELinux context" || true
	fi

	print_info "Final file permissions:"
	ls -la "$vm_disk_path"

	print_info "Attempting to start VM..."

	if ! virsh list --all | grep -q " $vm_name "; then
		print_error "VM not found after cleanup and restart"
		return 1
	fi

	local start_error=""
	if start_error=$(virsh start "$vm_name" 2>&1); then
		print_success "VM started successfully"

		sleep 3
		if virsh list | grep -q "$vm_name.*running"; then
			print_success "VM is running and stable"
			return 0
		else
			print_warning "VM started but may have stopped"
		fi
	else
		print_error "VM failed to start"
		print_info "Error details: $start_error"
		print_info "Last few lines of libvirt log:"
		tail -10 /var/log/libvirt/qemu/"$vm_name".log 2>/dev/null || echo "Log file not found"

		print_info "Additional troubleshooting information:"
		print_info "Checking disk image integrity..."
		if command -v qemu-img >/dev/null 2>&1; then
			qemu-img check "$vm_disk_path" 2>&1 | head -5
		fi

		print_info "Suggesting fix-lock.sh for advanced lock resolution..."
		local fix_lock_script="/srv/datacenter/scripts/fix-lock.sh"
		if [ -f "$fix_lock_script" ]; then
			print_info "Try running: sudo $fix_lock_script $vm_name"
		fi

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

restore_vm() {
	local vm_name="$1"
	local backup_date="$2"
	local force_restore="$3"

	print_info "Starting restore for VM: $vm_name"
	log "INFO" "Starting restore for VM: $vm_name"

	if [ -z "$backup_date" ]; then
		backup_date=$(get_latest_backup "$vm_name")
		if [ -z "$backup_date" ]; then
			print_error "No backups found for VM: $vm_name"
			log "ERROR" "No backups found for VM: $vm_name"
			return 1
		fi
		print_info "Using latest backup: $backup_date"
	fi

	local disk_backup=""
	local config_backup="$BACKUP_DIR/${vm_name}-config-${backup_date}.xml"
	local is_compressed=false

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

		if [ "$vm_state" = "running" ]; then
			print_info "Stopping existing VM..."
			virsh shutdown "$vm_name" >/dev/null 2>&1

			if ! wait_for_vm_state "$vm_name" "shut off" "$SHUTDOWN_TIMEOUT"; then
				print_warning "Graceful shutdown failed, forcing stop..."
				virsh destroy "$vm_name" >/dev/null 2>&1
				sleep 5
			fi
		fi

		print_info "Removing existing VM definition..."
		virsh undefine "$vm_name" --remove-all-storage >/dev/null 2>&1 || true
	fi

	local vm_dir="/srv/datacenter/vms/$vm_name"
	local vm_disk_path="$vm_dir/${vm_name}-disk.qcow2"

	print_info "Preparing VM directory..."
	if ! mkdir -p "$vm_dir"; then
		print_error "Failed to create VM directory: $vm_dir"
		return 1
	fi

	if [ "$is_compressed" = true ]; then
		print_info "Decompressing backup directly to destination..."

		if ! gunzip -t "$disk_backup" >/dev/null 2>&1; then
			print_error "Compressed backup file is corrupted: $disk_backup"
			return 1
		fi

		local original_size=$(stat -f%z "$disk_backup" 2>/dev/null || stat -c%s "$disk_backup" 2>/dev/null || echo "unknown")
		print_info "Decompressing $original_size bytes..."

		if gunzip -c "$disk_backup" >"$vm_disk_path" 2>/dev/null; then
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

	if [ ! -f "$vm_disk_path" ] || [ ! -s "$vm_disk_path" ]; then
		print_error "Restored disk file is missing or empty: $vm_disk_path"
		return 1
	fi

	print_info "Setting correct permissions and ownership..."

	if id -u libvirt-qemu >/dev/null 2>&1; then
		chown libvirt-qemu:kvm "$vm_disk_path" 2>/dev/null || chown root:root "$vm_disk_path"
	elif id -u qemu >/dev/null 2>&1; then
		chown qemu:qemu "$vm_disk_path" 2>/dev/null || chown root:root "$vm_disk_path"
	else
		chown root:root "$vm_disk_path"
	fi

	chmod 660 "$vm_disk_path"

	if command -v restorecon >/dev/null 2>&1 && [ -f /selinux/enforce ]; then
		restorecon "$vm_disk_path" 2>/dev/null || true
	fi

	print_success "File permissions and ownership set"

	print_info "Restoring VM configuration..."

	local temp_config=$(mktemp)

	if sed "s|<source file='[^']*'/>|<source file='$vm_disk_path'/>|g" "$config_backup" >"$temp_config"; then
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

	if virsh autostart "$vm_name" >/dev/null 2>&1; then
		print_success "VM autostart enabled"
	else
		print_warning "Failed to enable VM autostart (VM may still work)"
	fi

	if check_vm_exists "$vm_name"; then
		print_success "VM successfully restored and defined in libvirt"
	else
		print_error "VM restore completed but VM not found in libvirt"
		return 1
	fi

	print_info "Performing post-restore lock fix and startup test..."
	if troubleshoot_vm "$vm_name"; then
		print_success "VM restore completed and VM is now running!"
		local final_state="running"
	else
		print_warning "VM restored but failed to start automatically"
		print_info "You may need to manually fix issues before starting"
		local final_state="shut off (needs manual intervention)"
	fi

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
	echo "VM Status: $final_state"
	echo ""
	if [ "$final_state" = "running" ]; then
		echo "VM is ready to use!"
		echo "  SSH access: dcvm setup-forwarding  (to configure ports)"
		echo "  Console:    virsh console $vm_name"
	else
		echo "Manual startup required:"
		echo "  Try: dcvm start $vm_name"
		echo "  Or:  virsh start $vm_name"
		echo "  Fix locks: /srv/datacenter/scripts/fix-lock.sh $vm_name"
	fi
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

backup_vm() {
	local vm_name="$1"
	local was_running=false

	print_info "Starting backup for VM: $vm_name"
	log "INFO" "Starting backup for VM: $vm_name"

	if ! check_vm_exists "$vm_name"; then
		print_error "VM '$vm_name' does not exist"
		log "ERROR" "VM '$vm_name' does not exist"
		return 1
	fi

	local vm_disk_path=$(get_vm_disk_path "$vm_name")
	if [ -z "$vm_disk_path" ]; then
		print_error "Could not find disk path for VM '$vm_name'"
		log "ERROR" "Could not find disk path for VM '$vm_name'"
		return 1
	fi

	print_info "VM disk path: $vm_disk_path"
	print_info "Disk size: $(get_file_size "$vm_disk_path")"

	local vm_state=$(get_vm_state "$vm_name")
	print_info "VM current state: $vm_state"

	if [ "$vm_state" = "running" ]; then
		was_running=true
		print_info "Shutting down VM for consistent backup..."

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

	if ! mkdir -p "$BACKUP_DIR"; then
		print_error "Failed to create backup directory: $BACKUP_DIR"
		log "ERROR" "Failed to create backup directory: $BACKUP_DIR"
		return 1
	fi

	local disk_backup="$BACKUP_DIR/${vm_name}-disk-$DATE.qcow2"
	local config_backup="$BACKUP_DIR/${vm_name}-config-$DATE.xml"

	print_info "Backing up VM disk..."
	if cp "$vm_disk_path" "$disk_backup"; then
		local disk_size=$(get_file_size "$disk_backup")
		print_success "Disk backup completed ($disk_size)"
		log "INFO" "Disk backup completed for $vm_name: $disk_size"

		disk_backup=$(compress_backup "$disk_backup" "$vm_name")
	else
		print_error "Failed to backup VM disk"
		log "ERROR" "Failed to backup VM disk for $vm_name"

		if [ "$was_running" = true ]; then
			print_info "Restarting VM..."
			virsh start "$vm_name" >/dev/null 2>&1
		fi
		return 1
	fi

	print_info "Backing up VM configuration..."
	if virsh dumpxml "$vm_name" >"$config_backup" 2>/dev/null; then
		print_success "Configuration backup completed"
		log "INFO" "Configuration backup completed for $vm_name"
	else
		print_error "Failed to backup VM configuration"
		log "ERROR" "Failed to backup VM configuration for $vm_name"
	fi

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

	cleanup_old_backups "$vm_name"

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

for cmd in virsh cp gzip gunzip; do
	if ! command -v "$cmd" >/dev/null 2>&1; then
		print_error "Required command not found: $cmd"
		exit 1
	fi
done

LOG_DIR=$(dirname "$LOG_FILE")
if [ ! -d "$LOG_DIR" ]; then
	mkdir -p "$LOG_DIR" 2>/dev/null || {
		print_warning "Cannot create log directory, logging to stdout only"
		LOG_FILE="/dev/null"
	}
fi

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
