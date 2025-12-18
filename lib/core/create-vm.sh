#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../utils/common.sh"
source "$SCRIPT_DIR/../utils/mirror-manager.sh"

DEFAULT_USERNAME="admin"
DEFAULT_PASSWORD=""
DEFAULT_MEMORY="2048"
DEFAULT_CPUS="2"
DEFAULT_DISK_SIZE="20G"
DEFAULT_OS="3"
DEFAULT_ENABLE_ROOT="y"
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
FLAG_STATIC_IP=""
ADDITIONAL_PACKAGES=""

declare -A TEMPLATE_SHA256
TEMPLATE_SHA256["ubuntu-22.04-server-cloudimg-amd64.img"]=""
TEMPLATE_SHA256["debian-12-generic-amd64.qcow2"]=""
TEMPLATE_SHA256["debian-11-generic-amd64.qcow2"]=""
TEMPLATE_SHA256["ubuntu-20.04-server-cloudimg-amd64.img"]=""
TEMPLATE_SHA256["Arch-Linux-x86_64-cloudimg.qcow2"]=""

show_usage() {
	cat <<EOF
VM Creation Script
Usage: dcvm create <vm_name> [options]

Options:
  -u, --username <username>      		# Set VM username (default: admin)
  -p, --password <password>     		# Set VM password (required in force mode)
  --enable-root                  		# Enable root login (uses same password as user)
  -r, --root-password <password> 	    # Set root password (enables root access)
  -m, --memory <memory_mb>       		# Set memory in MB (default: 2048)
  -c, --cpus <cpu_count>         		# Set CPU count (default: 2)
  -d, --disk <size>              		# Set disk size (default: 20G)
  -o, --os <os_choice|iso_path>  		# Set OS: 1-5 or path to ISO file
  -k, --packages <packages>     		# Comma-separated package list
  --ip <address>                 		# Set static IP (e.g., 10.10.10.50) - DHCP if not specified
  --with-ssh-key                 		# Add SSH key for passwordless authentication
  --without-ssh-key              		# Disable SSH key setup (password-only)
  -f, --force                    		# Force mode - uses defaults for unspecified options (no prompts)
  -h, --help                     		# Show this help

OS Options:
  1 = Debian 12      2 = Debian 11      3 = Ubuntu 22.04 (default)
  4 = Ubuntu 20.04   5 = Arch Linux     /path/to/file.iso = Custom ISO

Modes:
  Interactive Mode (default)     		# Prompts for unspecified options
  Force Mode (-f)                		# Uses default values for unspecified options

Interactive Mode Examples:
  dcvm create datacenter-vm1             								# Prompts for all options
  dcvm create web-server -p mypass        								# Prompts for username, memory, CPU, disk, root
  dcvm create db-server -u dbadmin -m 4096 -k mysql-server  			# Prompts for password, CPU, disk, root

Force Mode Examples (uses defaults for unspecified options):
  dcvm create web-server -f -p mypass123                    			# Uses all defaults
  dcvm create db-server -f -p secret -m 4096 -c 4 -k mysql-server,php   # Custom memory/CPU, default disk/OS
  dcvm create test-vm -f -p mypass -o 1 --enable-root       			# Custom OS, root enabled
  dcvm create admin-vm -f -p mypass -r rootpass123          			# Different root password

ISO Installation Examples:
  dcvm create custom-vm -f -o /path/to/ubuntu.iso -m 4096   			# Install from ISO file
  dcvm create win-vm -f -o /isos/windows.iso -d 100G -m 8192 			# Windows from ISO

Available packages: nginx, apache2, mysql-server, postgresql, php, nodejs, docker.io
EOF
}

parse_arguments() {
	while [[ $# -gt 0 ]]; do
		case $1 in
			-u|--username) FLAG_USERNAME="$2"; shift 2 ;;
			-p|--password) FLAG_PASSWORD="$2"; shift 2 ;;
			--enable-root) FLAG_ENABLE_ROOT="y"; shift ;;
			-r|--root-password) FLAG_ROOT_PASSWORD="$2"; FLAG_ENABLE_ROOT="y"; shift 2 ;;
			-m|--memory) FLAG_MEMORY="$2"; shift 2 ;;
			-c|--cpus) FLAG_CPUS="$2"; shift 2 ;;
			-o|--os) FLAG_OS="$2"; shift 2 ;;
			-d|--disk) FLAG_DISK_SIZE="$2"; shift 2 ;;
			-k|--packages) ADDITIONAL_PACKAGES="$2"; shift 2 ;;
			--ip) FLAG_STATIC_IP="$2"; shift 2 ;;
			--with-ssh-key) FLAG_WITH_SSH_KEY=true; shift ;;
			--without-ssh-key) FLAG_DISABLE_SSH_KEY=true; shift ;;
			-f|--force) FORCE_MODE=true; shift ;;
			-h|--help) show_usage; exit 0 ;;
			-*) echo "Unknown option: $1"; show_usage; exit 1 ;;
			*)
				[ -z "$VM_NAME" ] && { VM_NAME="$1"; shift; } || {
					echo "Error: Unexpected argument '$1'"
					echo "If you want to install packages, use: -k <package1,package2,...>"
					show_usage; exit 1
				}
				;;
		esac
	done
}




