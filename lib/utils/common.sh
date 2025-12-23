#!/usr/bin/env bash

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# ============================================================================
# OS Detection & Platform Abstraction Layer
# ============================================================================

# Detect the current operating system
detect_os() {
  case "$(uname -s)" in
    Darwin) echo "macos" ;;
    Linux)  echo "linux" ;;
    *)      echo "unknown" ;;
  esac
}

# Check if running on macOS
is_macos() {
  [[ "$(uname -s)" == "Darwin" ]]
}

# Check if running on Linux
is_linux() {
  [[ "$(uname -s)" == "Linux" ]]
}

# Get the QEMU accelerator for the current platform
get_qemu_accel() {
  if is_macos; then
    # Check for Apple Silicon vs Intel
    if [[ "$(uname -m)" == "arm64" ]]; then
      echo "hvf"
    else
      # Intel Mac - try HVF first, fall back to TCG
      if sysctl -n kern.hv_support 2>/dev/null | grep -q "1"; then
        echo "hvf"
      else
        echo "tcg"
      fi
    fi
  else
    # Linux - prefer KVM
    if [[ -e /dev/kvm ]]; then
      echo "kvm"
    else
      echo "tcg"
    fi
  fi
}

# Get the QEMU system binary for the current architecture
get_qemu_binary() {
  local arch="${1:-$(uname -m)}"
  case "$arch" in
    x86_64|amd64)   echo "qemu-system-x86_64" ;;
    arm64|aarch64)  echo "qemu-system-aarch64" ;;
    *)              echo "qemu-system-$arch" ;;
  esac
}

# Map host architecture to cloud-image filename suffix.
# Debian/Ubuntu cloud images typically use "amd64" or "arm64" in filenames.
get_template_arch() {
  case "$(uname -m)" in
    arm64|aarch64) echo "arm64" ;;
    x86_64|amd64)  echo "amd64" ;;
    *)             echo "amd64" ;;
  esac
}

# Cross-platform sed in-place edit (handles BSD vs GNU sed)
sed_inplace() {
  # Prefer feature-detection over OS detection:
  # - GNU sed supports: sed -i 's/a/b/' file
  # - BSD sed supports: sed -i '' 's/a/b/' file
  if sed --version >/dev/null 2>&1; then
    sed -i "$@"
  else
    sed -i '' "$@"
  fi
}

# Cross-platform timeout command
timeout_cmd() {
  local duration="$1"
  shift
  if is_macos; then
    # Use gtimeout from coreutils if available, otherwise perl fallback
    if command -v gtimeout >/dev/null 2>&1; then
      gtimeout "$duration" "$@"
    else
      perl -e "alarm $duration; exec @ARGV" -- "$@"
    fi
  else
    timeout "$duration" "$@"
  fi
}

# Cross-platform nproc (number of CPUs)
get_nproc() {
  if is_macos; then
    sysctl -n hw.ncpu
  else
    nproc
  fi
}

# Cross-platform memory info (returns total RAM in KB)
get_total_memory_kb() {
  if is_macos; then
    # macOS: get memory in bytes, convert to KB
    local mem_bytes
    mem_bytes=$(sysctl -n hw.memsize 2>/dev/null)
    echo $((mem_bytes / 1024))
  else
    grep MemTotal /proc/meminfo | awk '{print $2}'
  fi
}

# Cross-platform readlink -f (canonical path)
readlink_f() {
  if is_macos; then
    # Use greadlink if available (from coreutils), otherwise Python fallback
    if command -v greadlink >/dev/null 2>&1; then
      greadlink -f "$1"
    else
      python3 -c "import os; print(os.path.realpath('$1'))" 2>/dev/null || echo "$1"
    fi
  else
    readlink -f "$1"
  fi
}

# Cross-platform stat for file size in bytes
get_file_size() {
  local file="$1"
  if is_macos; then
    stat -f%z "$file" 2>/dev/null
  else
    stat -c%s "$file" 2>/dev/null
  fi
}

# Cross-platform IP forwarding check
get_ip_forward_status() {
  if is_macos; then
    sysctl -n net.inet.ip.forwarding 2>/dev/null || echo "0"
  else
    cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo "0"
  fi
}

