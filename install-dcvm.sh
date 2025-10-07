#!/bin/bash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

DEFAULT_DATACENTER_BASE="/srv/datacenter"
CONFIG_FILE="/etc/dcvm-install.conf"
LOG_FILE="/var/log/datacenter-startup.log"

NETWORK_NAME="datacenter-net"
BRIDGE_NAME="virbr-dc"

NETWORK_ONLY=0
NETWORK_NAME_ARG=""

if [[ "${BASH_SOURCE[0]:-$0}" == "${0:-/dev/stdin}" ]] || [[ "${BASH_SOURCE[0]}" == "" ]]; then
	if [[ ! -f "$CONFIG_FILE" ]]; then
		echo "Welcome to DCVM Installer!"

		if [[ -t 0 && -t 1 ]]; then
			echo "Please choose the installation directory for Datacenter VM."
			read -p "Install directory [default: $DEFAULT_DATACENTER_BASE]: " USER_DIR || USER_DIR=""
			USER_DIR=${USER_DIR:-$DEFAULT_DATACENTER_BASE}
			DATACENTER_BASE="$USER_DIR"

			echo "Please enter the network name for the datacenter."
			read -p "Network name [default: $NETWORK_NAME]: " USER_NETWORK_NAME || USER_NETWORK_NAME=""
			NETWORK_NAME=${USER_NETWORK_NAME:-$NETWORK_NAME}

			echo "Please enter the bridge name for the datacenter."
			read -p "Bridge name [default: $BRIDGE_NAME]: " USER_BRIDGE_NAME || USER_BRIDGE_NAME=""
			BRIDGE_NAME=${USER_BRIDGE_NAME:-$BRIDGE_NAME}
		else
			echo "Non-interactive installation detected. Using default values."
			DATACENTER_BASE="$DEFAULT_DATACENTER_BASE"
		fi

		echo "DATACENTER_BASE=\"$DATACENTER_BASE\"" >"$CONFIG_FILE"
		echo "NETWORK_NAME=\"$NETWORK_NAME\"" >>"$CONFIG_FILE"
		echo "BRIDGE_NAME=\"$BRIDGE_NAME\"" >>"$CONFIG_FILE"
		echo "Installation directory set to: $DATACENTER_BASE"
		echo "Network name set to: $NETWORK_NAME"
		echo "Bridge name set to: $BRIDGE_NAME"
	else
		source "$CONFIG_FILE"
		echo "Using existing configuration:"
		echo "  Installation directory: $DATACENTER_BASE"
		echo "  Network name: $NETWORK_NAME"
		echo "  Bridge name: $BRIDGE_NAME"
	fi
else
	if [[ -f "$CONFIG_FILE" ]]; then
		source "$CONFIG_FILE"
	else
		DATACENTER_BASE="$DEFAULT_DATACENTER_BASE"
	fi
fi

NFS_EXPORT_PATH="$DATACENTER_BASE/nfs-share"

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

detect_shell() {
	local shell_name="unknown"
	local config_file=""

	if [[ -n "${SHELL:-}" ]]; then
		shell_name=$(basename "$SHELL")
	fi

	case "$shell_name" in
	"bash")
		config_file="~/.bashrc"
		;;
	"zsh")
		config_file="~/.zshrc"
		;;
	*)
		if [[ "$OSTYPE" == "darwin"* ]]; then
			shell_name="zsh"
			config_file="~/.zshrc"
		elif [[ -f "$HOME/.zshrc" ]]; then
			shell_name="zsh"
			config_file="~/.zshrc"
		elif [[ -f "$HOME/.bashrc" ]]; then
			shell_name="bash"
			config_file="~/.bashrc"
		else
			config_file="~/.bashrc or ~/.zshrc"
		fi
		;;
	esac
	echo "$shell_name|$config_file"
}