check_dependencies() {
	local missing_deps=()
	local iso_tool=""
	
	if command -v mkisofs >/dev/null 2>&1; then
		iso_tool="mkisofs"
	elif command -v genisoimage >/dev/null 2>&1; then
		iso_tool="genisoimage"
	else
		missing_deps+=("genisoimage or mkisofs")
	fi

	for cmd in virsh virt-install qemu-img openssl bc; do
		command -v "$cmd" >/dev/null 2>&1 || missing_deps+=("$cmd")
	done
	if [ ${#missing_deps[@]} -gt 0 ]; then
		print_error "Missing required dependencies: ${missing_deps[*]}"
		echo "Please install them first and try again."
		exit 1
	fi
}

select_os() {
	[ "$FORCE_MODE" = true ] && [ -z "$VM_OS_CHOICE" ] && VM_OS_CHOICE="$DEFAULT_OS"
	if [ "$FORCE_MODE" != true ]; then
		while true; do
			cat <<-EOF
			Supported OS options:
			  1) Debian 12
			  2) Debian 11
			  3) Ubuntu 22.04
			  4) Ubuntu 20.04
			  5) Arch Linux
			EOF
			read -p "Select the operating system for the VM [3]: " VM_OS_CHOICE
			VM_OS_CHOICE=${VM_OS_CHOICE:-3}
			break
		done
	fi
	case "$VM_OS_CHOICE" in
	1) VM_OS="debian12"; TEMPLATE_FILE="$DATACENTER_BASE/storage/templates/debian-12-generic-amd64.qcow2"
	   OS_VARIANT="debian12"; OS_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2" ;;
	2) VM_OS="debian11"; TEMPLATE_FILE="$DATACENTER_BASE/storage/templates/debian-11-generic-amd64.qcow2"
	   OS_VARIANT="debian11"; OS_URL="https://cloud.debian.org/images/cloud/bullseye/latest/debian-11-generic-amd64.qcow2" ;;
	3) VM_OS="ubuntu22.04"; TEMPLATE_FILE="$DATACENTER_BASE/storage/templates/ubuntu-22.04-server-cloudimg-amd64.img"
	   OS_VARIANT="ubuntu22.04"; OS_URL="https://cloud-images.ubuntu.com/releases/jammy/release/ubuntu-22.04-server-cloudimg-amd64.img" ;;
	4) VM_OS="ubuntu20.04"; TEMPLATE_FILE="$DATACENTER_BASE/storage/templates/ubuntu-20.04-server-cloudimg-amd64.img"
	   OS_VARIANT="ubuntu20.04"; OS_URL="https://cloud-images.ubuntu.com/releases/focal/release/ubuntu-20.04-server-cloudimg-amd64.img" ;;
	5) VM_OS="archlinux"; TEMPLATE_FILE="$DATACENTER_BASE/storage/templates/Arch-Linux-x86_64-cloudimg.qcow2"
	   OS_VARIANT="archlinux"; OS_URL="https://gitlab.archlinux.org/archlinux/arch-boxes/-/jobs/artifacts/master/raw/output/Arch-Linux-x86_64-cloudimg.qcow2?job=build:cloudimg" ;;
	*)

		if [[ "$VM_OS_CHOICE" == *.iso ]] || [[ "$VM_OS_CHOICE" == /* && -f "$VM_OS_CHOICE" ]]; then
			print_info "Detected ISO file - switching to custom ISO installation mode..."
			exec "$SCRIPT_DIR/custom-iso.sh" "$VM_NAME" --iso "$VM_OS_CHOICE" \
				${FLAG_MEMORY:+-m "$FLAG_MEMORY"} \
				${FLAG_CPUS:+-c "$FLAG_CPUS"} \
				${FLAG_DISK_SIZE:+-d "$FLAG_DISK_SIZE"} \
				${FLAG_STATIC_IP:+--ip "$FLAG_STATIC_IP"} \
				${FORCE_MODE:+-f}
			exit $?
		fi
		if [ "$FORCE_MODE" = true ]; then
			print_error "Invalid OS selection: $VM_OS_CHOICE. Must be 1-5 or path to ISO file."
			exit 1
		else
			echo "Invalid selection! Please enter 1-5 or full path to an ISO file."
			echo ""
			select_os
			return
		fi
		;;
	esac
	if [ ! -f "$TEMPLATE_FILE" ]; then
		echo "Base template for $VM_OS not found. Downloading..."
		mkdir -p "$DATACENTER_BASE/storage/templates"
		local tmpl_key
		tmpl_key="$(basename "$TEMPLATE_FILE")"
		local expected_sha
		expected_sha="${TEMPLATE_SHA256[$tmpl_key]:-}"
		if download_with_mirrors "$tmpl_key" "$TEMPLATE_FILE" 104857600 "$expected_sha"; then
			echo "$VM_OS template downloaded successfully."
		else
			print_error "Failed to download $VM_OS template. Please check your internet connection or mirrors." 
			exit 1
		fi
	fi
}

setup_user_account() {
	[ "$FORCE_MODE" = true ] && print_info "User account setup" || { echo ""; print_info "Setting up user account..."; }

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
		[ "$FORCE_MODE" = true ] && print_success "Username: $VM_USERNAME" || print_success "Username set to: $VM_USERNAME"
	elif [ "$FORCE_MODE" = true ]; then
		VM_USERNAME="$DEFAULT_USERNAME"
		print_success "Username: $VM_USERNAME (default)"
	else
		interactive_prompt_username
	fi

	[ "$FORCE_MODE" != true ] && echo ""

	if [ -n "$FLAG_PASSWORD" ]; then
		[ "$FORCE_MODE" = true ] && print_info "Password setup" || print_info "Setting password for user '$VM_USERNAME'..."
		VM_PASSWORD="$FLAG_PASSWORD"
		validation_result=$(validate_password "$VM_PASSWORD")
		[ $? -ne 0 ] && { print_error "Invalid password: $validation_result"; exit 1; }
		[ "$FORCE_MODE" = true ] && print_success "Password configured" || print_success "User '$VM_USERNAME' password configured successfully"
	elif [ "$FORCE_MODE" = true ]; then
		print_error "Password is required in force mode. Use -p <password>"
		exit 1
	else
		interactive_prompt_password
	fi

	[ "$FORCE_MODE" != true ] && echo ""
}

setup_root_access() {
	if [ "$FORCE_MODE" = true ]; then
		print_info "Root access configuration"
		[ -n "$FLAG_ENABLE_ROOT" ] && ENABLE_ROOT="$FLAG_ENABLE_ROOT" || ENABLE_ROOT="$DEFAULT_ENABLE_ROOT"
		ROOT_PASSWORD=""
		if [[ "$ENABLE_ROOT" =~ ^[Yy]$ ]]; then
			if [ -n "$FLAG_ROOT_PASSWORD" ]; then
				ROOT_PASSWORD="$FLAG_ROOT_PASSWORD"
				validation_result=$(validate_password "$ROOT_PASSWORD")
				[ $? -ne 0 ] && { print_error "Invalid root password: $validation_result"; exit 1; }
			else
				ROOT_PASSWORD="$VM_PASSWORD"
			fi
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
					[ $? -ne 0 ] && { print_error "Invalid root password: $validation_result"; exit 1; }
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

	[ "$FORCE_MODE" != true ] && echo ""
}

setup_ssh_key() {
	SSH_KEY=""
	SETUP_SSH_KEY=true

	[ "$FLAG_DISABLE_SSH_KEY" = true ] && SETUP_SSH_KEY=false
	[ "$FLAG_WITH_SSH_KEY" = true ] && SETUP_SSH_KEY=true

	if [ "$SETUP_SSH_KEY" = true ]; then
		[ "$FORCE_MODE" = true ] && print_info "SSH key setup" || print_info "Setting up SSH Key Authentication (RSA)..."
		if [ -f ~/.ssh/id_rsa.pub ]; then
			SSH_KEY=$(cat ~/.ssh/id_rsa.pub)
			[ "$FORCE_MODE" = true ] && print_success "SSH key configured" || print_success "Using existing RSA SSH key from ~/.ssh/id_rsa.pub"
		else
			[ "$FORCE_MODE" = true ] && print_info "Creating SSH key" || print_info "No RSA SSH key found. Creating new RSA SSH key..."
			if ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N "" -C "$VM_USERNAME@$(hostname)" >/dev/null 2>&1; then
				SSH_KEY=$(cat ~/.ssh/id_rsa.pub)
				[ "$FORCE_MODE" = true ] && print_success "SSH key created" || print_success "Created new RSA SSH key at ~/.ssh/id_rsa"
			else
				print_error "Failed to create SSH key"
				exit 1
			fi
		fi
	else
		[ "$FORCE_MODE" = true ] && print_info "SSH key disabled" || print_info "SSH key authentication disabled - using password-only authentication"
	fi
}

compute_incremental_ip() {
	local base_ip="$1"
	local idx="$2"
	local total="$3"

	if ! [[ "$base_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
		return 1
	fi
	IFS='.' read -r a b c d <<< "$base_ip"
	local prefix="${a}.${b}.${c}"
	local base_last=$d

	if [ "$base_last" -lt 2 ] || [ "$base_last" -gt 254 ]; then
		return 1
	fi

	local forward=$((base_last + idx))
	local assigned
	if [ $forward -le 254 ]; then
		assigned=$forward
	else
		local overflow=$((forward - 254))
		assigned=$((base_last - overflow))
	fi

	if [ $assigned -lt 2 ] || [ $assigned -gt 254 ]; then
		return 1
	fi

	echo "${prefix}.${assigned}"
	return 0
}

setup_static_ip() {
	if [ -n "$FLAG_STATIC_IP" ]; then
		if ! validate_ip_in_subnet "$FLAG_STATIC_IP"; then
			exit 1
		fi
		[ "$FORCE_MODE" = true ] && print_info "Static IP: $FLAG_STATIC_IP" || print_success "Using static IP: $FLAG_STATIC_IP"
		if [ -n "${DATACENTER_BASE:-}" ] && [ -n "${VM_NAME:-}" ]; then
			mkdir -p "$DATACENTER_BASE/config/network" 2>/dev/null || true
			cat > "$DATACENTER_BASE/config/network/${VM_NAME}.conf" <<NETCONF
VM_NAME="${VM_NAME}"
IP="${FLAG_STATIC_IP}"
ASSIGNED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
SOURCE="static"
NETCONF
		fi
	elif [ "$FORCE_MODE" != true ]; then
		interactive_prompt_static_ip
	fi
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
			cat <<-EOF
			  - 3-32 characters long
			  - Start with letter or underscore
			  - Only letters, numbers, underscore, hyphen allowed
			  - Examples: admin, user1, my_user, test-vm
			
			EOF
		fi
	done
}

interactive_prompt_password() {
	print_info "Setting password for user '$VM_USERNAME'..."
	while true; do
		read_password "Password: " VM_PASSWORD
		[ -z "$VM_PASSWORD" ] && { print_error "Password cannot be empty!"; echo ""; continue; }
		validation_result=$(validate_password "$VM_PASSWORD")
		[ $? -ne 0 ] && { print_error "$validation_result"; echo ""; continue; }
		read_password "Retype password: " VM_PASSWORD_CONFIRM
		[ "$VM_PASSWORD" = "$VM_PASSWORD_CONFIRM" ] && { print_success "User '$VM_USERNAME' password configured successfully"; break; }
		print_error "Passwords do not match! Please try again."
		echo ""
	done
}

interactive_prompt_memory() {
	while true; do
		read -p "Memory in MB (default: 2048, available: ${HOST_MEMORY_MB}MB, max recommended: ${MAX_VM_MEMORY}MB): " VM_MEMORY
		VM_MEMORY=$(echo "$VM_MEMORY" | xargs)
		VM_MEMORY=${VM_MEMORY:-2048}
		[[ ! "$VM_MEMORY" =~ ^[0-9]+$ ]] && { print_error "Memory must be a number"; continue; }
		[ "$VM_MEMORY" -lt 512 ] && { print_error "Memory must be at least 512MB"; continue; }
		if [ "$VM_MEMORY" -gt "$MAX_VM_MEMORY" ]; then
			print_warning "Warning: Requested ${VM_MEMORY}MB exceeds recommended ${MAX_VM_MEMORY}MB"
			read -p "Continue anyway? (y/N): " continue_anyway
			[[ ! "$continue_anyway" =~ ^[Yy]$ ]] && continue
		fi
		break
	done
}

interactive_prompt_cpus() {
	while true; do
		read -p "Number of CPUs (default: 2, available: ${HOST_CPUS}, max recommended: ${MAX_VM_CPUS}): " VM_CPUS
		VM_CPUS=$(echo "$VM_CPUS" | xargs)
		VM_CPUS=${VM_CPUS:-2}
		[[ ! "$VM_CPUS" =~ ^[0-9]+$ ]] && { print_error "CPU count must be a number"; continue; }
		[ "$VM_CPUS" -lt 1 ] && { print_error "CPU count must be at least 1"; continue; }
		if [ "$VM_CPUS" -gt "$MAX_VM_CPUS" ]; then
			print_warning "Warning: Requested ${VM_CPUS} CPUs exceeds recommended ${MAX_VM_CPUS}"
			read -p "Continue anyway? (y/N): " continue_anyway
			[[ ! "$continue_anyway" =~ ^[Yy]$ ]] && continue
		fi
		break
	done
}

interactive_prompt_disk() {
	while true; do
		read -p "Disk size (default: 20G, format: 10G, 500M, 2T): " VM_DISK_SIZE
		VM_DISK_SIZE=${VM_DISK_SIZE:-20G}
		[[ ! "$VM_DISK_SIZE" =~ ^[0-9]+[GMT]$ ]] && { print_error "Disk size format: number + G/M/T (e.g., 20G, 512M, 1T)"; continue; }
		size_num=$(echo "$VM_DISK_SIZE" | sed 's/[GMT]$//')
		size_unit=$(echo "$VM_DISK_SIZE" | sed 's/^[0-9]*//')
		case "$size_unit" in
		"M") [ "$size_num" -lt 100 ] && { print_error "Minimum disk size is 100M"; continue; } ;;
		"G") [ "$size_num" -lt 1 ] || [ "$size_num" -gt 1000 ] && { print_error "Disk size must be between 1G and 1000G"; continue; } ;;
		"T") [ "$size_num" -gt 10 ] && { print_error "Maximum disk size is 10T"; continue; } ;;
		esac
		break
	done
}

