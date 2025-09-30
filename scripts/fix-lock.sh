#!/bin/bash

VM_NAME="$1"
VERBOSE=false
EXIT_CODE=0

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
	EXIT_CODE=1
}

print_error() {
	echo -e "${RED}[ERROR]${NC} $1"
	EXIT_CODE=1
}

print_verbose() {
	if [ "$VERBOSE" = true ]; then
		echo -e "${BLUE}[DEBUG]${NC} $1"
	fi
}

check_permissions() {
	if [ "$EUID" -ne 0 ]; then
		print_warning "Script should be run as root for best results"
		print_info "Some operations may fail without root privileges"
	fi
}

check_dependencies() {
	local missing_tools=()
	
	for tool in virsh lsof fuser; do
		if ! command -v "$tool" >/dev/null 2>&1; then
			missing_tools+=("$tool")
		fi
	done
	
	if [ ${#missing_tools[@]} -gt 0 ]; then
		print_error "Missing required tools: ${missing_tools[*]}"
		exit 1
	fi
}

if [ -z "$VM_NAME" ]; then
	echo "VM Lock Fix Script - Enhanced Version"
	echo "Usage: $0 <vm_name> [--verbose]"
	echo "       $0 --all [--verbose]    # Fix locks for all VMs"
	echo ""
	echo "Examples:"
	echo "  $0 vm1                       # Fix locks for vm1"
	echo "  $0 vm1 --verbose             # Fix locks for vm1 with detailed output"
	echo "  $0 --all                     # Fix locks for all VMs"
	exit 1
fi

if [ "$2" = "--verbose" ] || [ "$VM_NAME" = "--verbose" ]; then
	VERBOSE=true
fi

check_permissions
check_dependencies

fix_vm_locks() {
	local vm_name="$1"
	local step_errors=0

	echo "=== QEMU Lock Fix for $vm_name ==="

	print_info "[1/9] Validating VM configuration..."

	if ! virsh list --all | grep -q " $vm_name "; then
		print_error "VM '$vm_name' not found in libvirt"
		return 1
	fi

	VM_DISK_PATH=$(virsh domblklist "$vm_name" --details 2>/dev/null | grep "disk" | grep "file" | awk '{print $4}' | head -1)

	if [ -z "$VM_DISK_PATH" ]; then
		print_error "Could not find disk path for VM $vm_name"
		return 1
	fi

	print_info "Checking for other VMs referencing the same disk image..."
	local conflicts=()
	local all_vms=$(virsh list --all --name 2>/dev/null | grep -v "^$" || true)
	for other in $all_vms; do
		if [ "$other" != "$vm_name" ]; then
			if virsh domblklist "$other" --details 2>/dev/null | awk '{print $4}' | grep -Fxq "$VM_DISK_PATH"; then
				conflicts+=("$other (domblklist)")
			fi
		fi
	done

	if [ -d /etc/libvirt/qemu ]; then
		local xml_matches=$(grep -l -- "$VM_DISK_PATH" /etc/libvirt/qemu/*.xml 2>/dev/null | xargs -r -n1 basename 2>/dev/null | sed 's/\.xml$//' | grep -v -E "^${vm_name}$" || true)
		if [ -n "$xml_matches" ]; then
			while IFS= read -r vmxml; do
				local already=false
				for c in "${conflicts[@]}"; do [ "$c" = "$vmxml (xml)" ] && already=true; done
				if [ "$already" = false ]; then
					conflicts+=("$vmxml (xml)")
				fi
			done <<< "$xml_matches"
		fi
	fi

	if [ ${#conflicts[@]} -gt 0 ]; then
		print_error "The disk image is referenced by other VM(s): ${conflicts[*]}"
		print_info "This will cause write-lock failures. Options:"
		print_info "  - Detach or change disk paths for the listed VMs"
		print_info "  - Clone the image and update one VM to use the clone"
		print_info "  - Or stop/undefine conflicting VMs before retry"
		return 1
	fi

	if [ ! -f "$VM_DISK_PATH" ]; then
		print_error "VM disk file does not exist: $VM_DISK_PATH"
		return 1
	fi

	print_info "VM disk path: $VM_DISK_PATH"
	print_verbose "VM disk size: $(du -h "$VM_DISK_PATH" 2>/dev/null | cut -f1 || echo "unknown")"

	print_info "[2/9] Force stopping VM and related processes..."
	
	local vm_state=$(virsh domstate "$vm_name" 2>/dev/null || echo "unknown")
	print_verbose "Current VM state: $vm_state"
	
	if [ "$vm_state" = "running" ]; then
		print_info "Attempting graceful shutdown first..."
		virsh shutdown "$vm_name" >/dev/null 2>&1
		sleep 3
		
		vm_state=$(virsh domstate "$vm_name" 2>/dev/null || echo "unknown")
		if [ "$vm_state" = "running" ]; then
			print_warning "Graceful shutdown failed, forcing destruction..."
		fi
	fi
	
	if ! virsh destroy "$vm_name" >/dev/null 2>&1; then
		print_verbose "VM destroy command failed or VM was not running"
	fi
	sleep 3

	print_info "Terminating QEMU processes..."
	local qemu_pids=$(pgrep -f "qemu.*$vm_name" 2>/dev/null || true)
	if [ -n "$qemu_pids" ]; then
		print_verbose "Found QEMU PIDs: $qemu_pids"
		echo "$qemu_pids" | xargs -r kill -TERM 2>/dev/null || true
		sleep 3
		
		qemu_pids=$(pgrep -f "qemu.*$vm_name" 2>/dev/null || true)
		if [ -n "$qemu_pids" ]; then
			print_warning "Force killing QEMU processes: $qemu_pids"
			echo "$qemu_pids" | xargs -r kill -KILL 2>/dev/null || true
		fi
	else
		print_verbose "No QEMU processes found for $vm_name"
	fi
	sleep 2


	print_info "Checking processes using VM disk file..."
	if [ -f "$VM_DISK_PATH" ]; then
		local disk_users=$(lsof "$VM_DISK_PATH" 2>/dev/null | awk 'NR>1 {print $2}' || true)
		if [ -n "$disk_users" ]; then
			print_warning "Found processes using disk: $disk_users"
			echo "$disk_users" | xargs -r kill -TERM 2>/dev/null || true
			sleep 2
			
			disk_users=$(lsof "$VM_DISK_PATH" 2>/dev/null | awk 'NR>1 {print $2}' || true)
			if [ -n "$disk_users" ]; then
				print_warning "Force killing disk users: $disk_users"
				echo "$disk_users" | xargs -r kill -KILL 2>/dev/null || true
			fi
		else
			print_verbose "No processes found using VM disk"
		fi
		
		if fuser -k "$VM_DISK_PATH" 2>/dev/null; then
			print_verbose "fuser killed additional processes"
			sleep 1
		fi
	fi

	print_info "[3/9] Clearing libvirt lock files..."
	
	local lock_dirs=(
		"/var/lib/libvirt/qemu"
		"/run/libvirt/qemu" 
		"/var/run/libvirt/qemu"
		"/tmp"
		"/var/tmp"
	)
	
	local locks_found=false
	for lock_dir in "${lock_dirs[@]}"; do
		if [ -d "$lock_dir" ]; then
			local found_locks=$(find "$lock_dir" -name "*${vm_name}*" \( -name "*.lock" -o -name "*.pid" \) 2>/dev/null)
			if [ -n "$found_locks" ]; then
				locks_found=true
				print_verbose "Removing locks in $lock_dir:"
				echo "$found_locks" | while read -r lock_file; do
					print_verbose "  Removing: $lock_file"
					rm -f "$lock_file" 2>/dev/null || {
						print_warning "Failed to remove: $lock_file"
						step_errors=$((step_errors + 1))
					}
				done
			fi
		else
			print_verbose "Lock directory not found: $lock_dir"
		fi
	done
	
	if [ "$locks_found" = false ]; then
		print_verbose "No libvirt lock files found"
	fi

	print_info "[4/9] Clearing QEMU image locks and shared memory..."

	local disk_dir=$(dirname "$VM_DISK_PATH")
	print_verbose "Checking disk directory: $disk_dir"
	
	local disk_locks=$(find "$disk_dir" -name "*.lock" 2>/dev/null || true)
	if [ -n "$disk_locks" ]; then
		print_verbose "Found disk locks:"
		echo "$disk_locks" | while read -r lock_file; do
			print_verbose "  Removing: $lock_file"
			rm -f "$lock_file" 2>/dev/null || {
				print_warning "Failed to remove disk lock: $lock_file"
				step_errors=$((step_errors + 1))
			}
		done
	else
		print_verbose "No disk lock files found"
	fi

	local vm_basename=$(basename "$vm_name")
	local shm_files=$(find /dev/shm -name "*qemu*${vm_basename}*" -o -name "*${vm_basename}*qemu*" 2>/dev/null || true)
	if [ -n "$shm_files" ]; then
		print_verbose "Found shared memory files:"
		echo "$shm_files" | while read -r shm_file; do
			print_verbose "  Removing: $shm_file"
			rm -f "$shm_file" 2>/dev/null || {
				print_warning "Failed to remove shared memory: $shm_file"
				step_errors=$((step_errors + 1))
			}
		done
	else
		print_verbose "No shared memory files found"
	fi

	if command -v qemu-img >/dev/null 2>&1; then
		print_info "Attempting to force unlock with qemu-img..."
		if qemu-img info "$VM_DISK_PATH" >/dev/null 2>&1; then
			print_verbose "qemu-img can access the disk"
		else
			print_warning "qemu-img cannot access disk - may indicate lock issues"
			step_errors=$((step_errors + 1))
		fi
		
		local qemu_check_output=$(qemu-img check "$VM_DISK_PATH" 2>&1 || true)
		if echo "$qemu_check_output" | grep -qi "lock\|busy\|use"; then
			print_warning "qemu-img detected lock issues: $qemu_check_output"
			step_errors=$((step_errors + 1))
		fi
	else
		print_warning "qemu-img not available - cannot force unlock disk"
	fi

	print_info "Attempting Python-based lock clearing..."
	if command -v python3 >/dev/null 2>&1; then
		python3 -c "
import fcntl
import sys
import os

try:
    disk_path = '$VM_DISK_PATH'
    if os.path.exists(disk_path):
        with open(disk_path, 'r+b') as f:
            # Try to release any advisory locks
            try:
                fcntl.flock(f.fileno(), fcntl.LOCK_UN)
                print('Released file lock')
            except Exception as e:
                print(f'Lock release failed: {e}', file=sys.stderr)
                sys.exit(1)
    else:
        print(f'Disk file not found: {disk_path}', file=sys.stderr)
        sys.exit(1)
except Exception as e:
    print(f'Python lock clear failed: {e}', file=sys.stderr)
    sys.exit(1)
" 2>/dev/null || {
			print_warning "Python lock clearing failed"
			step_errors=$((step_errors + 1))
		}
	else
		print_warning "Python3 not available for lock clearing"
	fi

	print_info "[5/9] Fixing file permissions and ownership..."

	if [ -f "$VM_DISK_PATH" ]; then
		local current_owner=$(stat -c '%U:%G' "$VM_DISK_PATH" 2>/dev/null || stat -f '%Su:%Sg' "$VM_DISK_PATH" 2>/dev/null || echo "unknown")
		local current_perms=$(stat -c '%a' "$VM_DISK_PATH" 2>/dev/null || stat -f '%A' "$VM_DISK_PATH" 2>/dev/null || echo "unknown")
		
		print_verbose "Current owner: $current_owner, permissions: $current_perms"
		
		local target_owner=""
		if id -u libvirt-qemu >/dev/null 2>&1; then
			target_owner="libvirt-qemu:kvm"
			chown libvirt-qemu:kvm "$VM_DISK_PATH" 2>/dev/null || {
				print_warning "Failed to set libvirt-qemu:kvm ownership, falling back to root"
				chown root:root "$VM_DISK_PATH" || {
					print_error "Failed to fix ownership"
					step_errors=$((step_errors + 1))
				}
				target_owner="root:root"
			}
		elif id -u qemu >/dev/null 2>&1; then
			target_owner="qemu:qemu"
			chown qemu:qemu "$VM_DISK_PATH" 2>/dev/null || {
				print_warning "Failed to set qemu:qemu ownership, falling back to root"
				chown root:root "$VM_DISK_PATH" || {
					print_error "Failed to fix ownership"
					step_errors=$((step_errors + 1))
				}
				target_owner="root:root"
			}
		else
			target_owner="root:root"
			chown root:root "$VM_DISK_PATH" || {
				print_error "Failed to fix ownership"
				step_errors=$((step_errors + 1))
			}
		fi

		if chmod 660 "$VM_DISK_PATH" 2>/dev/null; then
			print_success "Fixed permissions: $target_owner with 660"
		else
			print_error "Failed to set permissions to 660"
			step_errors=$((step_errors + 1))
		fi
		
		local new_owner=$(stat -c '%U:%G' "$VM_DISK_PATH" 2>/dev/null || stat -f '%Su:%Sg' "$VM_DISK_PATH" 2>/dev/null || echo "unknown")
		local new_perms=$(stat -c '%a' "$VM_DISK_PATH" 2>/dev/null || stat -f '%A' "$VM_DISK_PATH" 2>/dev/null || echo "unknown")
		print_verbose "New owner: $new_owner, permissions: $new_perms"
		
		if command -v restorecon >/dev/null 2>&1 && [ -f /selinux/enforce ]; then
			print_info "Restoring SELinux context..."
			if restorecon "$VM_DISK_PATH" 2>/dev/null; then
				print_verbose "SELinux context restored"
			else
				print_warning "Failed to restore SELinux context"
			fi
		fi
	else
		print_error "VM disk file not found: $VM_DISK_PATH"
		return 1
	fi

	print_info "[6/9] Cleaning and validating VM configuration..."

	local temp_xml=$(mktemp)
	if virsh dumpxml "$vm_name" >"$temp_xml" 2>/dev/null; then
		print_verbose "Successfully dumped VM XML configuration"
		
		local cdrom_removed=false
		if grep -qi 'device="cdrom"' "$temp_xml"; then
			sed -i '/<disk[^>]*device="cdrom"[^>]*>/,/<\/disk>/d' "$temp_xml"
			cdrom_removed=true
			print_verbose "Removed CD-ROM device blocks"
		fi
		sed -i '/<target dev="hd[ab]".*bus="ide"\/>/d' "$temp_xml"

		if grep -q 'controller type="ide"' "$temp_xml"; then
			sed -i '/<controller type="ide"/,/<\/controller>/d' "$temp_xml"
			print_verbose "Removed IDE controllers from configuration"
		fi

		local old_path=$(grep -o "file='[^']*'" "$temp_xml" | head -1 | sed "s/file='//;s/'//")
		if [ -n "$old_path" ] && [ "$old_path" != "$VM_DISK_PATH" ]; then
			sed -i "s|<source file='[^']*'/>|<source file='$VM_DISK_PATH'/>|g" "$temp_xml"
			print_verbose "Updated disk path from $old_path to $VM_DISK_PATH"
		fi

		if grep -q 'cache=' "$temp_xml"; then
			sed -i '/<driver.*cache=/s/cache="[^"]*"//g' "$temp_xml"
			print_verbose "Removed cache settings from disk configuration"
		fi

		sed -i 's/<driver name="qemu"[^>]*>/<driver name="qemu" type="qcow2">/g' "$temp_xml"
		if grep -q '<target dev=' "$temp_xml"; then
			sed -i 's/<target dev="\([a-z]*\)[0-9]*" bus="[^"]*"\/>/<target dev="vda" bus="virtio"\/>/g' "$temp_xml"
		fi
		
		if virsh define --validate "$temp_xml" >/dev/null 2>&1; then
			print_success "VM configuration cleaned and redefined with validation"
		elif virsh define "$temp_xml" >/dev/null 2>&1; then
			print_success "VM configuration cleaned and redefined (validation skipped)"
		else
			print_error "Failed to redefine VM configuration"
			print_verbose "Problematic XML content:"
			if [ "$VERBOSE" = true ]; then
				cat "$temp_xml"
			fi
			step_errors=$((step_errors + 1))
		fi
	else
		print_error "Failed to dump VM XML configuration"
		step_errors=$((step_errors + 1))
	fi
	rm -f "$temp_xml"

	print_info "[7/9] Restarting libvirtd service..."
	
	local restart_success=false
	if systemctl restart libvirtd 2>/dev/null; then
		restart_success=true
		print_success "libvirtd restarted with systemctl"
	elif service libvirtd restart 2>/dev/null; then
		restart_success=true  
		print_success "libvirtd restarted with service command"
	else
		print_error "Could not restart libvirtd - manual restart may be required"
		step_errors=$((step_errors + 1))
	fi

	if [ "$restart_success" = true ]; then
		print_info "Waiting for libvirtd to be ready..."
		local wait_count=0
		local max_wait=15
		
		while [ $wait_count -lt $max_wait ]; do
			if virsh list >/dev/null 2>&1; then
				print_verbose "libvirtd is responding after ${wait_count}s"
				break
			fi
			sleep 2
			wait_count=$((wait_count + 2))
		done
		
		if [ $wait_count -ge $max_wait ]; then
			print_error "libvirtd not responding after ${max_wait}s"
			step_errors=$((step_errors + 1))
		fi
	fi

	print_info "[8/9] Additional system cleanup..."

	if [ -d /var/lock ]; then
		find /var/lock -name "*${vm_name}*" -delete 2>/dev/null || true
	fi

	if virsh pool-list --all 2>/dev/null | grep -q "default"; then
		print_info "Refreshing storage pools..."
		virsh pool-refresh default >/dev/null 2>&1 || print_verbose "Could not refresh default storage pool"
	fi

	local vm_interfaces=$(virsh domiflist "$vm_name" 2>/dev/null | awk 'NR>2 {print $1}' || true)
	if [ -n "$vm_interfaces" ]; then
		print_verbose "VM has network interfaces: $vm_interfaces"
	fi

	print_info "[9/9] Final verification and testing..."

	if ! virsh list --all | grep -q " $vm_name "; then
		print_error "VM not found in libvirt after cleanup"
		return 1
	else
		print_verbose "VM is properly defined in libvirt"
	fi

	if [ ! -f "$VM_DISK_PATH" ]; then
		print_error "VM disk file not found: $VM_DISK_PATH"
		return 1
	elif [ ! -r "$VM_DISK_PATH" ]; then
		print_error "VM disk file not readable: $VM_DISK_PATH"
		return 1
	else
		print_verbose "VM disk file is accessible"
	fi

	if virsh dominfo "$vm_name" >/dev/null 2>&1; then
		print_verbose "VM domain info accessible"
	else
		print_warning "Cannot access VM domain info"
		step_errors=$((step_errors + 1))
	fi

	if lsof "$VM_DISK_PATH" >/dev/null 2>&1; then
		local remaining_users=$(lsof "$VM_DISK_PATH" 2>/dev/null | awk 'NR>1 {print $1 "(" $2 ")"}' | tr '\n' ' ')
		print_warning "Processes still using disk: $remaining_users"
		step_errors=$((step_errors + 1))
	else
		print_verbose "No processes using VM disk file"
	fi

	echo ""
	if [ $step_errors -eq 0 ]; then
		print_success "=== Lock Fix Complete for $vm_name (No Errors) ==="
	else
		print_warning "=== Lock Fix Complete for $vm_name ($step_errors warnings/errors) ==="
		print_info "Some operations had issues but basic functionality should work"
	fi
	
	echo ""
	print_info "Next steps:"
	echo "  1. Try starting VM: virsh start $vm_name"
	echo "  2. Or use DCVM:     dcvm start $vm_name"
	echo "  3. Check status:    virsh list --all"
	echo "  4. View logs:       tail -f /var/log/libvirt/qemu/$vm_name.log"
	echo ""

	if [ $step_errors -gt 0 ]; then
		return 1
	else
		return 0
	fi
}

if [ "$VM_NAME" = "--all" ]; then
	print_info "Fixing locks for all VMs..."

	VM_LIST=$(virsh list --all --name 2>/dev/null | grep -v "^$" || true)

	if [ -z "$VM_LIST" ]; then
		print_warning "No VMs found"
		exit 0
	fi

	local total_vms=0
	local failed_vms=0
	
	for vm in $VM_LIST; do
		total_vms=$((total_vms + 1))
		echo "Processing VM $total_vms: $vm"
		echo "----------------------------------------"
		
		if ! fix_vm_locks "$vm"; then
			failed_vms=$((failed_vms + 1))
			print_error "Failed to fix locks for $vm"
		fi
		echo ""
	done

	echo "=========================================="
	echo "Summary:"
	echo "  Total VMs processed: $total_vms"
	echo "  Successful: $((total_vms - failed_vms))"
	echo "  Failed: $failed_vms"
	echo "=========================================="
	
	if [ $failed_vms -gt 0 ]; then
		print_warning "Some VMs had issues during lock fix"
		exit 1
	else
		print_success "Lock fix completed successfully for all VMs"
		exit 0
	fi
else
	if fix_vm_locks "$VM_NAME"; then
		exit 0
	else
		print_error "Lock fix failed for $VM_NAME"
		exit 1
	fi
fi
