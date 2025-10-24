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

# Optional: allow self-bootstrap when script is not run inside repo
# You can override these via environment variables before running the installer
# - DCVM_REPO_TARBALL_URL: direct tarball URL to download
# - DCVM_REPO_SLUG: owner/repo (used to construct default tarball URL if above is empty)
# - DCVM_REPO_BRANCH: branch name to download (default: main)
DCVM_REPO_TARBALL_URL="${DCVM_REPO_TARBALL_URL:-}"
DCVM_REPO_SLUG="${DCVM_REPO_SLUG:-metharda/dcvm}"
DCVM_REPO_BRANCH="${DCVM_REPO_BRANCH:-main}"
SOURCE_DIR=""
TMP_WORKDIR=""

touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/dcvm-install.log"

print_status() {
	local status=$1
	local message=$2
	case $status in
	"INFO") echo -e "${BLUE}[INFO]${NC} $message" | tee -a "$LOG_FILE" 2>/dev/null || echo -e "${BLUE}[INFO]${NC} $message" ;;
	"SUCCESS") echo -e "${GREEN}[SUCCESS]${NC} $message" | tee -a "$LOG_FILE" 2>/dev/null || echo -e "${GREEN}[SUCCESS]${NC} $message" ;;
	"WARNING") echo -e "${YELLOW}[WARNING]${NC} $message" | tee -a "$LOG_FILE" 2>/dev/null || echo -e "${YELLOW}[WARNING]${NC} $message" ;;
	"ERROR") echo -e "${RED}[ERROR]${NC} $message" | tee -a "$LOG_FILE" 2>/dev/null || echo -e "${RED}[ERROR]${NC} $message" ;;
	esac
}

print_status_log() { print_status "$@"; }

# Create and cleanup temp work dir if we need to download sources
cleanup_tmp_dir() {
	if [[ -n "$TMP_WORKDIR" && -d "$TMP_WORKDIR" ]]; then
		rm -rf "$TMP_WORKDIR" 2>/dev/null || true
	fi
}

download_repo_source() {
	# Determine URL to download
	local url="$DCVM_REPO_TARBALL_URL"
	if [[ -z "$url" ]]; then
		url="https://codeload.github.com/${DCVM_REPO_SLUG}/tar.gz/refs/heads/${DCVM_REPO_BRANCH}"
	fi

	TMP_WORKDIR=$(mktemp -d 2>/dev/null || mktemp -d -t dcvm)
	trap cleanup_tmp_dir EXIT

	print_status_log "INFO" "Fetching DCVM sources from: $url"
	local tarball="$TMP_WORKDIR/dcvm.tar.gz"

	if command -v curl >/dev/null 2>&1; then
		if ! curl -L --fail -o "$tarball" "$url" 2>>"$LOG_FILE"; then
			print_status_log "ERROR" "Failed to download sources via curl"
			return 1
		fi
	elif command -v wget >/dev/null 2>&1; then
		if ! wget -O "$tarball" "$url" 2>>"$LOG_FILE"; then
			print_status_log "ERROR" "Failed to download sources via wget"
			return 1
		fi
	else
		print_status_log "ERROR" "Neither curl nor wget found to download sources"
		return 1
	fi

	if ! tar -xzf "$tarball" -C "$TMP_WORKDIR" 2>>"$LOG_FILE"; then
		print_status_log "ERROR" "Failed to extract downloaded tarball"
		return 1
	fi

	# Find extracted top-level directory (usually repoName-branch)
	local extracted_dir
	extracted_dir=$(find "$TMP_WORKDIR" -mindepth 1 -maxdepth 1 -type d | head -n 1)
	if [[ -z "$extracted_dir" ]]; then
		print_status_log "ERROR" "Could not locate extracted source directory"
		return 1
	fi

	if [[ -f "$extracted_dir/bin/dcvm" && -d "$extracted_dir/lib" ]]; then
		SOURCE_DIR="$extracted_dir"
		print_status_log "SUCCESS" "Sources downloaded and ready at: $SOURCE_DIR"
		return 0
	fi

	print_status_log "ERROR" "Downloaded archive doesn't contain expected layout (bin/ and lib/)"
	return 1
}