interactive_prompt_root() {
	print_info "Root access configuration..."
	while true; do
		read -p "Enable root login? (Y/n): " ENABLE_ROOT
		ENABLE_ROOT=${ENABLE_ROOT:-y}
		[[ "$ENABLE_ROOT" =~ ^[YyNn]$ ]] && break
		print_error "Please enter 'y' for yes or 'n' for no"
	done
	ROOT_PASSWORD=""
	if [[ "$ENABLE_ROOT" =~ ^[Yy]$ ]]; then
		while true; do
			read -p "Use same password for root? (Y/n): " SAME_ROOT_PASSWORD
			SAME_ROOT_PASSWORD=${SAME_ROOT_PASSWORD:-y}
			[[ "$SAME_ROOT_PASSWORD" =~ ^[YyNn]$ ]] && break
			print_error "Please enter 'y' for yes or 'n' for no"
		done
		if [[ "$SAME_ROOT_PASSWORD" =~ ^[Yy]$ ]]; then
			ROOT_PASSWORD="$VM_PASSWORD"
			print_success "Root will use the same password"
		else
			echo ""
			print_info "Setting password for root user..."
			while true; do
				read_password "Password: " ROOT_PASSWORD
				[ -z "$ROOT_PASSWORD" ] && { print_error "Password cannot be empty!"; echo ""; continue; }
				validation_result=$(validate_password "$ROOT_PASSWORD")
				[ $? -ne 0 ] && { print_error "$validation_result"; echo ""; continue; }
				read_password "Retype password: " ROOT_PASSWORD_CONFIRM
				[ "$ROOT_PASSWORD" = "$ROOT_PASSWORD_CONFIRM" ] && { print_success "Root password configured successfully"; break; }
				print_error "Passwords do not match! Please try again."
				echo ""
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
			[[ "$ENABLE_SSH_KEY" =~ ^[Yy]$ ]] && SETUP_SSH_KEY=true
			break
		fi
		print_error "Please enter 'y' for yes or 'n' for no"
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

interactive_prompt_static_ip() {
	local subnet="${NETWORK_SUBNET:-10.10.10}"
	echo ""
	print_info "Static IP Configuration..."
	cat <<NETINFO
  Network subnet: ${subnet}.0/24
  Gateway: ${subnet}.1
  Valid range: ${subnet}.2 - ${subnet}.254

NETINFO
	
	while true; do
		read -p "Use static IP? (y/N, default: DHCP): " use_static
		use_static=${use_static:-n}
		
		if [[ "$use_static" =~ ^[Nn]$ ]]; then
			FLAG_STATIC_IP=""
			print_success "Using DHCP for automatic IP assignment"
			break
		elif [[ "$use_static" =~ ^[Yy]$ ]]; then
			while true; do
				read -p "Enter static IP (e.g., ${subnet}.50): " FLAG_STATIC_IP
				if [ -z "$FLAG_STATIC_IP" ]; then
					print_error "IP address cannot be empty"
					continue
				fi
				if validate_ip_in_subnet "$FLAG_STATIC_IP"; then
					print_success "Static IP set to: $FLAG_STATIC_IP"
					break 2
				fi
			done
		else
			print_error "Please enter 'y' for static IP or 'n' for DHCP"
		fi
	done
}


validate_disk_size() {
	local disk_size="$1"
	[[ ! "$disk_size" =~ ^[0-9]+[GMT]$ ]] && { print_error "Disk size format: number + G/M/T (e.g., 20G, 512M, 1T)"; return 1; }
	local size_num=$(echo "$disk_size" | sed 's/[GMT]$//')
	local size_unit=$(echo "$disk_size" | sed 's/^[0-9]*//')
	case "$size_unit" in
		"M") [ "$size_num" -lt 100 ] && { print_error "Minimum disk size is 100M"; return 1; } ;;
		"G") [ "$size_num" -lt 1 ] || [ "$size_num" -gt 1000 ] && { print_error "Disk size must be between 1G and 1000G"; return 1; } ;;
		"T") [ "$size_num" -gt 10 ] && { print_error "Maximum disk size is 10T"; return 1; } ;;
	esac
	return 0
}

