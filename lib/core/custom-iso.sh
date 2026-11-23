#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../utils/common.sh"

VM_NAME=""
ISO_PATH=""
MEMORY=""
CPUS=""
DISK_SIZE=""
OS_VARIANT=""
GRAPHICS=""
BOOT_ORDER=""
STATIC_IP=""
COPY_ISO=""
FORCE_MODE=false
LOGIN_USER=""
UEFI=false
JSON=false
WAIT=false

show_usage() {
  ui_help <<EOF
dcvm create-iso - a VM that boots an installer ISO

Usage: dcvm create <name> -o <file.iso> [options]
       dcvm create-iso <name> --iso <file.iso> [options]

Options:
  --iso <path>                 Installer ISO (asked if missing)
  -m, --memory <MB>            Memory (asked if missing)
  -c, --cpus <N>               vCPUs (asked if missing)
  -d, --disk <SIZE>            Disk size, e.g. 20G (asked if missing)
  --os-variant <name>          libosinfo variant, e.g. debian12 (default: detected, else generic)
  --graphics <vnc|spice|none>  Display (default vnc, on 127.0.0.1)
  --boot <order>               Boot order (default hd,cdrom)
  --uefi                       UEFI firmware instead of BIOS
  --ip <address>               Static IP you set in the installer
  -u, --username <name>        Login user the installed OS has, for dcvm ssh/exec/cp
  --copy-iso                   Copy the ISO next to the VM's disk
  --ttl <90m|2h|3d>            Delete the VM after this long
  --wait                       Return once SSH answers (up to 30 minutes)
  --json                       Print the result as JSON on stdout
  -f, --force                  No questions: 2048 MB, 2 vCPUs, 20G disk unless given
  -h, --help                   Show this help

The VM boots its disk first and the ISO while the disk is empty, so an
installer's reboot lands in the installed OS and the VM keeps running. You
install the OS over VNC or the console, or the ISO installs itself (an
unattended or autoinstall ISO); with -u and your SSH key in the image,
dcvm ssh/exec/cp work afterwards.

Examples:
  dcvm create web -o /srv/iso/debian-13.iso
  dcvm create-iso arch --iso /srv/iso/arch.iso --graphics none
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
    -h | --help)
      show_usage
      exit 0
      ;;
    --iso | -o)
      ISO_PATH="$2"
      shift 2 || need_value "$1"
      ;;
    --iso=*)
      ISO_PATH="${1#--iso=}"
      shift
      ;;
    -m | --memory)
      MEMORY="$2"
      shift 2 || need_value "$1"
      ;;
    -c | --cpus)
      CPUS="$2"
      shift 2 || need_value "$1"
      ;;
    -d | --disk)
      DISK_SIZE="$2"
      shift 2 || need_value "$1"
      ;;
    --os-variant)
      OS_VARIANT="$2"
      shift 2 || need_value "$1"
      ;;
    --graphics)
      GRAPHICS="$2"
      shift 2 || need_value "$1"
      ;;
    --boot)
      BOOT_ORDER="$2"
      shift 2 || need_value "$1"
      ;;
    --ip)
      STATIC_IP="$2"
      shift 2 || need_value "$1"
      ;;
    --copy-iso)
      COPY_ISO="true"
      shift
      ;;
    -f | --force)
      FORCE_MODE=true
      shift
      ;;
    -u | --username)
      LOGIN_USER="$2"
      shift 2 || need_value "$1"
      ;;
    --uefi)
      UEFI=true
      shift
      ;;
    --json)
      JSON=true
      shift
      ;;
    --wait)
      WAIT=true
      shift
      ;;
    --ttl)
      TTL="$2"
      shift 2 || need_value "$1"
      ;;
    -*)
      print_error "Unknown option: $1 (dcvm create-iso --help)"
      exit 1
      ;;
    *)
      if [ -n "$VM_NAME" ]; then
        print_error "One VM per ISO create (got $VM_NAME and $1)"
        exit 1
      fi
      VM_NAME="$1"
      shift
      ;;
    esac
  done
}