ensure_source_dir() {
	# First try relative to this script (when run inside repo)
	local script_dir; script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	local repo_root; repo_root="$(cd "$script_dir/../.." && pwd)"

	if [[ -f "$repo_root/bin/dcvm" && -d "$repo_root/lib" ]]; then
		SOURCE_DIR="$repo_root"
		return 0
	fi

	# Not in repo; try to download from tarball
	print_status_log "WARNING" "DCVM repository files not found next to installer. Attempting to bootstrap from remote tarball..."
	if download_repo_source; then
		return 0
	fi

	print_status_log "ERROR" "Could not obtain DCVM sources automatically."
	print_status_log "INFO" "You can set DCVM_REPO_TARBALL_URL to a tar.gz URL of the repository,"
	print_status_log "INFO" "or set DCVM_REPO_SLUG (owner/repo) and DCVM_REPO_BRANCH, then re-run the installer."
	return 1
}

detect_shell() {
	local shell_name="unknown"
	local config_file=""

	[[ -n "${SHELL:-}" ]] && shell_name=$(basename "$SHELL")

	case "$shell_name" in
	"bash") config_file="~/.bashrc" ;;
	"zsh") config_file="~/.zshrc" ;;
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

prompt_yes_no() {
	local prompt="$1"
	local default="${2:-N}"
	local answer
	while true; do
		read -r -p "$prompt" answer || answer=""
		if [[ -z "$answer" ]]; then
			answer="$default"
		fi
		case "$answer" in
			[Yy]|[Yy][Ee][Ss]) return 0 ;;
			[Nn]|[Nn][Oo])    return 1 ;;
			*) print_status_log "ERROR" "Please answer y or n" ;;
		esac
	done
}

install_required_packages() {
	print_status "INFO" "Checking and installing required packages..."

	local debian_packages=(qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils virtinst wget curl nfs-kernel-server uuid-runtime genisoimage bc)
	local arch_packages=(qemu libvirt bridge-utils virt-install wget curl nfs-utils genisoimage)

	if [[ -f /etc/os-release ]]; then
		. /etc/os-release
		if [[ "$ID" == "debian" || "$ID" == "ubuntu" ]]; then
			command -v apt >/dev/null 2>&1 || { print_status "ERROR" "apt not found. Cannot install packages."; exit 1; }
			print_status "INFO" "Detected Debian/Ubuntu. Installing packages with apt..."
			export DEBIAN_FRONTEND=noninteractive
			apt update -y && apt install -y "${debian_packages[@]}"
		elif [[ "$ID" == "arch" ]]; then
			command -v pacman >/dev/null 2>&1 || { print_status "ERROR" "pacman not found. Cannot install packages."; exit 1; }
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
		systemctl is-active --quiet libvirtd && print_status "SUCCESS" "libvirtd is running" || { print_status "ERROR" "Failed to start libvirtd"; exit 1; }
	fi
}

start_datacenter_network() {
	print_status "INFO" "Checking datacenter network..."

	virsh net-list --all | grep -q "$NETWORK_NAME" || { print_status "ERROR" "Network '$NETWORK_NAME' not found. Please run the setup script first."; exit 1; }

	if ! virsh net-list | grep -q "$NETWORK_NAME.*active"; then
		print_status_log "INFO" "Starting network '$NETWORK_NAME'..."
		virsh net-start "$NETWORK_NAME"
	fi

	virsh net-list | grep -q "$NETWORK_NAME.*active" && print_status_log "SUCCESS" "Network '$NETWORK_NAME' is active" || { print_status_log "ERROR" "Failed to start network '$NETWORK_NAME'"; exit 1; }

	print_status_log "INFO" "Network configuration:"
	virsh net-dumpxml "$NETWORK_NAME" | grep -E "(bridge|ip)" | sed 's/^/    /'
}

