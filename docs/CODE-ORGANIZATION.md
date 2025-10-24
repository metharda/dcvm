# DCVM Code Organization

## Common Functions Architecture

### lib/utils/common.sh

**Core Functions:**
- Color definitions (RED, GREEN, YELLOW, BLUE, NC)
- Print functions (print_info, print_success, print_warning, print_error, print_status)
- Logging functions (log, log_message, log_to_file)

**Configuration & System:**
- load_dcvm_config() - Load /etc/dcvm-install.conf
- require_root() - Ensure root privileges
- check_permissions() - Warn if not root
- command_exists() - Check if command is available
- check_dependencies() - Check multiple commands
- get_system_info() - Display system information
- get_host_info() - Get CPU/memory info for VM allocation

**Validation:**
- validate_vm_name() - Validate VM name format (3-64 chars, alphanumeric)
- validate_username() - Validate username (3-32 chars, starts with letter)
- validate_password() - Validate password (4-128 chars)

**VM Management:**
- vm_exists() - Check if VM exists in libvirt
- get_vm_state() - Get VM state (running/shut off)
- get_vm_ip() - Get VM IP with retries
- get_vm_mac() - Get VM MAC address
- get_vm_disk_path() - Get VM disk file path

**Security & Authentication:**
- read_password() - Securely read password from stdin
- generate_password_hash() - Generate salted SHA-512 hash
- generate_random_mac() - Generate random MAC address

**File Operations:**
- create_dir_safe() - Create directory with permissions
- backup_file() - Backup file with suffix
- confirm_action() - Interactive yes/no prompt

**Utilities:**
- format_bytes() - Convert bytes to human readable (KB/MB/GB)

## Script Integration

### Core Scripts (lib/core/)

**create-vm.sh:**
- Sources: common.sh
- Uses: load_dcvm_config, validate_vm_name, validate_username, validate_password
- Uses: get_host_info, read_password, generate_password_hash
- Uses: All print functions

**delete-vm.sh:**
- Sources: common.sh
- Uses: load_dcvm_config, get_vm_ip, get_vm_mac, get_vm_disk_path
- Uses: All print functions

**vm-manager.sh:**
- Sources: common.sh
- Uses: Print functions for status displays

### Network Scripts (lib/network/)

**port-forward.sh:**
- Sources: common.sh
- Uses: load_dcvm_config, get_vm_ip (extended as get_vm_ip_advanced)
- Uses: All print functions
- Special: Has enhanced IP detection with network scanning

**dhcp.sh:**
- Sources: common.sh
- Uses: load_dcvm_config
- Uses: Print functions for cleanup operations

### Storage Scripts (lib/storage/)

**backup.sh:**
- Sources: common.sh
- Uses: All print functions, generate_random_mac
- Special: Has log_backup() for backup-specific logging

**storage-manager.sh:**
- Sources: common.sh
- Uses: load_dcvm_config, log_message
- Uses: Print functions for storage monitoring

### Utility Scripts (lib/utils/)

**fix-lock.sh:**
- Sources: common.sh
- Uses: check_permissions, check_dependencies
- Uses: All print functions
- Special: Overrides print_warning/error to set EXIT_CODE

## Benefits of This Architecture

1. **Single Source of Truth**: All common functionality in one place
2. **Easy Maintenance**: Update function once, applies everywhere
3. **Consistency**: Same behavior across all scripts
4. **Reduced Code**: Eliminated ~500 lines of duplicate code
5. **Better Testing**: Test common functions once
6. **Clear Dependencies**: Each script sources only what it needs

## Usage Pattern

```bash
#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../utils/common.sh"

load_dcvm_config

print_info "Starting operation..."
if vm_exists "$VM_NAME"; then
    print_error "VM already exists"
    exit 1
fi
```

## Function Exports

All functions are exported and available to child processes:
```bash
export -f print_info print_success print_warning print_error print_status
export -f log log_message log_to_file
export -f load_dcvm_config require_root check_permissions
export -f command_exists check_dependencies
export -f validate_vm_name validate_username validate_password
export -f vm_exists get_vm_state get_vm_ip get_vm_mac get_vm_disk_path
export -f read_password generate_password_hash generate_random_mac
export -f format_bytes create_dir_safe backup_file confirm_action
export -f get_system_info get_host_info
```

## Scripts Updated

✓ lib/core/create-vm.sh
✓ lib/core/delete-vm.sh
✓ lib/core/vm-manager.sh
✓ lib/network/port-forward.sh (new)
✓ lib/network/dhcp.sh (new)
✓ lib/storage/backup.sh
✓ lib/storage/storage-manager.sh
✓ lib/utils/fix-lock.sh
✓ lib/installation/uninstall-dcvm.sh

## Not Updated (By Design)

- lib/installation/install-dcvm.sh - Has its own print_status for logging
- bin/dcvm - CLI wrapper, minimal functions needed

## Testing Checklist

- [ ] VM creation (interactive): `sudo dcvm create testvm`
- [ ] VM creation (force): `sudo dcvm create testvm -f -p pass123`
- [ ] VM deletion: `sudo dcvm delete testvm`
- [ ] VM listing: `dcvm list`
- [ ] VM status: `dcvm status testvm`
- [ ] Network setup: `sudo dcvm network ports setup`
- [ ] DHCP cleanup: `sudo dcvm network dhcp cleanup`
- [ ] Backup: `sudo dcvm backup testvm`
- [ ] Storage info: `dcvm storage`
- [ ] Lock fixing: `sudo dcvm fix-lock testvm`
