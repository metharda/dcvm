#!/bin/bash
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

get_host_info() {
	HOST_MEMORY_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
	HOST_MEMORY_MB=$((HOST_MEMORY_KB / 1024))
	HOST_CPUS=$(nproc)
	HOST_CPU_MODEL=$(grep "model name" /proc/cpuinfo | head -1 | cut -d: -f2 | sed 's/^ *//')

	MAX_VM_MEMORY=$((HOST_MEMORY_MB * 75 / 100))
	MAX_VM_CPUS=$((HOST_CPUS - 1))
	if [ $MAX_VM_CPUS -lt 1 ]; then
		MAX_VM_CPUS=1
	fi
}

read_password() {
	local prompt="$1"
	local var_name="$2"
	local password=""

	echo -n "$prompt"
	read -s password
	echo
	printf -v "$var_name" '%s' "$password"
}

validate_username() {
	local username="$1"

	if [ -z "$username" ]; then
		return 1
	fi

	if [[ ! "$username" =~ ^[a-zA-Z0-9_-]+$ ]]; then
		return 1
	fi

	if [[ ! "$username" =~ ^[a-zA-Z_] ]]; then
		return 1
	fi

	if [ ${#username} -lt 3 ] || [ ${#username} -gt 32 ]; then
		return 1
	fi

	return 0
}

validate_password() {
	local password="$1"

	if [ ${#password} -lt 4 ]; then
		echo "Password must be at least 4 characters long"
		return 1
	fi

	if [ ${#password} -gt 128 ]; then
		echo "Password must be less than 128 characters"
		return 1
	fi

	return 0
}

generate_password_hash() {
	local password="$1"
	local salt=$(openssl rand -base64 16 | tr -d "=+/" | cut -c1-16)
	echo "$password" | openssl passwd -6 -salt "$salt" -stdin
}

interactive_prompt_username() {
	while true; do
		read -p "Enter username for VM (default: admin): " VM_USERNAME
		VM_USERNAME=${VM_USERNAME:-admin}

		if validate_username "$VM_USERNAME"; then
			print_success "Username set to: $VM_USERNAME"
			break
		else
			print_error "Invalid username! Requirements:"
			echo "  - 3-32 characters long"
			echo "  - Start with letter or underscore"
			echo "  - Only letters, numbers, underscore, hyphen allowed"
			echo "  - Examples: admin, user1, my_user, test-vm"
			echo ""
		fi
	done
}

interactive_prompt_password() {
	print_info "Setting password for user '$VM_USERNAME'..."
	while true; do
		read_password "Password: " VM_PASSWORD

		if [ -z "$VM_PASSWORD" ]; then
			print_error "Password cannot be empty!"
			echo ""
			continue
		fi

		validation_result=$(validate_password "$VM_PASSWORD")
		if [ $? -ne 0 ]; then
			print_error "$validation_result"
			echo ""
			continue
		fi

		read_password "Retype password: " VM_PASSWORD_CONFIRM
		if [ "$VM_PASSWORD" = "$VM_PASSWORD_CONFIRM" ]; then
			print_success "User '$VM_USERNAME' password configured successfully"
			break
		else
			print_error "Passwords do not match! Please try again."
			echo ""
		fi
	done
}

interactive_prompt_memory() {
	while true; do
		read -p "Memory in MB (default: 2048, available: ${HOST_MEMORY_MB}MB, max recommended: ${MAX_VM_MEMORY}MB): " VM_MEMORY
		VM_MEMORY=$(echo "$VM_MEMORY" | xargs)
		VM_MEMORY=${VM_MEMORY:-2048}

		if [[ ! "$VM_MEMORY" =~ ^[0-9]+$ ]]; then
			print_error "Memory must be a number"
			continue
		fi

		if [ "$VM_MEMORY" -lt 512 ]; then
			print_error "Memory must be at least 512MB"
			continue
		fi

		if [ "$VM_MEMORY" -gt "$MAX_VM_MEMORY" ]; then
			print_warning "Warning: Requested ${VM_MEMORY}MB exceeds recommended ${MAX_VM_MEMORY}MB"
			read -p "Continue anyway? (y/N): " continue_anyway
			if [[ ! "$continue_anyway" =~ ^[Yy]$ ]]; then
				continue
			fi
		fi

		break
	done
}

interactive_prompt_cpus() {
	while true; do
		read -p "Number of CPUs (default: 2, available: ${HOST_CPUS}, max recommended: ${MAX_VM_CPUS}): " VM_CPUS
		VM_CPUS=$(echo "$VM_CPUS" | xargs)
		VM_CPUS=${VM_CPUS:-2}

		if [[ ! "$VM_CPUS" =~ ^[0-9]+$ ]]; then
			print_error "CPU count must be a number"
			continue
		fi

		if [ "$VM_CPUS" -lt 1 ]; then
			print_error "CPU count must be at least 1"
			continue
		fi

		if [ "$VM_CPUS" -gt "$MAX_VM_CPUS" ]; then
			print_warning "Warning: Requested ${VM_CPUS} CPUs exceeds recommended ${MAX_VM_CPUS}"
			read -p "Continue anyway? (y/N): " continue_anyway
			if [[ ! "$continue_anyway" =~ ^[Yy]$ ]]; then
				continue
			fi
		fi

		break
	done
}

interactive_prompt_disk() {
	while true; do
		read -p "Disk size (default: 20G, format: 10G, 500M, 2T): " VM_DISK_SIZE
		VM_DISK_SIZE=${VM_DISK_SIZE:-20G}

		if [[ ! "$VM_DISK_SIZE" =~ ^[0-9]+[GMT]$ ]]; then
			print_error "Disk size format: number + G/M/T (e.g., 20G, 512M, 1T)"
			continue
		fi

		size_num=$(echo "$VM_DISK_SIZE" | sed 's/[GMT]$//')
		size_unit=$(echo "$VM_DISK_SIZE" | sed 's/^[0-9]*//')

		case "$size_unit" in
		"M")
			if [ "$size_num" -lt 100 ]; then
				print_error "Minimum disk size is 100M"
				continue
			fi
			;;
		"G")
			if [ "$size_num" -lt 1 ] || [ "$size_num" -gt 1000 ]; then
				print_error "Disk size must be between 1G and 1000G"
				continue
			fi
			;;
		"T")
			if [ "$size_num" -gt 10 ]; then
				print_error "Maximum disk size is 10T"
				continue
			fi
			;;
		esac

		break
	done
}

interactive_prompt_root() {
	print_info "Root access configuration..."
	while true; do
		read -p "Enable root login? (y/N): " ENABLE_ROOT
		ENABLE_ROOT=${ENABLE_ROOT:-n}

		if [[ "$ENABLE_ROOT" =~ ^[YyNn]$ ]]; then
			break
		else
			print_error "Please enter 'y' for yes or 'n' for no"
		fi
	done

	ROOT_PASSWORD=""
	if [[ "$ENABLE_ROOT" =~ ^[Yy]$ ]]; then
		while true; do
			read -p "Use same password for root? (Y/n): " SAME_ROOT_PASSWORD
			SAME_ROOT_PASSWORD=${SAME_ROOT_PASSWORD:-y}

			if [[ "$SAME_ROOT_PASSWORD" =~ ^[YyNn]$ ]]; then
				break
			else
				print_error "Please enter 'y' for yes or 'n' for no"
			fi
		done

		if [[ "$SAME_ROOT_PASSWORD" =~ ^[Yy]$ ]]; then
			ROOT_PASSWORD="$VM_PASSWORD"
			print_success "Root will use the same password"
		else
			echo ""
			print_info "Setting password for root user..."
			while true; do
				read_password "Password: " ROOT_PASSWORD

				if [ -z "$ROOT_PASSWORD" ]; then
					print_error "Password cannot be empty!"
					echo ""
					continue
				fi

				validation_result=$(validate_password "$ROOT_PASSWORD")
				if [ $? -ne 0 ]; then
					print_error "$validation_result"
					echo ""
					continue
				fi

				read_password "Retype password: " ROOT_PASSWORD_CONFIRM
				if [ "$ROOT_PASSWORD" = "$ROOT_PASSWORD_CONFIRM" ]; then
					print_success "Root password configured successfully"
					break
				else
					print_error "Passwords do not match! Please try again."
					echo ""
				fi
			done
		fi
		print_success "Root access enabled"
	else
		print_success "Root access disabled"
	fi
}

interactive_prompt_ssh_key() {
	SETUP_SSH_KEY=false
	while true; do
		read -p "Setup SSH key for passwordless authentication? (Y/n): " ENABLE_SSH_KEY
		ENABLE_SSH_KEY=${ENABLE_SSH_KEY:-y}
		
		if [[ "$ENABLE_SSH_KEY" =~ ^[YyNn]$ ]]; then
			if [[ "$ENABLE_SSH_KEY" =~ ^[Yy]$ ]]; then
				SETUP_SSH_KEY=true
			fi
			break
		else
			print_error "Please enter 'y' for yes or 'n' for no"
		fi
	done
	
	if [ "$SETUP_SSH_KEY" = true ]; then
		print_info "Setting up SSH Key Authentication (RSA)..."
		
		if [ -f ~/.ssh/id_rsa.pub ]; then
			SSH_KEY=$(cat ~/.ssh/id_rsa.pub)
			print_success "Using existing RSA SSH key from ~/.ssh/id_rsa.pub"
		else
			print_info "No RSA SSH key found. Creating new RSA SSH key..."
			if ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N "" -C "$VM_USERNAME@$(hostname)" >/dev/null 2>&1; then
				SSH_KEY=$(cat ~/.ssh/id_rsa.pub)
				print_success "Created new RSA SSH key at ~/.ssh/id_rsa"
			else
				print_error "Failed to create SSH key"
				exit 1
			fi
		fi
	else
		print_info "SSH key authentication disabled - using password-only authentication"
	fi
}

check_dependencies() {
	local missing_deps=()

	for cmd in virsh virt-install qemu-img genisoimage openssl bc; do
		if ! command -v "$cmd" >/dev/null 2>&1; then
			missing_deps+=("$cmd")
		fi
	done

	if [ ${#missing_deps[@]} -gt 0 ]; then
		print_error "Missing required dependencies: ${missing_deps[*]}"
		echo "Please install them first and try again."
		exit 1
	fi
}

select_os() {
	if [ "$FORCE_MODE" = true ]; then
		if [ -z "$VM_OS_CHOICE" ]; then
			VM_OS_CHOICE="$DEFAULT_OS"
		fi
	else
		while true; do
			echo "Supported OS options:"
			echo "  1) Debian 12"
			echo "  2) Debian 11"
			echo "  3) Ubuntu 22.04"
			echo "  4) Ubuntu 20.04"
			read -p "Select the operating system for the VM [3]: " VM_OS_CHOICE
			VM_OS_CHOICE=${VM_OS_CHOICE:-3}
			break
		done
	fi
	
	case "$VM_OS_CHOICE" in
	1)
		VM_OS="debian12"
		TEMPLATE_FILE="$DATACENTER_BASE/storage/templates/debian-12-generic-amd64.qcow2"
		OS_VARIANT="debian12"
		OS_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2"
		;;
	2)
		VM_OS="debian11"
		TEMPLATE_FILE="$DATACENTER_BASE/storage/templates/debian-11-generic-amd64.qcow2"
		OS_VARIANT="debian11"
		OS_URL="https://cloud.debian.org/images/cloud/bullseye/latest/debian-11-generic-amd64.qcow2"
		;;
	3)
		VM_OS="ubuntu22.04"
		TEMPLATE_FILE="$DATACENTER_BASE/storage/templates/ubuntu-22.04-server-cloudimg-amd64.img"
		OS_VARIANT="ubuntu22.04"
		OS_URL="https://cloud-images.ubuntu.com/releases/jammy/release/ubuntu-22.04-server-cloudimg-amd64.img"
		;;
	4)
		VM_OS="ubuntu20.04"
		TEMPLATE_FILE="$DATACENTER_BASE/storage/templates/ubuntu-20.04-server-cloudimg-amd64.img"
		OS_VARIANT="ubuntu20.04"
		OS_URL="https://cloud-images.ubuntu.com/releases/focal/release/ubuntu-20.04-server-cloudimg-amd64.img"
		;;
	*)
		if [ "$FORCE_MODE" = true ]; then
			print_error "Invalid OS selection: $VM_OS_CHOICE. Must be 1, 2, 3, or 4."
			exit 1
		else
			echo "Invalid selection! Please enter 1, 2, 3, or 4."
			echo ""
			select_os
			return
		fi
		;;
	esac

	if [ ! -f "$TEMPLATE_FILE" ]; then
		echo "Base template for $VM_OS not found. Downloading..."
		mkdir -p "$DATACENTER_BASE/storage/templates"
		wget --show-progress -O "$TEMPLATE_FILE" "$OS_URL"
		if [ $? -ne 0 ]; then
			echo "Failed to download $VM_OS template. Please check your internet connection."
			exit 1
		fi
		echo "$VM_OS template downloaded successfully."
	fi
}