start_nfs_server() {
	print_status_log "INFO" "Checking NFS server setup..."
	
	echo
	if ! prompt_yes_no "Do you want to setup NFS server for VM shared folders? [y/N]: " "N"; then
		print_status_log "INFO" "Skipping NFS server setup"
		return 0
	fi

	if [[ ! -d "$NFS_EXPORT_PATH" ]]; then
		print_status_log "INFO" "Creating NFS export directory..."
		mkdir -p "$NFS_EXPORT_PATH" 2>/dev/null || { print_status_log "ERROR" "Failed to create NFS export path"; return 1; }
		chmod 755 "$NFS_EXPORT_PATH" 2>/dev/null || print_status_log "WARNING" "Could not set permissions on NFS export path"
	fi

	if ! systemctl list-unit-files 2>/dev/null | grep -q -E 'nfs-kernel-server|nfs-server'; then
		print_status_log "WARNING" "NFS server is not installed"
		print_status_log "INFO" "Install with: apt install nfs-kernel-server (Debian/Ubuntu) or pacman -S nfs-utils (Arch)"
		return 0
	fi

	if ! systemctl is-active --quiet nfs-kernel-server 2>/dev/null && ! systemctl is-active --quiet nfs-server 2>/dev/null; then
		print_status_log "INFO" "Starting NFS server..."
		systemctl start nfs-kernel-server 2>/dev/null || systemctl start nfs-server 2>/dev/null || { print_status_log "WARNING" "Could not start NFS server"; return 0; }
		sleep 2
	fi

	if systemctl is-active --quiet nfs-kernel-server 2>/dev/null || systemctl is-active --quiet nfs-server 2>/dev/null; then
		print_status_log "SUCCESS" "NFS server is running"
		
		if ! grep -q "$NFS_EXPORT_PATH" /etc/exports 2>/dev/null; then
			echo "$NFS_EXPORT_PATH *(rw,sync,no_subtree_check,no_root_squash)" >> /etc/exports 2>/dev/null || { print_status_log "WARNING" "Could not update /etc/exports"; return 0; }
		fi
		
		exportfs -ra 2>/dev/null || print_status_log "WARNING" "Could not refresh NFS exports"
		print_status_log "SUCCESS" "NFS exports configured at: $NFS_EXPORT_PATH"
		print_status_log "INFO" "VMs can mount: $NFS_EXPORT_PATH from 10.10.10.1"
	else
		print_status_log "WARNING" "NFS server could not be started - you can set it up manually later"
	fi
}

check_directory_structure() {
	print_status_log "INFO" "Checking directory structure..."

	local directories=(
		"$DATACENTER_BASE/vms"
		"$DATACENTER_BASE/storage"
		"$DATACENTER_BASE/storage/templates"
		"$DATACENTER_BASE/nfs-share"
		"$DATACENTER_BASE/backups"
	)

	for dir in "${directories[@]}"; do
		if [[ -d "$dir" ]]; then
			print_status_log "INFO" "Directory $dir already exists."
		else
			print_status_log "WARNING" "Directory $dir does not exist, creating..."
			if mkdir -p "$dir" 2>/dev/null && chmod 755 "$dir" 2>/dev/null; then
				print_status_log "SUCCESS" "Directory $dir created."
			else
				print_status_log "ERROR" "Failed to create directory $dir"
				return 1
			fi
		fi
	done

	print_status_log "SUCCESS" "Directory structure verified"
}