interactive_prompt_memory() { interactive_prompt_memory_common "MEMORY"; }
interactive_prompt_cpus() { interactive_prompt_cpus_common "CPUS"; }
interactive_prompt_disk() { interactive_prompt_disk_common "DISK_SIZE"; }

interactive_prompt_graphics() {
  cat <<-EOF
	
	Graphics options:
	  1) VNC (recommended for graphical installers)
	  2) SPICE (better performance, requires virt-viewer)
	  3) None (text console only)
	EOF
  while true; do
    read -p "Select graphics [1]: " choice || no_input
    choice=${choice:-1}
    case "$choice" in
    1)
      GRAPHICS="vnc"
      break
      ;;
    2)
      GRAPHICS="spice"
      break
      ;;
    3)
      GRAPHICS="none"
      break
      ;;
    *) print_error "Please enter 1, 2, or 3" ;;
    esac
  done
}

interactive_prompt_os_variant() {
  cat <<-EOF
	
	OS Variant helps libvirt optimize settings for the guest OS.
	Common variants: ubuntu22.04, ubuntu20.04, debian12, debian11, fedora39, centos9, win10, win11
	Leave empty for generic settings, or run 'osinfo-query os' for full list.
	EOF
  read -p "OS variant (optional): " OS_VARIANT || no_input
}

interactive_prompt_boot_order() {
  cat <<-EOF
	
	Boot order determines which device boots first.
	  hd,cdrom = the disk, or the ISO while the disk is empty (default)
	  cdrom,hd = always the ISO first (the installer starts again on every boot)
	EOF
  read -p "Boot order [hd,cdrom]: " BOOT_ORDER || no_input
  BOOT_ORDER=${BOOT_ORDER:-hd,cdrom}
}

interactive_prompt_copy_iso() {
  [ "$(caller_role)" = root ] || return 0
  echo ""
  read -p "Copy ISO to VM directory? (y/N): " copy_choice || no_input
  if [[ "$copy_choice" =~ ^[Yy]$ ]]; then
    COPY_ISO="true"
  else
    COPY_ISO="false"
  fi
}

interactive_prompt_static_ip() {
  local subnet="${NETWORK_SUBNET:-10.10.10}"
  echo ""
  print_info "Static IP Configuration (manual setup required in VM)"
  echo "  Network subnet: ${subnet}.0/24"
  echo "  Gateway: ${subnet}.1"
  echo "  Valid range: ${subnet}.2 - ${subnet}.254"
  echo ""

  while true; do
    read -p "Use static IP? (y/N, default: DHCP): " use_static || no_input
    use_static=${use_static:-n}

    if [[ "$use_static" =~ ^[Nn]$ ]]; then
      STATIC_IP=""
      print_info "Using DHCP - configure network in VM after installation"
      break
    elif [[ "$use_static" =~ ^[Yy]$ ]]; then
      while true; do
        read -p "Enter static IP (e.g., ${subnet}.50): " STATIC_IP || no_input
        if [ -z "$STATIC_IP" ]; then
          print_error "IP address cannot be empty"
          continue
        fi
        if validate_ip_in_subnet "$STATIC_IP"; then
          print_success "Static IP set to: $STATIC_IP (configure manually in VM)"
          break 2
        fi
      done
    else
      print_error "Please enter 'y' for static IP or 'n' for DHCP"
    fi
  done
}

validate_vm_not_exists() {
  if virsh list --all --name 2>/dev/null | grep -qx "$VM_NAME"; then
    print_error "VM '$VM_NAME' already exists"
    echo "Use: dcvm delete $VM_NAME (to delete it first)"
    exit 1
  fi
}