if [ -f /etc/dcvm-install.conf ]; then
	source /etc/dcvm-install.conf
else
	print_error "/etc/dcvm-install.conf is not found!"
	exit 1
fi

DATACENTER_BASE="${DATACENTER_BASE:-/srv/datacenter}"
NETWORK_NAME="${NETWORK_NAME:-datacenter-net}"
BRIDGE_NAME="${BRIDGE_NAME:-virbr-dc}"

DEFAULT_USERNAME="admin"
DEFAULT_PASSWORD=""
DEFAULT_MEMORY="2048"
DEFAULT_CPUS="2"
DEFAULT_DISK_SIZE="20G"
DEFAULT_OS="3"  # Ubuntu 22.04
DEFAULT_ENABLE_ROOT="n"
DEFAULT_ROOT_PASSWORD=""
FORCE_MODE=false

FLAG_USERNAME=""
FLAG_PASSWORD=""
FLAG_MEMORY=""
FLAG_CPUS=""
FLAG_DISK_SIZE=""
FLAG_OS=""
FLAG_ENABLE_ROOT=""
FLAG_ROOT_PASSWORD=""
FLAG_WITH_SSH_KEY=false
FLAG_DISABLE_SSH_KEY=false
ADDITIONAL_PACKAGES=""

show_usage() {
	echo "VM Creation Script"
	echo "Usage: $0 <vm_name> [options]"
	echo ""
	echo "Options:"
	echo "  -u, --username <username>      Set VM username (default: admin)"
	echo "  -p, --password <password>      Set VM password (required in force mode)"
	echo "  --enable-root                  Enable root login (uses same password as user)"
	echo "  -r, --root-password <password> Set root password (enables root access)"
	echo "  -m, --memory <memory_mb>       Set memory in MB (default: 2048)"
	echo "  -c, --cpus <cpu_count>         Set CPU count (default: 2)"
	echo "  -d, --disk <size>              Set disk size (default: 20G)"
	echo "  -o, --os <os_choice>           Set OS: 1=Debian12, 2=Debian11, 3=Ubuntu22.04, 4=Ubuntu20.04 (default: 3)"
	echo "  -k, --packages <packages>      Comma-separated package list"
	echo "  --with-ssh-key                 Add SSH key for passwordless authentication"
	echo "  --without-ssh-key              Disable SSH key setup (password-only)"
	echo "  -f, --force                    Force mode - uses defaults for unspecified options (no prompts)"
	echo "  -h, --help                     Show this help"
	echo ""
	echo "Modes:"
	echo "  Interactive Mode (default)     Prompts for unspecified options"
	echo "  Force Mode (-f)                Uses default values for unspecified options"
	echo ""
	echo "Interactive Mode Examples:"
	echo "  $0 datacenter-vm1              # Prompts for all options"
	echo "  $0 web-server -p mypass        # Prompts for username, memory, CPU, disk, root"
	echo "  $0 db-server -u dbadmin -m 4096 -k mysql-server  # Prompts for password, CPU, disk, root"
	echo ""
	echo "Force Mode Examples (uses defaults for unspecified options):"
	echo "  $0 web-server -f -p mypass123                    # Uses all defaults"
	echo "  $0 db-server -f -p secret -m 4096 -c 4 -k mysql-server,php  # Custom memory/CPU, default disk/OS"
	echo "  $0 test-vm -f -p mypass -o 1 --enable-root       # Custom OS, root enabled"
	echo "  $0 admin-vm -f -p mypass -r rootpass123          # Different root password"
	echo ""
	echo "Available packages: nginx, apache2, mysql-server, postgresql, php, nodejs, docker.io"
}