# Cross-platform IP forwarding enable
enable_ip_forward() {
  if is_macos; then
    sudo sysctl -w net.inet.ip.forwarding=1 >/dev/null 2>&1
  else
    echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null
  fi
}

# Get host IP address (cross-platform)
get_primary_ip() {
  local subnet="${NETWORK_SUBNET:-10.10.10}"
  if is_macos; then
    # macOS: use route to find primary interface, then get its IP
    local iface
    iface=$(route -n get default 2>/dev/null | awk '/interface:/ {print $2}')
    if [[ -n "$iface" ]]; then
      ifconfig "$iface" 2>/dev/null | awk '/inet / && !/127.0.0.1/ {print $2}' | head -1
    else
      # Fallback: try common interfaces
      for iface in en0 en1 en2; do
        local ip
        ip=$(ifconfig "$iface" 2>/dev/null | awk '/inet / {print $2}' | head -1)
        [[ -n "$ip" && ! "$ip" =~ ^127\. && ! "$ip" =~ ^${subnet}\. ]] && echo "$ip" && return
      done
    fi
  else
    # Linux: use ip command
    for interface in eth0 ens3 ens18 enp0s3 wlan0; do
      local ip
      ip=$(ip addr show "$interface" 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1 | head -1)
      [[ -n "$ip" && ! "$ip" =~ ^127\. && ! "$ip" =~ ^${subnet}\. ]] && echo "$ip" && return
    done
    # Fallback
    ip route get 8.8.8.8 2>/dev/null | awk '{print $7; exit}'
  fi
}

# Check if virtualization is supported
check_virt_support() {
  if is_macos; then
    # macOS: check for Hypervisor.framework support
    if [[ "$(uname -m)" == "arm64" ]]; then
      # Apple Silicon always supports virtualization
      return 0
    else
      # Intel Mac: check HVF support
      if sysctl -n kern.hv_support 2>/dev/null | grep -q "1"; then
        return 0
      else
        return 1
      fi
    fi
  else
    # Linux: check for KVM
    if grep -E -q '(vmx|svm)' /proc/cpuinfo 2>/dev/null && [[ -e /dev/kvm ]]; then
      return 0
    else
      return 1
    fi
  fi
}

# Get virtualization type description
get_virt_type_desc() {
  if is_macos; then
    if [[ "$(uname -m)" == "arm64" ]]; then
      echo "Apple Hypervisor (HVF) on Apple Silicon"
    else
      echo "Apple Hypervisor (HVF) on Intel"
    fi
  else
    echo "KVM"
  fi
}

# ============================================================================
# macOS-Specific VM Management Functions
# ============================================================================