prompt_iso_path() {
  if [ -z "$ISO_PATH" ]; then
    if [ "$(caller_role)" != root ]; then
      print_error "Pass the ISO as a file: dcvm create-iso $VM_NAME --iso <file.iso>"
      exit 1
    fi
    echo ""
    read -p "Enter path to ISO file: " ISO_PATH || no_input
  fi
  if [ "$(caller_role)" != root ] && [ "$ISO_PATH" != "$DATACENTER_BASE/vms/$VM_NAME/installer.iso" ]; then
    print_error "Pass the ISO as a file: dcvm create-iso $VM_NAME --iso <file.iso>"
    exit 1
  fi
  ISO_PATH="${ISO_PATH/#\~/$HOME}"
  if [ ! -f "$ISO_PATH" ]; then
    print_error "ISO file not found: $ISO_PATH"
    exit 1
  fi
  ISO_PATH=$(realpath "$ISO_PATH")
}

show_iso_header() {
  ui_title "New VM from an ISO" "$VM_NAME ${SYM_DOT} $(basename "$ISO_PATH")"
}

collect_vm_options() {
  [ -z "$MEMORY" ] && interactive_prompt_memory
  [ -z "$CPUS" ] && interactive_prompt_cpus
  [ -z "$DISK_SIZE" ] && interactive_prompt_disk
  [ -z "$GRAPHICS" ] && interactive_prompt_graphics
  [ -z "$OS_VARIANT" ] && interactive_prompt_os_variant
  [ -z "$BOOT_ORDER" ] && interactive_prompt_boot_order
  [ -z "$COPY_ISO" ] && interactive_prompt_copy_iso
  [ -z "$STATIC_IP" ] && interactive_prompt_static_ip
}

show_vm_summary() {
  local rows=(
    "$(printf '%-11s%s' ISO "$(basename "$ISO_PATH")$([ "$COPY_ISO" = true ] && echo " (copied)")")"
    "$(printf '%-11s%s' Resources "$CPUS vCPU, $MEMORY MB RAM, $DISK_SIZE disk")"
    "$(printf '%-11s%s' Display "$GRAPHICS")"
    "$(printf '%-11s%s' OS "${OS_VARIANT:-generic}")"
    "$(printf '%-11s%s' Boot "$([ "$UEFI" = true ] && echo "UEFI, ")$BOOT_ORDER")"
    "$(printf '%-11s%s' Login "${LOGIN_USER:-not known to dcvm (-u <user> to set it)}")"
  )
  [ -n "${TTL:-}" ] && rows+=("$(printf '%-11s%s' Deleted "after $TTL")")
  [ -n "$STATIC_IP" ] && rows+=("$(printf '%-11s%s' Address "$STATIC_IP (set it in the installer)")")
  ui_box "$VM_NAME" "${rows[@]}"
  echo ""
}

confirm_creation() {
  confirm_action "Create it?" y || exit 0
  echo ""
}

check_iso_dependencies() {
  require_root
  for cmd in virsh virt-install qemu-img; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      print_error "Required command not found: $cmd"
      exit 1
    fi
  done
}

prepare_vm_directory() {
  VM_DIR="$DATACENTER_BASE/vms/$VM_NAME"
  DISK_PATH="$VM_DIR/${VM_NAME}-disk.qcow2"
  mkdir -p "$VM_DIR" && chmod 711 "$VM_DIR" || {
    print_error "Failed to create VM directory"
    exit 1
  }
}

copy_iso_if_needed() {
  INSTALL_ISO="$ISO_PATH"
  if [ "$COPY_ISO" = "true" ] && [ "$ISO_PATH" != "$VM_DIR/installer.iso" ]; then
    INSTALL_ISO="$VM_DIR/installer.iso"
    if [ -e "$INSTALL_ISO" ]; then
      print_error "$INSTALL_ISO is left over from another run; remove it first"
      exit 1
    fi
    ui_run "Copying ISO" sh -c 'umask 077 && cp -- "$1" "$2"' _ "$ISO_PATH" "$INSTALL_ISO" || {
      ui_step fail "ISO" "copy failed"
      exit 1
    }
    ISO_COPIED=true
    ui_step ok "ISO" "copied to $INSTALL_ISO (${UI_RUN_SECS}s)"
  fi
}