parse_arguments() {
	while [[ $# -gt 0 ]]; do
		case $1 in
			-u|--username)
				FLAG_USERNAME="$2"
				shift 2
				;;
			-p|--password)
				FLAG_PASSWORD="$2"
				shift 2
				;;
			--enable-root)
				FLAG_ENABLE_ROOT="y"
				shift
				;;
			-r|--root-password)
				FLAG_ROOT_PASSWORD="$2"
				FLAG_ENABLE_ROOT="y"
				shift 2
				;;
			-m|--memory)
				FLAG_MEMORY="$2"
				shift 2
				;;
			-c|--cpus)
				FLAG_CPUS="$2"
				shift 2
				;;
			-o|--os)
				FLAG_OS="$2"
				shift 2
				;;
			-d|--disk)
				FLAG_DISK_SIZE="$2"
				shift 2
				;;
			-k|--packages)
				ADDITIONAL_PACKAGES="$2"
				shift 2
				;;
			--with-ssh-key)
				FLAG_WITH_SSH_KEY=true
				shift
				;;
			--without-ssh-key)
				FLAG_DISABLE_SSH_KEY=true
				shift
				;;
			-f|--force)
				FORCE_MODE=true
				shift
				;;
			-h|--help)
				show_usage
				exit 0
				;;
			-*)
				echo "Unknown option: $1"
				show_usage
				exit 1
				;;
			*)
				if [ -z "$VM_NAME" ]; then
					VM_NAME="$1"
					shift
				else
					echo "Error: Unexpected argument '$1'"
					echo "If you want to install packages, use: -k <package1,package2,...>"
					show_usage
					exit 1
				fi
				;;
		esac
	done
}