# Check if a process is running on macOS
process_is_running() {
  local pid="$1"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

# Get QEMU process PID for a VM on macOS
get_qemu_pid_macos() {
  local vm_name="$1"
  local pid_file="${DATACENTER_BASE:-$HOME/.dcvm}/run/${vm_name}.pid"
  
  if [[ -f "$pid_file" ]]; then
    local pid
    pid=$(cat "$pid_file" 2>/dev/null)
    if [[ -n "$pid" ]] && process_is_running "$pid"; then
      echo "$pid"
      return 0
    fi
  fi
  
  # Fallback: search by process name
  pgrep -f "qemu.*-name.*$vm_name" 2>/dev/null | head -1
}

# Send command to QEMU monitor socket
send_qemu_command() {
  local socket="$1"
  local command="$2"
  
  if [[ -S "$socket" ]]; then
    echo "$command" | nc -U "$socket" 2>/dev/null
    return $?
  fi
  return 1
}

# Gracefully shutdown VM on macOS
shutdown_vm_macos() {
  local vm_name="$1"
  local timeout="${2:-60}"
  local base="${DATACENTER_BASE:-$HOME/.dcvm}"
  local monitor_socket="$base/run/${vm_name}.monitor"
  local pid_file="$base/run/${vm_name}.pid"
  
  # Try graceful shutdown via monitor
  if [[ -S "$monitor_socket" ]]; then
    send_qemu_command "$monitor_socket" "system_powerdown"
    
    # Wait for graceful shutdown
    local count=0
    while [[ $count -lt $timeout ]]; do
      if [[ ! -f "$pid_file" ]] || ! process_is_running "$(cat "$pid_file" 2>/dev/null)"; then
        rm -f "$pid_file" "$monitor_socket" 2>/dev/null
        return 0
      fi
      sleep 2
      count=$((count + 2))
    done
  fi
  
  # Force kill if still running
  if [[ -f "$pid_file" ]]; then
    local pid
    pid=$(cat "$pid_file" 2>/dev/null)
    if [[ -n "$pid" ]] && process_is_running "$pid"; then
      kill "$pid" 2>/dev/null
      sleep 2
      process_is_running "$pid" && kill -9 "$pid" 2>/dev/null
    fi
    rm -f "$pid_file" "$monitor_socket" 2>/dev/null
  fi
  
  return 0
}

# Get VM status on macOS
get_vm_status_macos() {
  local vm_name="$1"
  local base="${DATACENTER_BASE:-$HOME/.dcvm}"
  local pid_file="$base/run/${vm_name}.pid"
  
  if [[ -f "$pid_file" ]]; then
    local pid
    pid=$(cat "$pid_file" 2>/dev/null)
    if [[ -n "$pid" ]] && process_is_running "$pid"; then
      echo "running"
      return 0
    fi
  fi
  
  # Check if VM is registered
  if [[ -f "$base/config/vms/${vm_name}.conf" ]]; then
    echo "stopped"
  else
    echo "not-found"
  fi
}

# List all VMs on macOS
list_vms_macos_all() {
  local base="${DATACENTER_BASE:-$HOME/.dcvm}"
  local registry="$base/config/vms"
  
  [[ ! -d "$registry" ]] && return
  
  for vm_conf in "$registry"/*.conf; do
    [[ -e "$vm_conf" ]] || continue
    [[ -f "$vm_conf" ]] || continue
    local vm_name
    vm_name=$(basename "$vm_conf" .conf)
    local status
    status=$(get_vm_status_macos "$vm_name")
    echo "$vm_name $status"
  done
}

# Get VM configuration value on macOS
get_vm_config_value_macos() {
  local vm_name="$1"
  local key="$2"
  local base="${DATACENTER_BASE:-$HOME/.dcvm}"
  local vm_conf="$base/config/vms/${vm_name}.conf"
  
  if [[ -f "$vm_conf" ]]; then
    grep "^${key}=" "$vm_conf" 2>/dev/null | head -1 | cut -d'=' -f2- | tr -d '"'
  fi
}

# ============================================================================
# Cross-Platform Firewall/NAT Functions
# ============================================================================

# Setup port forwarding (platform-aware)
setup_port_forward() {
  local host_port="$1"
  local dest_ip="$2"
  local dest_port="$3"
  local protocol="${4:-tcp}"
  
  if is_macos; then
    # macOS uses pfctl for packet filtering
    # For QEMU user-mode networking, forwarding is done via hostfwd
    # This function is mainly for documentation/compatibility
    print_info "macOS: Port forwarding is configured via QEMU hostfwd option"
    print_info "  hostfwd=${protocol}::${host_port}-:${dest_port}"
    return 0
  else
    # Linux uses iptables
    iptables -t nat -I PREROUTING -p "$protocol" --dport "$host_port" \
      -j DNAT --to-destination "${dest_ip}:${dest_port}" 2>/dev/null || return 1
    iptables -I FORWARD -p "$protocol" -d "$dest_ip" --dport "$dest_port" \
      -j ACCEPT 2>/dev/null || return 1
  fi
}

# Remove port forwarding rule
remove_port_forward() {
  local host_port="$1"
  local dest_ip="$2"
  local dest_port="$3"
  local protocol="${4:-tcp}"
  
  if is_macos; then
    # macOS: port forwarding is tied to QEMU process
    print_info "macOS: Stop the VM to release port $host_port"
    return 0
  else
    iptables -t nat -D PREROUTING -p "$protocol" --dport "$host_port" \
      -j DNAT --to-destination "${dest_ip}:${dest_port}" 2>/dev/null
    iptables -D FORWARD -p "$protocol" -d "$dest_ip" --dport "$dest_port" \
      -j ACCEPT 2>/dev/null
  fi
}

# Check if port is available
check_port_available() {
  local port="$1"
  if is_macos; then
    ! lsof -i ":$port" >/dev/null 2>&1
  else
    ! ss -tuln 2>/dev/null | grep -q ":$port " && \
    ! netstat -tuln 2>/dev/null | grep -q ":$port "
  fi
}

# Get list of listening ports
get_listening_ports() {
  if is_macos; then
    lsof -iTCP -sTCP:LISTEN -P -n 2>/dev/null | awk 'NR>1 {print $9}' | cut -d: -f2 | sort -u
  else
    ss -tuln 2>/dev/null | awk 'NR>1 {print $5}' | rev | cut -d: -f1 | rev | sort -u
  fi
}

# ============================================================================
# Cross-Platform Disk/Storage Functions  
# ============================================================================

# Get disk usage in human-readable format
get_disk_usage() {
  local path="$1"
  if is_macos; then
    df -h "$path" 2>/dev/null | awk 'NR==2 {print $4}'
  else
    df -h "$path" 2>/dev/null | awk 'NR==2 {print $4}'
  fi
}

# Get directory size
get_dir_size() {
  local path="$1"
  if is_macos; then
    du -sh "$path" 2>/dev/null | cut -f1
  else
    du -sh "$path" 2>/dev/null | cut -f1
  fi
}

# Check if path is on SSD (useful for VM placement)
is_path_on_ssd() {
  local path="$1"
  if is_macos; then
    # macOS: check if APFS/SSD
    diskutil info "$(df "$path" | tail -1 | awk '{print $1}')" 2>/dev/null | grep -qi "solid state\|ssd"
  else
    # Linux: check rotational flag
    local device
    device=$(df "$path" 2>/dev/null | tail -1 | awk '{print $1}' | sed 's/[0-9]*$//')
    device=$(basename "$device")
    [[ -f "/sys/block/$device/queue/rotational" ]] && \
      [[ $(cat "/sys/block/$device/queue/rotational") -eq 0 ]]
  fi
}

# Service management abstraction
service_start() {
  local service="$1"
  if is_macos; then
    # macOS uses launchctl
    case "$service" in
      libvirtd) 
        brew services start libvirt 2>/dev/null || true
        ;;
      nfs*)
        sudo nfsd start 2>/dev/null || true
        ;;
      *)
        brew services start "$service" 2>/dev/null || true
        ;;
    esac
  else
    systemctl start "$service" 2>/dev/null
  fi
}

service_stop() {
  local service="$1"
  if is_macos; then
    case "$service" in
      libvirtd)
        brew services stop libvirt 2>/dev/null || true
        ;;
      nfs*)
        sudo nfsd stop 2>/dev/null || true
        ;;
      *)
        brew services stop "$service" 2>/dev/null || true
        ;;
    esac
  else
    systemctl stop "$service" 2>/dev/null
  fi
}

service_is_active() {
  local service="$1"
  if is_macos; then
    case "$service" in
      libvirtd)
        pgrep -x libvirtd >/dev/null 2>&1
        ;;
      nfs*)
        pgrep -x nfsd >/dev/null 2>&1
        ;;
      *)
        brew services list 2>/dev/null | grep -q "^$service.*started"
        ;;
    esac
  else
    systemctl is-active --quiet "$service" 2>/dev/null
  fi
}

# Get default datacenter base path for the platform
get_default_datacenter_base() {
  if is_macos; then
    echo "$HOME/.dcvm"
  else
    echo "/srv/datacenter"
  fi
}

# Get default config file path
get_default_config_path() {
  if is_macos; then
    echo "$HOME/.config/dcvm/dcvm.conf"
  else
    echo "/etc/dcvm-install.conf"
  fi
}

# Export platform detection functions
export -f detect_os is_macos is_linux
export -f get_qemu_accel get_qemu_binary get_template_arch
export -f sed_inplace timeout_cmd get_nproc get_total_memory_kb readlink_f get_file_size
export -f get_ip_forward_status enable_ip_forward get_primary_ip
export -f check_virt_support get_virt_type_desc
export -f service_start service_stop service_is_active
export -f get_default_datacenter_base get_default_config_path

# ============================================================================
# End of Platform Abstraction Layer
# ============================================================================

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
log_message() { log "INFO" "$1"; }
log_to_file() {
  local log_file="${1:-/var/log/dcvm.log}"
  local message="$2"
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $message" >>"$log_file"
}

load_dcvm_config() {
  local config_file="${1:-$(get_default_config_path)}"

  if [ ! -f "$config_file" ]; then
    print_error "Configuration file not found: $config_file"
    print_info "Please run the DCVM installer first"
    exit 1
  fi

  source "$config_file"

  DATACENTER_BASE="${DATACENTER_BASE:-$(get_default_datacenter_base)}"
  NETWORK_NAME="${NETWORK_NAME:-datacenter-net}"
  BRIDGE_NAME="${BRIDGE_NAME:-virbr-dc}"
  NETWORK_SUBNET="${NETWORK_SUBNET:-10.10.10}"

  if [[ "$NETWORK_SUBNET" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
    local oct1="${BASH_REMATCH[1]}"
    local oct2="${BASH_REMATCH[2]}"
    local oct3="${BASH_REMATCH[3]}"
    if [ "$oct1" -gt 255 ] || [ "$oct2" -gt 255 ] || [ "$oct3" -gt 255 ]; then
      echo "WARNING: Invalid NETWORK_SUBNET octets ($NETWORK_SUBNET), using default 10.10.10" >&2
      NETWORK_SUBNET="10.10.10"
    fi
  else
    echo "WARNING: Invalid NETWORK_SUBNET format ($NETWORK_SUBNET), using default 10.10.10" >&2
    NETWORK_SUBNET="10.10.10"
  fi
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

get_vm_state() {
  local vm_name="$1"
  virsh domstate "$vm_name" 2>/dev/null || echo "not-found"
}

get_vm_ip() {
  local vm_name="$1"
  local attempts="${2:-1}"
  local ip=""
  local count=0
  local subnet="${NETWORK_SUBNET:-10.10.10}"

  while [ -z "$ip" ] && [ $count -lt $attempts ]; do
    ip=$(virsh domifaddr "$vm_name" --source agent 2>/dev/null | awk '/ipv4/ {print $4}' | cut -d'/' -f1 | grep "^${subnet}\." | head -1)
    if [ -z "$ip" ]; then
      ip=$(virsh domifaddr "$vm_name" --source lease 2>/dev/null | awk '/ipv4/ {print $4}' | cut -d'/' -f1 | grep "^${subnet}\." | head -1)
    fi
    if [ -z "$ip" ]; then
      local network_name="${NETWORK_NAME:-datacenter-net}"
      ip=$(virsh net-dhcp-leases "$network_name" 2>/dev/null | grep "$vm_name" | awk '{print $5}' | cut -d'/' -f1 | grep "^${subnet}\." | head -1)
    fi
    if [ -z "$ip" ]; then
      local mac=$(virsh domiflist "$vm_name" 2>/dev/null | grep "${NETWORK_NAME:-datacenter-net}" | awk '{print $5}')
      if [ -n "$mac" ]; then
        ip=$(virsh net-dhcp-leases "${NETWORK_NAME:-datacenter-net}" 2>/dev/null | grep "$mac" | awk '{print $5}' | cut -d'/' -f1 | grep "^${subnet}\." | head -1)
      fi
    fi
    if [ -z "$ip" ] && [ $attempts -gt 1 ]; then
      sleep 2
    fi
    count=$((count + 1))
  done

  if [ -z "$ip" ]; then
    local static_conf="${DATACENTER_BASE:-/srv/datacenter}/config/network/${vm_name}.conf"
    if [ -f "$static_conf" ]; then
      ip=$(grep '^IP=' "$static_conf" | head -1 | cut -d'=' -f2- | sed 's/^"//;s/"$//')
    fi
  fi

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
  printf "52:54:00:%02x:%02x:%02x\n" $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256))
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
  if is_macos; then
    echo "  OS: macOS $(sw_vers -productVersion 2>/dev/null || echo 'Unknown')"
  else
    echo "  OS: $(lsb_release -d 2>/dev/null | cut -f2 || cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'"' -f2 || echo 'Unknown')"
  fi
  echo "  Kernel: $(uname -r)"
  echo "  CPUs: $(get_nproc)"
  local mem_kb
  mem_kb=$(get_total_memory_kb)
  local mem_gb=$((mem_kb / 1024 / 1024))
  echo "  Memory: ${mem_gb}G"
  if is_macos; then
    echo "  Disk: $(df -h / | awk 'NR==2 {print $4 " available"}')"
  else
    echo "  Disk: $(df -h / | awk 'NR==2 {print $4 " available"}')"
  fi
  echo "  Virtualization: $(get_virt_type_desc)"
}

get_host_info() {
  local host_mem_kb
  host_mem_kb=$(get_total_memory_kb)
  HOST_MEMORY_KB=$host_mem_kb
  HOST_MEMORY_MB=$((host_mem_kb / 1024))
  HOST_CPUS=$(get_nproc)
  
  if is_macos; then
    HOST_CPU_MODEL=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "Apple Silicon")
  else
    HOST_CPU_MODEL=$(grep "model name" /proc/cpuinfo | head -1 | cut -d: -f2 | sed 's/^ *//')
  fi
  
  MAX_VM_MEMORY=$((HOST_MEMORY_MB * 75 / 100))
  MAX_VM_CPUS=$((HOST_CPUS - 1))
  if [ $MAX_VM_CPUS -lt 1 ]; then
    MAX_VM_CPUS=1
  fi
}

check_port_connectivity() {
  local ip="$1"
  local port="$2"
  timeout_cmd 3 bash -c "</dev/tcp/$ip/$port" 2>/dev/null
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
  if is_macos; then
    local base="${DATACENTER_BASE:-$(get_default_datacenter_base)}"
    [[ -f "$base/config/vms/${vm_name}.conf" ]] || [[ -d "$base/vms/${vm_name}" ]]
    return $?
  fi
  virsh list --all 2>/dev/null | grep -q " $vm_name "
}

vm_exists() { check_vm_exists "$@"; }

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
  local config_file="${1:-$(get_default_config_path)}"
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

reload_dnsmasq() {
  local bridge="${BRIDGE_NAME:-virbr-dc}"
  local dnsmasq_pid=$(ps aux | grep "dnsmasq.*${bridge}" | grep -v grep | awk '{print $2}' | head -1)
  if [ -n "$dnsmasq_pid" ]; then
    kill -HUP "$dnsmasq_pid" 2>/dev/null && return 0 || return 1
  fi
  return 1
}

interactive_prompt_memory_common() {
  local var_name="${1:-VM_MEMORY}"
  local host_mem_kb
  host_mem_kb=$(get_total_memory_kb)
  local host_mem=$((host_mem_kb / 1024))
  local max_mem=$((host_mem * 75 / 100))
  local result=""

  while true; do
    read -p "Memory in MB (available: ${host_mem}MB, recommended max: ${max_mem}MB) [2048]: " result
    result=${result:-2048}
    if [[ ! "$result" =~ ^[0-9]+$ ]]; then
      print_error "Memory must be a number"
      continue
    fi
    if [ "$result" -lt 512 ]; then
      print_error "Memory must be at least 512MB"
      continue
    fi
    if [ "$result" -gt "$max_mem" ]; then
      print_warning "Requested ${result}MB exceeds recommended ${max_mem}MB"
      read -p "Continue anyway? (y/N): " cont
      [[ ! "$cont" =~ ^[Yy]$ ]] && continue
    fi
    break
  done
  printf -v "$var_name" '%s' "$result"
}

interactive_prompt_cpus_common() {
  local var_name="${1:-VM_CPUS}"
  local host_cpus
  host_cpus=$(get_nproc)
  local max_cpus=$((host_cpus > 1 ? host_cpus - 1 : 1))
  local result=""

  while true; do
    read -p "Number of CPUs (available: ${host_cpus}, recommended max: ${max_cpus}) [2]: " result
    result=${result:-2}
    if [[ ! "$result" =~ ^[0-9]+$ ]]; then
      print_error "CPU count must be a number"
      continue
    fi
    if [ "$result" -lt 1 ]; then
      print_error "CPU count must be at least 1"
      continue
    fi
    if [ "$result" -gt "$max_cpus" ]; then
      print_warning "Requested ${result} CPUs exceeds recommended ${max_cpus}"
      read -p "Continue anyway? (y/N): " cont
      [[ ! "$cont" =~ ^[Yy]$ ]] && continue
    fi
    break
  done
  printf -v "$var_name" '%s' "$result"
}

interactive_prompt_disk_common() {
  local var_name="${1:-VM_DISK_SIZE}"
  local result=""

  while true; do
    read -p "Disk size (formats: 20G, 512M, 1T) [20G]: " result
    result=${result:-20G}
    result=${result^^}
    if [[ ! "$result" =~ ^[0-9]+[GMT]$ ]]; then
      print_error "Invalid format. Use number + G/M/T (e.g., 20G, 512M, 1T)"
      continue
    fi
    local size_num=$(echo "$result" | sed 's/[GMT]$//')
    local size_unit=$(echo "$result" | sed 's/^[0-9]*//')
    case "$size_unit" in
    "M") [ "$size_num" -lt 100 ] && {
      print_error "Minimum disk size is 100M"
      continue
    } ;;
    "G") [ "$size_num" -lt 1 ] || [ "$size_num" -gt 1000 ] && {
      print_error "Disk size must be between 1G and 1000G"
      continue
    } ;;
    "T") [ "$size_num" -gt 10 ] && {
      print_error "Maximum disk size is 10T"
      continue
    } ;;
    esac
    break
  done
  printf -v "$var_name" '%s' "$result"
}