setup_vm_resources() {
	[ "$FORCE_MODE" = true ] && print_info "Resource configuration" || { echo ""; print_info "VM Resource Configuration..."; }

	if [ "$FORCE_MODE" = true ]; then
		VM_MEMORY="${FLAG_MEMORY:-$DEFAULT_MEMORY}"
		VM_CPUS="${FLAG_CPUS:-$DEFAULT_CPUS}"
		VM_DISK_SIZE="${FLAG_DISK_SIZE:-$DEFAULT_DISK_SIZE}"
		[[ ! "$VM_MEMORY" =~ ^[0-9]+$ ]] && { print_error "Memory must be a number"; exit 1; }
		[ "$VM_MEMORY" -lt 512 ] && { print_error "Memory must be at least 512MB"; exit 1; }
		[ "$VM_MEMORY" -gt "$MAX_VM_MEMORY" ] && print_warning "Warning: Requested ${VM_MEMORY}MB exceeds recommended ${MAX_VM_MEMORY}MB"
		[[ ! "$VM_CPUS" =~ ^[0-9]+$ ]] && { print_error "CPU count must be a number"; exit 1; }
		[ "$VM_CPUS" -lt 1 ] && { print_error "CPU count must be at least 1"; exit 1; }
		[ "$VM_CPUS" -gt "$MAX_VM_CPUS" ] && print_warning "Warning: Requested ${VM_CPUS} CPUs exceeds recommended ${MAX_VM_CPUS}"
		validate_disk_size "$VM_DISK_SIZE" || exit 1
	else
		if [ -n "$FLAG_MEMORY" ]; then
			VM_MEMORY="$FLAG_MEMORY"
			[[ ! "$VM_MEMORY" =~ ^[0-9]+$ ]] && { print_error "Memory must be a number"; exit 1; }
			[ "$VM_MEMORY" -lt 512 ] && { print_error "Memory must be at least 512MB"; exit 1; }
			[ "$VM_MEMORY" -gt "$MAX_VM_MEMORY" ] && print_warning "Warning: Requested ${VM_MEMORY}MB exceeds recommended ${MAX_VM_MEMORY}MB"
		else
			interactive_prompt_memory
		fi
		if [ -n "$FLAG_CPUS" ]; then
			VM_CPUS="$FLAG_CPUS"
			[[ ! "$VM_CPUS" =~ ^[0-9]+$ ]] && { print_error "CPU count must be a number"; exit 1; }
			[ "$VM_CPUS" -lt 1 ] && { print_error "CPU count must be at least 1"; exit 1; }
			[ "$VM_CPUS" -gt "$MAX_VM_CPUS" ] && print_warning "Warning: Requested ${VM_CPUS} CPUs exceeds recommended ${MAX_VM_CPUS}"
		else
			interactive_prompt_cpus
		fi
		if [ -n "$FLAG_DISK_SIZE" ]; then
			VM_DISK_SIZE="$FLAG_DISK_SIZE"
			validate_disk_size "$VM_DISK_SIZE" || exit 1
		else
			interactive_prompt_disk
		fi
	fi

	print_success "VM resources configured: ${VM_MEMORY}MB RAM, ${VM_CPUS} CPUs, ${VM_DISK_SIZE} disk"
}