if [ $# -lt 1 ]; then
	show_usage
	exit 1
fi

parse_arguments "$@"

if [ -z "$VM_NAME" ]; then
	echo "Error: VM name is required"
	show_usage
	exit 1
fi

check_dependencies
get_host_info
echo "=================================================="
echo "VM Creation Wizard"
echo "=================================================="
echo ""
echo "Host System Information:"
echo "  CPU: $HOST_CPU_MODEL"
echo "  Total CPUs: $HOST_CPUS"
echo "  Total Memory: ${HOST_MEMORY_MB}MB ($(echo "scale=1; $HOST_MEMORY_MB/1024" | bc -l)GB)"
echo "  Recommended VM Limits: ${MAX_VM_CPUS} CPUs, ${MAX_VM_MEMORY}MB RAM"
echo ""

print_info "Creating VM: $VM_NAME"

echo ""

print_info "Setting up operating system for the VM..."
if [ -n "$FLAG_OS" ]; then
	VM_OS_CHOICE="$FLAG_OS"
else
	VM_OS_CHOICE="${VM_OS_CHOICE:-$DEFAULT_OS}"
fi
select_os

echo ""
print_info "Setting up user account..."
echo ""

if [ -n "$FLAG_USERNAME" ]; then
	VM_USERNAME="$FLAG_USERNAME"
	if ! validate_username "$VM_USERNAME"; then
		print_error "Invalid username: $VM_USERNAME"
		print_error "Username requirements:"
		echo "  - 3-32 characters long"
		echo "  - Start with letter or underscore"
		echo "  - Only letters, numbers, underscore, hyphen allowed"
		exit 1
	fi
	print_success "Username set to: $VM_USERNAME"
elif [ "$FORCE_MODE" = true ]; then
	VM_USERNAME="$DEFAULT_USERNAME"
	print_success "Username set to: $VM_USERNAME"
else
	interactive_prompt_username
fi

echo ""

if [ -n "$FLAG_PASSWORD" ]; then
	print_info "Setting password for user '$VM_USERNAME'..."
	VM_PASSWORD="$FLAG_PASSWORD"
	validation_result=$(validate_password "$VM_PASSWORD")
	if [ $? -ne 0 ]; then
		print_error "Invalid password: $validation_result"
		exit 1
	fi
	print_success "User '$VM_USERNAME' password configured successfully"
elif [ "$FORCE_MODE" = true ]; then
	print_error "Password is required in force mode. Use -p <password>"
	exit 1
else
	interactive_prompt_password
fi

echo ""

if [ "$FORCE_MODE" = true ]; then
	print_info "Root access configuration..."
	if [ -n "$FLAG_ENABLE_ROOT" ]; then
		ENABLE_ROOT="$FLAG_ENABLE_ROOT"
	else
		ENABLE_ROOT="$DEFAULT_ENABLE_ROOT"
	fi

	ROOT_PASSWORD=""
	if [[ "$ENABLE_ROOT" =~ ^[Yy]$ ]]; then
		if [ -n "$FLAG_ROOT_PASSWORD" ]; then
			ROOT_PASSWORD="$FLAG_ROOT_PASSWORD"
			validation_result=$(validate_password "$ROOT_PASSWORD")
			if [ $? -ne 0 ]; then
				print_error "Invalid root password: $validation_result"
				exit 1
			fi
		else
			ROOT_PASSWORD="$VM_PASSWORD"
		fi
		print_success "Root will use the same password"
		print_success "Root access enabled"
	else
		print_success "Root access disabled"
	fi
else
	if [ -n "$FLAG_ENABLE_ROOT" ]; then
		print_info "Root access configuration..."
		ENABLE_ROOT="$FLAG_ENABLE_ROOT"
		ROOT_PASSWORD=""
		if [[ "$ENABLE_ROOT" =~ ^[Yy]$ ]]; then
			if [ -n "$FLAG_ROOT_PASSWORD" ]; then
				ROOT_PASSWORD="$FLAG_ROOT_PASSWORD"
				validation_result=$(validate_password "$ROOT_PASSWORD")
				if [ $? -ne 0 ]; then
					print_error "Invalid root password: $validation_result"
					exit 1
				fi
			else
				ROOT_PASSWORD="$VM_PASSWORD"
			fi
			print_success "Root will use the same password"
			print_success "Root access enabled"
		else
			print_success "Root access disabled"
		fi
	else
		interactive_prompt_root
	fi
fi

echo ""

SSH_KEY=""
SETUP_SSH_KEY=true

if [ "$FLAG_DISABLE_SSH_KEY" = true ]; then
	SETUP_SSH_KEY=false
elif [ "$FLAG_WITH_SSH_KEY" = true ]; then
	SETUP_SSH_KEY=true
fi

if [ "$SETUP_SSH_KEY" = true ]; then
	print_info "Setting up SSH Key Authentication (RSA)..."
	if [ -f ~/.ssh/id_rsa.pub ]; then
		SSH_KEY=$(cat ~/.ssh/id_rsa.pub)
		print_success "Using existing RSA SSH key from ~/.ssh/id_rsa.pub"
	else
		print_info "No RSA SSH key found. Creating new RSA SSH key..."
		if ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N "" -C "$VM_USERNAME@$(hostname)" >/dev/null 2>&1; then
			SSH_KEY=$(cat ~/.ssh/id_rsa.pub)
			print_success "Created new RSA SSH key at ~/.ssh/id_rsa"
		else
			print_error "Failed to create SSH key"
			exit 1
		fi
	fi
else
	print_info "SSH key authentication disabled - using password-only authentication"
fi

echo ""
print_info "VM Resource Configuration..."
echo ""

if [ "$FORCE_MODE" = true ]; then
	VM_MEMORY="${FLAG_MEMORY:-$DEFAULT_MEMORY}"
	VM_CPUS="${FLAG_CPUS:-$DEFAULT_CPUS}"
	VM_DISK_SIZE="${FLAG_DISK_SIZE:-$DEFAULT_DISK_SIZE}"

	if [[ ! "$VM_MEMORY" =~ ^[0-9]+$ ]]; then
		print_error "Memory must be a number"
		exit 1
	fi

	if [ "$VM_MEMORY" -lt 512 ]; then
		print_error "Memory must be at least 512MB"
		exit 1
	fi

	if [ "$VM_MEMORY" -gt "$MAX_VM_MEMORY" ]; then
		print_warning "Warning: Requested ${VM_MEMORY}MB exceeds recommended ${MAX_VM_MEMORY}MB"
	fi

	if [[ ! "$VM_CPUS" =~ ^[0-9]+$ ]]; then
		print_error "CPU count must be a number"
		exit 1
	fi

	if [ "$VM_CPUS" -lt 1 ]; then
		print_error "CPU count must be at least 1"
		exit 1
	fi

	if [ "$VM_CPUS" -gt "$MAX_VM_CPUS" ]; then
		print_warning "Warning: Requested ${VM_CPUS} CPUs exceeds recommended ${MAX_VM_CPUS}"
	fi

	if [[ ! "$VM_DISK_SIZE" =~ ^[0-9]+[GMT]$ ]]; then
		print_error "Disk size format: number + G/M/T (e.g., 20G, 512M, 1T)"
		exit 1
	fi

	size_num=$(echo "$VM_DISK_SIZE" | sed 's/[GMT]$//')
	size_unit=$(echo "$VM_DISK_SIZE" | sed 's/^[0-9]*//')

	case "$size_unit" in
	"M")
		if [ "$size_num" -lt 100 ]; then
			print_error "Minimum disk size is 100M"
			exit 1
		fi
		;;
	"G")
		if [ "$size_num" -lt 1 ] || [ "$size_num" -gt 1000 ]; then
			print_error "Disk size must be between 1G and 1000G"
			exit 1
		fi
		;;
	"T")
		if [ "$size_num" -gt 10 ]; then
			print_error "Maximum disk size is 10T"
			exit 1
		fi
		;;
	esac