check_cloud_images() {
	print_status_log "INFO" "Checking for cloud images..."

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
			local size=$(du -h "$image_path" 2>/dev/null | cut -f1 || echo "unknown")
			print_status_log "SUCCESS" "$label cloud image found ($size)"
		else
			print_status_log "WARNING" "$label cloud image not found"
			missing_images+=("$entry")
		fi
	done

	if [[ ${#missing_images[@]} -gt 0 ]]; then
		echo ""
		print_status_log "INFO" "Found ${#missing_images[@]} missing cloud image(s)"
		
		if [[ -t 0 && -t 1 ]]; then
			echo ""
			echo "Some cloud images are missing. Would you like to download them now?"
			select yn in "Yes, download now" "No, download when creating a VM"; do
				case $yn in
				"Yes, download now")
					for entry in "${missing_images[@]}"; do
						IFS='|' read -r filename label url <<<"$entry"
						local image_path="$DATACENTER_BASE/storage/templates/$filename"
						print_status_log "INFO" "Downloading $label cloud image..."
						if wget --show-progress -O "$image_path" "$url" 2>&1; then
							print_status_log "SUCCESS" "$label cloud image downloaded"
						else
							print_status_log "WARNING" "Failed to download $label - will download when creating VM"
							rm -f "$image_path" 2>/dev/null
						fi
					done
					break
					;;
				"No, download when creating a VM")
					print_status_log "INFO" "Skipping download - images will be downloaded when creating VMs"
					break
					;;
				esac
			done
		else
			print_status_log "INFO" "Non-interactive mode - images will be downloaded when creating VMs"
		fi
	else
		print_status_log "SUCCESS" "All cloud images are available"
	fi
}

create_network() {
	local net_name="$1"
	local bridge_name="$2"
	local ip_addr="10.10.10.1"
	local netmask="255.255.255.0"
	local dhcp_start="10.10.10.10"
	local dhcp_end="10.10.10.100"
	
	print_status_log "INFO" "Checking network '$net_name'..."
	
	if virsh net-info "$net_name" >/dev/null 2>&1; then
		print_status_log "INFO" "Network '$net_name' already exists."
		if ! virsh net-list | grep -q "$net_name.*active"; then
			print_status_log "INFO" "Starting existing network '$net_name'..."
			virsh net-start "$net_name" 2>/dev/null || print_status_log "WARNING" "Could not start network"
		fi
		
		return 0
	fi
	
	print_status_log "INFO" "Creating network '$net_name'..."
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

	if virsh net-define "$network_config" 2>/dev/null; then
		print_status_log "SUCCESS" "Network '$net_name' defined"
		
		if virsh net-start "$net_name" 2>/dev/null; then
			print_status_log "SUCCESS" "Network '$net_name' started"
		else
			print_status_log "WARNING" "Network defined but could not start - may need manual start"
		fi
		
		virsh net-autostart "$net_name" 2>/dev/null || print_status_log "WARNING" "Could not set network to autostart"
		
		print_status_log "SUCCESS" "Network '$net_name' created"
	else
		print_status_log "ERROR" "Failed to create network '$net_name'"
		return 1
	fi
	
	rm -f "$network_config" 2>/dev/null || true
}

create_datacenter_network() {
	create_network "$NETWORK_NAME" "$BRIDGE_NAME"
}

show_vm_status() {
	print_status_log "INFO" "Current VM status:"
	echo
	if virsh list --all --title 2>/dev/null | sed 's/^/    /'; then
		:
	else
		echo "    (Could not retrieve VM list)"
	fi
	echo
}

show_network_info() {
	print_status_log "INFO" "Network connectivity information:"

	if command -v brctl >/dev/null 2>&1; then
		echo "    Bridge information:"
		brctl show "$BRIDGE_NAME" 2>/dev/null | sed 's/^/        /' || echo "        Bridge $BRIDGE_NAME not configured yet"
	fi

	local ip_forward=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo "0")
	echo "    IP forwarding: $([ "$ip_forward" = "1" ] && echo "enabled" || echo "disabled")"
	
	local nat_count=$(iptables -t nat -L POSTROUTING 2>/dev/null | grep -c "MASQUERADE" || echo "0")
	echo "    NAT rules active: $nat_count"
}

enable_ip_forwarding() {
	print_status_log "INFO" "Checking IP forwarding..."
	local current_forward=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo "0")
	
	if [[ "$current_forward" != "1" ]]; then
		print_status_log "INFO" "Enabling IP forwarding..."
		echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || { print_status_log "WARNING" "Could not enable IP forwarding"; return 0; }
		
		if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null; then
			echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf 2>/dev/null || print_status_log "WARNING" "Could not persist IP forwarding setting"
		fi
		
		print_status_log "SUCCESS" "IP forwarding enabled"
	else
		print_status_log "INFO" "IP forwarding already enabled"
	fi
}

start_existing_vms() {
	print_status_log "INFO" "Checking for existing VMs to start..."

	local vms_started=0
	local vm_list=$(virsh list --all --name 2>/dev/null | grep -v "^$" || echo "")

	if [[ -z "$vm_list" ]]; then
		print_status_log "INFO" "No existing VMs found"
		return 0
	fi

	while IFS= read -r vm_name; do
		if [[ -n "$vm_name" ]]; then
			if ! virsh list 2>/dev/null | grep -q "$vm_name.*running"; then
				print_status_log "INFO" "Starting VM: $vm_name"
				if virsh start "$vm_name" >/dev/null 2>&1; then
					print_status_log "SUCCESS" "Started VM: $vm_name"
					((vms_started++))
				else
					print_status_log "WARNING" "Failed to start VM: $vm_name"
				fi
			else
				print_status_log "INFO" "VM $vm_name is already running"
			fi
		fi
	done <<< "$vm_list"

	if [[ $vms_started -eq 0 ]]; then
		print_status_log "INFO" "No VMs were started (either none exist or all are already running)"
	else
		print_status_log "SUCCESS" "Started $vms_started VM(s)"
	fi
}

