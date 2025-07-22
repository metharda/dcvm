#!/bin/bash

#=============================================================================
# Datacenter Startup Script
# Description: Initializes and starts the virtualized datacenter environment
# Author: Datacenter Administrator
# Version: 1.0
#=============================================================================

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
DATACENTER_BASE="/srv/datacenter"
NETWORK_NAME="datacenter-net"
BRIDGE_NAME="virbr-dc"
NFS_EXPORT_PATH="/srv/datacenter/nfs-share"
LOG_FILE="/var/log/datacenter-startup.log"

# Function to print colored output
print_status() {
    local status=$1
    local message=$2
    case $status in
        "INFO")
            echo -e "${BLUE}[INFO]${NC} $message" | tee -a "$LOG_FILE"
            ;;
        "SUCCESS")
            echo -e "${GREEN}[SUCCESS]${NC} $message" | tee -a "$LOG_FILE"
            ;;
        "WARNING")
            echo -e "${YELLOW}[WARNING]${NC} $message" | tee -a "$LOG_FILE"
            ;;
        "ERROR")
            echo -e "${RED}[ERROR]${NC} $message" | tee -a "$LOG_FILE"
            ;;
    esac
}

# Function to check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_status "ERROR" "This script must be run as root"
        exit 1
    fi
}

# Function to check if KVM is supported
check_kvm_support() {
    print_status "INFO" "Checking KVM support..."
    
    if ! kvm-ok >/dev/null 2>&1; then
        print_status "ERROR" "KVM is not supported or not properly configured"
        exit 1
    fi
    
    print_status "SUCCESS" "KVM support verified"
}

# Function to check and start libvirtd
start_libvirtd() {
    print_status "INFO" "Checking libvirtd service..."
    
    if ! systemctl is-active --quiet libvirtd; then
        print_status "INFO" "Starting libvirtd service..."
        systemctl start libvirtd
        sleep 2
    fi
    
    if systemctl is-active --quiet libvirtd; then
        print_status "SUCCESS" "libvirtd is running"
    else
        print_status "ERROR" "Failed to start libvirtd"
        exit 1
    fi
}

# Function to check and start the datacenter network
start_datacenter_network() {
    print_status "INFO" "Checking datacenter network..."
    
    # Check if network exists
    if ! virsh net-list --all | grep -q "$NETWORK_NAME"; then
        print_status "ERROR" "Network '$NETWORK_NAME' not found. Please run the setup script first."
        exit 1
    fi
    
    # Start network if not active
    if ! virsh net-list | grep -q "$NETWORK_NAME.*active"; then
        print_status "INFO" "Starting network '$NETWORK_NAME'..."
        virsh net-start "$NETWORK_NAME"
    fi
    
    # Verify network is active
    if virsh net-list | grep -q "$NETWORK_NAME.*active"; then
        print_status "SUCCESS" "Network '$NETWORK_NAME' is active"
    else
        print_status "ERROR" "Failed to start network '$NETWORK_NAME'"
        exit 1
    fi
    
    # Display network info
    print_status "INFO" "Network configuration:"
    virsh net-dumpxml "$NETWORK_NAME" | grep -E "(bridge|ip)" | sed 's/^/    /'
}

# Function to check and start NFS server
start_nfs_server() {
    print_status "INFO" "Checking NFS server..."
    
    # Check if NFS export directory exists
    if [[ ! -d "$NFS_EXPORT_PATH" ]]; then
        print_status "WARNING" "NFS export directory does not exist, creating it..."
        mkdir -p "$NFS_EXPORT_PATH"
        chmod 755 "$NFS_EXPORT_PATH"
    fi
    
    # Start NFS server if not running
    if ! systemctl is-active --quiet nfs-kernel-server; then
        print_status "INFO" "Starting NFS server..."
        systemctl start nfs-kernel-server
        sleep 2
    fi
    
    # Verify NFS server is running
    if systemctl is-active --quiet nfs-kernel-server; then
        print_status "SUCCESS" "NFS server is running"
        
        # Refresh exports
        exportfs -ra
        print_status "INFO" "NFS exports refreshed"
        
        # Display current exports
        print_status "INFO" "Active NFS exports:"
        exportfs -v | sed 's/^/    /'
    else
        print_status "ERROR" "Failed to start NFS server"
        exit 1
    fi
}