else
	if [ -n "$FLAG_MEMORY" ]; then
		VM_MEMORY="$FLAG_MEMORY"
		if [[ ! "$VM_MEMORY" =~ ^[0-9]+$ ]]; then
			print_error "Memory must be a number"
			exit 1
		fi
		if [ "$VM_MEMORY" -lt 512 ]; then
			print_error "Memory must be at least 512MB"
			exit 1
		fi
		if [ "$VM_MEMORY" -gt "$MAX_VM_MEMORY" ]; then
			print_warning "Warning: Requested ${VM_MEMORY}MB exceeds recommended ${MAX_VM_MEMORY}MB"
		fi
	else
		interactive_prompt_memory
	fi

	if [ -n "$FLAG_CPUS" ]; then
		VM_CPUS="$FLAG_CPUS"
		if [[ ! "$VM_CPUS" =~ ^[0-9]+$ ]]; then
			print_error "CPU count must be a number"
			exit 1
		fi
		if [ "$VM_CPUS" -lt 1 ]; then
			print_error "CPU count must be at least 1"
			exit 1
		fi
		if [ "$VM_CPUS" -gt "$MAX_VM_CPUS" ]; then
			print_warning "Warning: Requested ${VM_CPUS} CPUs exceeds recommended ${MAX_VM_CPUS}"
		fi
	else
		interactive_prompt_cpus
	fi

	if [ -n "$FLAG_DISK_SIZE" ]; then
		VM_DISK_SIZE="$FLAG_DISK_SIZE"
		if [[ ! "$VM_DISK_SIZE" =~ ^[0-9]+[GMT]$ ]]; then
			print_error "Disk size format: number + G/M/T (e.g., 20G, 512M, 1T)"
			exit 1
		fi
		size_num=$(echo "$VM_DISK_SIZE" | sed 's/[GMT]$//')
		size_unit=$(echo "$VM_DISK_SIZE" | sed 's/^[0-9]*//')

		case "$size_unit" in
		"M")
			if [ "$size_num" -lt 100 ]; then
				print_error "Minimum disk size is 100M"
				exit 1
			fi
			;;
		"G")
			if [ "$size_num" -lt 1 ] || [ "$size_num" -gt 1000 ]; then
				print_error "Disk size must be between 1G and 1000G"
				exit 1
			fi
			;;
		"T")
			if [ "$size_num" -gt 10 ]; then
				print_error "Maximum disk size is 10T"
				exit 1
			fi
			;;
		esac
	else
		interactive_prompt_disk
	fi
