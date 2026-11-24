#!/usr/bin/env bash
set -euo pipefail

DCVM_REPO_SLUG="${DCVM_REPO_SLUG:-metharda/dcvm}"
DCVM_REPO_BRANCH="${DCVM_REPO_BRANCH:-main}"

# Root runs and installs the checkout this script sits in, so it is used only
# when no other user can write to it; anything else (the one-liner, a
# downloaded copy in /tmp) installs from the repository.
checkout_root() {
  local real root d owner mode bad uid=0
  [[ "${SUDO_UID:-}" =~ ^[0-9]+$ ]] && uid=$SUDO_UID
  [ -f "${1:-}" ] || return 1
  real=$(readlink -f -- "$1") || return 1
  [[ "$real" == */lib/installation/install-dcvm.sh ]] || return 1
  root=${real%/lib/installation/install-dcvm.sh}
  [ -f "$root/dcvm" ] || return 1
  bad=$(find "$root/dcvm" "$root/lib" \( ! -uid 0 ! -uid "$uid" -o -perm /022 \) -print -quit 2>/dev/null) || bad=x
  d=$root
  while [ -z "$bad" ]; do
    read -r owner mode <<<"$(stat -c '%u %a' -- "${d:-/}" 2>/dev/null)"
    { [ "$owner" = 0 ] || [ "$owner" = "$uid" ]; } && [[ "$mode" =~ ^[0-7]+$ ]] && (((8#$mode & 8#022) == 0)) || bad=${d:-/}
    [ -n "$d" ] || break
    d=${d%/*}
  done
  if [ -n "$bad" ]; then
    echo "warning: not using the checkout in ${root:-/}: other users can write to it (${bad}); installing from $DCVM_REPO_SLUG@$DCVM_REPO_BRANCH" >&2
    return 1
  fi
  echo "${root:-/}"
}
DCVM_CHECKOUT=$(checkout_root "${BASH_SOURCE[0]:-}") || DCVM_CHECKOUT=""

# The output helpers are lib/utils/common.sh: from the checkout, or fetched
# from the commit the branch points to now, like the rest of dcvm.
load_common() {
  local tmp url api="https://api.github.com/repos/$DCVM_REPO_SLUG/commits/$DCVM_REPO_BRANCH"
  if [ -n "$DCVM_CHECKOUT" ] && [ -f "$DCVM_CHECKOUT/lib/utils/common.sh" ]; then
    source "$DCVM_CHECKOUT/lib/utils/common.sh"
    return
  fi
  DCVM_REPO_REF=$({ curl -fsSL -H "Accept: application/vnd.github.sha" "$api" || wget -q -O - --header="Accept: application/vnd.github.sha" "$api"; } 2>/dev/null) || true
  [[ "$DCVM_REPO_REF" =~ ^[0-9a-f]{40}$ ]] || DCVM_REPO_REF=$DCVM_REPO_BRANCH
  url="https://raw.githubusercontent.com/$DCVM_REPO_SLUG/$DCVM_REPO_REF/lib/utils/common.sh"
  tmp=$(mktemp)
  if ! { curl -fsSL -o "$tmp" "$url" 2>/dev/null || wget -q -O "$tmp" "$url" 2>/dev/null; }; then
    rm -f "$tmp"
    echo "error: could not download $url; check the network connection" >&2
    exit 1
  fi
  source "$tmp"
  rm -f "$tmp"
}
load_common

DEFAULT_DATACENTER_BASE="/srv/datacenter"
CONFIG_FILE="/etc/dcvm-install.conf"
LOG_FILE="/var/log/datacenter-startup.log"
NETWORK_NAME="datacenter-net"
BRIDGE_NAME="virbr-dc"
NETWORK_ONLY=0
NETWORK_NAME_ARG=""
SOURCE_DIR=""
TMP_WORKDIR=""
STARTED_VMS=()

touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/dcvm-install.log"

print_status() {
  local status=$1
  local message=$2
  echo "[$status] $message" >>"$LOG_FILE" 2>/dev/null || true
  case $status in
  "INFO" | "SUCCESS")
    if [ "${DCVM_VERBOSE:-0}" = 1 ]; then echo -e "  ${DIM}${SYM_INFO} $message${NC}"; fi
    ;;
  "WARNING") echo -e "${YELLOW}${SYM_WARN}${NC} $message" ;;
  "ERROR") echo -e "${RED}${SYM_FAIL} error:${NC} $message" ;;
  esac
  return 0
}
print_status_log() { print_status "$@"; }

step() {
  ui_step "$@"
  echo "[STEP] $2: ${3:-}" >>"$LOG_FILE" 2>/dev/null || true
}

run_step() {
  local rc=0
  ui_run "$@" || rc=$?
  STEP_SECS=$UI_RUN_SECS
  STEP_ERRORS=""
  cat "$UI_RUN_LOG" >>"$LOG_FILE" 2>/dev/null || true
  if [ "$rc" -ne 0 ]; then
    STEP_ERRORS=$({ grep -E '^(E|Error|error):' "$UI_RUN_LOG" || tail -n 10 "$UI_RUN_LOG"; } | tail -n 10)
  fi
  rm -f "$UI_RUN_LOG"
  return "$rc"
}
step_errors() {
  [ -n "${STEP_ERRORS:-}" ] || return 0
  while IFS= read -r line; do echo -e "      ${DIM}${line}${NC}"; done <<<"$STEP_ERRORS"
  echo -e "      ${DIM}full log: $LOG_FILE${NC}"
}

install_step() {
  local label="$1" detail="$2"
  shift 2
  if run_step "$label" "$@"; then
    step ok "$label" "$detail"
  else
    step fail "$label" "failed"
    step_errors
    exit 1
  fi
}

package_progress() {
  local counts n got unpacked setup phase pct last
  counts=$(awk '/[0-9]+ newly installed/ { match($0, /[0-9]+ newly installed/); n = substr($0, RSTART, RLENGTH) + 0; g = u = s = 0; next }
    n && /^Get:/ { g++ } n && /^Unpacking / { u++ } n && /^Setting up / { s++ }
    END { print n + 0, g, u, s }' "$UI_RUN_LOG")
  read -r n got unpacked setup <<<"$counts"
  last=$(ui_last_line "$UI_RUN_LOG")
  if [ "$n" -gt 0 ]; then
    [ "$got" -gt "$n" ] && got=$n
    [ "$unpacked" -gt "$n" ] && unpacked=$n
    [ "$setup" -gt "$n" ] && setup=$n
    pct=$(((got + unpacked + setup) * 100 / (3 * n)))
    if [ "$unpacked" -eq 0 ]; then
      phase="downloading $got of $n"
    elif [ "$setup" -eq 0 ]; then
      phase="unpacking $unpacked of $n"
    else
      phase="setting up $setup of $n"
    fi
    echo "      $(ui_bar "$pct" 20) $(printf '%3s' "$pct")%  ${DIM}${phase}${NC}"
  fi
  [ -n "$last" ] && echo "      ${DIM}$(ui_fit 6 "$last")${NC}"
}

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
  SOURCE_DIR=$DCVM_CHECKOUT
  [[ -n "$SOURCE_DIR" ]]
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
  discovered_files=$(list_repo_files)

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

    if [[ "$file_path" == "dcvm" ]]; then
      local dest="$install_bin/dcvm"
      if fetch_repo_file "$file_path" "$dest"; then
        chmod +x "$dest" 2>/dev/null || true
        print_status_log "SUCCESS" "Fetched dcvm"
        fetched_count=$((fetched_count + 1))
      else
        print_status_log "ERROR" "Failed to fetch $file_path"
        ok=false
      fi

    elif [[ "$file_path" == bin/* ]]; then
      local dest="$install_bin/$(basename "$file_path")"
      if fetch_repo_file "$file_path" "$dest"; then
        chmod +x "$dest" 2>/dev/null || true
        print_status_log "SUCCESS" "Fetched $(basename "$file_path")"
        fetched_count=$((fetched_count + 1))
      else
        print_status_log "ERROR" "Failed to fetch $file_path"
        ok=false
      fi

    elif [[ "$file_path" == lib/* ]]; then
      local rel_no_lib="${file_path#lib/}"
      local dest="$install_lib/$rel_no_lib"
      if fetch_repo_file "$file_path" "$dest"; then
        [[ "$dest" == *.sh ]] && chmod +x "$dest" 2>/dev/null || true
        print_status_log "SUCCESS" "Fetched $rel_no_lib"
        fetched_count=$((fetched_count + 1))
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

  local debian_packages=(qemu-system-x86 qemu-utils libvirt-daemon-system libvirt-clients bridge-utils virtinst wget curl nfs-kernel-server uuid-runtime genisoimage bc guestfish libguestfs-tools jq dnsmasq-utils iptables aria2 python3 ovmf)
  local arch_packages=(qemu-full libvirt bridge-utils virt-install wget curl nfs-utils cdrtools dnsmasq ebtables iptables dmidecode bc util-linux guestfish libguestfs-tools jq aria2 python edk2-ovmf)

  local fedora_packages=(qemu-system-x86 qemu-img libvirt-daemon-kvm libvirt-daemon-config-network libvirt-client bridge-utils virt-install wget curl nfs-utils util-linux genisoimage bc libguestfs guestfs-tools jq dnsmasq dnsmasq-utils iptables-nft aria2 xz python3 edk2-ovmf)

  local family manager
  family=$(distro_family)
  case "$family" in
  debian) manager=apt-get ;;
  arch) manager=pacman ;;
  fedora) manager=dnf ;;
  *)
    print_status "WARNING" "Unsupported distribution: install the dependencies manually (see docs/installation.md)."
    return 0
    ;;
  esac
  command -v "$manager" >/dev/null 2>&1 || {
    print_status "ERROR" "$manager not found. Cannot install packages."
    exit 1
  }
  print_status "INFO" "Detected a $family-based distribution. Installing packages with $manager..."
  case "$family" in
  debian)
    export DEBIAN_FRONTEND=noninteractive
    apt-get update && apt-get install -y "${debian_packages[@]}"
    ;;
  arch) pacman -Sy --noconfirm "${arch_packages[@]}" ;;
  fedora) dnf install -y "${fedora_packages[@]}" ;;
  esac
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

# libvirt's nftables backend rejects forwarded connections no iptables rule can accept.
use_iptables_backend() {
  local conf=/etc/libvirt/network.conf
  command -v iptables >/dev/null 2>&1 && [ -f "$conf" ] && grep -q 'firewall_backend' "$conf" || return 1
  grep -qE '^[[:space:]]*firewall_backend[[:space:]]*=[[:space:]]*"iptables"' "$conf" && return 1
  sed -i -E '/^[[:space:]]*firewall_backend[[:space:]]*=/d' "$conf"
  echo 'firewall_backend = "iptables"' >>"$conf"
}

start_libvirtd() {
  print_status "INFO" "Checking libvirtd service..."

  if use_iptables_backend; then
    print_status "INFO" "libvirt networks now use iptables, like dcvm's port forwards"
    systemctl try-restart libvirtd virtnetworkd 2>/dev/null || true
    # The restart puts libvirt's rules above the saved port forwards.
    [ -s "$(get_port_mappings_file)" ] && dcvm network ports apply >/dev/null 2>&1 || true
  fi

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
  print_status "INFO" "Checking dcvm network..."

  virsh net-list --all --name | grep -qxF "$NETWORK_NAME" || {
    print_status "ERROR" "Network '$NETWORK_NAME' not found. Please run the setup script first."
    exit 1
  }

  if ! virsh net-list --name | grep -qxF "$NETWORK_NAME"; then
    print_status_log "INFO" "Starting network '$NETWORK_NAME'..."
    virsh net-start "$NETWORK_NAME"
  fi

  virsh net-list --name | grep -qxF "$NETWORK_NAME" && print_status_log "SUCCESS" "Network '$NETWORK_NAME' is active" || {
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
    NFS_RESULT="skip|not set up (re-run the installer to add it)"
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

  # Not grep -q: it exits at the first match, systemctl dies of SIGPIPE, and
  # pipefail turns that into "not installed".
  if ! systemctl list-unit-files 2>/dev/null | grep -E 'nfs-kernel-server|nfs-server' >/dev/null; then
    print_status_log "WARNING" "NFS server is not installed"
    print_status_log "INFO" "Install with: apt install nfs-kernel-server (Debian/Ubuntu), pacman -S nfs-utils (Arch) or dnf install nfs-utils (Fedora)"
    return 0
  fi

  # Fedora doesn't enable it; VMs then wait 90s for /mnt/shared after a reboot.
  systemctl enable --now nfs-server 2>/dev/null || systemctl enable --now nfs-kernel-server 2>/dev/null || {
    print_status_log "WARNING" "Could not start NFS server"
    return 0
  }

  if systemctl is-active --quiet nfs-kernel-server 2>/dev/null || systemctl is-active --quiet nfs-server 2>/dev/null; then
    print_status_log "SUCCESS" "NFS server is running"

    local subnet="${NETWORK_SUBNET:-10.10.10}"
    if ! secure_nfs_share "$NFS_EXPORT_PATH" "$subnet"; then
      print_status_log "WARNING" "Could not set up the NFS export"
      return 0
    fi
    [ "${NFS_QUARANTINED:-0}" -gt 0 ] && print_status_log "WARNING" "Moved $NFS_QUARANTINED setuid or device files out of the share into $NFS_QUARANTINE_DIR"
    # firewalld puts the bridge in libvirt's zone, which rejects NFS.
    if systemctl is-active --quiet firewalld 2>/dev/null; then
      local zone services=(--add-service=nfs --add-service=rpc-bind --add-service=mountd)
      zone=$(firewall-cmd --get-zone-of-interface="$BRIDGE_NAME" 2>/dev/null) || zone=libvirt
      if firewall-cmd -q --zone="$zone" "${services[@]}" && firewall-cmd -q --permanent --zone="$zone" "${services[@]}"; then
        print_status_log "SUCCESS" "firewalld: NFS allowed in zone $zone"
      else
        print_status_log "WARNING" "Could not allow NFS in firewalld zone $zone"
      fi
    fi
    print_status_log "SUCCESS" "NFS exports configured at: $NFS_EXPORT_PATH"
    NFS_RESULT="ok|$NFS_EXPORT_PATH for ${subnet}.0/24, mounted in VMs at /mnt/shared"
    print_status_log "INFO" "VMs can mount: $NFS_EXPORT_PATH from ${subnet}.1"
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
      print_status_log "INFO" "Directory $dir does not exist, creating..."
      if mkdir -p "$dir" 2>/dev/null && chmod 755 "$dir" 2>/dev/null; then
        print_status_log "SUCCESS" "Directory $dir created."
      else
        print_status_log "ERROR" "Failed to create directory $dir"
        return 1
      fi
    fi
  done
  chmod 700 "$DATACENTER_BASE/backups"
  # Search only: libvirt reaches each VM's folder by name, other users cannot list the VM names.
  chmod 711 "$DATACENTER_BASE/vms"

  print_status_log "SUCCESS" "Directory structure verified"
}

source_mirror_manager() {
  local repo_mirror="$DCVM_CHECKOUT/lib/utils/mirror-manager.sh"
  local installed_mirror="/usr/local/lib/dcvm/utils/mirror-manager.sh"
  local loaded_from=""

  if [[ -n "$DCVM_CHECKOUT" && -f "$repo_mirror" ]]; then
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

check_cloud_images() {
  print_status_log "INFO" "Checking for cloud images..."

  if ! source_mirror_manager; then
    print_status_log "WARNING" "mirror-manager.sh not found, cloud images will be downloaded when creating VMs"
    return 0
  fi

  local images=() filename
  for filename in $SUPPORTED_IMAGES; do
    images+=("$filename|$(image_label "$filename")")
  done

  local missing_images=()

  for entry in "${images[@]}"; do
    IFS='|' read -r filename label <<<"$entry"
    local image_path="$DATACENTER_BASE/storage/templates/$filename"
    if [[ -f "$image_path" ]]; then
      local size
      size=$(format_bytes "$(file_bytes "$image_path")")
      print_status_log "SUCCESS" "$label cloud image found ($size)"
    else
      print_status_log "INFO" "$label cloud image not found"
      missing_images+=("$entry")
    fi
  done

  if [[ ${#missing_images[@]} -gt 0 ]]; then
    echo ""
    print_status_log "INFO" "Found ${#missing_images[@]} missing cloud image(s)"

    if [[ -t 0 && -t 1 ]]; then
      echo ""
      echo -e "${BOLD}${#missing_images[@]} of ${#images[@]} cloud images are not downloaded yet.${NC} Download them now?"
      select yn in "Yes, download now" "No, download when creating a VM"; do
        case $yn in
        "Yes, download now")
          for entry in "${missing_images[@]}"; do
            IFS='|' read -r filename label <<<"$entry"
            local image_path="$DATACENTER_BASE/storage/templates/$filename"
            if download_image_ui "$filename" "$image_path" 104857600; then
              print_status_log "SUCCESS" "$label cloud image downloaded successfully"
            else
              print_status_log "WARNING" "Failed to download $label - will attempt later when creating VM"
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
  local subnet="${NETWORK_SUBNET:-10.10.10}"
  local ip_addr="${subnet}.1"
  local netmask="255.255.255.0"
  local dhcp_start="${subnet}.10"
  local dhcp_end="${subnet}.200"

  print_status_log "INFO" "Checking network '$net_name'..."

  if virsh net-info "$net_name" >/dev/null 2>&1; then
    print_status_log "INFO" "Network '$net_name' already exists."
    if [ "$(virsh net-info "$net_name" 2>/dev/null | awk '/^Active:/ { print $2 }')" != yes ]; then
      print_status_log "INFO" "Starting existing network '$net_name'..."
      if ! virsh net-start "$net_name" >/dev/null; then
        print_status_log "ERROR" "Network '$net_name' could not start (subnet or bridge in use?): virsh net-start $net_name"
        return 1
      fi
    fi

    return 0
  fi

  print_status_log "INFO" "Creating network '$net_name'..."
  local network_config
  network_config=$(mktemp)

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
  <ip address='${ip_addr}' netmask='${netmask}'>
	<dhcp>
	  <range start='${dhcp_start}' end='${dhcp_end}'/>
	</dhcp>
  </ip>
</network>
EOF

  # virsh's own error goes to the step log, which install_step shows on failure.
  if ! virsh net-define "$network_config" >/dev/null; then
    rm -f "$network_config"
    print_status_log "ERROR" "Failed to create network '$net_name'"
    return 1
  fi
  rm -f "$network_config"
  print_status_log "SUCCESS" "Network '$net_name' defined"

  if ! virsh net-start "$net_name" >/dev/null; then
    print_status_log "ERROR" "Network '$net_name' defined but could not start (${subnet}.0/24 or bridge $bridge_name in use?): virsh net-start $net_name"
    return 1
  fi

  virsh net-autostart "$net_name" >/dev/null 2>&1 || print_status_log "WARNING" "Could not set network to autostart"

  print_status_log "SUCCESS" "Network '$net_name' created"
}

# Linux interface names are at most 15 bytes (IFNAMSIZ).
valid_bridge_name() { [[ "$1" =~ ^[A-Za-z0-9_.-]{1,15}$ ]]; }

# First <a.b>.N subnet that no host address, route or libvirt network uses.
unused_subnet() {
  local base="${NETWORK_SUBNET:-10.10.10}" used n
  used=$({
    echo "$base."
    ip -4 -o addr show
    ip -4 route show
    virsh net-list --all --name | while read -r n; do [ -z "$n" ] || virsh net-dumpxml "$n"; done
  } 2>/dev/null)
  for n in $(seq 0 254); do
    grep -qF "${base%.*}.$n." <<<"$used" || {
      echo "${base%.*}.$n"
      return 0
    }
  done
  return 1
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

  local nat_count=$(iptables -t nat -L POSTROUTING 2>/dev/null | grep -c "MASQUERADE" || true)
  echo "    NAT rules active: $nat_count"
}

start_existing_vms() {
  print_status_log "INFO" "Checking for existing dcvm VMs to start..."

  local vms_started=0
  local vm_list=$(virsh list --all --name 2>/dev/null | grep -v "^$" || echo "")

  if [[ -z "$vm_list" ]]; then
    print_status_log "INFO" "No existing dcvm VMs found"
    return 0
  fi

  while IFS= read -r vm_name; do
    if [[ -n "$vm_name" ]] && virsh domiflist "$vm_name" 2>/dev/null | awk -v n="$NETWORK_NAME" '$3 == n { f = 1 } END { exit !f }'; then
      if ! virsh list 2>/dev/null | grep -q "$vm_name.*running"; then
        print_status_log "INFO" "Starting VM: $vm_name"
        if virsh start "$vm_name" >/dev/null 2>&1; then
          print_status_log "SUCCESS" "Started VM: $vm_name"
          STARTED_VMS+=("$vm_name")
          vms_started=$((vms_started + 1)) # ((x++)) returns 1 at 0, which set -e treats as failure
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
  local version
  version=$(/usr/local/bin/dcvm version 2>/dev/null | sed -n 's/^Version: //p')
  ui_box "dcvm ${version:-} is installed" \
    "$(printf '%-10s%s' Data "$DATACENTER_BASE")" \
    "$(printf '%-10s%s' Network "$NETWORK_NAME, ${NETWORK_SUBNET:-10.10.10}.0/24, bridge $BRIDGE_NAME")" \
    "$(printf '%-10s%s' Log "$LOG_FILE")"
  ui_next "dcvm create myvm" "create your first VM (asks a few questions)" \
    "dcvm help" "all commands"
  print_status_log "SUCCESS" "dcvm is ready to use!"
}

setup_aliases() {
  local cleaned
  cleaned=$(remove_shell_lines "$DCVM_ALIAS_LINE" | tr '\n' ' ')
  ALIAS_RESULT=""
  [ -n "$cleaned" ] && ALIAS_RESULT="ok|old dcvm alias removed from ${cleaned% } (open a new shell, or: unalias dcvm)"
  return 0
}

setup_admin_user() {
  local who="${SUDO_USER:-}"
  [ -n "$who" ] && [ "$who" != root ] || return 0
  if [[ ! -t 0 || ! -t 1 ]]; then
    ADMIN_RESULT="skip|let users in without sudo: sudo dcvm user add <user> [--admin]"
    return 0
  fi
  echo
  if ! prompt_yes_no "Let $who use dcvm without sudo, as a dcvm admin? [Y/n]: " "Y"; then
    ADMIN_RESULT="skip|nobody added (sudo dcvm user add <user> [--admin])"
    return 0
  fi
  if ensure_dcvm_groups && usermod -aG "$DCVM_USER_GROUP,$DCVM_ADMIN_GROUP" "$who"; then
    ADMIN_RESULT="ok|$who is a dcvm admin; log in again to use dcvm without sudo"
  else
    ADMIN_RESULT="warn|could not add $who to the dcvm groups"
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
      COMPLETION_RESULT="ok|enabled (new shells)"
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
      COMPLETION_RESULT="skip|not enabled (source $completion_dst to enable)"
      print_status_log "INFO" "You can enable later by adding: 'source $completion_dst' to your shell rc"
    fi
  else
    COMPLETION_RESULT="skip|installed, not enabled (source $completion_dst)"
    print_status_log "INFO" "Non-interactive mode. Completion script installed at $completion_dst"
    print_status_log "INFO" "Add 'source $completion_dst' to your shell rc to enable"
  fi
}

setup_service() {
  install_dcvm_services
}

install_dcvm_command() {
  print_status_log "INFO" "Installing dcvm command and libraries..."

  local install_bin="/usr/local/bin"
  local install_lib="/usr/local/lib/dcvm"

  mkdir -p "$install_bin" "$install_lib"

  if ! install_by_fetch "$install_bin" "$install_lib" || ! dcvm_tree_permissions "$install_bin/dcvm" "$install_lib"; then
    print_status_log "ERROR" "Failed to install dcvm files"
    exit 1
  fi

  if command -v dcvm >/dev/null 2>&1; then
    print_status_log "SUCCESS" "dcvm command is available in PATH"
  else
    print_status_log "WARNING" "dcvm command not found in PATH yet"
    print_status_log "INFO" "The command is installed at: $install_bin/dcvm"
    print_status_log "INFO" "You may need to restart your shell or add /usr/local/bin to PATH"
  fi
}

main() {
  print_status_log "INFO" "dcvm installer is starting..." >&2

  touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/dcvm-install.log"
  echo "$(date) - Installation started" >>"$LOG_FILE" 2>/dev/null || true

  print_status_log "INFO" "Starting dcvm installation..."

  check_root

  if [[ "$NETWORK_ONLY" == "1" ]]; then
    install_required_packages
    start_libvirtd
    local net_name="$NETWORK_NAME"
    local bridge_name="$BRIDGE_NAME" subnet_note=""
    if [[ -n "$NETWORK_NAME_ARG" && "$NETWORK_NAME_ARG" != "$NETWORK_NAME" ]]; then
      net_name="$NETWORK_NAME_ARG"
      bridge_name="virbr-${net_name//[^a-zA-Z0-9]/}"
      bridge_name="${bridge_name:0:15}"
    fi
    if [[ ! "$net_name" =~ ^[A-Za-z0-9_.-]+$ ]] || ! valid_bridge_name "$bridge_name"; then
      print_status_log "ERROR" "Invalid network name '$net_name' or bridge name '$bridge_name' (letters, digits, - _ .; a bridge at most 15)"
      exit 1
    fi
    # A second network on the primary's subnet could not start next to it.
    if [[ "$net_name" != "$NETWORK_NAME" ]] && ! virsh net-info "$net_name" >/dev/null 2>&1; then
      NETWORK_SUBNET=$(unused_subnet) || {
        print_status_log "ERROR" "No free subnet for '$net_name'"
        exit 1
      }
      subnet_note="$NETWORK_SUBNET.0/24, "
    fi
    create_network "$net_name" "$bridge_name" || exit 1
    enable_ip_forwarding || exit 1
    ui_done ok "Network $net_name" "${subnet_note}bridge $bridge_name, IP forwarding on"
    exit 0
  fi

  ui_title "Installing dcvm" "${DCVM_REPO_SLUG}@${DCVM_REPO_BRANCH} ${SYM_DOT} $DATACENTER_BASE"
  local log_start installed
  log_start=$(($(wc -l <"$LOG_FILE" 2>/dev/null || echo 0) + 1))
  if UI_RUN_DETAIL=package_progress run_step "Packages" install_required_packages; then
    installed=$(tail -n +"$log_start" "$LOG_FILE" 2>/dev/null |
      grep -oE '[0-9]+ newly installed|Installing: +[0-9]+ packages?|^Packages? \([0-9]+\)' | tail -1 | grep -oE '[0-9]+' || true)
    if [ "${installed:-0}" -gt 0 ]; then
      step ok "Packages" "$installed installed in ${STEP_SECS}s (QEMU/KVM, libvirt, aria2, image tools)"
    else
      step ok "Packages" "QEMU/KVM, libvirt, aria2 and image tools already installed"
    fi
  else
    step fail "Packages" "installing them failed"
    step_errors
    exit 1
  fi
  check_kvm_support
  step ok "KVM" "/dev/kvm available"
  install_step "dcvm" "/usr/local/bin/dcvm and /usr/local/lib/dcvm" install_dcvm_command
  install_step "libvirt" "libvirtd running" start_libvirtd
  install_step "Directories" "$DATACENTER_BASE" check_directory_structure
  check_cloud_images
  local have=0 total=0 img
  for img in ${SUPPORTED_IMAGES:-}; do
    total=$((total + 1))
    [ -f "$DATACENTER_BASE/storage/templates/$img" ] && have=$((have + 1))
  done
  if [ "$have" -eq "$total" ]; then
    step ok "Cloud images" "all $total downloaded"
  else
    step skip "Cloud images" "$have of $total downloaded; the rest download on first use"
  fi
  install_step "IP forwarding" "on, persisted in /etc/sysctl.d/90-dcvm.conf" enable_ip_forwarding
  install_step "Network" "$NETWORK_NAME, ${NETWORK_SUBNET:-10.10.10}.0/24, DHCP .10-.200" create_datacenter_network
  install_completion
  [ -n "${COMPLETION_RESULT:-}" ] && step "${COMPLETION_RESULT%%|*}" "Tab completion" "${COMPLETION_RESULT#*|}"
  start_nfs_server
  [ -n "${NFS_RESULT:-}" ] && step "${NFS_RESULT%%|*}" "NFS share" "${NFS_RESULT#*|}"
  start_existing_vms
  [ ${#STARTED_VMS[@]} -gt 0 ] && step ok "dcvm VMs" "started ${STARTED_VMS[*]}"
  setup_aliases
  [ -n "${ALIAS_RESULT:-}" ] && step "${ALIAS_RESULT%%|*}" "Shell alias" "${ALIAS_RESULT#*|}"
  install_step "Services" "hourly storage check, network and port forwards back after reboot, socket for users without root" setup_service
  setup_admin_user
  [ -n "${ADMIN_RESULT:-}" ] && step "${ADMIN_RESULT%%|*}" "Admin" "${ADMIN_RESULT#*|}"
  show_datacenter_summary
}

dcvm_init() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    ui_title "dcvm installer" "${DCVM_REPO_SLUG}@${DCVM_REPO_BRANCH}"

    if [[ -t 0 && -t 1 ]]; then
      echo "Please choose the installation directory for dcvm."
      read -p "Install directory [default: $DEFAULT_DATACENTER_BASE]: " USER_DIR || USER_DIR=""
      USER_DIR=${USER_DIR:-$DEFAULT_DATACENTER_BASE}
      DATACENTER_BASE="${USER_DIR%/}"
      # The file is sourced by root and parsed by the socket service: plain paths only.
      if [[ ! "$DATACENTER_BASE" =~ ^(/[A-Za-z0-9_][A-Za-z0-9._-]*)+$ ]]; then
        echo "Invalid directory: an absolute path of letters, digits, - _ . Using default: $DEFAULT_DATACENTER_BASE"
        DATACENTER_BASE="$DEFAULT_DATACENTER_BASE"
      fi

      echo "Please enter the network name for dcvm."
      read -p "Network name [default: $NETWORK_NAME]: " USER_NETWORK_NAME || USER_NETWORK_NAME=""
      NETWORK_NAME=${USER_NETWORK_NAME:-$NETWORK_NAME}
      if [[ ! "$NETWORK_NAME" =~ ^[A-Za-z0-9_.-]+$ ]]; then
        echo "Invalid network name: letters, digits, - _ or . Using default: datacenter-net"
        NETWORK_NAME="datacenter-net"
      fi

      echo "Please enter the bridge name for dcvm."
      read -p "Bridge name [default: $BRIDGE_NAME]: " USER_BRIDGE_NAME || USER_BRIDGE_NAME=""
      BRIDGE_NAME=${USER_BRIDGE_NAME:-$BRIDGE_NAME}
      if ! valid_bridge_name "$BRIDGE_NAME"; then
        echo "Invalid bridge name: at most 15 letters, digits, - _ or . Using default: virbr-dc"
        BRIDGE_NAME="virbr-dc"
      fi

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

    printf 'DATACENTER_BASE="%s"\nNETWORK_NAME="%s"\nBRIDGE_NAME="%s"\nNETWORK_SUBNET="%s"\n' \
      "$DATACENTER_BASE" "$NETWORK_NAME" "$BRIDGE_NAME" "$NETWORK_SUBNET" >"$CONFIG_FILE"
    chmod 644 "$CONFIG_FILE"
    print_status_log "INFO" "Installation directory: $DATACENTER_BASE, network: $NETWORK_NAME, bridge: $BRIDGE_NAME, subnet: $NETWORK_SUBNET.0/24"
  else
    source "$CONFIG_FILE"
    ui_title "dcvm installer" "${DCVM_REPO_SLUG}@${DCVM_REPO_BRANCH} ${SYM_DOT} using $CONFIG_FILE"
  fi

  NFS_EXPORT_PATH="$DATACENTER_BASE/nfs-share"

  while [ $# -gt 0 ]; do
    case $1 in
    --network-only) NETWORK_ONLY=1 ;;
    --network-name=*) NETWORK_NAME_ARG="${1#*=}" ;;
    --network-name)
      [[ -n "${2:-}" && "$2" != -* ]] || {
        echo "Error: --network-name requires a value" >&2
        exit 1
      }
      NETWORK_NAME_ARG="$2"
      shift
      ;;
    esac
    shift
  done
  echo ""
  print_status_log "INFO" "Executing dcvm installer..." >&2
  main
}

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]] || [[ -z "${BASH_SOURCE[0]:-}" ]]; then
  dcvm_init "$@"
fi