show_vm_summary() {
	if [ "$FORCE_MODE" = true ]; then
		echo ""
		print_info "Starting VM creation"
	else
		echo ""
		echo "=================================================="
		print_info "VM Configuration Summary"
		echo "=================================================="
		echo "VM Name: $VM_NAME"
		echo "Username: $VM_USERNAME"
		echo "Password: ****"
		[[ "$ENABLE_ROOT" =~ ^[Yy]$ ]] && { echo "Root Access: Enabled"; echo "Root Password: ****"; } || echo "Root Access: Disabled"
		[ -n "$SSH_KEY" ] && echo "SSH Key: Configured"
		echo "Memory: ${VM_MEMORY}MB"
		echo "CPUs: $VM_CPUS"
		echo "Disk: $VM_DISK_SIZE"
		echo ""
		echo ""
	fi
}

confirm_vm_creation() {
	if [ "$FORCE_MODE" = true ]; then
		CONFIRM="y"
	else
		while true; do
			read -p "Proceed with VM creation? (Y/n): " CONFIRM
			CONFIRM=${CONFIRM:-y}
			[[ "$CONFIRM" =~ ^[Yy]$ ]] && break
			[[ "$CONFIRM" =~ ^[Nn]$ ]] && { print_info "VM creation cancelled by user."; exit 0; }
			print_error "Please enter 'y' to proceed or 'n' to cancel"
		done
	fi
}