fi

print_success "VM resources configured: ${VM_MEMORY}MB RAM, ${VM_CPUS} CPUs, ${VM_DISK_SIZE} disk"

echo ""
echo "=================================================="
print_info "VM Configuration Summary"
echo "=================================================="
echo "VM Name: $VM_NAME"
echo "Username: $VM_USERNAME"
echo "Password: ****"
if [[ "$ENABLE_ROOT" =~ ^[Yy]$ ]]; then
	echo "Root Access: Enabled"
	echo "Root Password: ****"
else
	echo "Root Access: Disabled"
fi
if [ -n "$SSH_KEY" ]; then
	echo "SSH Key: Configured"
fi
echo "Memory: ${VM_MEMORY}MB"
echo "CPUs: $VM_CPUS"
echo "Disk: $VM_DISK_SIZE"
echo ""
echo ""

if [ "$FORCE_MODE" = true ]; then
	CONFIRM="y"
else
	while true; do
		read -p "Proceed with VM creation? (Y/n): " CONFIRM
		CONFIRM=${CONFIRM:-y}

		if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
			break
		elif [[ "$CONFIRM" =~ ^[Nn]$ ]]; then
			print_info "VM creation cancelled by user."
			exit 0
		else
			print_error "Please enter 'y' to proceed or 'n' to cancel"
		fi
	done
fi

if virsh list --all 2>/dev/null | grep -q " $VM_NAME "; then
	print_error "VM $VM_NAME already exists"
	echo "Use: dcvm delete $VM_NAME (to delete it first)"
	exit 1
fi

print_info "Starting VM creation process..."

if [ ! -d "$DATACENTER_BASE/vms" ]; then
	print_error "Directory $DATACENTER_BASE/vms does not exist"
	exit 1
fi

if [ ! -f "$TEMPLATE_FILE" ]; then
	print_error "Base template $TEMPLATE_FILE not found"
	exit 1