install_required_packages() {
	print_status "INFO" "Checking and installing required packages..."

	local debian_packages=(qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils virtinst wget curl nfs-kernel-server uuid-runtime genisoimage bc)
	local arch_packages=(qemu libvirt bridge-utils virt-install wget curl nfs-utils genisoimage)

	if [[ -f /etc/os-release ]]; then
		. /etc/os-release
		if [[ "$ID" == "debian" || "$ID" == "ubuntu" ]]; then
			if ! command -v apt >/dev/null 2>&1; then
				print_status "ERROR" "apt not found. Cannot install packages."
				exit 1
			fi
			print_status "INFO" "Detected Debian/Ubuntu. Installing packages with apt..."
			export DEBIAN_FRONTEND=noninteractive
			apt update -y && apt install -y "${debian_packages[@]}"
		elif [[ "$ID" == "arch" ]]; then
			if ! command -v pacman >/dev/null 2>&1; then
				print_status "ERROR" "pacman not found. Cannot install packages."
				exit 1
			fi
			print_status "INFO" "Detected Arch Linux. Installing packages with pacman..."
			pacman -Sy --noconfirm "${arch_packages[@]}"
		else
			print_status "WARNING" "Unsupported distro: $ID. Please install dependencies manually."
		fi
	else
		print_status "WARNING" "/etc/os-release not found. Cannot detect distribution. Please install dependencies manually."
	fi
}

check_root() {
	if [[ $EUID -ne 0 ]]; then
		print_status "ERROR" "This script must be run as root"
		exit 1
	else
		print_status "INFO" "Running as root user."
	fi
}

check_kvm_support() {
	print_status "INFO" "Checking KVM support..."

	if grep -E -q '(vmx|svm)' /proc/cpuinfo; then
		if [ -e /dev/kvm ]; then
			print_status "SUCCESS" "KVM support verified"
		else
			print_status "ERROR" "CPU supports KVM but /dev/kvm not present (BIOS/UEFI disabled or kernel module missing)"
			exit 1
		fi
	else
		print_status "ERROR" "CPU does not support KVM (no vmx/svm flag)"
		exit 1
	fi
}