validate_iso_size() {
  # ISO 9660 (also the bridge in UDF installer ISOs) puts CD001 at byte 32769.
  if [ "$(dd if="$INSTALL_ISO" bs=1 skip=32769 count=5 2>/dev/null)" != CD001 ]; then
    print_warning "$(basename "$INSTALL_ISO") doesn't look like an ISO 9660 image; the VM may not boot it"
  fi
}

check_iso_accessibility() {
  local check_path="${ISO_PATH:-$INSTALL_ISO}"
  local iso_realpath
  iso_realpath=$(realpath "$check_path" 2>/dev/null || echo "$check_path")
  # virt-install splits its options on commas, so such a path can't be passed.
  if [[ "$iso_realpath" =~ ^/root/ ]] || [[ "$iso_realpath" =~ ^/home/[^/]+/ ]] || [[ "$iso_realpath" == *,* ]]; then
    if [ "$COPY_ISO" != "true" ]; then
      ui_step warn "ISO" "in a home folder or a path with a comma; copying it next to the disk"
      COPY_ISO="true"
      copy_iso_if_needed
    fi
  fi

  if [ ! -r "$INSTALL_ISO" ]; then
    print_error "ISO file is not readable: $INSTALL_ISO"
    exit 1
  fi
}

create_vm_disk() {
  (umask 077 && qemu-img create -f qcow2 "$DISK_PATH" "$DISK_SIZE") >/dev/null 2>&1 || {
    ui_step fail "Disk" "qemu-img create failed"
    exit 1
  }
  DISK_MADE=true
  ui_step ok "Disk" "$DISK_SIZE, $DISK_PATH"
}

# --boot and --graphics reach virt-install's option parser: free text can name host files.
validate_iso_options() {
  GRAPHICS=${GRAPHICS:-vnc} BOOT_ORDER=${BOOT_ORDER:-hd,cdrom}
  case "$GRAPHICS" in none | vnc | spice) ;; *)
    print_error "Graphics must be none, vnc or spice"
    exit 1
    ;;
  esac
  case "$BOOT_ORDER" in cdrom,hd | hd,cdrom | cdrom | hd) ;; *)
    print_error "Boot order must be cdrom,hd or hd,cdrom"
    exit 1
    ;;
  esac
  if [[ ! "$OS_VARIANT" =~ ^[A-Za-z0-9._-]{0,64}$ ]]; then
    print_error "Invalid OS variant: $OS_VARIANT"
    exit 1
  fi
  if [ -n "$STATIC_IP" ] && ! valid_vm_ip "$STATIC_IP"; then
    print_error "Invalid static IP: $STATIC_IP"
    exit 1
  fi
  if [[ ! "$LOGIN_USER" =~ ^([a-z_][a-z0-9_-]{0,31})?$ ]]; then
    print_error "Invalid username: $LOGIN_USER"
    exit 1
  fi
  DISK_SIZE=${DISK_SIZE^^}
  if [[ ! "$MEMORY" =~ ^[0-9]+$ ]] || [ "$MEMORY" -lt 512 ]; then
    print_error "Memory must be at least 512 (MB)"
    exit 1
  fi
  if [[ ! "$CPUS" =~ ^[1-9][0-9]{0,2}$ ]]; then
    print_error "vCPUs must be a number from 1"
    exit 1
  fi
  if [[ ! "$DISK_SIZE" =~ ^[1-9][0-9]*[GMT]$ ]]; then
    print_error "Disk size must look like 20G"
    exit 1
  fi
}