detect_host_ip() {
  local host_ip=""
  host_ip=$(get_primary_ip)
  [ -z "$host_ip" ] && host_ip="YOUR_HOST_IP"
  echo "$host_ip"
}

get_fix_lock_script_path() {
  local script_dir="${1:-}"
  if [ -n "$script_dir" ] && [ -f "$script_dir/../utils/fix-lock.sh" ]; then
    echo "$script_dir/../utils/fix-lock.sh"
  elif [ -f "/usr/local/lib/dcvm/utils/fix-lock.sh" ]; then
    echo "/usr/local/lib/dcvm/utils/fix-lock.sh"
  else
    echo ""
  fi
}

validate_ip_in_subnet() {
  local ip="$1"
  local subnet="${NETWORK_SUBNET:-10.10.10}"

  if [[ ! "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
    print_error "Invalid IP address format: $ip"
    return 1
  fi

  local oct1="${BASH_REMATCH[1]}"
  local oct2="${BASH_REMATCH[2]}"
  local oct3="${BASH_REMATCH[3]}"
  local oct4="${BASH_REMATCH[4]}"

  if [ "$oct1" -gt 255 ] || [ "$oct2" -gt 255 ] || [ "$oct3" -gt 255 ] || [ "$oct4" -gt 255 ]; then
    print_error "Invalid IP address: octets must be 0-255"
    return 1
  fi

  if [[ ! "$ip" =~ ^${subnet}\. ]]; then
    print_error "IP address $ip is not in subnet ${subnet}.0/24"
    print_info "Valid range: ${subnet}.2 - ${subnet}.254"
    return 1
  fi

  if [ "$oct4" -lt 2 ] || [ "$oct4" -gt 254 ]; then
    print_error "Last octet must be between 2-254 (1 is gateway, 255 is broadcast)"
    return 1
  fi

  return 0
}

interactive_prompt_static_ip_common() {
  local var_name="${1:-STATIC_IP}"
  local subnet="${NETWORK_SUBNET:-10.10.10}"
  local result=""

  echo ""
  print_info "Static IP Configuration..."
  echo "  Network subnet: ${subnet}.0/24"
  echo "  Gateway: ${subnet}.1"
  echo "  Valid range: ${subnet}.2 - ${subnet}.254"
  echo ""

  while true; do
    read -p "Use static IP? (y/N, default: DHCP): " use_static
    use_static=${use_static:-n}

    if [[ "$use_static" =~ ^[Nn]$ ]]; then
      result=""
      print_success "Using DHCP for automatic IP assignment"
      break
    elif [[ "$use_static" =~ ^[Yy]$ ]]; then
      while true; do
        read -p "Enter static IP (e.g., ${subnet}.50): " result
        if [ -z "$result" ]; then
          print_error "IP address cannot be empty"
          continue
        fi
        if validate_ip_in_subnet "$result"; then
          print_success "Static IP set to: $result"
          break 2
        fi
      done
    else
      print_error "Please enter 'y' for static IP or 'n' for DHCP"
    fi
  done
  printf -v "$var_name" '%s' "$result"
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
export -f reload_dnsmasq detect_host_ip get_fix_lock_script_path
export -f validate_ip_in_subnet interactive_prompt_static_ip_common
export -f interactive_prompt_memory_common interactive_prompt_cpus_common interactive_prompt_disk_common
