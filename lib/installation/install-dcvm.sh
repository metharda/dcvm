#!/usr/bin/env bash
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

cleanup_tmp_dir() {
  if [[ -n "$TMP_WORKDIR" && -d "$TMP_WORKDIR" ]]; then
    rm -rf "$TMP_WORKDIR" 2>/dev/null || true
  fi
}

clone_repo_source() {
  if ! command -v git >/dev/null 2>&1; then
    print_status_log "WARNING" "git is not available for repository cloning"
    return 1
  fi

  TMP_WORKDIR=$(mktemp -d)
  trap cleanup_tmp_dir EXIT

  local repo_url="https://github.com/${DCVM_REPO_SLUG}.git"
  print_status_log "INFO" "Cloning repository from $repo_url"

  if git clone --depth 1 --branch "$DCVM_REPO_BRANCH" "$repo_url" "$TMP_WORKDIR/dcvm" 2>>"$LOG_FILE"; then
    SOURCE_DIR="$TMP_WORKDIR/dcvm"
    return 0
  else
    print_status_log "ERROR" "Failed to clone repository"
    return 1
  fi
}

ensure_source_dir() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local repo_root
  repo_root="$(cd "$script_dir/../.." && pwd)"

  if [[ -f "$repo_root/dcvm" && -d "$repo_root/lib" ]]; then
    SOURCE_DIR="$repo_root"
    return 0
  fi

  SOURCE_DIR=""
  return 1
}

fetch_file() {
  local rel_path="$1"
  local dest_path="$2"
  local base_url="https://raw.githubusercontent.com/${DCVM_REPO_SLUG}/${DCVM_REPO_BRANCH}"

  mkdir -p "$(dirname "$dest_path")" 2>/dev/null || true

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$dest_path" "$base_url/$rel_path" 2>>"$LOG_FILE"
  else
    wget -q -O "$dest_path" "$base_url/$rel_path" 2>>"$LOG_FILE"
  fi
}

