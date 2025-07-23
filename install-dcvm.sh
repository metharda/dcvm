#!/bin/bash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

DATACENTER_BASE="/srv/datacenter"
NETWORK_NAME="datacenter-net"
BRIDGE_NAME="virbr-dc"
NFS_EXPORT_PATH="/srv/datacenter/nfs-share"
LOG_FILE="/var/log/datacenter-startup.log"

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

check_root() {
	if [[ $EUID -ne 0 ]]; then
		print_status "ERROR" "This script must be run as root"
		exit 1
	fi
}

check_kvm_support() {
	print_status "INFO" "Checking KVM support..."

	if ! kvm-ok >/dev/null 2>&1; then
		print_status "ERROR" "KVM is not supported or not properly configured"
		exit 1
	fi

	print_status "SUCCESS" "KVM support verified"
}

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

start_datacenter_network() {
	print_status "INFO" "Checking datacenter network..."

	if ! virsh net-list --all | grep -q "$NETWORK_NAME"; then
		print_status "ERROR" "Network '$NETWORK_NAME' not found. Please run the setup script first."
		exit 1
	fi

	if ! virsh net-list | grep -q "$NETWORK_NAME.*active"; then
		print_status "INFO" "Starting network '$NETWORK_NAME'..."
		virsh net-start "$NETWORK_NAME"
	fi

	if virsh net-list | grep -q "$NETWORK_NAME.*active"; then
		print_status "SUCCESS" "Network '$NETWORK_NAME' is active"
	else
		print_status "ERROR" "Failed to start network '$NETWORK_NAME'"
		exit 1
	fi

	print_status "INFO" "Network configuration:"
	virsh net-dumpxml "$NETWORK_NAME" | grep -E "(bridge|ip)" | sed 's/^/    /'
}

start_nfs_server() {
	print_status "INFO" "Checking NFS server..."

	if [[ ! -d "$NFS_EXPORT_PATH" ]]; then
		print_status "WARNING" "NFS export directory does not exist, creating it..."
		mkdir -p "$NFS_EXPORT_PATH"
		chmod 755 "$NFS_EXPORT_PATH"
	fi

	if ! systemctl is-active --quiet nfs-kernel-server; then
		print_status "INFO" "Starting NFS server..."
		systemctl start nfs-kernel-server
		sleep 2
	fi

	if systemctl is-active --quiet nfs-kernel-server; then
		print_status "SUCCESS" "NFS server is running"

		exportfs -ra
		print_status "INFO" "NFS exports refreshed"

		print_status "INFO" "Active NFS exports:"
		exportfs -v | sed 's/^/    /'
	else
		print_status "ERROR" "Failed to start NFS server"
		exit 1
	fi
}