show_datacenter_summary() {
	echo
	print_status_log "INFO" "=== DCVM INSTALLATION COMPLETE ==="
	echo
	echo "Installation directory: $DATACENTER_BASE"
	echo "Network: $NETWORK_NAME (10.10.10.1/24)"
	echo "Bridge: $BRIDGE_NAME"
	echo "NFS Share: $NFS_EXPORT_PATH"
	echo "Log file: $LOG_FILE"
	echo
	echo "Management commands:"
	echo "    • List VMs: dcvm list"
	echo "    • Create VM: dcvm create <vm_name>"
	echo "    • Network info: dcvm network"
	echo "    • Show help: dcvm help"
	echo "    • Uninstall: dcvm uninstall"
	echo
	print_status_log "SUCCESS" "DCVM is ready to use!"
	print_status_log "INFO" "Run 'dcvm help' to see all available commands"
}

setup_aliases() {
	print_status_log "INFO" "Checking dcvm command availability..."

	if command -v dcvm >/dev/null 2>&1; then
		print_status_log "SUCCESS" "dcvm command is available in PATH"
		print_status_log "INFO" "You can use 'dcvm' command directly"
	else
		print_status_log "WARNING" "dcvm command not found in PATH"
		print_status_log "INFO" "Please add /usr/local/bin to your PATH or restart your shell"
	fi
}

install_completion() {
	local install_share="/usr/local/share/dcvm"
	local completion_dst="$install_share/dcvm-completion.sh"
	local install_lib="/usr/local/lib/dcvm"

	mkdir -p "$install_share" 2>/dev/null || true
	if [[ -f "$install_lib/utils/dcvm-completion.sh" ]]; then
		if cp "$install_lib/utils/dcvm-completion.sh" "$completion_dst" 2>/dev/null; then
			print_status_log "SUCCESS" "Installed completion script to $completion_dst"
		else
			print_status_log "WARNING" "Could not copy completion script"
			return 0
		fi
	else
		print_status_log "INFO" "Completion script not found in installed libraries; skipping"
		return 0
	fi

	if [[ -t 0 && -t 1 ]]; then
		echo
		if prompt_yes_no "Enable dcvm tab-completion in your shell now? [y/N]: " "N"; then
			local shell_info; shell_info=$(detect_shell)
			local shell_name="${shell_info%%|*}"
			local config_file="${shell_info##*|}"
			[[ "$config_file" == ~* ]] && config_file="${config_file/#~/$HOME}"

			if [[ "$shell_name" == "bash" ]]; then
				if [[ -d "/etc/bash_completion.d" && -w "/etc/bash_completion.d" ]]; then
					cp "$completion_dst" "/etc/bash_completion.d/dcvm" 2>/dev/null && print_status_log "SUCCESS" "Bash completion installed: /etc/bash_completion.d/dcvm" || print_status_log "WARNING" "Could not write to /etc/bash_completion.d"
				else
					grep -q "$completion_dst" "$config_file" 2>/dev/null || echo "source $completion_dst" >> "$config_file"
					print_status_log "SUCCESS" "Added 'source $completion_dst' to $config_file"
				fi
			else
				grep -q "$completion_dst" "$config_file" 2>/dev/null || echo "source $completion_dst" >> "$config_file"
				print_status_log "SUCCESS" "Added 'source $completion_dst' to $config_file"
			fi

			if [[ -n ${ZSH_VERSION-} || -n ${BASH_VERSION-} ]]; then
				source "$completion_dst" 2>/dev/null && print_status_log "SUCCESS" "Completion enabled in current shell" || print_status_log "WARNING" "Could not enable completion in current shell. You can run: source $completion_dst"
			fi
		else
			print_status_log "INFO" "You can enable later by adding: 'source $completion_dst' to your shell rc"
		fi
	else
		print_status_log "INFO" "Non-interactive mode. Completion script installed at $completion_dst"
		print_status_log "INFO" "Add 'source $completion_dst' to your shell rc to enable"
	fi
}