start_libvirtd() {
	print_status "INFO" "Checking libvirtd service..."

	if systemctl is-active --quiet libvirtd; then
		print_status "INFO" "libvirtd is already running."
	else
		print_status "INFO" "Starting libvirtd service..."
		systemctl start libvirtd
		sleep 2
		if systemctl is-active --quiet libvirtd; then
			print_status "SUCCESS" "libvirtd is running"
		else
			print_status "ERROR" "Failed to start libvirtd"
			exit 1
		fi
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

		echo "$NFS_EXPORT_PATH *(rw,sync,no_subtree_check)" >/etc/exports
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
		if [[ -d "$dir" ]]; then
			print_status "INFO" "Directory $dir already exists."
		else
			print_status "WARNING" "Directory $dir does not exist, creating..."
			mkdir -p "$dir"
			chmod 755 "$dir"
			print_status "SUCCESS" "Directory $dir created."
		fi
	done

	if [[ -d "/scripts" && ! -L "/scripts" ]]; then
		print_status "INFO" "Moving /scripts to $DATACENTER_BASE/scripts..."
		cp -r /scripts/* "$DATACENTER_BASE/scripts/" 2>/dev/null || true
		print_status "SUCCESS" "Scripts moved to datacenter directory"
	fi

	print_status "SUCCESS" "Directory structure verified"
}

check_cloud_images() {
	print_status "INFO" "Checking for cloud images..."

	local images=(
		"debian-12-generic-amd64.qcow2|Debian 12|https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2"
		"debian-11-generic-amd64.qcow2|Debian 11|https://cloud.debian.org/images/cloud/bullseye/latest/debian-11-generic-amd64.qcow2"
		"ubuntu-20.04-server-cloudimg-amd64.img|Ubuntu 20.04|https://cloud-images.ubuntu.com/releases/focal/release/ubuntu-20.04-server-cloudimg-amd64.img"
		"ubuntu-22.04-server-cloudimg-amd64.img|Ubuntu 22.04|https://cloud-images.ubuntu.com/releases/jammy/release/ubuntu-22.04-server-cloudimg-amd64.img"
	)

	local missing_images=()

	for entry in "${images[@]}"; do
		IFS='|' read -r filename label url <<<"$entry"
		local image_path="$DATACENTER_BASE/storage/templates/$filename"
		if [[ -f "$image_path" ]]; then
			local size=$(du -h "$image_path" | cut -f1)
			print_status "SUCCESS" "$label cloud image found ($size)"
		else
			print_status "WARNING" "$label cloud image not found at $image_path"
			missing_images+=("$entry")
		fi
	done

	if [[ ${#missing_images[@]} -gt 0 ]]; then
		echo
		if [[ -t 0 && -t 1 ]]; then
			echo "Some cloud images are missing. Would you like to download them now?"
			select yn in "Yes, download now" "No, download when creating a VM"; do
				case $yn in
				"Yes, download now")
					for entry in "${missing_images[@]}"; do
						IFS='|' read -r filename label url <<<"$entry"
						local image_path="$DATACENTER_BASE/storage/templates/$filename"
						print_status "INFO" "Downloading $label cloud image..."
						if wget --show-progress -q -O "$image_path" "$url"; then
							print_status "SUCCESS" "$label cloud image downloaded"
						else
							print_status "ERROR" "Failed to download $label cloud image"
						fi
					done
					break
					;;
				"No, download when creating a VM")
					print_status "INFO" "Missing images will be downloaded when you create a VM."
					break
					;;
				esac
			done
		else
			print_status "INFO" "Non-interactive mode: Missing cloud images will be downloaded when creating VMs."
		fi
	fi
}

create_network() {
	local net_name="$1"
	local bridge_name="$2"
	local ip_addr="10.10.10.1"
	local netmask="255.255.255.0"
	local dhcp_start="10.10.10.10"
	local dhcp_end="10.10.10.100"
	print_status "INFO" "Checking network '$net_name'..."
	if virsh net-info "$net_name" >/dev/null 2>&1; then
		print_status "INFO" "Network '$net_name' already exists."
	else
		print_status "INFO" "Creating network '$net_name'..."
		local network_config="/tmp/${net_name}.xml"
		cat >"$network_config" <<EOF
<network>
  <name>${net_name}</name>
  <uuid>$(uuidgen | tr -d '\n')</uuid>
  <forward mode='nat'>
	<nat>
	  <port start='1024' end='65535'/>
	</nat>
  </forward>
  <bridge name='${bridge_name}' stp='on' delay='0'/>
  <mac address='52:54:00:8a:8b:8c'/>
  <ip address='${ip_addr}' netmask='${netmask}'>
	<dhcp>
	  <range start='${dhcp_start}' end='${dhcp_end}'/>
	</dhcp>
  </ip>
</network>
EOF
		if virsh net-define "$network_config" && virsh net-start "$net_name" && virsh net-autostart "$net_name"; then
			print_status "SUCCESS" "Network '$net_name' created and started"
		else
			print_status "ERROR" "Failed to create network '$net_name'"
			exit 1
		fi
		rm -f "$network_config"
	fi
}

create_datacenter_network() {
	create_network "$NETWORK_NAME" "$BRIDGE_NAME"
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
	print_status "INFO" "Restart your shell or source your config file (.bashrc/.zshrc) to use dcvm command"
}

setup_aliases() {
	print_status "INFO" "Setting up command aliases for dcvm..."

	local configured_shells=()

	if [[ -f "/root/.bashrc" ]]; then
		if ! grep -q "alias dcvm=" "/root/.bashrc"; then
			echo "alias dcvm='$DATACENTER_BASE/scripts/vm-manager.sh'" >>"/root/.bashrc"
			print_status "SUCCESS" "Added dcvm alias to /root/.bashrc (bash)"
			configured_shells+=("bash")
		else
			print_status "INFO" "dcvm alias already exists in /root/.bashrc (bash)"
			configured_shells+=("bash")
		fi
	fi

	if [[ -f "/root/.zshrc" ]]; then
		if ! grep -q "alias dcvm=" "/root/.zshrc"; then
			echo "alias dcvm='$DATACENTER_BASE/scripts/vm-manager.sh'" >>"/root/.zshrc"
			print_status "SUCCESS" "Added dcvm alias to /root/.zshrc (zsh)"
			configured_shells+=("zsh")
		else
			print_status "INFO" "dcvm alias already exists in /root/.zshrc (zsh)"
			configured_shells+=("zsh")
		fi
	fi

	echo
	local shell_info=$(detect_shell)
	local shell_name=$(echo "$shell_info" | cut -d'|' -f1)
	local config_file=$(echo "$shell_info" | cut -d'|' -f2)

	print_status "INFO" "Detected shell: $shell_name"
	print_status "INFO" "To activate dcvm alias, run: source $config_file"

	if [[ "$shell_name" == "unknown" ]]; then
		print_status "INFO" "Or restart your terminal to apply changes"
	fi

	if [[ ${#configured_shells[@]} -gt 0 ]]; then
		print_status "SUCCESS" "dcvm alias configured for ${configured_shells[*]}"
	else
		print_status "WARNING" "No shell configuration files found"
	fi
}

setup_service() {
	print_status "INFO" "Setting up datacenter storage service..."

	cat >/etc/systemd/system/datacenter-storage.service <<EOF
[Unit]
Description=Datacenter Storage Management
After=libvirtd.service
Requires=libvirtd.service

[Service]
Type=oneshot
User=root
ExecStart=$DATACENTER_BASE/scripts/storage-manager.sh
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
	print_status "INFO" "Checking and downloading DCVM scripts..."

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

	if [[ -d "./scripts" ]]; then
		print_status "INFO" "Local './scripts' directory found. Copying scripts..."
		for script in "${scripts[@]}"; do
			if [[ -f "./scripts/$script" ]]; then
				cp "./scripts/$script" "$scripts_dir/"
				chmod +x "$scripts_dir/$script"
				print_status "SUCCESS" "Copied and made executable: $script"
			else
				print_status "WARNING" "Script $script not found in local './scripts' directory."
			fi
		done
	else
		print_status "INFO" "Local './scripts' directory not found. Downloading scripts from GitHub..."
		for script in "${scripts[@]}"; do
			if [[ -f "$scripts_dir/$script" ]]; then
				print_status "INFO" "Using local script: $script"
			else
				print_status "INFO" "Downloading $script from GitHub..."
				if curl -fsSL "$github_base/$script" -o "$scripts_dir/$script"; then
					chmod +x "$scripts_dir/$script"
					print_status "SUCCESS" "Downloaded and made executable: $script"
				else
					print_status "WARNING" "Failed to download $script - continuing with installation"
				fi
			fi
		done
	fi

	if [[ -f "$scripts_dir/vm-manager.sh" ]]; then
		print_status "SUCCESS" "Essential scripts are ready"
	else
		print_status "ERROR" "Failed to prepare essential scripts"
		print_status "INFO" "Please manually clone the repository: git clone https://github.com/metharda/dcvm.git"
		exit 1
	fi
}

main() {
	echo "DCVM installer is starting..." >&2
	print_status "INFO" "Starting datacenter initialization..."
	echo "$(date)" >>"$LOG_FILE"
	install_required_packages
	if [[ "$NETWORK_ONLY" == "1" ]]; then
		check_root
		start_libvirtd
		local net_name="$NETWORK_NAME"
		local bridge_name="$BRIDGE_NAME"
		if [[ -n "$NETWORK_NAME_ARG" ]]; then
			net_name="$NETWORK_NAME_ARG"
			bridge_name="virbr-${net_name//[^a-zA-Z0-9]/}"
		fi
		create_network "$net_name" "$bridge_name"
		exit 0
	fi

	check_root
	check_kvm_support

	download_scripts

	start_libvirtd
	enable_ip_forwarding

	check_directory_structure
	check_cloud_images

	create_datacenter_network
	start_nfs_server

	start_existing_vms

	setup_aliases
	setup_service
	show_vm_status
	show_network_info
	show_datacenter_summary
}

for arg in "$@"; do
	case $arg in
	--network-only)
		NETWORK_ONLY=1
		;;
	--network-name=*)
		NETWORK_NAME_ARG="${arg#*=}"
		;;
	--network-name)
		if [[ -n "${2:-}" ]]; then
			NETWORK_NAME_ARG="$2"
		else
			echo "Error: --network-name requires a value" >&2
			exit 1
		fi
		;;
	esac
done

echo "Executing DCVM installer..." >&2
main "$@"