build_virt_install_opts() {
  validate_iso_options
  # No bus or NIC model: libosinfo picks what the detected OS has drivers for (Windows has no virtio).
  VIRT_INSTALL_OPTS=(
    --name "$VM_NAME"
    --memory "$MEMORY"
    --vcpus "$CPUS"
    --disk "path=$DISK_PATH,format=qcow2"
    --disk "path=$INSTALL_ISO,device=cdrom,readonly=on"
    --network "network=$NETWORK_NAME"
    --boot "$([ "$UEFI" = true ] && echo uefi,)$BOOT_ORDER"
    --import
    --noautoconsole
  )

  if [ "$GRAPHICS" = "none" ]; then
    VIRT_INSTALL_OPTS+=(--graphics none --console pty,target_type=serial)
  else
    VIRT_INSTALL_OPTS+=(--graphics "$GRAPHICS,listen=127.0.0.1") # VNC listens on 127.0.0.1 for security - use SSH tunnel for remote access
  fi
  VIRT_INSTALL_OPTS+=(--os-variant "${OS_VARIANT:-detect=on,require=off}")
}

run_virt_install() {
  local cmd=(virt-install "${VIRT_INSTALL_OPTS[@]}")
  if [ "$(caller_role)" != root ] && [ "$GRAPHICS" != none ]; then
    VNC_PW=$(vnc_password)
    cmd=(virt_install_with_vnc_password "$VNC_PW" "${cmd[@]}")
  fi
  ui_run "Starting VM" "${cmd[@]}" || {
    ui_step fail "VM" "virt-install failed"
    sed 's/^/    /' "$UI_RUN_LOG" | tail -10
    grep -qi 'uefi\|firmware' "$UI_RUN_LOG" && [ "$UEFI" = true ] &&
      echo -e "  ${DIM}UEFI needs OVMF on the host: ovmf (Debian, Ubuntu) or edk2-ovmf (Fedora, Arch)${NC}"
    exit 1
  }
  DEFINED=true
  [ -n "$STATIC_IP" ] && save_static_ip "$VM_NAME" "$STATIC_IP"
  virsh autostart "$VM_NAME" >/dev/null 2>&1 || true
  register_vm "$VM_NAME" "source=iso" "user=$LOGIN_USER" "cpus=$CPUS" "memory_mb=$MEMORY" "disk_gb=$(size_gb "$DISK_SIZE")" \
    "expires=${TTL_SECONDS:+$(($(date +%s) + TTL_SECONDS))}"
  ui_step ok "VM" "defined and booting the ISO"
  [ -n "${VNC_PW:-}" ] && ui_step ok "${GRAPHICS^^}" "password $VNC_PW (dcvm network vnc status $VM_NAME shows it again)"
}

save_vm_info() {
  cat >"$VM_DIR/vm-info.txt" <<EOF
VM_NAME=$VM_NAME
CREATED=$(date '+%Y-%m-%d %H:%M:%S')
ISO=$INSTALL_ISO
MEMORY=$MEMORY
CPUS=$CPUS
DISK_SIZE=$DISK_SIZE
STATIC_IP=$STATIC_IP
NETWORK=$NETWORK_NAME
EOF
}

show_post_creation_info() {
  local subnet="${NETWORK_SUBNET:-10.10.10}"
  if [ -n "$STATIC_IP" ]; then
    ui_box "$VM_NAME is running the installer" \
      "$(printf '%-11s%s' Address "$STATIC_IP/24")" \
      "$(printf '%-11s%s' Gateway "$subnet.1")" \
      "$(printf '%-11s%s' DNS "8.8.8.8, 8.8.4.4")"
  else
    ui_box "$VM_NAME is running the installer" "$(printf '%-11s%s' Network "DHCP on $NETWORK_NAME")"
  fi
  if [ "$GRAPHICS" = "none" ]; then
    ui_next "dcvm console $VM_NAME" "the installer, on the serial console (if the ISO uses one)" \
      "dcvm network ports add $VM_NAME" "after the install: reach it from other machines"
  else
    ui_next "dcvm network vnc status $VM_NAME" "the VNC port of the installer (127.0.0.1 only)" \
      "dcvm network ports add $VM_NAME" "after the install: reach it from other machines"
  fi
}