fi

if ! mkdir -p $DATACENTER_BASE/vms/$VM_NAME/cloud-init; then
	print_error "Failed to create VM directory structure"
	exit 1
fi

print_info "Generating secure password hash..."
PASSWORD_HASH=$(generate_password_hash "$VM_PASSWORD")
if [ -z "$PASSWORD_HASH" ]; then
	print_error "Failed to generate password hash"
	exit 1
fi

PACKAGE_LIST=""
if [ -n "$ADDITIONAL_PACKAGES" ]; then
	IFS=',' read -ra PACKAGES <<<"$ADDITIONAL_PACKAGES"
	for package in "${PACKAGES[@]}"; do
		package=$(echo "$package" | xargs)
		PACKAGE_LIST="${PACKAGE_LIST}  - ${package}\n"
	done
fi

ROOT_LOGIN_SETTING="no"
if [[ "$ENABLE_ROOT" =~ ^[Yy]$ ]]; then
	ROOT_LOGIN_SETTING="yes"
fi

cat >$DATACENTER_BASE/vms/$VM_NAME/cloud-init/user-data <<USERDATA_EOF
#cloud-config
hostname: $VM_NAME
users:
  - name: $VM_USERNAME
    sudo: ['ALL=(ALL) NOPASSWD:ALL']
    shell: /bin/bash
    lock_passwd: false
    passwd: '$PASSWORD_HASH'$(if [ -n "$SSH_KEY" ]; then echo "
    ssh_authorized_keys:
      - $SSH_KEY"; fi)

ssh_pwauth: true
disable_root: $([ "$ROOT_LOGIN_SETTING" = "yes" ] && echo "false" || echo "true")$(if [ "$ROOT_LOGIN_SETTING" = "yes" ]; then echo "
chpasswd:
  list: |
    root:$ROOT_PASSWORD
  expire: False"; fi)
package_update: true
packages:
  - openssh-server
  - openssh-sftp-server
  - nfs-common
  - htop
  - curl
  - wget
  - net-tools
  - rsync
  - nano
  - vim
  - tree
  - unzip
$(if [ -n "$PACKAGE_LIST" ]; then echo -e "$PACKAGE_LIST"; fi)

bootcmd:
  - echo '$VM_USERNAME:$VM_PASSWORD' | chpasswd
$(if [[ "$ENABLE_ROOT" =~ ^[Yy]$ ]]; then echo "  - echo 'root:$ROOT_PASSWORD' | chpasswd"; fi)

write_files:
  - content: |
      # SSH Configuration for VM: $VM_NAME
      Port 22
      Protocol 2
      
      # Authentication
      PermitRootLogin $ROOT_LOGIN_SETTING
      PasswordAuthentication yes
      PubkeyAuthentication yes
      AuthorizedKeysFile .ssh/authorized_keys
      
      # Security settings
      UsePAM yes
      ChallengeResponseAuthentication no
      
      # SFTP subsystem (required for scp/sftp)
      Subsystem sftp /usr/lib/openssh/sftp-server
      
      # Connection settings
      ClientAliveInterval 300
      ClientAliveCountMax 2
      MaxAuthTries 6
      
      # Logging
      SyslogFacility AUTH
      LogLevel INFO
    path: /etc/ssh/sshd_config
    owner: root:root
    permissions: '0644'
  - content: |
      # VM Information - Created $(date)
      VM_NAME="$VM_NAME"
      VM_USERNAME="$VM_USERNAME"
      VM_MEMORY="${VM_MEMORY}MB"
      VM_CPUS="$VM_CPUS"
      VM_DISK="$VM_DISK_SIZE"
      ROOT_ACCESS="$ROOT_LOGIN_SETTING"
      SSH_KEY_AUTH="enabled"
      CREATED="$(date)"
      
      # Connection examples:
      # SSH: ssh $VM_USERNAME@<vm_ip>
      # SCP: scp file $VM_USERNAME@<vm_ip>:/path/
      # SFTP: sftp $VM_USERNAME@<vm_ip>
    path: /etc/vm-info
    owner: root:root
    permissions: '0644'

runcmd:
  # SSH setup
  - systemctl enable ssh
  - systemctl restart ssh
  - systemctl status ssh --no-pager
  
  # Network setup
  - mkdir -p /mnt/shared
  - chown $VM_USERNAME:$VM_USERNAME /mnt/shared
  - echo "10.10.10.1:${DATACENTER_BASE}/nfs-share /mnt/shared nfs defaults 0 0" >> /etc/fstab
  - mount -a || true
  
  # Create user directories
  - mkdir -p /home/$VM_USERNAME/{Documents,Downloads,Scripts}
  - chown -R $VM_USERNAME:$VM_USERNAME /home/$VM_USERNAME
  
$(if echo "$ADDITIONAL_PACKAGES" | grep -q "nginx"; then
	cat <<'NGINX_EOF'
  # Nginx setup
  - systemctl enable nginx
  - systemctl start nginx
  - echo "<h1>Welcome to $VM_NAME</h1><p>Nginx server running!</p><p>User: $VM_USERNAME</p>" > /var/www/html/index.html
  - chown www-data:www-data /var/www/html/index.html
NGINX_EOF
fi)

$(if echo "$ADDITIONAL_PACKAGES" | grep -q "apache2"; then
	cat <<'APACHE_EOF'
  # Apache setup
  - systemctl enable apache2
  - systemctl start apache2
  - echo "<h1>Welcome to $VM_NAME</h1><p>Apache server running!</p><p>User: $VM_USERNAME</p>" > /var/www/html/index.html
  - chown www-data:www-data /var/www/html/index.html
APACHE_EOF
fi)

$(if echo "$ADDITIONAL_PACKAGES" | grep -q "mysql-server"; then
	cat <<'MYSQL_EOF'
  # MySQL setup
  - systemctl enable mysql
  - systemctl start mysql
  - mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$VM_PASSWORD';"
  - mysql -e "CREATE USER '$VM_USERNAME'@'localhost' IDENTIFIED BY '$VM_PASSWORD';"
  - mysql -e "GRANT ALL PRIVILEGES ON *.* TO '$VM_USERNAME'@'localhost' WITH GRANT OPTION;"
  - mysql -e "FLUSH PRIVILEGES;"
MYSQL_EOF
fi)

$(if echo "$ADDITIONAL_PACKAGES" | grep -q "docker"; then
	cat <<'DOCKER_EOF'
  # Docker setup
  - systemctl enable docker
  - systemctl start docker
  - usermod -aG docker $VM_USERNAME
DOCKER_EOF
fi)
  
  # Final setup
  - echo "VM $VM_NAME setup completed successfully" >> /var/log/cloud-init-final.log
  - echo "User: $VM_USERNAME configured" >> /var/log/cloud-init-final.log
  - echo "SSH/SCP/SFTP ready for connections" >> /var/log/cloud-init-final.log
  - wall "VM $VM_NAME is ready! Login as $VM_USERNAME"

final_message: |
  VM $VM_NAME setup completed!
  Username: $VM_USERNAME
  SSH ready for connections.
USERDATA_EOF

if [ ! -f "$DATACENTER_BASE/vms/$VM_NAME/cloud-init/user-data" ]; then
	print_error "Failed to create cloud-init user-data file"
	exit 1
fi

cat >$DATACENTER_BASE/vms/$VM_NAME/cloud-init/meta-data <<METADATA_EOF
instance-id: $VM_NAME-$(date +%s)
local-hostname: $VM_NAME
METADATA_EOF

cat >$DATACENTER_BASE/vms/$VM_NAME/cloud-init/network-config <<'NETWORK_EOF'
version: 2
ethernets:
  enp1s0:
    dhcp4: true
    dhcp-identifier: mac
NETWORK_EOF

print_info "Creating cloud-init configuration..."
cd $DATACENTER_BASE/vms/$VM_NAME
if ! genisoimage -output cloud-init.iso -volid cidata -joliet -rock cloud-init/ >/dev/null 2>&1; then
	print_error "Failed to create cloud-init ISO"
	exit 1
fi

print_info "Creating VM disk ($VM_DISK_SIZE)..."
if ! qemu-img create -f qcow2 -F qcow2 -b $TEMPLATE_FILE ${VM_NAME}-disk.qcow2 $VM_DISK_SIZE >/dev/null 2>&1; then
	print_error "Failed to create VM disk"
	exit 1
fi

print_info "Installing VM with $VM_MEMORY MB RAM and $VM_CPUS CPUs..."
if ! virt-install \
	--name $VM_NAME \
	--virt-type kvm \
	--memory $VM_MEMORY \
	--vcpus $VM_CPUS \
	--boot hd,menu=on \
	--disk path=$DATACENTER_BASE/vms/$VM_NAME/${VM_NAME}-disk.qcow2,device=disk \
	--disk path=$DATACENTER_BASE/vms/$VM_NAME/cloud-init.iso,device=cdrom \
	--graphics none \
	--os-variant $OS_VARIANT \
	--network network=$NETWORK_NAME \
	--console pty,target_type=serial \
	--import \
	--noautoconsole >/dev/null 2>&1; then
	print_error "Failed to create VM"
	exit 1
fi

if ! virsh autostart $VM_NAME >/dev/null 2>&1; then
	print_warning "Failed to set VM autostart (VM created successfully)"
fi

echo ""
echo "=================================================="
print_success "VM $VM_NAME created successfully!"
echo "=================================================="
echo ""
echo "Connection Methods:"
echo "   Console: virsh console $VM_NAME"
echo "   SSH: ssh $VM_USERNAME@<vm_ip>"
echo "   SCP: scp file $VM_USERNAME@<vm_ip>:/path/"
echo "   SFTP: sftp $VM_USERNAME@<vm_ip>"
echo ""
echo "Quick Commands:"
echo "   Check status: dcvm status"
echo "   Get IP: dcvm network"
echo "   Setup ports: dcvm setup-forwarding"
echo "   Delete VM: dcvm delete $VM_NAME"
echo ""
echo "Wait 2-3 minutes for cloud-init to complete setup"
echo "   Monitor: virsh console $VM_NAME"
echo "   Check logs: tail -f /var/log/cloud-init-output.log (inside VM)"
