#!/usr/bin/env bash

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_status() {
    local status=$1
    local message=$2
    case $status in
        "INFO") print_info "$message" ;;
        "SUCCESS") print_success "$message" ;;
        "WARNING") print_warning "$message" ;;
        "ERROR") print_error "$message" ;;
    esac
}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] ${*:2}"; }
log_message() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_to_file() {
    local log_file="${1:-/var/log/dcvm.log}"
    local message="$2"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $message" >> "$log_file"
}

load_dcvm_config() {
    local config_file="${1:-/etc/dcvm-install.conf}"
    
    if [ ! -f "$config_file" ]; then
        print_error "Configuration file not found: $config_file"
        print_info "Please run the DCVM installer first"
        exit 1
    fi
    
    source "$config_file"
    
    DATACENTER_BASE="${DATACENTER_BASE:-/srv/datacenter}"
    NETWORK_NAME="${NETWORK_NAME:-datacenter-net}"
    BRIDGE_NAME="${BRIDGE_NAME:-virbr-dc}"
}

require_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "This script must be run as root"
        exit 1
    fi
}

check_permissions() {
    if [ "$EUID" -ne 0 ]; then
        print_warning "Script should be run as root for best results"
        print_info "Some operations may fail without root privileges"
    fi
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

check_dependencies() {
    local missing_deps=()
    for cmd in "$@"; do
        if ! command_exists "$cmd"; then
            missing_deps+=("$cmd")
        fi
    done
    if [ ${#missing_deps[@]} -gt 0 ]; then
        print_error "Missing required dependencies: ${missing_deps[*]}"
        print_info "Please install them first and try again"
        exit 1
    fi
}

validate_vm_name() {
    local vm_name="$1"
    if [ -z "$vm_name" ]; then
        print_error "VM name cannot be empty"
        return 1
    fi
    if [[ ! "$vm_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        print_error "VM name can only contain letters, numbers, underscores, and hyphens"
        return 1
    fi
    if [ ${#vm_name} -lt 3 ] || [ ${#vm_name} -gt 64 ]; then
        print_error "VM name must be between 3 and 64 characters"
        return 1
    fi
    return 0
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

vm_exists() {
    local vm_name="$1"
    virsh list --all 2>/dev/null | grep -q " $vm_name "
}

get_vm_state() {
    local vm_name="$1"
    virsh domstate "$vm_name" 2>/dev/null || echo "not-found"
}

get_vm_ip() {
    local vm_name="$1"
    local attempts="${2:-1}"
    local ip=""
    local count=0
    
    while [ -z "$ip" ] && [ $count -lt $attempts ]; do
        ip=$(virsh domifaddr "$vm_name" --source agent 2>/dev/null | awk '/ipv4/ {print $4}' | cut -d'/' -f1 | grep '^10\.10\.10\.' | head -1)
        if [ -z "$ip" ]; then
            ip=$(virsh domifaddr "$vm_name" --source lease 2>/dev/null | awk '/ipv4/ {print $4}' | cut -d'/' -f1 | grep '^10\.10\.10\.' | head -1)
        fi
        if [ -z "$ip" ]; then
            local network_name="${NETWORK_NAME:-datacenter-net}"
            ip=$(virsh net-dhcp-leases "$network_name" 2>/dev/null | grep "$vm_name" | awk '{print $5}' | cut -d'/' -f1 | grep '^10\.10\.10\.' | head -1)
        fi
        if [ -z "$ip" ]; then
            local mac=$(virsh domiflist "$vm_name" 2>/dev/null | grep "${NETWORK_NAME:-datacenter-net}" | awk '{print $5}')
            if [ -n "$mac" ]; then
                ip=$(virsh net-dhcp-leases "${NETWORK_NAME:-datacenter-net}" 2>/dev/null | grep "$mac" | awk '{print $5}' | cut -d'/' -f1 | grep '^10\.10\.10\.' | head -1)
            fi
        fi
        if [ -z "$ip" ] && [ $attempts -gt 1 ]; then
            sleep 2
        fi
        count=$((count + 1))
    done
    
    if [ -z "$ip" ]; then
        echo "N/A"
        return 1
    fi
    echo "$ip"
}

get_vm_mac() {
    local vm_name="$1"
    local network_name="${NETWORK_NAME:-datacenter-net}"
    virsh domiflist "$vm_name" 2>/dev/null | grep "$network_name" | awk '{print $5}'
}

get_vm_disk_path() {
    local vm_name="$1"
    local disk_path=""
    disk_path=$(virsh domblklist "$vm_name" 2>/dev/null | grep -v "Target" | grep -v "^$" | awk '{print $2}' | head -1)
    if [ -z "$disk_path" ]; then
        disk_path=$(virsh dumpxml "$vm_name" 2>/dev/null | grep -oP "source file='\K[^']+(?=')" | head -1)
    fi
    echo "$disk_path"
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

generate_password_hash() {
    local password="$1"
    local salt=$(openssl rand -base64 16 | tr -d "=+/" | cut -c1-16)
    echo "$password" | openssl passwd -6 -salt "$salt" -stdin
}

generate_random_mac() {
    printf "52:54:00:%02x:%02x:%02x\n" $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256))
}

format_bytes() {
    local bytes=$1
    local units=("B" "KB" "MB" "GB" "TB")
    local unit=0
    while [ $bytes -ge 1024 ] && [ $unit -lt 4 ]; do
        bytes=$((bytes / 1024))
        unit=$((unit + 1))
    done
    echo "${bytes}${units[$unit]}"
}

create_dir_safe() {
    local dir_path="$1"
    local permissions="${2:-755}"
    if [ ! -d "$dir_path" ]; then
        if ! mkdir -p "$dir_path"; then
            print_error "Failed to create directory: $dir_path"
            return 1
        fi
        chmod "$permissions" "$dir_path"
    fi
    return 0
}

backup_file() {
    local file_path="$1"
    local backup_suffix="${2:-.backup}"
    if [ -f "$file_path" ]; then
        cp "$file_path" "${file_path}${backup_suffix}"
        print_info "Backup created: ${file_path}${backup_suffix}"
    fi
}

confirm_action() {
    local prompt="${1:-Are you sure?}"
    local default="${2:-n}"
    while true; do
        read -p "$prompt (y/n) [${default}]: " response
        response=${response:-$default}
        case "$response" in
            [Yy]*) return 0 ;;
            [Nn]*) return 1 ;;
            *) print_error "Please answer y or n" ;;
        esac
    done
}

get_system_info() {
    echo "System Information:"
    echo "  OS: $(lsb_release -d 2>/dev/null | cut -f2 || echo 'Unknown')"
    echo "  Kernel: $(uname -r)"
    echo "  CPUs: $(nproc)"
    echo "  Memory: $(free -h | awk '/^Mem:/ {print $2}')"
    echo "  Disk: $(df -h / | awk 'NR==2 {print $4 " available"}')"
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

check_port_connectivity() {
    local ip="$1"
    local port="$2"
    timeout 3 bash -c "</dev/tcp/$ip/$port" 2>/dev/null
}

is_vm_in_network() {
    local vm_name="$1"
    local network_name="${NETWORK_NAME:-datacenter-net}"
    virsh domiflist "$vm_name" 2>/dev/null | grep -q "$network_name"
}

get_port_mappings_file() {
    echo "${DATACENTER_BASE:-/srv/datacenter}/port-mappings.txt"
}

read_port_mappings() {
    local file=$(get_port_mappings_file)
    [ -f "$file" ] && grep -v "^#" "$file" | grep -v "^$"
}

check_vm_exists() {
    local vm_name="$1"
    virsh list --all 2>/dev/null | grep -q " $vm_name "
}

list_all_vms() {
    virsh list --all | grep -E "(running|shut off)" | while read line; do
        vm=$(echo "$line" | awk '{print $2}')
        state=$(echo "$line" | awk '{print $3}')
        [ -n "$vm" ] && [ "$vm" != "Name" ] && printf "  %-15s: %s\n" "$vm" "$state"
    done
}

list_datacenter_vms() {
    virsh list --all | grep -E "(running|shut off)" | while read line; do
        vm=$(echo "$line" | awk '{print $2}')
        state=$(echo "$line" | awk '{print $3}')
        if [ -n "$vm" ] && [ "$vm" != "Name" ] && is_vm_in_network "$vm"; then
            printf "  %-15s: %s\n" "$vm" "$state"
        fi
    done
}

get_host_ip() {
    local config_file="${1:-/etc/dcvm-install.conf}"
    if [ -f "$config_file" ]; then
        grep "^DATACENTER_IP=" "$config_file" | cut -d'=' -f2 | tr -d '"'
    else
        echo "10.8.8.223"
    fi
}

check_ping() {
    local ip="$1"
    ping -c 1 -W 2 "$ip" >/dev/null 2>&1
}

require_confirmation() {
    local message="$1"
    echo "$message"
    read -p "Are you sure? (y/N): " CONFIRM
    CONFIRM=${CONFIRM:-n}
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        print_info "Operation cancelled"
        exit 0
    fi
}

validate_memory_size() {
    local memory="$1"
    local max_memory="${2:-$MAX_VM_MEMORY}"
    
    [[ ! "$memory" =~ ^[0-9]+$ ]] && return 1
    [ "$memory" -lt 512 ] && return 1
    [ "$memory" -gt "$max_memory" ] && return 2
    return 0
}

validate_cpu_count() {
    local cpus="$1"
    local max_cpus="${2:-$MAX_VM_CPUS}"
    
    [[ ! "$cpus" =~ ^[0-9]+$ ]] && return 1
    [ "$cpus" -lt 1 ] && return 1
    [ "$cpus" -gt "$max_cpus" ] && return 2
    return 0
}

validate_disk_size() {
    local disk_size="$1"
    
    [[ ! "$disk_size" =~ ^[0-9]+[GMT]$ ]] && return 1
    
    local size_num=$(echo "$disk_size" | sed 's/[GMT]$//')
    local size_unit=$(echo "$disk_size" | sed 's/^[0-9]*//')
    
    case "$size_unit" in
        "M") [ "$size_num" -lt 100 ] && return 1 ;;
        "G") [ "$size_num" -lt 1 ] || [ "$size_num" -gt 1000 ] && return 1 ;;
        "T") [ "$size_num" -gt 10 ] && return 1 ;;
    esac
    return 0
}

stop_vm_gracefully() {
    local vm_name="$1"
    local timeout="${2:-60}"
    
    if ! virsh list | grep -q " $vm_name .*running"; then
        return 0
    fi
    
    virsh shutdown "$vm_name" >/dev/null 2>&1
    
    local count=0
    while [ $count -lt $timeout ]; do
        if ! virsh list | grep -q " $vm_name .*running"; then
            return 0
        fi
        sleep 2
        count=$((count + 2))
    done
    
    virsh destroy "$vm_name" >/dev/null 2>&1
    return 0
}

export -f print_info print_success print_warning print_error print_status
export -f log log_message log_to_file
export -f load_dcvm_config require_root check_permissions command_exists check_dependencies
export -f validate_vm_name validate_username validate_password
export -f vm_exists get_vm_state get_vm_ip get_vm_mac get_vm_disk_path
export -f read_password generate_password_hash generate_random_mac
export -f format_bytes create_dir_safe backup_file confirm_action
export -f get_system_info get_host_info
export -f check_port_connectivity is_vm_in_network get_port_mappings_file read_port_mappings
export -f check_vm_exists list_all_vms list_datacenter_vms get_host_ip check_ping require_confirmation
export -f validate_memory_size validate_cpu_count validate_disk_size stop_vm_gracefully