check_directory_structure() {
	print_status "INFO" "Checking directory structure..."

	local directories=(
		"$DATACENTER_BASE/vms"
		"$DATACENTER_BASE/storage"
		"$DATACENTER_BASE/storage/templates"
		"$DATACENTER_BASE/nfs-share"
		"$DATACENTER_BASE/backups"
		"$DATACENTER_BASE/scripts"
	)

	for dir in "${directories[@]}"; do
		if [[ ! -d "$dir" ]]; then
			print_status "WARNING" "Directory $dir does not exist, creating..."
			mkdir -p "$dir"
			chmod 755 "$dir"
		fi
	done

	if [[ -d "/scripts" && ! -L "/scripts" ]]; then
		print_status "INFO" "Moving /scripts to $DATACENTER_BASE/scripts..."
		cp -r /scripts/* "$DATACENTER_BASE/scripts/" 2>/dev/null || true
		print_status "SUCCESS" "Scripts moved to datacenter directory"
	fi

	print_status "SUCCESS" "Directory structure verified"
}

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

show_vm_status() {
	print_status "INFO" "Current VM status:"
	echo
	virsh list --all --title | sed 's/^/    /'
	echo
}

show_network_info() {
	print_status "INFO" "Network connectivity information:"

	if command -v brctl >/dev/null 2>&1; then
		echo "    Bridge information:"
		brctl show "$BRIDGE_NAME" 2>/dev/null | sed 's/^/        /' || echo "        Bridge $BRIDGE_NAME not found"
	fi

	local ip_forward=$(cat /proc/sys/net/ipv4/ip_forward)
	echo "    IP forwarding: $([ "$ip_forward" = "1" ] && echo "enabled" || echo "disabled")"

	echo "    NAT rules active: $(iptables -t nat -L POSTROUTING | grep -c "MASQUERADE" || echo "0")"
}

enable_ip_forwarding() {
	if [[ $(cat /proc/sys/net/ipv4/ip_forward) != "1" ]]; then
		print_status "INFO" "Enabling IP forwarding..."
		echo 1 >/proc/sys/net/ipv4/ip_forward

		if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
			echo "net.ipv4.ip_forward=1" >>/etc/sysctl.conf
		fi

		print_status "SUCCESS" "IP forwarding enabled"
	fi
}

start_existing_vms() {
	print_status "INFO" "Checking for existing VMs to start..."

	local vms_started=0

	while IFS= read -r vm_name; do
		if [[ -n "$vm_name" ]]; then
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

show_datacenter_summary() {
	echo
	print_status "INFO" "=== DATACENTER STARTUP COMPLETE ==="
	echo

	echo "Base directory: $DATACENTER_BASE"
	echo "Network: $NETWORK_NAME (10.10.10.1/24)"
	echo "Bridge: $BRIDGE_NAME"
	echo "NFS Share: $NFS_EXPORT_PATH"
	echo "Log file: $LOG_FILE"
	echo

	echo "Management commands:"
	echo "    • List VMs: virsh list --all"
	echo "    • Create VM: virt-install [options]"
	echo "    • Network info: virsh net-dumpxml $NETWORK_NAME"
	echo "    • NFS exports: exportfs -v"
	echo "    • VM Manager: dcvm"
	echo

	print_status "SUCCESS" "Datacenter environment is ready!"
}

setup_aliases() {
	print_status "INFO" "Setting up command aliases..."

	local bashrc_files=("/root/.bashrc" "/home/*/.bashrc")

	for bashrc in /root/.bashrc; do
		if [[ -f "$bashrc" ]]; then
			if ! grep -q "alias dcvm=" "$bashrc"; then
				echo "alias dcvm='/srv/datacenter/scripts/vm-manager.sh'" >>"$bashrc"
				print_status "SUCCESS" "Added dcvm alias to $bashrc"
			fi
		fi
	done

	for user_home in /home/*/; do
		if [[ -d "$user_home" ]]; then
			local user_bashrc="${user_home}.bashrc"
			if [[ -f "$user_bashrc" ]]; then
				if ! grep -q "alias dcvm=" "$user_bashrc"; then
					echo "alias dcvm='/srv/datacenter/scripts/vm-manager.sh'" >>"$user_bashrc"
					print_status "SUCCESS" "Added dcvm alias to $user_bashrc"
				fi
			fi
		fi
	done

	print_status "INFO" "Aliases configured. Run 'source ~/.bashrc' or start a new shell to use 'dcvm' command"
}

setup_service() {
	print_status "INFO" "Setting up datacenter storage service..."

	cat >/etc/systemd/system/datacenter-storage.service <<'EOF'
[Unit]
Description=Datacenter Storage Management
After=libvirtd.service
Requires=libvirtd.service

[Service]
Type=oneshot
User=root
ExecStart=/srv/datacenter/scripts/storage-manager.sh
EOF

	cat >/etc/systemd/system/datacenter-storage.timer <<'EOF'
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

download_scripts() {
	print_status "INFO" "Downloading DCVM scripts from GitHub..."

	local github_base="https://raw.githubusercontent.com/metharda/dcvm/main/scripts"
	local scripts_dir="$DATACENTER_BASE/scripts"

	mkdir -p "$scripts_dir"

	local scripts=(
		"vm-manager.sh"
		"create-vm.sh"
		"delete-vm.sh"
		"backup.sh"
		"setup-port-forwarding.sh"
		"storage-manager.sh"
		"dhcp-cleanup.sh"
		"fix-lock.sh"
		"uninstall-dcvm.sh"
	)

	for script in "${scripts[@]}"; do
		print_status "INFO" "Downloading $script..."
		if curl -fsSL "$github_base/$script" -o "$scripts_dir/$script"; then
			chmod +x "$scripts_dir/$script"
			print_status "SUCCESS" "Downloaded and made executable: $script"
		else
			print_status "WARNING" "Failed to download $script - continuing with installation"
		fi
	done

	if [[ -f "$scripts_dir/vm-manager.sh" ]]; then
		print_status "SUCCESS" "Essential scripts downloaded successfully"
	else
		print_status "ERROR" "Failed to download essential scripts"
		print_status "INFO" "Please manually clone the repository: git clone https://github.com/metharda/dcvm.git"
		exit 1
	fi
}

main() {
	print_status "INFO" "Starting datacenter initialization..."
	echo "$(date)" >>"$LOG_FILE"

	check_root
	check_kvm_support

	download_scripts

	start_libvirtd
	enable_ip_forwarding

	check_directory_structure
	check_cloud_image

	start_datacenter_network
	start_nfs_server

	start_existing_vms

	setup_aliases

	setup_service

	show_vm_status
	show_network_info
	show_datacenter_summary
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