print_result() {
  local ip="" ready=null display=""
  if [ "$WAIT" = true ]; then
    if ip=$(wait_for_vm "$VM_NAME" 1800); then
      ready=true
      ui_step ok "Ready" "SSH answers on $ip"
    else
      ready=false
      ui_step warn "Ready" "SSH did not answer within 30 minutes; the VM exists (dcvm info $VM_NAME)"
    fi
  fi
  [ "$JSON" = true ] || {
    show_post_creation_info
    [ "$ready" != false ]
    return
  }
  [ -n "$ip" ] || ip=$(get_vm_ip "$VM_NAME")
  valid_vm_ip "$ip" || ip=""
  [ "$GRAPHICS" = none ] || display=$(virsh domdisplay "$VM_NAME" 2>/dev/null | head -1)
  printf '{"name":"%s","state":"%s","ip":%s,"user":%s,"expires":%s,"ready":%s,"display":%s,"display_password":%s}\n' \
    "$VM_NAME" "$(get_vm_state "$VM_NAME")" "$([ -n "$ip" ] && echo "\"$ip\"" || echo null)" \
    "$([ -n "$LOGIN_USER" ] && echo "\"$LOGIN_USER\"" || echo null)" "$(registry_get "$VM_NAME" expires | grep . || echo null)" \
    "$ready" "$([ -n "$display" ] && echo "\"$display\"" || echo null)" "$([ -n "${VNC_PW:-}" ] && echo "\"$VNC_PW\"" || echo null)" >&3
  [ "$ready" != false ]
}

# Undo a create that stopped half way: everything here was made by this run.
undo_on_failure() {
  [ $? -ne 0 ] && [ "${STARTED:-false}" = true ] && [ "${DEFINED:-false}" = false ] || return
  virsh destroy "$VM_NAME" >/dev/null 2>&1
  virsh undefine "$VM_NAME" --nvram >/dev/null 2>&1 || virsh undefine "$VM_NAME" >/dev/null 2>&1
  [ "${DISK_MADE:-false}" = true ] && rm -f "$DISK_PATH"
  [ "${ISO_COPIED:-false}" = true ] && rm -f "$VM_DIR/installer.iso"
  rmdir "$DATACENTER_BASE/vms/$VM_NAME" 2>/dev/null
}

main() {
  parse_args "$@"
  load_dcvm_config
  if [ -n "${TTL:-}" ] && ! TTL_SECONDS=$(ttl_seconds "$TTL"); then
    print_error "--ttl must look like 90m, 2h or 3d"
    exit 1
  fi
  [ "${DCVM_ORIGIN:-terminal}" = agent ] && [ ! -t 0 ] && FORCE_MODE=true
  [ "$JSON" = true ] && exec 3>&1 1>&2

  if [ -z "$VM_NAME" ]; then
    show_usage
    exit 1
  fi
  validate_vm_name "$VM_NAME" || exit 1

  check_iso_dependencies
  prompt_iso_path
  validate_vm_not_exists
  if [ -e "$DATACENTER_BASE/vms/$VM_NAME/$VM_NAME-disk.qcow2" ]; then
    print_error "$DATACENTER_BASE/vms/$VM_NAME already has a disk; remove it or pick another name"
    exit 1
  fi
  show_iso_header
  if [ "$FORCE_MODE" = true ]; then
    MEMORY=${MEMORY:-2048} CPUS=${CPUS:-2} DISK_SIZE=${DISK_SIZE:-20G} COPY_ISO=${COPY_ISO:-false}
  else
    collect_vm_options
  fi
  validate_iso_options
  show_vm_summary
  [ "$FORCE_MODE" = true ] || confirm_creation
  within_quota "$CPUS" "$MEMORY" "$(size_gb "$DISK_SIZE")" || exit 1
  if [ -n "$STATIC_IP" ]; then
    # ponytail: two creates naming the same new --ip at once can both pass; lock on the address if that matters.
    claim_static_ip "$VM_NAME" "$STATIC_IP" || exit 1
  fi
  STARTED=true
  trap undo_on_failure EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM HUP
  prepare_vm_directory
  copy_iso_if_needed
  validate_iso_size
  check_iso_accessibility
  create_vm_disk
  build_virt_install_opts
  run_virt_install
  save_vm_info
  print_result
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