prepare_vm_directory() {
	[ "$FORCE_MODE" = true ] && print_info "Creating VM files" || print_info "Starting VM creation process..."

	[ ! -d "$DATACENTER_BASE/vms" ] && { print_error "Directory $DATACENTER_BASE/vms does not exist"; exit 1; }
	[ ! -f "$TEMPLATE_FILE" ] && { print_error "Base template $TEMPLATE_FILE not found"; exit 1; }

	mkdir -p "$DATACENTER_BASE/vms/$VM_NAME/cloud-init" || { print_error "Failed to create cloud-init directory"; exit 1; }
}

generate_cloud_init_userdata() {
	[ "$FORCE_MODE" = true ] && print_info "Generating password hash" || print_info "Generating secure password hash..."
	PASSWORD_HASH=$(generate_password_hash "$VM_PASSWORD")
	[ -z "$PASSWORD_HASH" ] && { print_error "Failed to generate password hash"; exit 1; }

	PACKAGE_LIST=""
	if [ -n "$ADDITIONAL_PACKAGES" ]; then
		IFS=',' read -ra PACKAGES <<<"$ADDITIONAL_PACKAGES"
		for package in "${PACKAGES[@]}"; do
			package=$(echo "$package" | xargs)
			PACKAGE_LIST="${PACKAGE_LIST}
  - ${package}"
		done
	fi

	ROOT_LOGIN_SETTING="no"
	[[ "$ENABLE_ROOT" =~ ^[Yy]$ ]] && ROOT_LOGIN_SETTING="yes"

	cat >"$DATACENTER_BASE/vms/$VM_NAME/cloud-init/user-data" <<USERDATA_EOF
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
  - unzip$(if [ -n "$PACKAGE_LIST" ]; then echo "$PACKAGE_LIST"; fi)

bootcmd:
  - echo '$VM_USERNAME:$VM_PASSWORD' | chpasswd
$(if [[ "$ENABLE_ROOT" =~ ^[Yy]$ ]]; then echo "  - echo 'root:$ROOT_PASSWORD' | chpasswd"; fi)

write_files:
  - content: |
      Port 22
      Protocol 2
      PermitRootLogin $ROOT_LOGIN_SETTING
      PasswordAuthentication yes
      PubkeyAuthentication yes
      AuthorizedKeysFile .ssh/authorized_keys
      UsePAM yes
      ChallengeResponseAuthentication no
      Subsystem sftp /usr/lib/openssh/sftp-server
      ClientAliveInterval 300
      ClientAliveCountMax 2
      MaxAuthTries 6
      SyslogFacility AUTH
      LogLevel INFO
    path: /etc/ssh/sshd_config
    owner: root:root
    permissions: '0644'
  - content: |
      VM_NAME="$VM_NAME"
      VM_USERNAME="$VM_USERNAME"
      VM_MEMORY="${VM_MEMORY}MB"
      VM_CPUS="$VM_CPUS"
      VM_DISK="$VM_DISK_SIZE"
      ROOT_ACCESS="$ROOT_LOGIN_SETTING"
      SSH_KEY_AUTH="enabled"
      CREATED="$(date)"
    path: /etc/vm-info
    owner: root:root
    permissions: '0644'

runcmd:
  - systemctl enable ssh
  - systemctl restart ssh
  - systemctl status ssh --no-pager
  - mkdir -p /mnt/shared
  - chown $VM_USERNAME:$VM_USERNAME /mnt/shared
  - echo "10.10.10.1:${DATACENTER_BASE}/nfs-share /mnt/shared nfs defaults 0 0" >> /etc/fstab
  - mount -a || true
  - mkdir -p /home/$VM_USERNAME/{Documents,Downloads,Scripts}
  - chown -R $VM_USERNAME:$VM_USERNAME /home/$VM_USERNAME
$(if echo "$ADDITIONAL_PACKAGES" | grep -q "nginx"; then cat <<'NGINX_EOF'
  - systemctl enable nginx
  - systemctl start nginx
  - echo "<h1>Welcome to $VM_NAME</h1><p>Nginx server running!</p><p>User: $VM_USERNAME</p>" > /var/www/html/index.html
  - chown www-data:www-data /var/www/html/index.html
NGINX_EOF
fi)
$(if echo "$ADDITIONAL_PACKAGES" | grep -q "apache2"; then cat <<'APACHE_EOF'
  - systemctl enable apache2
  - systemctl start apache2
  - echo "<h1>Welcome to $VM_NAME</h1><p>Apache server running!</p><p>User: $VM_USERNAME</p>" > /var/www/html/index.html
  - chown www-data:www-data /var/www/html/index.html
APACHE_EOF
fi)
$(if echo "$ADDITIONAL_PACKAGES" | grep -q "mysql-server"; then cat <<'MYSQL_EOF'
  - systemctl enable mysql
  - systemctl start mysql
  - mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$VM_PASSWORD';"
  - mysql -e "CREATE USER '$VM_USERNAME'@'localhost' IDENTIFIED BY '$VM_PASSWORD';"
  - mysql -e "GRANT ALL PRIVILEGES ON *.* TO '$VM_USERNAME'@'localhost' WITH GRANT OPTION;"
  - mysql -e "FLUSH PRIVILEGES;"
MYSQL_EOF
fi)
$(if echo "$ADDITIONAL_PACKAGES" | grep -q "docker"; then cat <<'DOCKER_EOF'
  - systemctl enable docker
  - systemctl start docker
  - usermod -aG docker $VM_USERNAME
DOCKER_EOF
fi)
  - echo "VM $VM_NAME setup completed successfully" >> /var/log/cloud-init-final.log
  - echo "User: $VM_USERNAME configured" >> /var/log/cloud-init-final.log
  - echo "SSH/SCP/SFTP ready for connections" >> /var/log/cloud-init-final.log
  - wall "VM $VM_NAME is ready! Login as $VM_USERNAME"

final_message: |
  VM $VM_NAME setup completed!
  Username: $VM_USERNAME
  SSH ready for connections.
USERDATA_EOF

	[ ! -f "$DATACENTER_BASE/vms/$VM_NAME/cloud-init/user-data" ] && { print_error "Failed to create cloud-init user-data file"; exit 1; }
}