setup_service() {
	print_status_log "INFO" "Setting up datacenter storage service..."

	if ! command -v systemctl >/dev/null 2>&1; then
		print_status_log "WARNING" "systemd not available - skipping service setup"
		return 0
	fi

	cat >/etc/systemd/system/datacenter-storage.service 2>/dev/null <<EOF || { print_status_log "WARNING" "Could not create systemd service"; return 0; }
[Unit]
Description=Datacenter Storage Management
After=libvirtd.service
Requires=libvirtd.service

[Service]
Type=oneshot
User=root
ExecStart=/usr/local/bin/dcvm storage-cleanup
EOF

	cat >/etc/systemd/system/datacenter-storage.timer 2>/dev/null <<'EOF' || { print_status_log "WARNING" "Could not create systemd timer"; return 0; }
[Unit]
Description=Run datacenter storage management hourly
Requires=datacenter-storage.service

[Timer]
OnCalendar=hourly
Persistent=true

[Install]
WantedBy=timers.target
EOF

	systemctl daemon-reload 2>/dev/null || { print_status_log "WARNING" "Could not reload systemd"; return 0; }
	systemctl enable datacenter-storage.timer 2>/dev/null || print_status_log "WARNING" "Could not enable timer"
	systemctl start datacenter-storage.timer 2>/dev/null || print_status_log "WARNING" "Could not start timer"

	print_status_log "SUCCESS" "Datacenter storage service configured"
}

install_dcvm_command() {
	print_status_log "INFO" "Installing DCVM command and libraries..."

	local install_bin="/usr/local/bin"
	local install_lib="/usr/local/lib/dcvm"
    
	mkdir -p "$install_bin" "$install_lib"

	# Ensure we have a valid source directory to install from (repo or downloaded)
	if ! ensure_source_dir; then
		exit 1
	fi

	print_status_log "INFO" "Using source directory: $SOURCE_DIR"

	if cp "$SOURCE_DIR/bin/dcvm" "$install_bin/dcvm"; then
		chmod +x "$install_bin/dcvm"
		print_status_log "SUCCESS" "Installed dcvm command to $install_bin/dcvm"
	else
		print_status_log "ERROR" "Failed to copy dcvm command"
		exit 1
	fi

	if cp -r "$SOURCE_DIR/lib/"* "$install_lib/"; then
		print_status_log "SUCCESS" "Installed libraries to $install_lib/"
	else
		print_status_log "ERROR" "Failed to copy library files"
		exit 1
	fi

	if find "$install_lib" -type f -name "*.sh" -exec chmod +x {} \; ; then
		print_status_log "SUCCESS" "Made all library scripts executable"
	else
		print_status_log "WARNING" "Could not set executable permissions on some scripts"
	fi

	if command -v dcvm >/dev/null 2>&1; then
		print_status_log "SUCCESS" "DCVM command is available in PATH"
	else
		print_status_log "WARNING" "DCVM command not found in PATH yet"
		print_status_log "INFO" "The command is installed at: $install_bin/dcvm"
		print_status_log "INFO" "You may need to restart your shell or add /usr/local/bin to PATH"
	fi
}

main() {
	echo "DCVM installer is starting..." >&2
	
	touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/dcvm-install.log"
	echo "$(date) - Installation started" >> "$LOG_FILE" 2>/dev/null || true
	
	print_status_log "INFO" "Starting DCVM installation..."
	
	check_root
	
	if [[ "$NETWORK_ONLY" == "1" ]]; then
		install_required_packages
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

	install_required_packages
	check_kvm_support
	install_dcvm_command
	install_completion
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
	[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE" || DATACENTER_BASE="$DEFAULT_DATACENTER_BASE"
fi

NFS_EXPORT_PATH="$DATACENTER_BASE/nfs-share"

for arg in "$@"; do
	case $arg in
	--network-only) NETWORK_ONLY=1 ;;
	--network-name=*) NETWORK_NAME_ARG="${arg#*=}" ;;
	--network-name)
		[[ -n "${2:-}" ]] && NETWORK_NAME_ARG="$2" || { echo "Error: --network-name requires a value" >&2; exit 1; }
		;;
	esac
done

echo "Executing DCVM installer..." >&2
main "$@"