# Function to check directory structure
check_directory_structure() {
    print_status "INFO" "Checking directory structure..."
    
    local directories=(
        "$DATACENTER_BASE/vms"
        "$DATACENTER_BASE/storage"
        "$DATACENTER_BASE/storage/templates"
        "$DATACENTER_BASE/nfs-share"
        "$DATACENTER_BASE/backups"
        "$DATACENTER_BASE/scripts"
        "$DATACENTER_BASE/vms/vm1"
        "$DATACENTER_BASE/vms/vm2"
    )
    
    for dir in "${directories[@]}"; do
        if [[ ! -d "$dir" ]]; then
            print_status "WARNING" "Directory $dir does not exist, creating..."
            mkdir -p "$dir"
            chmod 755 "$dir"
        fi
    done
    
    # Move scripts from old location if they exist
    if [[ -d "/scripts" && ! -L "/scripts" ]]; then
        print_status "INFO" "Moving /scripts to $DATACENTER_BASE/scripts..."
        cp -r /scripts/* "$DATACENTER_BASE/scripts/" 2>/dev/null || true
        print_status "SUCCESS" "Scripts moved to datacenter directory"
    fi
    
    print_status "SUCCESS" "Directory structure verified"
}

# Function to check for Debian cloud image
check_cloud_image() {
    print_status "INFO" "Checking for Debian cloud image..."
    
    local image_path="$DATACENTER_BASE/storage/templates/debian-12-generic-amd64.qcow2"
    
    if [[ ! -f "$image_path" ]]; then
        print_status "WARNING" "Debian cloud image not found at $image_path"
        print_status "INFO" "Please run: wget https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2"
        print_status "INFO" "And place it in $DATACENTER_BASE/storage/templates/"
    else
        local size=$(du -h "$image_path" | cut -f1)
        print_status "SUCCESS" "Debian cloud image found ($size)"
    fi
}

# Function to display VM status
show_vm_status() {
    print_status "INFO" "Current VM status:"
    echo
    virsh list --all --title | sed 's/^/    /'
    echo
}

# Function to show network connectivity
show_network_info() {
    print_status "INFO" "Network connectivity information:"
    
    # Show bridge information
    if command -v brctl >/dev/null 2>&1; then
        echo "    Bridge information:"
        brctl show "$BRIDGE_NAME" 2>/dev/null | sed 's/^/        /' || echo "        Bridge $BRIDGE_NAME not found"
    fi
    
    # Show IP forwarding status
    local ip_forward=$(cat /proc/sys/net/ipv4/ip_forward)
    echo "    IP forwarding: $([ "$ip_forward" = "1" ] && echo "enabled" || echo "disabled")"
    
    # Show iptables NAT rules
    echo "    NAT rules active: $(iptables -t nat -L POSTROUTING | grep -c "MASQUERADE" || echo "0")"
}

# Function to enable IP forwarding if needed
enable_ip_forwarding() {
    if [[ $(cat /proc/sys/net/ipv4/ip_forward) != "1" ]]; then
        print_status "INFO" "Enabling IP forwarding..."
        echo 1 > /proc/sys/net/ipv4/ip_forward
        
        # Make it permanent
        if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
            echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        fi
        
        print_status "SUCCESS" "IP forwarding enabled"
    fi
}

# Function to start VMs if they exist and are defined
start_existing_vms() {
    print_status "INFO" "Checking for existing VMs to start..."
    
    local vms_started=0
    
    # Get list of all defined VMs
    while IFS= read -r vm_name; do
        if [[ -n "$vm_name" ]]; then
            # Check if VM is not running
            if ! virsh list | grep -q "$vm_name.*running"; then
                print_status "INFO" "Starting VM: $vm_name"
                if virsh start "$vm_name" >/dev/null 2>&1; then
                    print_status "SUCCESS" "Started VM: $vm_name"
                    ((vms_started++))
                else
                    print_status "WARNING" "Failed to start VM: $vm_name"
                fi
            else
                print_status "INFO" "VM $vm_name is already running"
            fi
        fi
    done < <(virsh list --all --name | grep -v "^$")
    
    if [[ $vms_started -eq 0 ]]; then
        print_status "INFO" "No VMs were started (either none exist or all are already running)"
    else
        print_status "SUCCESS" "Started $vms_started VM(s)"
    fi
}

# Function to show datacenter summary
show_datacenter_summary() {
    echo
    print_status "INFO" "=== DATACENTER STARTUP COMPLETE ==="
    echo
    
    echo "📁 Base directory: $DATACENTER_BASE"
    echo "🌐 Network: $NETWORK_NAME (10.10.10.1/24)"
    echo "🔗 Bridge: $BRIDGE_NAME"
    echo "📂 NFS Share: $NFS_EXPORT_PATH"
    echo "📝 Log file: $LOG_FILE"
    echo
    
    echo "🔧 Management commands:"
    echo "    • List VMs: virsh list --all"
    echo "    • Create VM: virt-install [options]"
    echo "    • Network info: virsh net-dumpxml $NETWORK_NAME"
    echo "    • NFS exports: exportfs -v"
    echo "    • VM Manager: dcvm"
    echo
    
    print_status "SUCCESS" "Datacenter environment is ready!"
}

# Function to setup aliases
setup_aliases() {
    print_status "INFO" "Setting up command aliases..."
    
    # Add dcvm alias to bashrc if it doesn't exist
    local bashrc_files=("/root/.bashrc" "/home/*/.bashrc")
    
    for bashrc in /root/.bashrc; do
        if [[ -f "$bashrc" ]]; then
            if ! grep -q "alias dcvm=" "$bashrc"; then
                echo "alias dcvm='/srv/datacenter/scripts/vm-manager.sh'" >> "$bashrc"
                print_status "SUCCESS" "Added dcvm alias to $bashrc"
            fi
        fi
    done
    
    # Add alias for all user home directories
    for user_home in /home/*/; do
        if [[ -d "$user_home" ]]; then
            local user_bashrc="${user_home}.bashrc"
            if [[ -f "$user_bashrc" ]]; then
                if ! grep -q "alias dcvm=" "$user_bashrc"; then
                    echo "alias dcvm='/srv/datacenter/scripts/vm-manager.sh'" >> "$user_bashrc"
                    print_status "SUCCESS" "Added dcvm alias to $user_bashrc"
                fi
            fi
        fi
    done
    
    print_status "INFO" "Aliases configured. Run 'source ~/.bashrc' or start a new shell to use 'dcvm' command"
}

# Function to setup service
setup_service() {
    print_status "INFO" "Setting up datacenter storage service..."
    
    cat > /etc/systemd/system/datacenter-storage.service << 'EOF'
[Unit]
Description=Datacenter Storage Management
After=libvirtd.service
Requires=libvirtd.service

[Service]
Type=oneshot
User=root
ExecStart=/srv/datacenter/scripts/storage-manager.sh
EOF

    cat > /etc/systemd/system/datacenter-storage.timer << 'EOF'
[Unit]
Description=Run datacenter storage management hourly
Requires=datacenter-storage.service

[Timer]
OnCalendar=hourly
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable datacenter-storage.timer
    systemctl start datacenter-storage.timer
    
    print_status "SUCCESS" "Datacenter storage service configured and started"
}

# Function to download scripts from GitHub
download_scripts() {
    print_status "INFO" "Downloading DCVM scripts from GitHub..."
    
    local github_base="https://raw.githubusercontent.com/metharda/dcvm/main/scripts"
    local scripts_dir="$DATACENTER_BASE/scripts"
    
    # Create scripts directory
    mkdir -p "$scripts_dir"
    
    # List of scripts to download
    local scripts=(
        "vm-manager.sh"
        "create-vm.sh"
        "delete-vm.sh"
        "backup.sh"
        "setup-port-forwarding.sh"
        "storage-manager.sh"
        "dhcp-cleanup.sh"
        "fix-lock.sh"
    )
    
    # Download each script
    for script in "${scripts[@]}"; do
        print_status "INFO" "Downloading $script..."
        if curl -fsSL "$github_base/$script" -o "$scripts_dir/$script"; then
            chmod +x "$scripts_dir/$script"
            print_status "SUCCESS" "Downloaded and made executable: $script"
        else
            print_status "WARNING" "Failed to download $script - continuing with installation"
        fi
    done
    
    # Verify at least vm-manager.sh was downloaded
    if [[ -f "$scripts_dir/vm-manager.sh" ]]; then
        print_status "SUCCESS" "Essential scripts downloaded successfully"
    else
        print_status "ERROR" "Failed to download essential scripts"
        print_status "INFO" "Please manually clone the repository: git clone https://github.com/metharda/dcvm.git"
        exit 1
    fi
}

# Main execution
main() {
    print_status "INFO" "Starting datacenter initialization..."
    echo "$(date)" >> "$LOG_FILE"
    
    # Pre-flight checks
    check_root
    check_kvm_support
    
    # Download scripts from GitHub
    download_scripts
    
    # Start core services
    start_libvirtd
    enable_ip_forwarding
    
    # Check infrastructure
    check_directory_structure
    check_cloud_image
    
    # Start network services
    start_datacenter_network
    start_nfs_server
    
    # Start VMs if any exist
    start_existing_vms
    
    # Setup command aliases
    setup_aliases
    
    # Setup systemd service
    setup_service
    
    # Display status information
    show_vm_status
    show_network_info
    show_datacenter_summary
}

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