generate_cloud_init_metadata() {
	cat >"$DATACENTER_BASE/vms/$VM_NAME/cloud-init/meta-data" <<METADATA_EOF
instance-id: $VM_NAME-$(date +%s)
local-hostname: $VM_NAME
METADATA_EOF
}

generate_cloud_init_network() {
	local network_config="$DATACENTER_BASE/vms/$VM_NAME/cloud-init/network-config"
	
	if [ -n "$FLAG_STATIC_IP" ]; then
		if [ "$VM_OS" = "archlinux" ]; then
			cat >"$network_config" <<NETWORK_EOF
version: 2
ethernets:
  enp1s0:
    dhcp4: false
    addresses:
      - ${FLAG_STATIC_IP}/24
    gateway4: ${NETWORK_SUBNET}.1
    nameservers:
      addresses: [8.8.8.8, 8.8.4.4]
NETWORK_EOF
		else
			cat >"$network_config" <<NETWORK_EOF
version: 2
ethernets:
  enp1s0:
    dhcp4: false
    addresses:
      - ${FLAG_STATIC_IP}/24
    gateway4: ${NETWORK_SUBNET}.1
    nameservers:
      addresses: [8.8.8.8, 8.8.4.4]
NETWORK_EOF
		fi
	else
		if [ "$VM_OS" = "archlinux" ]; then
			cat >"$network_config" <<'NETWORK_EOF'
version: 2
ethernets:
  enp1s0:
    dhcp4: true
    dhcp-identifier: mac
    nameservers:
      addresses: [8.8.8.8, 8.8.4.4]
NETWORK_EOF
		else
			cat >"$network_config" <<'NETWORK_EOF'
version: 2
ethernets:
  enp1s0:
    dhcp4: true
    dhcp-identifier: mac
NETWORK_EOF
		fi
	fi
}

create_cloud_init_iso() {
	[ "$FORCE_MODE" = true ] && print_info "Creating cloud-init config" || print_info "Creating cloud-init configuration..."
	cd "$DATACENTER_BASE/vms/$VM_NAME"
	if command -v mkisofs >/dev/null 2>&1; then
		mkisofs -output cloud-init.iso -volid cidata -joliet -rock cloud-init/ >/dev/null 2>&1 || { print_error "Failed to create cloud-init ISO"; exit 1; }
	else
		genisoimage -output cloud-init.iso -volid cidata -joliet -rock cloud-init/ >/dev/null 2>&1 || { print_error "Failed to create cloud-init ISO"; exit 1; }
	fi
}

create_vm_disk() {
	[ "$FORCE_MODE" = true ] && print_info "Creating VM disk ($VM_DISK_SIZE)" || print_info "Creating VM disk ($VM_DISK_SIZE)..."
	qemu-img create -f qcow2 -F qcow2 -b "$TEMPLATE_FILE" "${VM_NAME}-disk.qcow2" "$VM_DISK_SIZE" >/dev/null 2>&1 || { print_error "Failed to create VM disk"; exit 1; }
}