discover_repo_files() {
  local api_url="https://api.github.com/repos/${DCVM_REPO_SLUG}/git/trees/${DCVM_REPO_BRANCH}?recursive=1"
  local response

  if command -v curl >/dev/null 2>&1; then
    response=$(curl -fsSL -H "Accept: application/vnd.github.v3+json" "$api_url" 2>>"$LOG_FILE")
  elif command -v wget >/dev/null 2>&1; then
    response=$(wget -q -O - --header="Accept: application/vnd.github.v3+json" "$api_url" 2>>"$LOG_FILE")
  else
    print_status_log "ERROR" "Neither curl nor wget is available"
    return 1
  fi

  local has_error
  if [[ -z "$response" ]]; then
    has_error=1
  else
    if command -v python3 >/dev/null 2>&1; then
      has_error=$(echo "$response" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(1 if 'message' in data else 0)
except Exception:
    print(1)
")
    else
      if [[ "$response" == *'"message"'* ]]; then
        has_error=1
      else
        has_error=0
      fi
    fi
  fi
  if [[ "$has_error" -eq 1 ]]; then
    print_status_log "WARNING" "GitHub API request failed or rate limited"
    echo "$response" >>"$LOG_FILE" 2>/dev/null
    return 1
  fi

  local files
  if command -v python3 >/dev/null 2>&1; then
    files=$(echo "$response" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    if 'tree' in data:
        for item in data['tree']:
            path = item.get('path', '')
            if path == 'dcvm' or (path.startswith('lib/') and path.endswith('.sh')):
                print(path)
except:
    pass
" 2>/dev/null)
  elif command -v jq >/dev/null 2>&1; then
    files=$(echo "$response" | jq -r '.tree[]? | select(.path == "dcvm" or (.path | startswith("lib/") and endswith(".sh"))) | .path' 2>/dev/null)
  else
    print_status_log "WARNING" "Using basic JSON parsing; install python3 or jq for better reliability"
    files=$(echo "$response" | grep -o '"path":"[^"]*"' | sed 's/"path":"//;s/"$//' | grep -E '^(dcvm$|lib/.+\.sh$)')
  fi
  if [[ -z "$files" ]]; then
    return 1
  fi
  echo "$files"
}

install_by_fetch() {
  local install_bin="$1"
  local install_lib="$2"

  if ensure_source_dir; then
    print_status_log "INFO" "Using local repository at: $SOURCE_DIR"

    if [[ -f "$SOURCE_DIR/dcvm" ]]; then
      if ! cp "$SOURCE_DIR/dcvm" "$install_bin/dcvm"; then
        print_status_log "ERROR" "Failed to copy dcvm from local repository"
        return 1
      fi
      chmod +x "$install_bin/dcvm"
      print_status_log "SUCCESS" "Copied dcvm from local repository"
    fi

    if [[ -d "$SOURCE_DIR/lib" ]]; then
      if ! cp -r "$SOURCE_DIR/lib/"* "$install_lib/"; then
        print_status_log "ERROR" "Failed to copy libraries from local repository"
        return 1
      fi
      find "$install_lib" -type f -name "*.sh" -exec chmod +x {} \;
      print_status_log "SUCCESS" "Copied all libraries from local repository"
    fi

    return 0
  fi

  print_status_log "INFO" "Discovering repository files from ${DCVM_REPO_SLUG}@${DCVM_REPO_BRANCH}"

  local discovered_files
  discovered_files=$(discover_repo_files)

  if [[ -z "$discovered_files" ]]; then
    print_status_log "WARNING" "Could not discover files via GitHub API"
    print_status_log "INFO" "Attempting to clone repository instead..."

    if clone_repo_source; then
      print_status_log "INFO" "Repository cloned successfully, using local files"
      if [[ -f "$SOURCE_DIR/dcvm" ]]; then
        cp "$SOURCE_DIR/dcvm" "$install_bin/dcvm" && chmod +x "$install_bin/dcvm"
        print_status_log "SUCCESS" "Copied dcvm from cloned repository"
      fi

      if [[ -d "$SOURCE_DIR/lib" ]]; then
        cp -r "$SOURCE_DIR/lib/"* "$install_lib/"
        find "$install_lib" -type f -name "*.sh" -exec chmod +x {} \;
        print_status_log "SUCCESS" "Copied all libraries from cloned repository"
      fi
      return 0
    else
      print_status_log "ERROR" "Failed to discover files and clone repository failed"
      print_status_log "ERROR" "Please ensure git is installed or check network connectivity"
      return 1
    fi
  fi

  local file_count=$(echo "$discovered_files" | grep -c '^.')
  print_status_log "INFO" "Found $file_count files to fetch"

  local ok=true
  local fetched_count=0

  while IFS= read -r file_path; do
    [[ -z "$file_path" ]] && continue

    if [[ "$file_path" == bin/* ]]; then
      local dest="$install_bin/$(basename "$file_path")"
      if fetch_file "$file_path" "$dest"; then
        chmod +x "$dest" 2>/dev/null || true
        print_status_log "SUCCESS" "Fetched $(basename "$file_path")"
        ((fetched_count++))
      else
        print_status_log "ERROR" "Failed to fetch $file_path"
        ok=false
      fi
    elif [[ "$file_path" == lib/* ]]; then
      local rel_no_lib="${file_path#lib/}"
      local dest="$install_lib/$rel_no_lib"
      if fetch_file "$file_path" "$dest"; then
        [[ "$dest" == *.sh ]] && chmod +x "$dest" 2>/dev/null || true
        print_status_log "SUCCESS" "Fetched $rel_no_lib"
        ((fetched_count++))
      else
        print_status_log "ERROR" "Failed to fetch $file_path"
        ok=false
      fi
    fi
  done <<<"$discovered_files"

  print_status_log "INFO" "Successfully fetched $fetched_count/$file_count files"

  $ok || {
    print_status_log "ERROR" "Some files failed to download. Please check network/branch and try again."
    return 1
  }

  return 0
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
    [Yy] | [Yy][Ee][Ss]) return 0 ;;
    [Nn] | [Nn][Oo]) return 1 ;;
    *) print_status_log "ERROR" "Please answer y or n" ;;
    esac
  done
}

install_required_packages() {
  print_status "INFO" "Checking and installing required packages..."

  local debian_packages=(qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils virtinst wget curl nfs-kernel-server uuid-runtime genisoimage bc guestfish)
  local arch_packages=(qemu-full libvirt bridge-utils virt-install wget curl nfs-utils cdrtools dnsmasq ebtables iptables dmidecode bc util-linux guestfish)

  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    if [[ "$ID" == "debian" || "$ID" == "ubuntu" ]]; then
      command -v apt >/dev/null 2>&1 || {
        print_status "ERROR" "apt not found. Cannot install packages."
        exit 1
      }
      print_status "INFO" "Detected Debian/Ubuntu. Installing packages with apt..."
      export DEBIAN_FRONTEND=noninteractive
      apt update -y && apt install -y "${debian_packages[@]}"
    elif [[ "$ID" == "arch" ]]; then
      command -v pacman >/dev/null 2>&1 || {
        print_status "ERROR" "pacman not found. Cannot install packages."
        exit 1
      }
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
    systemctl is-active --quiet libvirtd && print_status "SUCCESS" "libvirtd is running" || {
      print_status "ERROR" "Failed to start libvirtd"
      exit 1
    }
  fi
}

start_datacenter_network() {
  print_status "INFO" "Checking datacenter network..."

  virsh net-list --all | grep -q "$NETWORK_NAME" || {
    print_status "ERROR" "Network '$NETWORK_NAME' not found. Please run the setup script first."
    exit 1
  }

  if ! virsh net-list | grep -q "$NETWORK_NAME.*active"; then
    print_status_log "INFO" "Starting network '$NETWORK_NAME'..."
    virsh net-start "$NETWORK_NAME"
  fi

  virsh net-list | grep -q "$NETWORK_NAME.*active" && print_status_log "SUCCESS" "Network '$NETWORK_NAME' is active" || {
    print_status_log "ERROR" "Failed to start network '$NETWORK_NAME'"
    exit 1
  }

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
    mkdir -p "$NFS_EXPORT_PATH" 2>/dev/null || {
      print_status_log "ERROR" "Failed to create NFS export path"
      return 1
    }
    chmod 755 "$NFS_EXPORT_PATH" 2>/dev/null || print_status_log "WARNING" "Could not set permissions on NFS export path"
  fi

  if ! systemctl list-unit-files 2>/dev/null | grep -q -E 'nfs-kernel-server|nfs-server'; then
    print_status_log "WARNING" "NFS server is not installed"
    print_status_log "INFO" "Install with: apt install nfs-kernel-server (Debian/Ubuntu) or pacman -S nfs-utils (Arch)"
    return 0
  fi

  if ! systemctl is-active --quiet nfs-kernel-server 2>/dev/null && ! systemctl is-active --quiet nfs-server 2>/dev/null; then
    print_status_log "INFO" "Starting NFS server..."
    systemctl start nfs-kernel-server 2>/dev/null || systemctl start nfs-server 2>/dev/null || {
      print_status_log "WARNING" "Could not start NFS server"
      return 0
    }
    sleep 2
  fi

  if systemctl is-active --quiet nfs-kernel-server 2>/dev/null || systemctl is-active --quiet nfs-server 2>/dev/null; then
    print_status_log "SUCCESS" "NFS server is running"

    if ! grep -q "$NFS_EXPORT_PATH" /etc/exports 2>/dev/null; then
      echo "$NFS_EXPORT_PATH *(rw,sync,no_subtree_check,no_root_squash)" >>/etc/exports 2>/dev/null || {
        print_status_log "WARNING" "Could not update /etc/exports"
        return 0
      }
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
    "$DATACENTER_BASE/config"
    "$DATACENTER_BASE/config/network"
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

source_mirror_manager() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local repo_mirror="$script_dir/../utils/mirror-manager.sh"
  local installed_mirror="/usr/local/lib/dcvm/utils/mirror-manager.sh"
  local loaded_from=""

  if [[ -f "$repo_mirror" ]]; then
    loaded_from="$repo_mirror"
  elif [[ -f "$installed_mirror" ]]; then
    loaded_from="$installed_mirror"
  elif [[ -n "$SOURCE_DIR" && -f "$SOURCE_DIR/lib/utils/mirror-manager.sh" ]]; then
    loaded_from="$SOURCE_DIR/lib/utils/mirror-manager.sh"
  else
    return 1
  fi

  source "$loaded_from"
  print_status_log "INFO" "Using mirror-manager: $loaded_from"

  if ! declare -F get_mirrors >/dev/null 2>&1; then
    print_status_log "ERROR" "mirror-manager loaded but get_mirrors() is missing"
    return 1
  fi
  if ! get_mirrors "debian-12-generic-amd64.qcow2" >/dev/null 2>&1; then
    print_status_log "ERROR" "mirror-manager loaded but MIRRORS are not accessible (get_mirrors failed)"
    return 1
  fi

  return 0
}

declare -A IMAGE_LABELS
IMAGE_LABELS["debian-12-generic-amd64.qcow2"]="Debian 12"
IMAGE_LABELS["debian-11-generic-amd64.qcow2"]="Debian 11"
IMAGE_LABELS["ubuntu-22.04-server-cloudimg-amd64.img"]="Ubuntu 22.04"
IMAGE_LABELS["ubuntu-20.04-server-cloudimg-amd64.img"]="Ubuntu 20.04"
IMAGE_LABELS["Arch-Linux-x86_64-cloudimg.qcow2"]="Arch Linux"

IMAGE_ORDER=(
  "debian-11-generic-amd64.qcow2"
  "debian-12-generic-amd64.qcow2"
  "ubuntu-20.04-server-cloudimg-amd64.img"
  "ubuntu-22.04-server-cloudimg-amd64.img"
  "Arch-Linux-x86_64-cloudimg.qcow2"
)

check_cloud_images() {
  print_status_log "INFO" "Checking for cloud images..."

  if ! source_mirror_manager; then
    print_status_log "WARNING" "mirror-manager.sh not found, cloud images will be downloaded when creating VMs"
    return 0
  fi

  local images=()
  for filename in "${IMAGE_ORDER[@]}"; do
    local label="${IMAGE_LABELS[$filename]:-Unknown}"
    images+=("$filename|$label")
  done

  local missing_images=()

  for entry in "${images[@]}"; do
    IFS='|' read -r filename label <<<"$entry"
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
            IFS='|' read -r filename label <<<"$entry"
            local image_path="$DATACENTER_BASE/storage/templates/$filename"
            print_status_log "INFO" "Downloading $label cloud image..."
            if download_with_mirrors "$filename" "$image_path" 104857600; then
              print_status_log "SUCCESS" "$label cloud image downloaded successfully"
            else
              print_status_log "WARNING" "Failed to download $label - will attempt later when creating VM"
            fi
            echo ""
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
  local subnet="${NETWORK_SUBNET:-10.10.10}"
  local ip_addr="${subnet}.1"
  local netmask="255.255.255.0"
  local dhcp_start="${subnet}.10"
  local dhcp_end="${subnet}.200"

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
    echo 1 >/proc/sys/net/ipv4/ip_forward 2>/dev/null || {
      print_status_log "WARNING" "Could not enable IP forwarding"
      return 0
    }

    if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null; then
      echo "net.ipv4.ip_forward=1" >>/etc/sysctl.conf 2>/dev/null || print_status_log "WARNING" "Could not persist IP forwarding setting"
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
  done <<<"$vm_list"

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
    if prompt_yes_no "Enable dcvm tab-completion in your shell now? [Y/n]: " "Y"; then
      local shell_info
      shell_info=$(detect_shell)
      local shell_name="${shell_info%%|*}"
      local config_file="${shell_info##*|}"
      [[ "$config_file" == ~* ]] && config_file="${config_file/#~/$HOME}"

      if [[ "$shell_name" == "bash" ]]; then
        if [[ -d "/etc/bash_completion.d" && -w "/etc/bash_completion.d" ]]; then
          cp "$completion_dst" "/etc/bash_completion.d/dcvm" 2>/dev/null && print_status_log "SUCCESS" "Bash completion installed: /etc/bash_completion.d/dcvm" || print_status_log "WARNING" "Could not write to /etc/bash_completion.d"
        else
          grep -q "$completion_dst" "$config_file" 2>/dev/null || echo "source $completion_dst" >>"$config_file"
          print_status_log "SUCCESS" "Added 'source $completion_dst' to $config_file"
        fi
      else
        grep -q "$completion_dst" "$config_file" 2>/dev/null || echo "source $completion_dst" >>"$config_file"
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

  cat >/etc/systemd/system/datacenter-storage.service 2>/dev/null <<EOF || {
[Unit]
Description=Datacenter Storage Management
After=libvirtd.service
Requires=libvirtd.service

[Service]
Type=oneshot
User=root
ExecStart=/usr/local/bin/dcvm storage-cleanup
EOF
    print_status_log "WARNING" "Could not create systemd service"
    return 0
  }

  cat >/etc/systemd/system/datacenter-storage.timer 2>/dev/null <<'EOF' || {
[Unit]
Description=Run datacenter storage management hourly
Requires=datacenter-storage.service

[Timer]
OnCalendar=hourly
Persistent=true

[Install]
WantedBy=timers.target
EOF
    print_status_log "WARNING" "Could not create systemd timer"
    return 0
  }

  systemctl daemon-reload 2>/dev/null || {
    print_status_log "WARNING" "Could not reload systemd"
    return 0
  }
  systemctl enable datacenter-storage.timer 2>/dev/null || print_status_log "WARNING" "Could not enable timer"
  systemctl start datacenter-storage.timer 2>/dev/null || print_status_log "WARNING" "Could not start timer"

  print_status_log "SUCCESS" "Datacenter storage service configured"
}

install_dcvm_command() {
  print_status_log "INFO" "Installing DCVM command and libraries..."

  local install_bin="/usr/local/bin"
  local install_lib="/usr/local/lib/dcvm"

  mkdir -p "$install_bin" "$install_lib"

  if ! install_by_fetch "$install_bin" "$install_lib"; then
    print_status_log "ERROR" "Failed to install DCVM files"
    exit 1
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
  echo "$(date) - Installation started" >>"$LOG_FILE" 2>/dev/null || true

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
  start_libvirtd
  check_directory_structure
  check_cloud_images
  enable_ip_forwarding
  create_datacenter_network
  install_completion
  start_nfs_server
  start_existing_vms
  setup_aliases
  setup_service
  show_vm_status
  show_network_info
  show_datacenter_summary
}

dcvm_init() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Welcome to DCVM Installer!"
    echo "Repository: ${DCVM_REPO_SLUG}"
    echo "Branch: ${DCVM_REPO_BRANCH}"
    echo ""

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

      echo ""
      echo "Network IP Configuration (default: 10.10.10.0/24)"
      echo "This determines the IP range for your VMs."
      read -p "Network subnet (e.g., 10.10.10, 192.168.100) [default: 10.10.10]: " USER_SUBNET || USER_SUBNET=""
      NETWORK_SUBNET=${USER_SUBNET:-10.10.10}

      if [[ ! "$NETWORK_SUBNET" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        echo "Invalid subnet format. Using default: 10.10.10"
        NETWORK_SUBNET="10.10.10"
      else
        oct1="${BASH_REMATCH[1]}"
        oct2="${BASH_REMATCH[2]}"
        oct3="${BASH_REMATCH[3]}"

        if [ "$oct1" -gt 255 ] || [ "$oct2" -gt 255 ] || [ "$oct3" -gt 255 ]; then
          echo "Invalid subnet: octets must be 0-255. Using default: 10.10.10"
          NETWORK_SUBNET="10.10.10"
        fi
      fi
    else
      echo "Non-interactive installation detected. Using default values."
      DATACENTER_BASE="$DEFAULT_DATACENTER_BASE"
      NETWORK_SUBNET="10.10.10"
    fi

    echo "DATACENTER_BASE=\"$DATACENTER_BASE\"" >"$CONFIG_FILE"
    echo "NETWORK_NAME=\"$NETWORK_NAME\"" >>"$CONFIG_FILE"
    echo "BRIDGE_NAME=\"$BRIDGE_NAME\"" >>"$CONFIG_FILE"
    echo "NETWORK_SUBNET=\"$NETWORK_SUBNET\"" >>"$CONFIG_FILE"
    echo "Installation directory set to: $DATACENTER_BASE"
    echo "Network name set to: $NETWORK_NAME"
    echo "Bridge name set to: $BRIDGE_NAME"
    echo "Network subnet set to: $NETWORK_SUBNET.0/24"
  else
    source "$CONFIG_FILE"
    echo "Using existing configuration:"
    echo "  Installation directory: $DATACENTER_BASE"
    echo "  Network name: $NETWORK_NAME"
    echo "  Bridge name: $BRIDGE_NAME"
  fi

  NFS_EXPORT_PATH="$DATACENTER_BASE/nfs-share"

  for arg in "$@"; do
    case $arg in
    --network-only) NETWORK_ONLY=1 ;;
    --network-name=*) NETWORK_NAME_ARG="${arg#*=}" ;;
    --network-name)
      [[ -n "${2:-}" ]] && NETWORK_NAME_ARG="$2" || {
        echo "Error: --network-name requires a value" >&2
        exit 1
      }
      ;;
    esac
  done

  echo "Executing DCVM installer..." >&2
  main "$@"
}

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]] || [[ -z "${BASH_SOURCE[0]:-}" ]]; then
  dcvm_init "$@"
fi