install_vm() {
	[ "$FORCE_MODE" = true ] && print_info "Installing VM (${VM_MEMORY}MB, ${VM_CPUS} CPUs)" || print_info "Installing VM with $VM_MEMORY MB RAM and $VM_CPUS CPUs..."
	virt-install \
		--name "$VM_NAME" \
		--virt-type kvm \
		--memory "$VM_MEMORY" \
		--vcpus "$VM_CPUS" \
		--boot hd,menu=on \
		--disk "path=$DATACENTER_BASE/vms/$VM_NAME/${VM_NAME}-disk.qcow2,device=disk" \
		--disk "path=$DATACENTER_BASE/vms/$VM_NAME/cloud-init.iso,device=cdrom" \
		--graphics none \
		--os-variant "$OS_VARIANT" \
		--network "network=$NETWORK_NAME" \
		--console pty,target_type=serial \
		--import \
		--noautoconsole >/dev/null 2>&1 || { print_error "Failed to create VM"; exit 1; }

	virsh autostart "$VM_NAME" >/dev/null 2>&1 || { [ "$FORCE_MODE" = true ] && print_warning "Failed to set VM autostart" || print_warning "Failed to set VM autostart (VM created successfully)"; }
}

show_post_creation_info() {
	cat <<EOF
==================================================
 VM $VM_NAME created successfully!
==================================================

Connection Methods:
   Console: virsh console $VM_NAME
   SSH: ssh $VM_USERNAME@<vm_ip>
   SCP: scp file $VM_USERNAME@<vm_ip>:/path/
   SFTP: sftp $VM_USERNAME@<vm_ip>

Quick Commands:
   Check status: dcvm status
   Get IP: dcvm network
   Setup ports: dcvm network ports setup
   Delete VM: dcvm delete $VM_NAME

Wait 2-3 minutes for cloud-init to complete setup
   Monitor: virsh console $VM_NAME
   Check logs: tail -f /var/log/cloud-init-output.log (inside VM)
EOF
}

main() {
	load_dcvm_config
	
	[ -f /etc/dcvm-install.conf ] && source /etc/dcvm-install.conf || { print_error "/etc/dcvm-install.conf is not found!"; exit 1; }
	
	DATACENTER_BASE="${DATACENTER_BASE:-/srv/datacenter}"
	NETWORK_NAME="${NETWORK_NAME:-datacenter-net}"
	BRIDGE_NAME="${BRIDGE_NAME:-virbr-dc}"

	if [ $# -lt 1 ] || [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
		show_usage
		exit 0
	fi

	parse_arguments "$@"

	if [ -z "$VM_NAME" ]; then
		show_usage
		exit 0
	fi

	IFS=',' read -ra VM_NAMES <<< "$VM_NAME"
	BASE_STATIC_IP="$FLAG_STATIC_IP"

	for vm in "${VM_NAMES[@]}"; do
		vm=$(echo "$vm" | xargs) 
		[ -z "$vm" ] && continue
		if virsh list --all 2>/dev/null | grep -q " $vm "; then
			print_error "VM $vm already exists"
			echo "Use: dcvm delete $vm (to delete it first)"
			exit 1
		fi
	done

	check_dependencies
	get_host_info

	if [ ${#VM_NAMES[@]} -gt 1 ] && [ "$FORCE_MODE" != true ]; then
		print_error "Multiple VMs require force mode (-f) with password (-p)"
		echo "Example: dcvm create vm1,vm2,vm3 -f -p mypassword"
		exit 1
	fi

		for i in "${!VM_NAMES[@]}"; do
				VM_NAME="${VM_NAMES[$i]}"
				VM_NAME=$(echo "$VM_NAME" | xargs)
				[ -z "$VM_NAME" ] && continue
				if [ -n "$BASE_STATIC_IP" ]; then
					if computed_ip=$(compute_incremental_ip "$BASE_STATIC_IP" "$i" "${#VM_NAMES[@]}"); then
						FLAG_STATIC_IP="$computed_ip"
					else
						print_error "Failed to compute static IP for $VM_NAME from base $BASE_STATIC_IP"
						exit 1
					fi
				fi

		cat <<EOF
====================
 VM Creation Wizard
====================

Host System Information:
  CPU: $HOST_CPU_MODEL
  Total CPUs: $HOST_CPUS
  Total Memory: ${HOST_MEMORY_MB}MB ($(echo "scale=1; $HOST_MEMORY_MB/1024" | bc -l)GB)
  Recommended VM Limits: ${MAX_VM_CPUS} CPUs, ${MAX_VM_MEMORY}MB RAM

EOF
		print_info "Creating VM: $VM_NAME"
		[ -n "$FLAG_OS" ] && VM_OS_CHOICE="$FLAG_OS" || VM_OS_CHOICE="${VM_OS_CHOICE:-$DEFAULT_OS}"
		select_os
		[ "$FORCE_MODE" = true ] && { echo ""; print_info "OS configuration"; print_success "Operating system set to: $VM_OS"; } || { echo ""; print_info "Setting up operating system for the VM..."; }
		setup_user_account
		setup_root_access
		setup_ssh_key
		setup_static_ip
		setup_vm_resources
		show_vm_summary
		confirm_vm_creation
		prepare_vm_directory
		generate_cloud_init_userdata
		generate_cloud_init_metadata
		generate_cloud_init_network
		create_cloud_init_iso
		create_vm_disk
		install_vm
		show_post_creation_info
	done

	if [ ${#VM_NAMES[@]} -gt 1 ]; then
		echo ""
		print_success "All ${#VM_NAMES[@]} VMs created successfully!"
	fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi