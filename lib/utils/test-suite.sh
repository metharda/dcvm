#!/usr/bin/env bash

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh" 2>/dev/null || {
  echo "Error: Cannot source common.sh"
  exit 1
}

TEST_VM_NAME="dcvm-test-vm-$$"
TEST_RESULTS=()
PASSED=0
FAILED=0
SKIPPED=0
WARNINGS=0
START_TIME=$(date +%s)
QUICK_MODE=false
FULL_MODE=false
SYNTAX_ONLY=false
UNIT_ONLY=false
INTEGRATION_ONLY=false
VERBOSE=false
INSTALL_DEPS=false

readonly C_PASS="${GREEN}"
readonly C_FAIL="${RED}"
readonly C_SKIP="${YELLOW}"
readonly C_WARN="${YELLOW}"
readonly C_INFO="${BLUE}"
readonly C_RESET="${NC}"

show_test_usage() {
  cat <<-EOF
	dcvm Comprehensive Test Suite
	
	Usage: $0 [options]
	
	Options:
	  --quick        Run quick tests only (no VM creation, no root required)
	  --full         Run full tests including VM creation/deletion
	  --syntax       Run syntax checks only
	  --unit         Run unit tests only (common.sh functions)
	  --integration  Run integration tests only (requires root)
	  --verbose      Show detailed output
	  --install-deps Install missing test tools with the package manager (sudo)
	  --help         Show this help
	
	Test Categories:
	  1. Syntax checks          All .sh files
	  2. Shellcheck analysis    Static analysis
	  3. Configuration          Config files and directories
	  4. Dependencies           Required and optional commands
	  5. Common functions       validate_*, format_*, generate_*
	  6. Libvirt tests          Service, network, VM operations
	  7. CLI tests              All dcvm commands and help
	  8. Network tests          Ports, DHCP, VNC
	  9. Storage tests          Backup, template, storage commands
	  10. VM lifecycle          Create, start, stop, delete (--full only)
	
	Examples:
	  $0 --quick           # Fast validation without root
	  sudo $0 --full       # Complete test with VM operations
	  $0 --syntax          # Check all scripts for syntax errors
	  $0 --unit            # Test common.sh functions only
	EOF
}

log_test() {
  local status="$1"
  local test_name="$2"
  local message="${3:-}"
  local duration="${4:-}"

  case "$status" in
  PASS)
    echo -e "${C_PASS}[PASS]${C_RESET} $test_name ${duration:+(${duration}ms)}"
    ((PASSED++))
    ;;
  FAIL)
    echo -e "${C_FAIL}[FAIL]${C_RESET} $test_name ${message:+- $message}"
    ((FAILED++))
    ;;
  SKIP)
    echo -e "${C_SKIP}[SKIP]${C_RESET} $test_name ${message:+- $message}"
    ((SKIPPED++))
    ;;
  WARN)
    echo -e "${C_WARN}[WARN]${C_RESET} $test_name ${message:+- $message}"
    ((WARNINGS++))
    ;;
  INFO)
    echo -e "${C_INFO}[INFO]${C_RESET} $test_name"
    ;;
  esac

  TEST_RESULTS+=("$status|$test_name|$message")
}

install_missing_test_deps() {
  local family cmd pkg missing_pkgs=() sudo=()
  family=$(distro_family)
  for cmd in openssl genisoimage jq shellcheck xmlstarlet qemu-img; do
    command -v "$cmd" &>/dev/null && continue
    case "$family:$cmd" in
    debian:qemu-img) pkg=qemu-utils ;;
    arch:genisoimage) pkg=cdrtools ;;
    fedora:shellcheck) pkg=ShellCheck ;;
    *) pkg=$cmd ;;
    esac
    missing_pkgs+=("$pkg")
  done

  if [ ${#missing_pkgs[@]} -eq 0 ]; then
    return 0
  fi

  echo -e "${C_INFO}[INFO]${C_RESET} Installing missing test dependencies: ${missing_pkgs[*]}"
  [ "$EUID" -eq 0 ] || sudo=(sudo)
  case "$family" in
  debian) "${sudo[@]}" apt-get update -qq &>/dev/null && "${sudo[@]}" apt-get install -y -qq "${missing_pkgs[@]}" &>/dev/null ;;
  fedora) "${sudo[@]}" dnf install -y -q "${missing_pkgs[@]}" &>/dev/null ;;
  arch) "${sudo[@]}" pacman -S --needed --noconfirm "${missing_pkgs[@]}" &>/dev/null ;;
  *) false ;;
  esac
  if [ $? -eq 0 ]; then
    echo -e "${C_PASS}[PASS]${C_RESET} Installed missing dependencies"
    return 0
  else
    echo -e "${C_WARN}[WARN]${C_RESET} Failed to install some dependencies"
    return 1
  fi
}

run_test() {
  local test_name="$1"
  shift
  local cmd="$*"
  local start_ms=$(date +%s%N)
  local output
  local exit_code

  output=$(eval "$cmd" 2>&1)
  exit_code=$?

  local end_ms=$(date +%s%N)
  local duration=$(((end_ms - start_ms) / 1000000))

  if [ $exit_code -eq 0 ]; then
    log_test "PASS" "$test_name" "" "$duration"
    return 0
  else
    log_test "FAIL" "$test_name" "Exit code: $exit_code"
    [ "$VERBOSE" = true ] && [ -n "$output" ] && echo "    Output: ${output:0:200}"
    return 1
  fi
}

run_test_expect_fail() {
  local test_name="$1"
  shift
  local cmd="$*"
  local output
  local exit_code

  output=$(eval "$cmd" 2>&1)
  exit_code=$?

  if [ $exit_code -ne 0 ]; then
    log_test "PASS" "$test_name (expected failure)"
    return 0
  else
    log_test "FAIL" "$test_name" "Expected failure but got success"
    return 1
  fi
}

run_test_output_contains() {
  local test_name="$1"
  local expected="$2"
  shift 2
  local cmd="$*"
  local output

  output=$(eval "$cmd" 2>&1)

  if echo "$output" | grep -q "$expected"; then
    log_test "PASS" "$test_name"
    return 0
  else
    log_test "FAIL" "$test_name" "Expected '$expected' in output"
    [ "$VERBOSE" = true ] && echo "    Output: ${output:0:200}"
    return 1
  fi
}

check_command_exists() {
  local cmd="$1"
  if command -v "$cmd" >/dev/null 2>&1; then
    return 0
  else
    return 1
  fi
}

require_root_for_test() {
  if [ "$EUID" -ne 0 ]; then
    log_test "SKIP" "$1" "Requires root privileges"
    return 1
  fi
  return 0
}

get_dcvm_cmd() {
  local dcvm_cmd="${SCRIPT_DIR}/../../dcvm"
  if [ ! -x "$dcvm_cmd" ]; then
    if check_command_exists dcvm; then
      echo "dcvm"
    else
      echo ""
    fi
  else
    echo "$dcvm_cmd"
  fi
}

test_syntax_all_scripts() {
  echo ""
  log_test "INFO" "═══ SYNTAX CHECKS ═══"

  local lib_dir="${SCRIPT_DIR}/.."
  local scripts=(
    "$lib_dir/core/create-vm.sh"
    "$lib_dir/core/custom-iso.sh"
    "$lib_dir/core/delete-vm.sh"
    "$lib_dir/core/vm-manager.sh"
    "$lib_dir/network/network-manager.sh"
    "$lib_dir/network/port-forward.sh"
    "$lib_dir/network/dhcp.sh"
    "$lib_dir/storage/backup.sh"
    "$lib_dir/storage/storage-manager.sh"
    "$lib_dir/utils/common.sh"
    "$lib_dir/utils/fix-lock.sh"
    "$lib_dir/utils/doctor.sh"
    "$lib_dir/utils/mirror-manager.sh"
    "$lib_dir/utils/dcvm-completion.sh"
    "$lib_dir/utils/test-suite.sh"
    "$lib_dir/installation/install-dcvm.sh"
    "$lib_dir/installation/self-update.sh"
    "$lib_dir/installation/uninstall-dcvm.sh"
    "${SCRIPT_DIR}/../../dcvm"
  )

  for script in "${scripts[@]}"; do
    if [ -f "$script" ]; then
      local name=$(basename "$script")
      if bash -n "$script" 2>/dev/null; then
        log_test "PASS" "Syntax: $name"
      else
        local error=$(bash -n "$script" 2>&1 | head -1)
        log_test "FAIL" "Syntax: $name" "$error"
      fi
    else
      log_test "SKIP" "Syntax: $(basename "$script")" "File not found"
    fi
  done
}

test_shellcheck() {
  echo ""
  log_test "INFO" "═══ SHELLCHECK ANALYSIS ═══"

  if ! check_command_exists shellcheck; then
    log_test "SKIP" "Shellcheck analysis" "shellcheck not installed"
    return
  fi

  local lib_dir="${SCRIPT_DIR}/.."
  local error_count=0

  while IFS= read -r -d '' script; do
    local name
    name=$(basename "$script")
    local errors
    errors=$(shellcheck --severity=error "$script" 2>&1 | grep -c "error" || true)
    if [ "$errors" -eq 0 ]; then
      log_test "PASS" "Shellcheck: $name"
    else
      log_test "FAIL" "Shellcheck: $name" "$errors error(s)"
      ((error_count += errors))
    fi
  done < <(find "$lib_dir" -type f -name '*.sh' -print0)
}

test_grep_count_fallback() {
  echo ""
  log_test "INFO" "═══ GREP -c FALLBACK ═══"

  local hits
  hits=$(grep -rnE 'grep -c[^|]*\|\|[[:space:]]*echo' "${SCRIPT_DIR}/.." "${SCRIPT_DIR}/../../dcvm" 2>/dev/null |
    grep -v '/test-suite.sh:' || true)
  if [ -z "$hits" ]; then
    log_test "PASS" "No 'grep -c ... || echo' double output"
  else
    log_test "FAIL" "'grep -c ... || echo' prints the count twice; use '|| true'" "$(echo "$hits" | head -1)"
  fi
}

test_configuration() {
  echo ""
  log_test "INFO" "═══ CONFIGURATION TESTS ═══"

  if [ -f "/etc/dcvm-install.conf" ]; then
    log_test "PASS" "Config file exists"

    if [ -r "/etc/dcvm-install.conf" ]; then
      log_test "PASS" "Config file readable"
    else
      log_test "FAIL" "Config file readable"
    fi

    source /etc/dcvm-install.conf 2>/dev/null
    [ -n "$DATACENTER_BASE" ] && log_test "PASS" "DATACENTER_BASE: $DATACENTER_BASE" || log_test "WARN" "DATACENTER_BASE not defined"
    [ -n "$NETWORK_NAME" ] && log_test "PASS" "NETWORK_NAME: $NETWORK_NAME" || log_test "WARN" "NETWORK_NAME not defined"
    [ -n "$NETWORK_SUBNET" ] && log_test "PASS" "NETWORK_SUBNET: $NETWORK_SUBNET" || log_test "WARN" "NETWORK_SUBNET not defined"
    [ -n "$BRIDGE_NAME" ] && log_test "PASS" "BRIDGE_NAME: $BRIDGE_NAME" || log_test "WARN" "BRIDGE_NAME not defined"
    [ -n "$DCVM_LIB_DIR" ] && log_test "PASS" "DCVM_LIB_DIR: $DCVM_LIB_DIR" || log_test "WARN" "DCVM_LIB_DIR not defined"
  else
    log_test "SKIP" "Config file tests" "dcvm not installed"
  fi
}

test_directory_structure() {
  echo ""
  log_test "INFO" "═══ DIRECTORY STRUCTURE TESTS ═══"

  local datacenter_base="${DATACENTER_BASE:-/srv/datacenter}"

  local dirs=(
    "$datacenter_base"
    "$datacenter_base/vms"
    "$datacenter_base/storage"
    "$datacenter_base/storage/templates"
    "$datacenter_base/backups"
    "$datacenter_base/config"
    "$datacenter_base/config/network"
  )

  for dir in "${dirs[@]}"; do
    if [ -d "$dir" ]; then
      log_test "PASS" "Directory exists: $dir"
      if [ "$EUID" -eq 0 ]; then
        local owner=$(stat -c '%U' "$dir" 2>/dev/null)
        [ "$owner" = "root" ] && log_test "PASS" "Directory owned by root: $dir" || log_test "WARN" "Directory not owned by root: $dir"
      fi
    else
      log_test "WARN" "Directory missing: $dir"
    fi
  done
}

test_dependencies() {
  echo ""
  log_test "INFO" "═══ DEPENDENCY TESTS ═══"

  local required_always=(
    "bash"
    "openssl"
    "bc"
    "sed"
    "awk"
    "grep"
  )

  local required_network=(
    "curl"
    "wget"
  )

  local required_virtualization=(
    "virsh"
    "virt-install"
    "qemu-img"
    "virt-customize"
  )

  local required_iso=(
    "mkisofs:genisoimage"
  )

  local optional_commands=(
    "shellcheck"
    "aria2c"
    "jq"
    "xz"
    "tar"
  )

  echo "  Required (always):"
  for cmd in "${required_always[@]}"; do
    if check_command_exists "$cmd"; then
      log_test "PASS" "Required: $cmd"
    else
      log_test "FAIL" "Required: $cmd" "Not found"
    fi
  done

  echo "  Required (network - at least one):"
  local has_network=false
  for cmd in "${required_network[@]}"; do
    if check_command_exists "$cmd"; then
      log_test "PASS" "Network: $cmd"
      has_network=true
    else
      log_test "WARN" "Network: $cmd" "Not found"
    fi
  done
  [ "$has_network" = false ] && log_test "FAIL" "Network tools" "Neither curl nor wget found"

  echo "  Required (virtualization):"
  for cmd in "${required_virtualization[@]}"; do
    if check_command_exists "$cmd"; then
      log_test "PASS" "Virtualization: $cmd"
    else
      if [ "$QUICK_MODE" = true ]; then
        log_test "WARN" "Virtualization: $cmd" "Not found (skipped in --quick)"
      else
        log_test "FAIL" "Virtualization: $cmd" "Not found"
      fi
    fi
  done

  echo "  Required (ISO creation - at least one):"
  local has_iso=false
  for cmd_pair in "${required_iso[@]}"; do
    IFS=':' read -ra cmds <<<"$cmd_pair"
    for cmd in "${cmds[@]}"; do
      if check_command_exists "$cmd"; then
        log_test "PASS" "ISO tool: $cmd"
        has_iso=true
        break
      fi
    done
  done
  [ "$has_iso" = false ] && log_test "FAIL" "ISO tools" "Neither mkisofs nor genisoimage found"

  echo "  Optional:"
  for cmd in "${optional_commands[@]}"; do
    if check_command_exists "$cmd"; then
      log_test "PASS" "Optional: $cmd"
    else
      log_test "WARN" "Optional: $cmd" "Not found"
    fi
  done
}

test_libvirt() {
  echo ""
  log_test "INFO" "═══ LIBVIRT TESTS ═══"

  if ! require_root_for_test "libvirt tests"; then
    return
  fi

  if systemctl is-active --quiet libvirtd 2>/dev/null; then
    log_test "PASS" "libvirtd service running"
  else
    log_test "FAIL" "libvirtd service running" "Service not active"
    return
  fi

  if systemctl is-enabled --quiet libvirtd 2>/dev/null; then
    log_test "PASS" "libvirtd service enabled"
  else
    log_test "WARN" "libvirtd service enabled" "Service not enabled for autostart"
  fi

  if virsh list >/dev/null 2>&1; then
    log_test "PASS" "virsh connection"
  else
    log_test "FAIL" "virsh connection" "Cannot connect to libvirt"
    return
  fi

  local network_name="${NETWORK_NAME:-datacenter-net}"
  if virsh net-info "$network_name" >/dev/null 2>&1; then
    log_test "PASS" "Network exists: $network_name"

    if virsh net-list --name | grep -q "$network_name"; then
      log_test "PASS" "Network active: $network_name"
    else
      log_test "WARN" "Network active: $network_name" "Not active"
    fi

    if virsh net-info "$network_name" 2>/dev/null | grep -q "Autostart:.*yes"; then
      log_test "PASS" "Network autostart: $network_name"
    else
      log_test "WARN" "Network autostart: $network_name" "Autostart disabled"
    fi
  else
    log_test "WARN" "Network exists: $network_name" "Not found"
  fi

  local bridge_name="${BRIDGE_NAME:-virbr-dc}"
  if ip link show "$bridge_name" >/dev/null 2>&1; then
    log_test "PASS" "Bridge exists: $bridge_name"
  else
    log_test "WARN" "Bridge exists: $bridge_name" "Not found"
  fi

  if [ -c /dev/kvm ]; then
    log_test "PASS" "KVM device available"
    if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
      log_test "PASS" "KVM device accessible"
    else
      log_test "WARN" "KVM device accessible" "Permission issue"
    fi
  else
    log_test "WARN" "KVM device available" "/dev/kvm not found (VMs will be slow)"
  fi
}

test_get_vm_username_lookup() {
  local tmp result
  tmp=$(mktemp -d)

  result=$(DATACENTER_BASE="$tmp" get_vm_username "web-1")
  if [ "$result" = "admin" ]; then
    log_test "PASS" "get_vm_username (none recorded)"
  else
    log_test "FAIL" "get_vm_username (none recorded)" "got '$result'"
  fi

  mkdir -p "$tmp/vms/web-1/cloud-init"
  cat >"$tmp/vms/web-1/cloud-init/user-data" <<'EOF'
#cloud-config
hostname: web-1
users:
  - name: dbadmin
    sudo: ['ALL=(ALL) NOPASSWD:ALL']
write_files:
  - content: |
      VM_USERNAME="dbadmin"
final_message: |
  Username: dbadmin
EOF

  result=$(DATACENTER_BASE="$tmp" get_vm_username "web-1")
  if [ "$result" = "dbadmin" ]; then
    log_test "PASS" "get_vm_username (recorded in user-data)"
  else
    log_test "FAIL" "get_vm_username (recorded in user-data)" "got '$result'"
  fi

  cat >"$tmp/vms/web-1/cloud-init/user-data" <<'EOF'
#cloud-config
write_files:
  - content: |
      VM_USERNAME="poweruser"
EOF

  result=$(DATACENTER_BASE="$tmp" get_vm_username "web-1")
  if [ "$result" = "poweruser" ]; then
    log_test "PASS" "get_vm_username (VM_USERNAME fallback)"
  else
    log_test "FAIL" "get_vm_username (VM_USERNAME fallback)" "got '$result'"
  fi

  rm -rf "$tmp"
}

test_dhcp_cleanup_dispatch() {
  local dhcp_sh="$SCRIPT_DIR/../network/dhcp.sh"
  local stubs="load_dcvm_config() { :; }; require_root() { :; }; check_dependencies() { :; }; clear_stale_leases() { echo STALE_CALLED; }"
  run_test_output_contains "dhcp.sh cleanup runs clear_stale_leases" "STALE_CALLED" "(source '$dhcp_sh'; $stubs; main cleanup)"
  run_test_output_contains "dhcp.sh help lists cleanup" "cleanup" "(source '$dhcp_sh'; $stubs; main help)"
  run_test_expect_fail "dhcp.sh unknown subcommand" "(source '$dhcp_sh'; $stubs; main no-such-subcommand)"
  local clear_stubs="clear_all_leases() { echo ALL_CALLED; }; clear_lease_by_mac() { echo MAC_CALLED \$1; }; clear_vm_lease() { echo VM_CALLED \$1; }; restart_network() { :; }"
  run_test_output_contains "dhcp.sh clear --all (vm-manager clear-leases)" "ALL_CALLED" "(source '$dhcp_sh'; $stubs; $clear_stubs; main clear --all)"
  run_test "no internal callers use removed dhcp subcommands" "! grep -nE 'dhcp\\.sh\\\" (clear-mac|clear-vm|clear-all)' '$SCRIPT_DIR/../core/delete-vm.sh' '$SCRIPT_DIR/../core/vm-manager.sh'"
  run_test "completion has no removed dhcp subcommands" "! grep -nE 'clear-(mac|vm|all)' '$SCRIPT_DIR/dcvm-completion.sh'"
  run_test_output_contains "completion: dhcp clear offers VM names and lease MACs" "vm1 52:54:00:ab:cd:ef" "(source '$SCRIPT_DIR/dcvm-completion.sh'; _dcvm_vm_list() { echo vm1; }; _dcvm_lease_macs() { echo 52:54:00:ab:cd:ef; }; COMP_WORDS=(dcvm network dhcp clear ''); COMP_CWORD=4; _dcvm_completion; echo \"\${COMPREPLY[*]}\")"
  run_test_output_contains "completion: backup restore date offers latest" "latest" "(source '$SCRIPT_DIR/dcvm-completion.sh'; _dcvm_backup_dates_for_vm() { echo 20260101_120000; }; COMP_WORDS=(dcvm backup restore vm1 ''); COMP_CWORD=4; _dcvm_completion; echo \"\${COMPREPLY[*]}\")"
}

# shellcheck disable=SC2034,SC2317 # stubs are called by delete_single_vm
test_delete_vm_keeps_network() {
  local t out
  t=$(mktemp -d)
  out=$(
    HOME="$t"
    # shellcheck source=../core/delete-vm.sh
    source "$SCRIPT_DIR/../core/delete-vm.sh" >/dev/null 2>&1
    DATACENTER_BASE="$t" NETWORK_NAME=datacenter-net BRIDGE_NAME=virbr-dc
    virsh() {
      echo "virsh $*" >>"$t/calls"
      case "$1" in
      net-dhcp-leases) echo " 2026-10-08 12:00:00  52:54:00:ab:cd:ef  ipv4  10.10.10.60/24  dcvm-deltest  -" ;;
      esac
      return 0
    }
    bash() {
      echo "bash $*" >>"$t/calls"
      case "$1" in
      *dhcp.sh)
        (
          f="$1"
          shift
          source "$f"
          load_dcvm_config() { :; }
          require_root() { :; }
          check_dependencies() { :; }
          BRIDGE_NAME=dcvm-test-no-such-bridge
          main "$@"
        ) >/dev/null 2>&1 </dev/null
        ;;
      esac
      return 0
    }
    restart_network() { echo "restart_network" >>"$t/calls"; }
    cleanup_dhcp_lease() { echo "cleanup_dhcp_lease $*" >>"$t/calls"; }
    check_vm_exists() { return 0; }
    get_vm_mac() { echo 52:54:00:ab:cd:ef; }
    get_vm_disk_path() { :; }
    get_vm_ip() { :; }
    get_port_mappings_file() { echo "$t/port-mappings.txt"; }
    stop_vm_gracefully() { :; }
    cleanup_port_forwarding_for_vm() { :; }
    systemctl() { :; }
    sleep() { :; }
    delete_single_vm dcvm-deltest 2>&1
  )
  if grep -qx 'cleanup_dhcp_lease 52:54:00:ab:cd:ef dcvm-deltest' "$t/calls" 2>/dev/null &&
    ! grep -qE '^bash .*dhcp\.sh|^restart_network' "$t/calls"; then
    log_test "PASS" "delete VM (cleanup_dhcp_lease only; no dhcp.sh clear, no restart_network)"
  else
    log_test "FAIL" "delete VM (cleanup_dhcp_lease only; no dhcp.sh clear, no restart_network)" "$(grep -E 'dhcp|restart' "$t/calls" 2>/dev/null | tr '\n' ';')"
  fi
  if [ -s "$t/calls" ] && ! grep -qE '^virsh net-(destroy|start)( |$)' "$t/calls"; then
    log_test "PASS" "delete VM (never calls virsh net-destroy or net-start)"
  else
    log_test "FAIL" "delete VM (never calls virsh net-destroy or net-start)" "$(grep -E '^virsh net-' "$t/calls" 2>/dev/null | tr '\n' ';')"
  fi
  if echo "$out" | grep -qF 'They expire on their own; to remove stale leases now: dcvm network dhcp cleanup' &&
    ! echo "$out" | grep -q 'dhcp clear'; then
    log_test "PASS" "delete VM (lingering lease prints the dhcp cleanup hint, not clear <vm>)"
  else
    log_test "FAIL" "delete VM (lingering lease prints the dhcp cleanup hint, not clear <vm>)" "$(echo "$out" | grep -i lease | tr '\n' ';')"
  fi
  rm -rf "$t"
}

load_backup_sh_for_test() {
  local base="$1"
  local backup_sh="$SCRIPT_DIR/../storage/backup.sh"
  # shellcheck disable=SC2317 # stub: overrides builtin source while backup.sh loads
  source() {
    builtin source "$@" || return
    # shellcheck disable=SC2317
    load_dcvm_config() {
      DATACENTER_BASE="$base"
      NETWORK_NAME=datacenter-net
      NETWORK_SUBNET=10.10.10
      BRIDGE_NAME=virbr-dc
    }
  }
  # shellcheck source=../storage/backup.sh
  builtin source "$backup_sh" 2>/dev/null
  unset -f source
  # shellcheck disable=SC2034 # used by log() inside backup.sh
  LOG_FILE=/dev/null
}

stub_backup_tools() {
  local t="$1"
  # shellcheck disable=SC2317 # stub: invoked via PATH/function override from restore_vm
  virsh() {
    echo "virsh $*" >>"$t/calls"
    case "$1" in
    list) cat "$t/list" 2>/dev/null ;;
    dominfo)
      grep -q " ${*: -1} " "$t/list" 2>/dev/null
      return
      ;;
    define)
      cp "$2" "$t/defined.xml"
      printf ' -    %s    shut off\n' "$(sed -n 's|.*<name>\(.*\)</name>.*|\1|p' "$2" | head -1)" >>"$t/list"
      ;;
    domstate) cat "$t/state" 2>/dev/null || echo running ;;
    shutdown | destroy) echo "shut off" >"$t/state" ;;
    start) echo running >"$t/state" ;;
    dumpxml) echo "<domain><name>${*: -1}</name></domain>" ;;
    capabilities) cat "$t/caps" 2>/dev/null ;;
    esac
    return 0
  }
  # shellcheck disable=SC2317
  qemu-img() { echo "qemu-img $*" >>"$t/calls"; }
  # shellcheck disable=SC2317
  check_disk_image() { :; }
  # shellcheck disable=SC2317
  virt-customize() { echo "virt-customize ${LIBGUESTFS_BACKEND:+backend=$LIBGUESTFS_BACKEND }$*" >>"$t/calls"; }
  # shellcheck disable=SC2317
  sleep() { :; }
}

test_hosts_rename_sed_expr() {
  local t out
  t=$(mktemp -d)
  printf '127.0.1.1\tvm1 vm1\n127.0.1.1 vm1 vm1.local\n' >"$t/hosts"
  out=$(
    load_backup_sh_for_test "$t"
    expr=$(hosts_rename_sed_expr vm1 vm1-copy)
    echo "--once"
    sed -E -e "$expr" "$t/hosts"
    echo "--twice"
    sed -E -e "$expr" -e "$expr" "$t/hosts"
  )
  if echo "$out" | sed -n '/^--once/,/^--twice/p' | grep -q $'^127.0.1.1\tvm1-copy vm1$'; then
    log_test "PASS" "hosts_rename_sed_expr (one pass misses the adjacent duplicate)"
  else
    log_test "FAIL" "hosts_rename_sed_expr (one pass misses the adjacent duplicate)" "$out"
  fi
  if echo "$out" | sed -n '/^--twice/,$p' | grep -q $'^127.0.1.1\tvm1-copy vm1-copy$' &&
    echo "$out" | sed -n '/^--twice/,$p' | grep -q '^127.0.1.1 vm1-copy vm1-copy.local$'; then
    log_test "PASS" "hosts_rename_sed_expr (applied twice: 'vm1 vm1' and 'vm1 vm1.local')"
  else
    log_test "FAIL" "hosts_rename_sed_expr (applied twice)" "$out"
  fi
  rm -rf "$t"
}

test_backup_restore_in_place() {
  local t ts=20260101_120000 mode
  t=$(mktemp -d)
  mkdir -p "$t/backups/vm1-$ts" "$t/vms/vm1"
  echo backup-disk >"$t/backups/vm1-$ts/vm1-disk-$ts.qcow2"
  cat >"$t/backups/vm1-$ts/vm1-config-$ts.xml" <<EOF
<domain type='kvm'>
  <name>vm1</name>
  <os>
    <type arch='x86_64' machine='pc-q35-noble'>hvm</type>
  </os>
  <devices>
    <disk type='file' device='disk'>
      <source file='$t/vms/vm1/vm1-disk.qcow2'/>
    </disk>
    <controller type='pci' index='0' model='pcie-root'/>
    <interface type='network'>
      <mac address='52:54:00:11:22:33'/>
    </interface>
  </devices>
</domain>
EOF

  for mode in xmlstarlet sed; do
    if [ "$mode" = xmlstarlet ] && ! command -v xmlstarlet >/dev/null 2>&1; then
      log_test "SKIP" "backup restore in place ($mode)" "xmlstarlet not installed"
      continue
    fi
    echo original >"$t/vms/vm1/vm1-disk.qcow2"
    printf ' 1    vm1    running\n' >"$t/list"
    rm -f "$t/defined.xml"
    (
      load_backup_sh_for_test "$t"
      stub_backup_tools "$t"
      if [ "$mode" = sed ]; then
        # shellcheck disable=SC2317 # hide xmlstarlet to exercise the sed path
        command() {
          if [ "$1" = -v ] && [ "$2" = xmlstarlet ]; then return 1; fi
          builtin command "$@"
        }
      fi
      echo yes | restore_vm vm1 "$ts" >"$t/out" 2>&1
    )
    if grep -q "52:54:00:11:22:33" "$t/defined.xml" 2>/dev/null &&
      grep -qE "machine=['\"]q35['\"]" "$t/defined.xml"; then
      log_test "PASS" "backup restore in place keeps MAC, q35 machine ($mode)"
    else
      log_test "FAIL" "backup restore in place keeps MAC, q35 machine ($mode)" "$(grep -oE "machine=[^ >]*|address=[^ />]*" "$t/defined.xml" 2>/dev/null | tr '\n' ' ')"
    fi
  done

  echo original >"$t/vms/vm1/vm1-disk.qcow2"
  printf ' 1    vm1    running\n' >"$t/list"
  rm -f "$t/defined.xml"
  (
    load_backup_sh_for_test "$t"
    stub_backup_tools "$t"
    wget() { :; }
    main restore vm1 "$ts" --yes </dev/null >"$t/out" 2>&1
  )
  if [ -f "$t/defined.xml" ]; then
    log_test "PASS" "backup restore in place --yes replaces the VM without a terminal"
  else
    log_test "FAIL" "backup restore in place --yes replaces the VM without a terminal" "$(tail -2 "$t/out" | tr '\n' ' ')"
  fi

  rm -f "$t/defined.xml"
  (
    load_backup_sh_for_test "$t"
    stub_backup_tools "$t"
    restore_vm vm1 "$ts" "" "" vm1-copy </dev/null >/dev/null 2>&1
  )
  if [ -f "$t/defined.xml" ] && grep -q "<mac address=" "$t/defined.xml" &&
    ! grep -q "52:54:00:11:22:33" "$t/defined.xml"; then
    log_test "PASS" "backup restore <new_name> (new MAC)"
  else
    log_test "FAIL" "backup restore <new_name> (new MAC)"
  fi

  rm -rf "$t"
}

test_backup_restore_new_name() {
  local t ts=20260101_120000
  t=$(mktemp -d)
  mkdir -p "$t/backups/vm1-$ts" "$t/vms/vm1"
  echo backup-disk >"$t/backups/vm1-$ts/vm1-disk-$ts.qcow2"
  cat >"$t/backups/vm1-$ts/vm1-config-$ts.xml" <<EOF
<domain type='kvm'>
  <name>vm1</name>
  <os>
    <nvram>/var/lib/libvirt/qemu/nvram/vm1_VARS.fd</nvram>
  </os>
  <devices>
    <disk type='file' device='disk'>
      <source file='$t/vms/vm1/vm1-disk.qcow2'/>
    </disk>
    <interface type='network'>
      <mac address='52:54:00:11:22:33'/>
    </interface>
  </devices>
</domain>
EOF
  echo original >"$t/vms/vm1/vm1-disk.qcow2"
  printf ' 1    vm1    running\n' >"$t/list"

  (
    load_backup_sh_for_test "$t"
    stub_backup_tools "$t"
    restore_vm vm1 "$ts" "" "" vm1-copy </dev/null >"$t/out" 2>&1
    echo "rc=$?" >>"$t/out"
  )

  if grep -q '^rc=0$' "$t/out" && grep -q '<name>vm1-copy</name>' "$t/defined.xml" 2>/dev/null &&
    grep -q "$t/vms/vm1-copy/vm1-copy-disk.qcow2" "$t/defined.xml" &&
    [ "$(cat "$t/vms/vm1-copy/vm1-copy-disk.qcow2" 2>/dev/null)" = "backup-disk" ]; then
    log_test "PASS" "backup restore <vm> <date> <new_name> (defines new VM)"
  else
    log_test "FAIL" "backup restore <vm> <date> <new_name> (defines new VM)" "$(tail -1 "$t/out")"
  fi

  if [ "$(cat "$t/vms/vm1/vm1-disk.qcow2")" = "original" ] && ! grep -qE 'virsh (shutdown|destroy|undefine) vm1$' "$t/calls"; then
    log_test "PASS" "backup restore <new_name> (source VM untouched)"
  else
    log_test "FAIL" "backup restore <new_name> (source VM untouched)"
  fi

  if grep -q 'virt-customize .*--hostname vm1-copy' "$t/calls" &&
    grep -q "truncate -s 0 /etc/machine-id" "$t/calls" &&
    grep -q -- '--firstboot-command' "$t/calls"; then
    log_test "PASS" "backup restore <new_name> (hostname + machine-id + SSH host keys)"
  else
    log_test "FAIL" "backup restore <new_name> (hostname + machine-id + SSH host keys)" "$(grep virt-customize "$t/calls" | head -2)"
  fi

  echo 1000 >"$t/backups/vm1-$ts/owner"
  : >"$t/calls"
  (
    load_backup_sh_for_test "$t"
    stub_backup_tools "$t"
    mkisofs() { while [ $# -gt 0 ]; do
      [ "$1" = -output ] && echo seed >"$2"
      shift
    done; }
    DCVM_CALLER_ROLE=user DCVM_CALLER_UID=1000 restore_vm vm1 "$ts" "" "" "vm1-ucopy" </dev/null >"$t/out-user" 2>&1
  )
  rm -f "$t/backups/vm1-$ts/owner"
  if ! grep -q virt-customize "$t/calls" && grep -q '^local-hostname: vm1-ucopy$' "$t/vms/vm1-ucopy/cloud-init/meta-data" 2>/dev/null &&
    grep -q '^instance-id: vm1-ucopy-' "$t/vms/vm1-ucopy/cloud-init/meta-data" && grep -q 'systemd-machine-id-setup' "$t/vms/vm1-ucopy/cloud-init/user-data" &&
    [ -s "$t/vms/vm1-ucopy/cloud-init.iso" ] && grep -q 'attach-disk vm1-ucopy .*cloud-init.iso' "$t/calls"; then
    log_test "PASS" "backup restore <new_name> by a user (new cloud-init identity, no libguestfs on the user's disk)"
  else
    log_test "FAIL" "backup restore <new_name> by a user (new cloud-init identity, no libguestfs on the user's disk)" "$(tail -2 "$t/out-user" | tr '\n' ' ')"
  fi

  if ! grep -qi '<nvram' "$t/defined.xml" 2>/dev/null; then
    log_test "PASS" "backup restore <new_name> (nvram dropped from XML)"
  else
    log_test "FAIL" "backup restore <new_name> (nvram dropped from XML)"
  fi

  : >"$t/calls"
  if (
    load_backup_sh_for_test "$t"
    stub_backup_tools "$t"
    restore_vm vm1 "$ts" "" "" "bad'name" </dev/null >/dev/null 2>&1
  ); then
    log_test "FAIL" "backup restore <new_name> (invalid name rejected)" "Expected failure but got success"
  elif [ ! -s "$t/calls" ]; then
    log_test "PASS" "backup restore <new_name> (invalid name rejected)"
  else
    log_test "FAIL" "backup restore <new_name> (invalid name rejected)" "virsh was called"
  fi

  rm -f "$t/defined.xml"
  (
    load_backup_sh_for_test "$t"
    stub_backup_tools "$t"
    restore_vm vm1 01.01.2026-1 "" "" vm1-sel </dev/null >/dev/null 2>&1
  )
  if grep -q '<name>vm1-sel</name>' "$t/defined.xml" 2>/dev/null; then
    log_test "PASS" "backup restore (dd.mm.yyyy-N selector)"
  else
    log_test "FAIL" "backup restore (dd.mm.yyyy-N selector)"
  fi
  rm -f "$t/defined.xml"
  (
    load_backup_sh_for_test "$t"
    stub_backup_tools "$t"
    restore_vm vm1 vm1-01.01.2026-1 "" "" vm1-pfx </dev/null >"$t/out-pfx" 2>&1
  )
  if grep -q '<name>vm1-pfx</name>' "$t/defined.xml" 2>/dev/null && grep -q "backup $ts" "$t/out-pfx"; then
    log_test "PASS" "backup restore (<vm>-dd.mm.yyyy-N as backup list prints it)"
  else
    log_test "FAIL" "backup restore (<vm>-dd.mm.yyyy-N as backup list prints it)" "$(grep -i 'selector\|error' "$t/out-pfx" | head -2)"
  fi
  if (
    load_backup_sh_for_test "$t"
    stub_backup_tools "$t"
    restore_vm vm1 02.01.2026 "" "" vm1-none </dev/null >/dev/null 2>&1
  ); then
    log_test "FAIL" "backup restore (unknown selector)" "Expected failure but got success"
  else
    log_test "PASS" "backup restore (unknown selector) (expected failure)"
  fi

  rm -f "$t/defined.xml"
  (
    load_backup_sh_for_test "$t"
    stub_backup_tools "$t"
    restore_vm vm1 latest "" "" vm1-latest </dev/null >/dev/null 2>&1
  )
  if grep -q '<name>vm1-latest</name>' "$t/defined.xml" 2>/dev/null; then
    log_test "PASS" "backup restore (latest selector)"
  else
    log_test "FAIL" "backup restore (latest selector)"
  fi

  mkdir -p "$t/config/network"
  cat >"$t/config/network/vm1.conf" <<'NET'
VM_NAME="vm1"
IP="10.10.10.50"
ASSIGNED_AT="2026-01-01T00:00:00Z"
SOURCE="static"
NET
  rm -f "$t/defined.xml"
  : >"$t/calls"
  (
    load_backup_sh_for_test "$t"
    stub_backup_tools "$t"
    restore_vm vm1 "$ts" "" "" vm1-static </dev/null >"$t/out-static" 2>&1
    echo "rc=$?" >>"$t/out-static"
  )
  if grep -q '^rc=0$' "$t/out-static" &&
    grep -qi 'keeps static IP 10.10.10.50 from vm1' "$t/out-static" &&
    grep -qi "Not starting 'vm1-static'" "$t/out-static" &&
    ! grep -qE 'virsh start vm1-static$' "$t/calls" &&
    ! grep -qE 'virsh autostart vm1-static$' "$t/calls" && [ "$(registry_get vm1-static autostart)" = off ]; then
    log_test "PASS" "backup restore <new_name> (static IP copy skips start/autostart)"
  else
    log_test "FAIL" "backup restore <new_name> (static IP copy skips start/autostart)" "$(tail -5 "$t/out-static")"
  fi

  rm -f "$t/defined.xml"
  : >"$t/calls"
  (
    load_backup_sh_for_test "$t"
    stub_backup_tools "$t"
    # shellcheck disable=SC2317 # hide xmlstarlet to exercise the sed path
    command() {
      if [ "$1" = -v ] && [ "$2" = xmlstarlet ]; then return 1; fi
      builtin command "$@"
    }
    restore_vm vm1 "$ts" "" "" vm1-sed </dev/null >/dev/null 2>&1
  )
  if [ -f "$t/defined.xml" ] && ! grep -qi '<nvram' "$t/defined.xml"; then
    log_test "PASS" "backup restore <new_name> (nvram dropped via sed)"
  else
    log_test "FAIL" "backup restore <new_name> (nvram dropped via sed)"
  fi

  mkdir -p "$t/pkg"
  cp "$t/backups/vm1-$ts/vm1-disk-$ts.qcow2" "$t/backups/vm1-$ts/vm1-config-$ts.xml" "$t/pkg/"
  tar -czf "$t/pkg.tar.gz" -C "$t/pkg" .
  : >"$t/calls"
  if (
    load_backup_sh_for_test "$t"
    stub_backup_tools "$t"
    import_backup "$t/pkg.tar.gz" "../x" </dev/null >/dev/null 2>&1
  ); then
    log_test "FAIL" "backup import <pkg> <new_name> (invalid name rejected)" "Expected failure but got success"
  elif [ ! -s "$t/calls" ] && [ ! -e "$t/x" ] && ! ls -d "$t"/backups/*x* >/dev/null 2>&1; then
    log_test "PASS" "backup import <pkg> <new_name> (invalid name rejected before use)"
  else
    log_test "FAIL" "backup import <pkg> <new_name> (invalid name rejected before use)" "something was created or called"
  fi

  rm -rf "$t"
}

# shellcheck disable=SC2317 # stubs
test_backup_restore_safety() {
  local t ts=20260101_120000 cfg
  t=$(mktemp -d)
  mkdir -p "$t/backups/vm1-$ts" "$t/vms/vm1"
  echo backup-disk >"$t/backups/vm1-$ts/vm1-disk-$ts.qcow2"
  cfg="$t/backups/vm1-$ts/vm1-config-$ts.xml"
  cat >"$cfg" <<EOF
<domain type='kvm'>
  <name>vm1</name>
  <memory unit='KiB'>16777216</memory>
  <vcpu placement='static'>8</vcpu>
  <devices>
    <disk type='file' device='disk'><source file='$t/vms/vm1/vm1-disk.qcow2'/></disk>
  </devices>
</domain>
EOF
  cp "$cfg" "$t/good.xml"
  run() {
    echo original >"$t/vms/vm1/vm1-disk.qcow2"
    printf ' 1    vm1    running\n' >"$t/list"
    echo "$1" >"$t/state"
    : >"$t/calls"
    (
      load_backup_sh_for_test "$t"
      stub_backup_tools "$t"
      qemu-img() { echo '{"virtual-size": 10737418240}'; }
      eval "$2"
      restore_vm vm1 "$ts" true >"$t/out" 2>&1
    )
  }
  untouched() { [ "$(cat "$t/vms/vm1/vm1-disk.qcow2")" = original ] && ! grep -qE '^virsh (shutdown|destroy|undefine)' "$t/calls"; }

  : >"$cfg"
  if ! run running "" && untouched; then
    log_test "PASS" "backup restore (empty config refused before the VM is touched)"
  else
    log_test "FAIL" "backup restore (empty config refused before the VM is touched)" "$(tr '\n' ';' <"$t/calls")"
  fi
  cp "$t/good.xml" "$cfg"

  if ! run running 'DCVM_QUOTA_LIMITS="1 1024 20" DCVM_STATE_DIR="$t/qstate"' && untouched && grep -q 'Over your quota' "$t/out"; then
    log_test "PASS" "backup restore in place (quota checked before the VM is touched)"
  else
    log_test "FAIL" "backup restore in place (quota checked before the VM is touched)" "$(tail -2 "$t/out")"
  fi

  if run paused "" && grep -qx 'virsh destroy vm1' "$t/calls" &&
    [ "$(grep -n 'destroy vm1$' "$t/calls" | head -1 | cut -d: -f1)" -lt "$(grep -n 'undefine vm1' "$t/calls" | head -1 | cut -d: -f1)" ]; then
    log_test "PASS" "backup restore (paused VM is stopped before undefine)"
  else
    log_test "FAIL" "backup restore (paused VM is stopped before undefine)" "$(tr '\n' ';' <"$t/calls")"
  fi

  rm -f "$t/redefined.xml"
  if ! run "shut off" 'virsh() {
      echo "virsh $*" >>"$t/calls"
      case "$1" in
      dominfo) return 0 ;;
      domstate) cat "$t/state" ;;
      dumpxml) echo "<domain><name>vm1</name><!-- previous --></domain>" ;;
      define) grep -q previous "$2" && cp "$2" "$t/redefined.xml" || { echo "error: bad config"; return 1; } ;;
      esac
    }' && [ "$(cat "$t/vms/vm1/vm1-disk.qcow2")" = original ] && grep -q previous "$t/redefined.xml" 2>/dev/null &&
    [ ! -e "$t/vms/vm1/vm1-disk.qcow2.pre-restore" ]; then
    log_test "PASS" "backup restore (failed define puts the previous VM and disk back)"
  else
    log_test "FAIL" "backup restore (failed define puts the previous VM and disk back)" "$(tail -3 "$t/out" | tr '\n' ';')"
  fi

  mkdir -p "$t/pkg"
  cp "$t/backups/vm1-$ts/"* "$t/pkg/"
  tar -czf "$t/pkg.tar.gz" -C "$t/pkg" .
  echo keep >"$t/backups/vm1-$ts/owner"
  if ! (
    load_backup_sh_for_test "$t"
    restore_vm() {
      echo called >"$t/restored"
      return 1
    }
    import_backup "$t/pkg.tar.gz" </dev/null >/dev/null 2>&1
  ) && [ "$(cat "$t/backups/vm1-$ts/owner" 2>/dev/null)" = keep ] && [ ! -e "$t/restored" ]; then
    log_test "PASS" "backup import (refuses an existing backup folder, never deletes it)"
  else
    log_test "FAIL" "backup import (refuses an existing backup folder, never deletes it)"
  fi
  rm -rf "$t"
}

# shellcheck disable=SC2034,SC2317,SC2329 # stubs; DATE is read by backup_vm
test_backup_create_streams_disk() {
  local t
  t=$(mktemp -d)
  mkdir -p "$t/bin"
  # 64 MiB apparent size, about 1 MiB allocated: the free-space check must use the allocated size.
  head -c 1048576 /dev/urandom >"$t/disk.qcow2"
  truncate -s 64M "$t/disk.qcow2"
  run_backup() {
    load_backup_sh_for_test "$t"
    stub_backup_tools "$t"
    DATE=20260101_120000
    free_bytes() { echo $((8 * 1048576)); }
    get_vm_disk_path() { echo "$t/disk.qcow2"; }
    prepare_vm_disk() { :; }
    write_base_record() { :; }
    vm_owner_uid() { echo 0; }
    vm_login() { :; }
    cp() {
      echo "cp $*" >>"$t/calls"
      command cp "$@"
    }
    eval "${1:-}"
    backup_vm vm1 >"$t/out" 2>&1
    echo "rc=$?" >>"$t/out"
  }
  printf ' 1    vm1    running\n' >"$t/list"
  echo running >"$t/state"
  (run_backup)
  local f="$t/backups/vm1-20260101_120000/vm1-disk-20260101_120000.qcow2.gz"
  if grep -q '^rc=0$' "$t/out" && gunzip -c "$f" 2>/dev/null | cmp -s - "$t/disk.qcow2" &&
    [ "$(find "$t/backups" -name '*.qcow2' -o -name '*.part' | wc -l)" = 0 ] && ! grep -q '^cp ' "$t/calls"; then
    log_test "PASS" "backup create (streams the disk into .qcow2.gz, sized by allocated blocks)"
  else
    log_test "FAIL" "backup create (streams the disk into .qcow2.gz, sized by allocated blocks)" "$(grep -E 'rc=|Free space|cp ' "$t/out" "$t/calls" | tr '\n' ';')"
  fi

  rm -rf "$t/backups" "$t/calls"
  echo running >"$t/state"
  printf '#!/bin/sh\necho partial\nexit 1\n' >"$t/bin/gzip"
  chmod +x "$t/bin/gzip"
  cp "$t/bin/gzip" "$t/bin/pigz"
  (PATH="$t/bin:$PATH" run_backup)
  if grep -q '^rc=1$' "$t/out" && [ -z "$(ls -A "$t/backups" 2>/dev/null)" ] && grep -q 'virsh start vm1' "$t/calls"; then
    log_test "PASS" "backup create (failed compression leaves no partial file and restarts the VM)"
  else
    log_test "FAIL" "backup create (failed compression leaves no partial file and restarts the VM)" "$(tail -1 "$t/out"); $(find "$t/backups" 2>/dev/null | tr '\n' ' ')"
  fi

  rm -rf "$t/backups" "$t/calls"
  echo running >"$t/state"
  (run_backup 'eval "$(declare -f virsh | sed "1s/virsh/stub_virsh/")"; virsh() { [ "$1" = dumpxml ] && return 1; stub_virsh "$@"; }')
  if grep -q '^rc=1$' "$t/out" && ! grep -q 'Backup saved' "$t/out" && [ -z "$(ls -A "$t/backups" 2>/dev/null)" ] &&
    grep -q 'virsh start vm1' "$t/calls"; then
    log_test "PASS" "backup create (failed dumpxml is a failed backup: nothing kept, VM restarted)"
  else
    log_test "FAIL" "backup create (failed dumpxml is a failed backup: nothing kept, VM restarted)" "$(tail -1 "$t/out"); $(find "$t/backups" 2>/dev/null | tr '\n' ' ')"
  fi
  rm -rf "$t"
}

# shellcheck disable=SC2317 # stubs
test_backup_export_selectors() {
  local t ts=20260101_120000 sel r=""
  t=$(mktemp -d)
  mkdir -p "$t/backups/vm1-$ts"
  echo backup-disk >"$t/backups/vm1-$ts/vm1-disk-$ts.qcow2"
  echo '<domain><name>vm1</name></domain>' >"$t/backups/vm1-$ts/vm1-config-$ts.xml"
  for sel in latest vm1-01.01.2026-1; do
    rm -rf "$t/out"
    (
      load_backup_sh_for_test "$t"
      stub_backup_tools "$t"
      export_backup vm1 "$sel" "$t/out" </dev/null >/dev/null 2>&1
    )
    [ -f "$t/out/vm1-$ts.tar.gz" ] && r+="$sel "
  done
  if [ "$r" = "latest vm1-01.01.2026-1 " ]; then
    log_test "PASS" "backup export (latest and <vm>-dd.mm.yyyy-N selectors)"
  else
    log_test "FAIL" "backup export (latest and <vm>-dd.mm.yyyy-N selectors)" "resolved: $r"
  fi

  : >"$t/calls"
  (
    load_backup_sh_for_test "$t"
    stub_backup_tools "$t"
    wget() { :; }
    main export vm1 latest "$t/full" --full </dev/null >/dev/null 2>&1
  )
  if tar -xzOf "$t/full/vm1-$ts.tar.gz" ./manifest.txt 2>/dev/null | grep -qx 'disk=full' &&
    grep -q '^qemu-img convert -f qcow2 ' "$t/calls"; then
    log_test "PASS" "backup export --full (after the selector; convert names its input format)"
  else
    log_test "FAIL" "backup export --full (after the selector; convert names its input format)" "$(grep convert "$t/calls")"
  fi

  echo untouched >"$t/target"
  (
    load_backup_sh_for_test "$t"
    stub_backup_tools "$t"
    exec 7<"$t/target"
    DCVM_EXPORT_FD=7 export_backup vm1 </dev/null >/dev/null 2>&1
  )
  echo -n >"$t/target2"
  (
    load_backup_sh_for_test "$t"
    stub_backup_tools "$t"
    exec 7>"$t/target2"
    DCVM_EXPORT_FD=7 export_backup vm1 </dev/null >/dev/null 2>&1
  )
  if [ "$(cat "$t/target")" = untouched ] && tar -tzf "$t/target2" 2>/dev/null | grep -q manifest.txt; then
    log_test "PASS" "backup export to a descriptor (writes through it, never reopens /dev/fd/N)"
  else
    log_test "FAIL" "backup export to a descriptor (writes through it, never reopens /dev/fd/N)" "$(head -c 20 "$t/target" | od -c | head -1)"
  fi
  rm -rf "$t"
}

# shellcheck disable=SC2317 # stubs
test_backup_export_recompress() {
  local t ts=20260101_120000 real_gzip
  real_gzip=$(command -v gzip)
  t=$(mktemp -d)
  mkdir -p "$t/backups/vm1-$ts" "$t/bin"
  echo backup-disk | gzip >"$t/backups/vm1-$ts/vm1-disk-$ts.qcow2.gz"
  echo '<domain><name>vm1</name></domain>' >"$t/backups/vm1-$ts/vm1-config-$ts.xml"
  printf '#!/bin/sh\nexit 0\n' >"$t/bin/guestfish"
  # Fails only "gzip -c <file>" (the recompression); unpacking and tar's own gzip still work.
  printf '#!/bin/sh\n[ "$1" = -c ] && [ -f "$2" ] && exit 1\nexec %s "$@"\n' "$real_gzip" >"$t/bin/gzip"
  chmod +x "$t/bin/guestfish" "$t/bin/gzip"
  export_run() {
    (
      PATH="$1:$PATH"
      load_backup_sh_for_test "$t"
      stub_backup_tools "$t"
      export_backup vm1 latest "$t/out" </dev/null >"$t/log" 2>&1
    )
  }
  if ! export_run "$t/bin" && [ ! -e "$t/out/vm1-$ts.tar.gz" ]; then
    log_test "PASS" "backup export (failed recompression fails the export, no truncated disk packed)"
  else
    log_test "FAIL" "backup export (failed recompression fails the export, no truncated disk packed)" "$(tail -2 "$t/log" | tr '\n' ';')"
  fi
  rm -f "$t/bin/gzip"
  if export_run "$t/bin" && [ "$(tar -tzf "$t/out/vm1-$ts.tar.gz" | grep -c 'disk')" = 1 ] &&
    tar -xzOf "$t/out/vm1-$ts.tar.gz" "./vm1-disk-$ts.qcow2.gz" | gunzip | grep -qx backup-disk; then
    log_test "PASS" "backup export (cleaned disk recompressed in place, no temporary file packed)"
  else
    log_test "FAIL" "backup export (cleaned disk recompressed in place, no temporary file packed)" "$(tar -tzf "$t/out/vm1-$ts.tar.gz" 2>&1 | tr '\n' ' ')"
  fi
  rm -rf "$t"
}

# shellcheck disable=SC2317 # stubs
test_backup_builds_kept() {
  local t ts=20260101_120000 sha out
  t=$(mktemp -d)
  sha=$(printf 'a%.0s' {1..64})
  mkdir -p "$t/pkg" "$t/storage/templates/builds" "$t/backups"
  echo disk >"$t/pkg/vm1-disk-$ts.qcow2"
  echo '<domain><name>vm1</name></domain>' >"$t/pkg/vm1-config-$ts.xml"
  printf 'image=test.img\nbuild=/elsewhere/x.img\nsha256=%s\n' "$sha" >"$t/pkg/base"
  tar -czf "$t/pkg.tar.gz" -C "$t/pkg" .
  : >"$t/storage/templates/builds/test-aaaaaaaaaaaa.img"
  out=$(
    load_backup_sh_for_test "$t"
    restore_vm() { :; }
    import_backup "$t/pkg.tar.gz" >/dev/null 2>&1
    grep -qx "build=$t/storage/templates/builds/test-aaaaaaaaaaaa.img" "$t/backups/vm1-$ts/base" && echo "import records the local build"
    virsh() { :; }
    [ -z "$(prune_builds)" ] && echo "imported backup keeps its build"
    sed -i '/^build=/d' "$t/backups/vm1-$ts/base"
    [ -z "$(prune_builds)" ] && echo "older import keeps its build"
    rm -rf "$t/backups/vm1-$ts"
    virsh() { return 1; }
    [ -z "$(prune_builds)" ] && [ -f "$t/storage/templates/builds/test-aaaaaaaaaaaa.img" ] && echo "virsh failure keeps builds"
    virsh() { :; }
    [ "$(prune_builds)" = test-aaaaaaaaaaaa.img ] && echo "unused build deleted"
  )
  local want="import records the local build imported backup keeps its build older import keeps its build virsh failure keeps builds unused build deleted"
  if [ "$(echo $out)" = "$want" ]; then
    log_test "PASS" "builds: imported backups keep theirs, a failed virsh list prunes nothing"
  else
    log_test "FAIL" "builds: imported backups keep theirs, a failed virsh list prunes nothing" "got: $(echo $out)"
  fi
  rm -rf "$t"
}

test_backup_ssh_setup_ip_wait() {
  local t out
  t=$(mktemp -d)
  echo 0 >"$t/n"
  out=$(
    load_backup_sh_for_test "$t"
    HOME="$t"
    # shellcheck disable=SC2317
    sleep() { SECONDS=$((SECONDS + ${1:-1} + 120)); }
    # shellcheck disable=SC2317
    ssh-copy-id() { return 1; }
    # shellcheck disable=SC2317
    check_vm_exists() { return 0; }
    # shellcheck disable=SC2317
    get_vm_state() { echo running; }
    # shellcheck disable=SC2317
    get_vm_ip() {
      echo $(($(cat "$t/n") + 1)) >"$t/n"
      echo "N/A"
      return 1
    }
    ssh_setup_vm vm1-copy <<<"debian" 2>&1
    echo "rc=$?"
  )
  if echo "$out" | grep -q '^rc=1$' && echo "$out" | grep -q 'Could not determine VM IP' &&
    ! echo "$out" | grep -q 'Waiting for SSH on N/A'; then
    log_test "PASS" "ssh_setup_vm (N/A is treated as no IP)"
  else
    log_test "FAIL" "ssh_setup_vm (N/A is treated as no IP)"
  fi
  if [ "$(cat "$t/n" 2>/dev/null)" -ge 1 ] 2>/dev/null; then
    log_test "PASS" "ssh_setup_vm (polls get_vm_ip: $(cat "$t/n") lookups)"
  else
    log_test "FAIL" "ssh_setup_vm (polls get_vm_ip)" "n=$(cat "$t/n" 2>/dev/null)"
  fi
  rm -rf "$t"
}

# shellcheck disable=SC2034,SC2030,SC2031,SC2317,SC2016,SC1091 # stubs; globals are read by create-vm.sh
test_create_extra_packages_userdata() {
  local t ud
  t=$(mktemp -d)
  (
    source "$SCRIPT_DIR/../core/create-vm.sh" >/dev/null 2>&1
    generate_password_hash() { echo '$6$test$hash'; }
    FORCE_MODE=true VM_NAME=pkgtest VM_USERNAME=tester VM_PASSWORD=testpass123
    VM_MEMORY=2048 VM_CPUS=2 VM_DISK_SIZE=30G ENABLE_ROOT=n ROOT_PASSWORD="" SSH_KEY=""
    DATACENTER_BASE="$t" ADDITIONAL_PACKAGES="nginx, msql" VM_OS=debian12 TAILSCALE_AUTHKEY=""
    mkdir -p "$t/vms/pkgtest/cloud-init"
    generate_cloud_init_userdata >/dev/null 2>&1
  )
  ud="$t/vms/pkgtest/cloud-init/user-data"
  if [ -f "$ud" ] && grep -q '^    for pkg in nginx msql; do$' "$ud" &&
    ! sed -n '/^packages:/,/^$/p' "$ud" | grep -qE '^  - (nginx|msql)$'; then
    log_test "PASS" "create -k installs extra packages one by one"
  else
    log_test "FAIL" "create -k installs extra packages one by one"
  fi
  rm -rf "$t"
}

# shellcheck disable=SC2016 # literal $6$ prefix
test_hash() { printf '$6$test$%s\n' "$(printf '%s' "$1" | base64 -w0 | tr '+/=' '._-')"; }

# shellcheck disable=SC2034,SC2030,SC2031,SC2317,SC2016,SC1091 # stubs; globals are read by create-vm.sh
generate_test_userdata() {
  local t
  t=$(mktemp -d)
  (
    source "$SCRIPT_DIR/../core/create-vm.sh" >/dev/null 2>&1
    generate_password_hash() { test_hash "$1"; }
    FORCE_MODE=true VM_NAME=usertest VM_USERNAME="$1" VM_PASSWORD="${6:-testpass123}"
    VM_MEMORY=2048 VM_CPUS=2 VM_DISK_SIZE=30G ENABLE_ROOT="$2" ROOT_PASSWORD="${8:-}" SSH_KEY="$3"
    DATACENTER_BASE="$t" ADDITIONAL_PACKAGES="${5:-}" VM_OS="${7:-debian12}" TAILSCALE_AUTHKEY=""
    mkdir -p "$t/vms/usertest/cloud-init"
    generate_cloud_init_userdata >/dev/null 2>&1
  )
  cp "$t/vms/usertest/cloud-init/user-data" "$4" 2>/dev/null
  rm -rf "$t"
}

# shellcheck disable=SC2034,SC2030,SC2031,SC2317,SC2016,SC1091 # stubs; globals are read by create-vm.sh
test_root_username_userdata() {
  local t key='ssh-ed25519 AAAAC3NzaTEST dcvm-test'
  t=$(mktemp -d)

  generate_test_userdata root n "$key" "$t/root.yaml"
  local users_block
  users_block=$(sed -n '/^users:/,/^$/p' "$t/root.yaml")
  if [ "$(echo "$users_block" | grep -c -- '- name:')" = "1" ] && echo "$users_block" | grep -q '^  - name: "root"$' &&
    ! echo "$users_block" | grep -qE '^    (sudo|shell|passwd|groups):'; then
    log_test "PASS" "username root (one root entry, no create/sudo fields)"
  else
    log_test "FAIL" "username root (one root entry, no create/sudo fields)"
  fi
  if echo "$users_block" | grep -q "^      - \"$key\"\$" && grep -qxF "    root:$(test_hash testpass123)" "$t/root.yaml" &&
    ! grep -q 'testpass123' "$t/root.yaml" && ! grep -q '^bootcmd:' "$t/root.yaml"; then
    log_test "PASS" "username root (SSH key and password for root)"
  else
    log_test "FAIL" "username root (SSH key and password for root)"
  fi
  if grep -q '^disable_root: false$' "$t/root.yaml" && grep -q 'PermitRootLogin yes' "$t/root.yaml" &&
    grep -q '^  - mkdir -p /root/{Documents,Downloads,Scripts}$' "$t/root.yaml" && ! grep -q '/home/' "$t/root.yaml"; then
    log_test "PASS" "username root (disable_root false, /root paths)"
  else
    log_test "FAIL" "username root (disable_root false, /root paths)"
  fi
  if command -v python3 >/dev/null 2>&1 && python3 -I -c 'import yaml' 2>/dev/null; then
    if python3 -I -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$t/root.yaml" 2>/dev/null; then
      log_test "PASS" "username root (user-data parses as YAML)"
    else
      log_test "FAIL" "username root (user-data parses as YAML)"
    fi
  else
    log_test "SKIP" "username root (YAML parse)" "python3 yaml not available"
  fi
  mkdir -p "$t/vms/rootvm/cloud-init" && cp "$t/root.yaml" "$t/vms/rootvm/cloud-init/user-data"
  if [ "$(DATACENTER_BASE="$t" get_vm_username rootvm)" = "root" ]; then
    log_test "PASS" "get_vm_username (username root)"
  else
    log_test "FAIL" "get_vm_username (username root)"
  fi

  generate_test_userdata tester n "$key" "$t/user.yaml"
  if grep -q '^  - name: "tester"$' "$t/user.yaml" && grep -q "^    sudo: \['ALL=(ALL) NOPASSWD:ALL'\]$" "$t/user.yaml" &&
    grep -q '^    shell: /bin/bash$' "$t/user.yaml" && grep -qxF "    passwd: '$(test_hash testpass123)'" "$t/user.yaml" &&
    grep -q "^      - \"$key\"\$" "$t/user.yaml" && grep -q '^disable_root: true$' "$t/user.yaml" &&
    grep -q 'PermitRootLogin no' "$t/user.yaml" && grep -q '^  - chown -R tester:tester /home/tester$' "$t/user.yaml" &&
    ! grep -qE "^    root:|echo 'root:" "$t/user.yaml"; then
    log_test "PASS" "normal username user-data unchanged"
  else
    log_test "FAIL" "normal username user-data unchanged"
  fi
  rm -rf "$t"
}

# shellcheck disable=SC2034,SC2030,SC2031,SC2317,SC2016,SC1091 # stubs; globals are read by create-vm.sh
test_cloud_init_quoting() {
  local t r="" key='ssh-ed25519 AAAAC3NzaTEST work: laptop #2 "x" \y'
  t=$(mktemp -d)
  printf '%s\n' 'not a key' "${key}"$'\xe2\x80\xa8' 'ssh-rsa AAAAB3second other' >"$t/id.pub"
  (
    source "$SCRIPT_DIR/../core/create-vm.sh" >/dev/null 2>&1
    generate_password_hash() { test_hash "$1"; }
    FORCE_MODE=true VM_NAME=123 VM_USERNAME=yes VM_PASSWORD=testpass123
    VM_MEMORY=2048 VM_CPUS=2 VM_DISK_SIZE=30G ENABLE_ROOT=n ROOT_PASSWORD="" SSH_KEY=$(first_ssh_key "$t/id.pub")
    DATACENTER_BASE="$t" ADDITIONAL_PACKAGES="" VM_OS=debian12 TAILSCALE_AUTHKEY=""
    mkdir -p "$t/vms/123/cloud-init"
    generate_cloud_init_userdata >/dev/null 2>&1
    generate_cloud_init_metadata >/dev/null 2>&1
  )
  local ud="$t/vms/123/cloud-init/user-data" md="$t/vms/123/cloud-init/meta-data"
  grep -qx 'hostname: "123"' "$ud" && grep -qx '  - name: "yes"' "$ud" && grep -qx 'local-hostname: "123"' "$md" &&
    grep -qxF '      - "ssh-ed25519 AAAAC3NzaTEST work: laptop #2 \"x\" \\y"' "$ud" && ! grep -q second "$ud" && r+="quoted "
  [ "$(DATACENTER_BASE="$t" get_vm_username 123)" = yes ] && r+="login "
  if has_pyyaml; then
    python3 -I -c 'import sys, yaml
u, m = yaml.safe_load(open(sys.argv[1])), yaml.safe_load(open(sys.argv[2]))
assert u["hostname"] == "123" and m["local-hostname"] == "123" and u["users"][0]["name"] == "yes"
assert u["users"][0]["ssh_authorized_keys"] == [sys.argv[3]]' "$ud" "$md" "$key" 2>/dev/null && r+="yaml "
  else
    r+="yaml "
  fi
  if [ "$r" = "quoted login yaml " ]; then
    log_test "PASS" "cloud-init quotes hostname, user and SSH key (yes, 123, comments with : and #)"
  else
    log_test "FAIL" "cloud-init quotes hostname, user and SSH key (yes, 123, comments with : and #)" "$r"
  fi

  r=""
  ts() {
    (
      source "$SCRIPT_DIR/../core/create-vm.sh" >/dev/null 2>&1
      FORCE_MODE=true FLAG_TAILSCALE_AUTHKEY="$1" ADDITIONAL_PACKAGES="$2"
      setup_tailscale >/dev/null 2>&1 && echo "$ADDITIONAL_PACKAGES|$TAILSCALE_AUTHKEY"
    )
  }
  [ "$(ts tskey-auth-k1_X tailscale-exporter)" = "tailscale-exporter,tailscale|tskey-auth-k1_X" ] && r+="exact "
  [ -z "$(ts 'tskey-a;reboot' "")" ] && r+="key-refused "
  [ "$(ts "" Tailscale)" = "Tailscale|" ] && r+="case "
  if [ "$r" = "exact key-refused case " ]; then
    log_test "PASS" "tailscale: exact package match, auth key must be tskey-[A-Za-z0-9_-]"
  else
    log_test "FAIL" "tailscale: exact package match, auth key must be tskey-[A-Za-z0-9_-]" "$r"
  fi
  rm -rf "$t"
}

# shellcheck disable=SC2034,SC2030,SC2031,SC2317,SC2016,SC1091 # stubs; globals are read by create-vm.sh
test_create_cancel_and_failure_cleanup() {
  local t r="" rc
  t=$(mktemp -d)
  (source "$SCRIPT_DIR/../core/create-vm.sh" >/dev/null 2>&1 && FORCE_MODE=false && confirm_vm_creation) <<<n >/dev/null 2>&1
  rc=$?
  [ "$rc" = 130 ] && r+="decline "
  (source "$SCRIPT_DIR/../core/custom-iso.sh" >/dev/null 2>&1 && confirm_creation) <<<n >/dev/null 2>&1
  rc=$?
  [ "$rc" = 130 ] && r+="decline-iso "
  if ! (
    virsh() {
      echo "$*" >>"$t/calls"
      [ "$1" != start ]
    }
    fake_vi() { echo "<domain><name>vm1</name><devices><graphics type='vnc'/></devices></domain>"; }
    virt_install_with_vnc_password pw fake_vi
  ) >/dev/null 2>&1 && grep -q '^undefine vm1' "$t/calls"; then
    r+="undefined "
  fi
  mkdir -p "$t/vms/live"
  (
    source "$SCRIPT_DIR/../core/create-vm.sh" >/dev/null 2>&1
    caller_role() { echo root; }
    check_vm_exists() { return 0; }
    virt-install() { return 1; }
    SCRIPT_DIR=$t FORCE_MODE=true DATACENTER_BASE=$t VM_NAME=live VM_OS=debian12
    install_vm
  ) >/dev/null 2>&1
  [ -d "$t/vms/live" ] && r+="disk-kept "
  if [ "$r" = "decline decline-iso undefined disk-kept " ]; then
    log_test "PASS" "create: declining exits 130, a failed start undefines, a defined VM's folder is never removed"
  else
    log_test "FAIL" "create: declining exits 130, a failed start undefines, a defined VM's folder is never removed" "$r"
  fi
  rm -rf "$t"
}

# shellcheck disable=SC2034,SC2030,SC2031,SC2317,SC2016,SC1091 # stubs; globals are read by create-vm.sh
test_root_mysql_userdata() {
  if ! has_pyyaml; then
    log_test "SKIP" "-k mysql-server SQL" "python3 yaml not available"
    return
  fi
  local t root_sql user_sql
  t=$(mktemp -d)
  generate_test_userdata root y "" "$t/root.yaml" mysql-server
  generate_test_userdata tester n "" "$t/user.yaml" mysql-server
  root_sql=$(ud_py "$t/root.yaml" "$ud_sql_expr" 2>/dev/null)
  user_sql=$(ud_py "$t/user.yaml" "$ud_sql_expr" 2>/dev/null)
  local alter="ALTER USER 'root'@'localhost' IDENTIFIED VIA unix_socket OR mysql_native_password USING PASSWORD('testpass123');"
  if [ "$root_sql" = "$alter
FLUSH PRIVILEGES;" ] && ! grep -qF '$VM_' "$t/root.yaml"; then
    log_test "PASS" "-k mysql-server with username root (no CREATE USER/GRANT)"
  else
    log_test "FAIL" "-k mysql-server with username root (no CREATE USER/GRANT)" "$(tr '\n' ';' <<<"$root_sql")"
  fi
  if [ "$user_sql" = "$alter
CREATE USER 'tester'@'localhost' IDENTIFIED BY 'testpass123';
GRANT ALL PRIVILEGES ON *.* TO 'tester'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;" ] && ! grep -qF '$VM_' "$t/user.yaml"; then
    log_test "PASS" "-k mysql-server with a normal user (CREATE USER/GRANT kept)"
  else
    log_test "FAIL" "-k mysql-server with a normal user (CREATE USER/GRANT kept)"
  fi
  rm -rf "$t"
}

# shellcheck disable=SC2034,SC2030,SC2031,SC2317,SC2016,SC1091 # stubs; globals are read by create-vm.sh
test_root_username_setup() {
  local out
  out=$(
    source "$SCRIPT_DIR/../core/create-vm.sh" >/dev/null 2>&1
    exec 2>&1
    FORCE_MODE=true VM_NAME=rootvm FLAG_USERNAME=root FLAG_PASSWORD=testpass123
    setup_user_account
    setup_root_access
    echo "ENABLE_ROOT=$ENABLE_ROOT ROOT_PASSWORD=$ROOT_PASSWORD"
  )
  if echo "$out" | grep -q "Warning: configuring root login for VM rootvm (username 'root')" &&
    echo "$out" | grep -q '^ENABLE_ROOT=y ROOT_PASSWORD=testpass123$'; then
    log_test "PASS" "create -u root (warning, root enabled, one password)"
  else
    log_test "FAIL" "create -u root (warning, root enabled, one password)"
  fi
  if (
    source "$SCRIPT_DIR/../core/create-vm.sh" >/dev/null 2>&1
    FORCE_MODE=true VM_NAME=rootvm FLAG_USERNAME=root FLAG_PASSWORD=testpass123 FLAG_ROOT_PASSWORD=different123
    setup_user_account
    setup_root_access
  ) >/dev/null 2>&1; then
    log_test "FAIL" "create -u root with a different --root-password" "Expected failure but got success"
  else
    log_test "PASS" "create -u root with a different --root-password (expected failure)"
  fi
}

ud_py() {
  python3 -I -c 'import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
r = eval(sys.argv[2])
print(r if isinstance(r, str) else repr(r), end="")' "$1" "$2"
}

has_pyyaml() { command -v python3 >/dev/null 2>&1 && python3 -I -c 'import yaml' 2>/dev/null; }

ud_sql_expr='[__import__("base64").b64decode(w["content"]).decode() for w in d["write_files"] if w["path"] == "/root/dcvm-mysql-init.sql" and w.get("encoding") == "b64"][0]'

# shellcheck disable=SC2016 # literal $ in patterns and passwords
test_userdata_passwords() {
  if ! has_pyyaml; then
    log_test "SKIP" "user-data passwords (#36)" "python3 yaml not available"
    return
  fi
  local t f i pw esc sql ok
  t=$(mktemp -d)
  local sql_expr="$ud_sql_expr"
  local shell_expr='"\n".join(d.get("bootcmd", []) + [c if isinstance(c, str) else " ".join(c) for c in d["runcmd"]])'
  local pws=('plainpw1' 'ab #cd' "a'b\\c" 'x"$y`id`$(id): z' 'abcd' "$(printf 'p%.0s' {1..128})")
  for i in "${!pws[@]}"; do
    pw=${pws[$i]}
    esc=${pw//\\/\\\\}
    esc=${esc//\'/\'\'}
    f="$t/u$i.yaml"
    generate_test_userdata tester y "" "$f" mysql-server "$pw" ubuntu24.04 "$pw"
    ok=true
    ud_py "$f" 'd["hostname"]' >/dev/null 2>&1 || ok=false
    grep -qF -e '$VM_PASSWORD' -e '$VM_USERNAME' -e "''@'localhost'" "$f" 2>/dev/null && ok=false
    [ "$(ud_py "$f" 'd["users"][0]["passwd"]' 2>/dev/null)" = "$(test_hash "$pw")" ] || ok=false
    [ "$(ud_py "$f" 'd["chpasswd"]["list"]' 2>/dev/null)" = "root:$(test_hash "$pw")" ] || ok=false
    ud_py "$f" 'd.get("bootcmd") or ""' 2>/dev/null | grep -q chpasswd && ok=false
    sql=$(ud_py "$f" "$sql_expr" 2>/dev/null)
    grep -q "ALTER USER 'root'" <<<"$sql" && ok=false
    grep -qxF "CREATE USER 'tester'@'localhost' IDENTIFIED BY '$esc';" <<<"$sql" || ok=false
    grep -qxF "GRANT ALL PRIVILEGES ON *.* TO 'tester'@'localhost' WITH GRANT OPTION;" <<<"$sql" || ok=false
    [ "$(ud_py "$f" '[w["permissions"] for w in d["write_files"] if w["path"] == "/root/dcvm-mysql-init.sql"][0]' 2>/dev/null)" = "0600" ] || ok=false
    ud_py "$f" "$shell_expr" 2>/dev/null | grep -qF -- "$pw" && ok=false
    if [ "$ok" = true ]; then
      log_test "PASS" "user-data password #$i reaches the passwd/chpasswd hashes and MySQL unchanged, no shell text, no bootcmd chpasswd (#36)"
    else
      log_test "FAIL" "user-data password #$i reaches the passwd/chpasswd hashes and MySQL unchanged, no shell text, no bootcmd chpasswd (#36)" "password: $(printf %q "${pw:0:20}")"
    fi
  done

  pw="a'b #c"
  generate_test_userdata root y "" "$t/root.yaml" mysql-server "$pw" debian12
  sql=$(ud_py "$t/root.yaml" "$sql_expr" 2>/dev/null)
  if [ "$sql" = "ALTER USER 'root'@'localhost' IDENTIFIED VIA unix_socket OR mysql_native_password USING PASSWORD('a''b #c');
FLUSH PRIVILEGES;" ] && [ "$(ud_py "$t/root.yaml" 'd["chpasswd"]["list"]')" = "root:$(test_hash "$pw")" ] &&
    [ "$(ud_py "$t/root.yaml" '"bootcmd" in d')" = "False" ]; then
    log_test "PASS" "username root: one password in chpasswd and ALTER USER only, MariaDB keeps socket auth (#36)"
  else
    log_test "FAIL" "username root: one password in chpasswd and ALTER USER only, MariaDB keeps socket auth (#36)" "$sql"
  fi

  if validate_password "$(printf 'a%.0s' {1..128})" >/dev/null &&
    [ "$(validate_password "$(printf 'a%.0s' {1..129})")" = "Password must be at most 128 characters" ]; then
    log_test "PASS" "validate_password accepts 128 and rejects 129 characters (#36)"
  else
    log_test "FAIL" "validate_password accepts 128 and rejects 129 characters (#36)"
  fi

  local h
  h=$(generate_password_hash -neE)
  if ! command -v openssl >/dev/null 2>&1; then
    log_test "SKIP" "generate_password_hash hashes a password that looks like echo options (#36)" "openssl not installed"
  elif [ "$(printf '%s\n' -neE | openssl passwd -6 -salt "$(cut -d'$' -f3 <<<"$h")" -stdin)" = "$h" ]; then
    log_test "PASS" "generate_password_hash hashes a password that looks like echo options (#36)"
  else
    log_test "FAIL" "generate_password_hash hashes a password that looks like echo options (#36)" "$h"
  fi

  local typed='  a\b c\  ' got=""
  read_password "Password: " got <<<"$typed" >/dev/null
  if [ "$got" = "$typed" ]; then
    log_test "PASS" "read_password keeps leading/trailing spaces and backslashes (#36)"
  else
    log_test "FAIL" "read_password keeps leading/trailing spaces and backslashes (#36)" "got '$got'"
  fi

  local sep lsep psep nel
  lsep=$(printf '\xe2\x80\xa8') psep=$(printf '\xe2\x80\xa9') nel=$(printf '\xc2\x85')
  ok=true
  for sep in "$lsep" "$psep" "$nel"; do
    [ "$(validate_password "ab${sep}cd")" = "Password must not contain line breaks" ] || ok=false
  done
  if [ "$ok" = true ]; then
    log_test "PASS" "validate_password rejects U+2028, U+2029 and U+0085 (YAML line breaks) (#36)"
  else
    log_test "FAIL" "validate_password rejects U+2028, U+2029 and U+0085 (YAML line breaks) (#36)"
  fi

  pw="ab${lsep}cd${nel}ef"
  generate_test_userdata tester n "" "$t/sep.yaml" mysql-server "$pw" debian12
  sql=$(ud_py "$t/sep.yaml" "$ud_sql_expr" 2>/dev/null)
  if grep -qxF "CREATE USER 'tester'@'localhost' IDENTIFIED BY '$pw';" <<<"$sql"; then
    log_test "PASS" "user-data with U+2028/U+0085 in the MySQL password still loads in PyYAML (#36)"
  else
    log_test "FAIL" "user-data with U+2028/U+0085 in the MySQL password still loads in PyYAML (#36)"
  fi

  generate_test_userdata tester n "" "$t/client.yaml" mysql-client
  generate_test_userdata tester n "" "$t/docker.yaml" docker
  if ! grep -qE 'dcvm-mysql-init|systemctl (enable|start) (mysql|mariadb)' "$t/client.yaml" &&
    grep -q '^    for pkg in mysql-client; do$' "$t/client.yaml" &&
    grep -qx '  - usermod -aG docker tester' "$t/docker.yaml"; then
    log_test "PASS" "-k mysql-client runs no SQL setup; docker group gets the user (#36)"
  else
    log_test "FAIL" "-k mysql-client runs no SQL setup; docker group gets the user (#36)"
  fi

  for os in debian12 ubuntu24.04; do
    for req in my-mysql-server-tools mysql-server-core-8.0; do
      f="$t/$os-$req.yaml"
      generate_test_userdata tester n "" "$f" "$req" pw1234 "$os"
      if grep -qx "    for pkg in $req; do" "$f" &&
        ! grep -qE 'dcvm-mysql-init|systemctl (enable|start) (mysql|mariadb)' "$f"; then
        log_test "PASS" "-k $req on $os installs as typed, no SQL setup (#36)"
      else
        log_test "FAIL" "-k $req on $os installs as typed, no SQL setup (#36)"
      fi
    done
  done

  local os pkg svc req auth
  for os in debian11 debian12 debian13 kali ubuntu20.04 ubuntu22.04 ubuntu24.04 archlinux; do
    for req in mysql-server default-mysql-server; do
      generate_test_userdata tester n "" "$t/$os-$req.yaml" "$req" pw1234 "$os"
      case "$os" in
      ubuntu*) pkg=$req svc=mysql ;;
      archlinux) pkg=mariadb svc=mariadb ;;
      *) pkg=mariadb-server svc=mariadb ;;
      esac
      [ "$req" = default-mysql-server ] && [ "$os" != archlinux ] && pkg=default-mysql-server
      f="$t/$os-$req.yaml"
      sql=$(ud_py "$f" "$sql_expr" 2>/dev/null)
      ok=true
      grep -q "^    for pkg in $pkg; do\$" "$f" || ok=false
      grep -qx "  - systemctl enable $svc" "$f" || ok=false
      grep -qF "  - '$svc < /root/dcvm-mysql-init.sql || echo " "$f" || ok=false
      grep -q "^CREATE USER 'tester'@'localhost'" <<<"$sql" || ok=false
      auth="ALTER USER 'root'@'localhost' IDENTIFIED VIA unix_socket OR mysql_native_password USING PASSWORD('pw1234');"
      if [ "$svc" = mysql ]; then
        grep -q "ALTER USER" <<<"$sql" && ok=false
      else
        grep -qxF "$auth" <<<"$sql" || ok=false
      fi
      grep -qxF "  - systemctl start $svc" "$f" || ok=false
      if [ "$os" = archlinux ]; then
        line_of() { grep -nxF -- "$1" "$f" | head -1 | cut -d: -f1; }
        [ "$(line_of "    for pkg in mariadb; do")" -lt "$(line_of '  - mariadb-install-db --user=mysql --basedir=/usr --datadir=/var/lib/mysql')" ] 2>/dev/null &&
          [ "$(line_of '  - mariadb-install-db --user=mysql --basedir=/usr --datadir=/var/lib/mysql')" -lt "$(line_of '  - systemctl start mariadb')" ] 2>/dev/null || ok=false
      else
        grep -q 'mariadb-install-db' "$f" && ok=false
      fi
      if [ "$ok" = true ]; then
        log_test "PASS" "-k $req on $os uses $pkg/$svc (#36)"
      else
        log_test "FAIL" "-k $req on $os uses $pkg/$svc (#36)"
      fi
    done
  done
  rm -rf "$t"
}

# shellcheck disable=SC2016 # literal $pkg in the expected install lines
test_userdata_per_os() {
  if ! has_pyyaml; then
    log_test "SKIP" "per-OS user-data (#38)" "python3 yaml not available"
    return
  fi
  local t f os ok
  local deb="['openssh-server', 'openssh-sftp-server', 'nfs-common', 'htop', 'curl', 'wget', 'net-tools', 'rsync', 'nano', 'vim', 'tree', 'unzip']"
  local arch="['openssh', 'nfs-utils', 'htop', 'curl', 'wget', 'net-tools', 'rsync', 'nano', 'vim', 'tree', 'unzip']"
  t=$(mktemp -d)
  for os in debian12 debian13 ubuntu24.04 kali archlinux; do
    f="$t/$os.yaml"
    generate_test_userdata tester n "" "$f" "nginx,apache2" pw1234 "$os"
    ok=true
    if [ "$os" = archlinux ]; then
      [ "$(ud_py "$f" 'd["packages"]' 2>/dev/null)" = "$arch" ] || ok=false
      [ "$(ud_py "$f" 'd["runcmd"][0:3]' 2>/dev/null)" = "['systemctl enable sshd', 'systemctl restart sshd', 'systemctl status sshd --no-pager']" ] || ok=false
      grep -qx '      Subsystem sftp /usr/lib/ssh/sftp-server' "$f" || ok=false
      grep -qx '    for pkg in nginx apache; do' "$f" || ok=false
      grep -qxF '        pacman -S --noconfirm --needed "$pkg"' "$f" || ok=false
      grep -qF '> /usr/share/nginx/html/index.html' "$f" || ok=false
      grep -qx '  - chown http:http /usr/share/nginx/html/index.html' "$f" || ok=false
      grep -qx '  - systemctl enable httpd' "$f" || ok=false
      grep -qx '  - chown http:http /srv/http/index.html' "$f" || ok=false
      grep -qE 'www-data|/var/www|systemctl (enable|start) apache2' "$f" && ok=false
    else
      if [[ "$os" == debian* ]]; then
        [ "$(ud_py "$f" 'd["packages"]' 2>/dev/null)" = "${deb%]}, 'unattended-upgrades']" ] || ok=false
      else
        [ "$(ud_py "$f" 'd["packages"]' 2>/dev/null)" = "$deb" ] || ok=false
      fi
      [ "$(ud_py "$f" 'd["package_upgrade"]' 2>/dev/null)" = True ] || ok=false
      [ "$(ud_py "$f" 'd["runcmd"][0:3]' 2>/dev/null)" = "['systemctl enable ssh', 'systemctl restart ssh', 'systemctl status ssh --no-pager']" ] || ok=false
      grep -qx '      Subsystem sftp /usr/lib/openssh/sftp-server' "$f" || ok=false
      grep -qx '    for pkg in nginx apache2; do' "$f" || ok=false
      grep -qxF '        DEBIAN_FRONTEND=noninteractive apt-get install -y -o DPkg::Lock::Timeout=300 "$pkg"' "$f" || ok=false
      [ "$(grep -c '^  - chown www-data:www-data /var/www/html/index.html$' "$f")" = "2" ] || ok=false
      grep -qx '  - systemctl enable apache2' "$f" || ok=false
    fi
    if [ "$ok" = true ]; then
      log_test "PASS" "user-data for $os: packages, ssh unit, sftp path, web paths (#38)"
    else
      log_test "FAIL" "user-data for $os: packages, ssh unit, sftp path, web paths (#38)"
    fi
  done
  rm -rf "$t"
}

# shellcheck disable=SC2016,SC2030,SC2031,SC1091 # literal $ in patterns; create-vm.sh in a subshell
test_guest_setup_userdata() {
  if ! has_pyyaml; then
    log_test "SKIP" "guest setup user-data (#45, #46)" "python3 yaml not available"
    return
  fi
  local t r="" os
  t=$(mktemp -d)
  generate_test_userdata tester n "" "$t/arch.yaml" mariadb pw1234 archlinux
  [ "$(ud_py "$t/arch.yaml" 'd["bootcmd"]' 2>/dev/null)" = "[\"cloud-init-per once dcvm-pacman-keyring sh -c 'pacman-key --init && pacman-key --populate archlinux && pacman -Sy --noconfirm archlinux-keyring'\"]" ] && r+="keyring "
  generate_test_userdata tester n "" "$t/d11.yaml" "" pw1234 debian11
  generate_test_userdata tester n "" "$t/d12.yaml" "" pw1234 debian12
  ud_py "$t/d11.yaml" '[w["content"] for w in d["write_files"] if w["path"] == "/etc/apt/sources.list"][0]' 2>/dev/null |
    grep -qx 'deb http://archive.debian.org/debian-security bullseye-security main' &&
    ! grep -q 'sources.list\|bootcmd' "$t/d12.yaml" && r+="bullseye "
  for os in debian12 ubuntu24.04 kali archlinux; do
    generate_test_userdata tester n "" "$t/u.yaml" docker pw1234 "$os"
    if [ "$os" = archlinux ]; then
      grep -qx '    for pkg in docker; do' "$t/u.yaml" && r+="$os "
    else
      grep -qx '    for pkg in docker.io; do' "$t/u.yaml" && grep -qx '  - systemctl enable docker' "$t/u.yaml" && r+="$os "
    fi
  done
  generate_test_userdata tester n "" "$t/my.yaml" mysql-server pw1234 ubuntu24.04
  generate_test_userdata root y "" "$t/myroot.yaml" mysql-server pw1234 ubuntu24.04 pw1234
  [ "$(ud_py "$t/my.yaml" "$ud_sql_expr" 2>/dev/null)" = "CREATE USER 'tester'@'localhost' IDENTIFIED BY 'pw1234';
GRANT ALL PRIVILEGES ON *.* TO 'tester'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;" ] && [ "$(ud_py "$t/myroot.yaml" "$ud_sql_expr" 2>/dev/null)" = "FLUSH PRIVILEGES;" ] && r+="socket "
  ud_py "$t/my.yaml" 'd["runcmd"]' 2>/dev/null | grep -qF 'mysql < /root/dcvm-mysql-init.sql || echo "dcvm: database user setup failed, see /var/log/cloud-init-output.log" | tee -a /var/log/dcvm-packages.log; rm -f /root/dcvm-mysql-init.sql' &&
    ! grep -q '|| true; rm -f /root/dcvm-mysql-init.sql' "$t/my.yaml" && r+="reported "
  (
    source "$SCRIPT_DIR/../core/create-vm.sh" >/dev/null 2>&1
    ADDITIONAL_PACKAGES="nginx, apache2" web_servers_clash && ADDITIONAL_PACKAGES="apache,nginx" web_servers_clash &&
      ! ADDITIONAL_PACKAGES="nginx,libapache2-mod-php,apache2-utils" web_servers_clash && ! ADDITIONAL_PACKAGES="apache2" web_servers_clash
  ) && r+="clash "
  if [ "$r" = "keyring bullseye debian12 ubuntu24.04 kali archlinux socket reported clash " ]; then
    log_test "PASS" "guest setup: Arch keyring, Debian 11 archive, apt docker is docker.io, MySQL root on auth_socket, SQL failure logged, nginx+apache2 refused (#45, #46)"
  else
    log_test "FAIL" "guest setup: Arch keyring, Debian 11 archive, apt docker is docker.io, MySQL root on auth_socket, SQL failure logged, nginx+apache2 refused (#45, #46)" "$r"
  fi
  rm -rf "$t"
}

write_lease_fixture() {
  local h m ip exp sep=""
  {
    echo "["
    while read -r h m ip exp; do
      printf '%s  {\n    "ip-address": "%s",\n    "mac-address": "%s",\n    "hostname": "%s",\n    "expiry-time": %s\n  }' "$sep" "$ip" "$m" "$h" "$exp"
      sep=$',\n'
    done <<'EOF'
vm10 52:54:00:00:00:10 10.10.10.10 1893456000
vm1 52:54:00:00:00:01 10.10.10.11 1893456000
vm1-copy 52:54:00:00:00:02 10.10.10.12 1893456000
web 52:54:00:ab:c2:54 10.10.10.254 1893456000
gone 52:54:00:00:00:66 10.10.10.66 1000
EOF
    printf '\n]\n'
  } >"$1/br.status"
  cat >"$1/virsh-leases" <<'EOF'
 Expiry Time           MAC address         Protocol   IP address        Hostname   Client ID or DUID
-----------------------------------------------------------------------------------------------------
 2030-01-01 00:00:00   52:54:00:00:00:10   ipv4       10.10.10.10/24    vm10       01:52:54:00:00:00:10
 2030-01-01 00:00:00   52:54:00:00:00:01   ipv4       10.10.10.11/24    VM1        01:52:54:00:00:00:01
 2030-01-01 00:00:00   52:54:00:00:00:02   ipv4       10.10.10.12/24    vm1-copy   -
 2030-01-01 00:00:00   52:54:00:ab:c2:54   ipv4       10.10.10.254/24   web        -
EOF
  printf 'vm10\nvm1\nvm1-copy\nweb\n' >"$1/vms"
  printf 'vm10 52:54:00:00:00:10\nvm1 52:54:00:00:00:01\nvm1-copy 52:54:00:00:00:02\nweb 52:54:00:AB:C2:54\n' >"$1/ifaces"
}

# shellcheck disable=SC2317,SC2034,SC1090,SC1091 # stubs; globals read by dhcp.sh
run_dhcp_fixture() {
  local t="$1" extra="$2"
  shift 2
  (
    source "$SCRIPT_DIR/../network/dhcp.sh" 2>/dev/null
    load_dcvm_config() { :; }
    require_root() { :; }
    check_dependencies() { :; }
    dhcp_release() { echo "dhcp_release $*" >>"$t/calls"; }
    get_vm_mac() { :; }
    sleep() { :; }
    virsh() {
      echo "virsh $*" >>"$t/calls"
      case "$1" in
      net-dhcp-leases) cat "$t/virsh-leases" ;;
      list) cat "$t/vms" ;;
      domiflist)
        printf ' Interface Type Source Model MAC\n---\n'
        awk -v d="${*: -1}" '$1 == d { print " vnet0 network net virtio " $2 }' "$t/ifaces"
        ;;
      esac
      return 0
    }
    DNSMASQ_DIR="$t" BRIDGE_NAME=br NETWORK_NAME=net
    eval "$extra"
    main "$@"
  ) </dev/null 2>&1
}

status_hosts() { jq -c '[.[].hostname]' "$1/br.status" 2>/dev/null || echo invalid; }

# shellcheck disable=SC2016 # stub code is eval'd later
test_dhcp_clear_exact() {
  if ! command -v jq >/dev/null 2>&1; then
    log_test "SKIP" "dhcp clear exact match (#37)" "jq not available"
    return
  fi
  local t out name ok inode
  t=$(mktemp -d)

  write_lease_fixture "$t"
  out=$(run_dhcp_fixture "$t" "" clear vm1)
  if [ "$(status_hosts "$t")" = '["vm10","vm1-copy","web","gone"]' ] &&
    ! grep -qE '^virsh net-(destroy|start)' "$t/calls"; then
    log_test "PASS" "dhcp clear vm1 removes only VM1 (not vm10/vm1-copy), status stays JSON, no restart (#37)"
  else
    log_test "FAIL" "dhcp clear vm1 removes only VM1 (not vm10/vm1-copy), status stays JSON, no restart (#37)" "$(status_hosts "$t"); $(tr '\n' ';' <"$t/calls")"
  fi
  if ! grep -q '^virsh net-update' "$t/calls"; then
    log_test "PASS" "dhcp clear vm1 keeps any static DHCP reservation (no net-update) (#37)"
  else
    log_test "FAIL" "dhcp clear vm1 keeps any static DHCP reservation (no net-update) (#37)" "$(grep '^virsh net-update' "$t/calls")"
  fi

  rm -f "$t"/*
  write_lease_fixture "$t"
  run_dhcp_fixture "$t" "" clear 52:54:00:AB:C2:54 >/dev/null
  if [ "$(status_hosts "$t")" = '["vm10","vm1","vm1-copy","gone"]' ] &&
    ! grep -qE '^virsh net-(destroy|start)' "$t/calls"; then
    log_test "PASS" "dhcp clear <upper-case MAC> removes that status entry, no restart (#37)"
  else
    log_test "FAIL" "dhcp clear <upper-case MAC> removes that status entry, no restart (#37)" "$(status_hosts "$t")"
  fi

  for name in 254 ipv4 ip hostname mac abc 10 vm2; do
    rm -f "$t"/*
    write_lease_fixture "$t"
    cp "$t/br.status" "$t/status.orig"
    inode=$(stat -c %i "$t/br.status")
    out=$(run_dhcp_fixture "$t" "" clear "$name")
    ok=$?
    if [ "$ok" = 0 ] && cmp -s "$t/br.status" "$t/status.orig" &&
      [ "$(stat -c %i "$t/br.status")" = "$inode" ] && echo "$out" | grep -q 'No matching DHCP lease' &&
      ! grep -qE '^virsh net-(destroy|start|update)|^dhcp_release' "$t/calls"; then
      log_test "PASS" "dhcp clear $name: no lease, files untouched, exit 0, no restart (#37)"
    else
      log_test "FAIL" "dhcp clear $name: no lease, files untouched, exit 0, no restart (#37)" "exit $ok; $(tr '\n' ';' <"$t/calls")"
    fi
  done

  rm -f "$t"/*
  write_lease_fixture "$t"
  run_dhcp_fixture "$t" "" clear --stale >/dev/null
  if [ "$(status_hosts "$t")" = '["vm10","vm1","vm1-copy","web"]' ] &&
    ! grep -qE '^virsh net-(destroy|start)' "$t/calls"; then
    log_test "PASS" "dhcp clear --stale removes the expired status entry, no restart (#37)"
  else
    log_test "FAIL" "dhcp clear --stale removes the expired status entry, no restart (#37)" "$(status_hosts "$t"); $(tr '\n' ';' <"$t/calls")"
  fi

  rm -f "$t"/*
  write_lease_fixture "$t"
  cp "$t/br.status" "$t/status.orig"
  out=$(run_dhcp_fixture "$t" 'command_exists() { [ "$1" != jq ] && command -v "$1" >/dev/null; }' clear vm1)
  ok=$?
  if [ "$ok" = 1 ] && cmp -s "$t/br.status" "$t/status.orig" && ! grep -q '^dhcp_release' "$t/calls" &&
    echo "$out" | grep -qF "jq not available; the lease is still listed in $t/br.status"; then
    log_test "PASS" "dhcp clear without jq: fails, status file left as is, with the reason (#37)"
  else
    log_test "FAIL" "dhcp clear without jq: fails, status file left as is, with the reason (#37)" "exit $ok; $(echo "$out" | tr '\n' ';')"
  fi
  rm -rf "$t"
}

# shellcheck disable=SC2016 # stub code is eval'd later
test_dhcp_release() {
  if ! command -v jq >/dev/null 2>&1; then
    log_test "SKIP" "dhcp clear releases leases (37-10)" "jq not available"
    return
  fi
  local t out rc
  t=$(mktemp -d)
  local nostub='unset -f dhcp_release; command_exists() { [ "$1" != dhcp_release ] && command -v "$1" >/dev/null; }'

  write_lease_fixture "$t"
  run_dhcp_fixture "$t" "" clear vm1 >/dev/null
  if [ "$(grep '^dhcp_release' "$t/calls")" = "dhcp_release br 10.10.10.11 52:54:00:00:00:01" ]; then
    log_test "PASS" "dhcp clear vm1 runs dhcp_release br <ip> <mac> for its lease only (37-10)"
  else
    log_test "FAIL" "dhcp clear vm1 runs dhcp_release br <ip> <mac> for its lease only (37-10)" "$(tr '\n' ';' <"$t/calls")"
  fi

  rm -rf "${t:?}"/*
  write_lease_fixture "$t"
  run_dhcp_fixture "$t" "" clear 52:54:00:AB:C2:54 >/dev/null
  if [ "$(grep '^dhcp_release' "$t/calls")" = "dhcp_release br 10.10.10.254 52:54:00:ab:c2:54" ]; then
    log_test "PASS" "dhcp clear <MAC> runs dhcp_release for that lease (37-10)"
  else
    log_test "FAIL" "dhcp clear <MAC> runs dhcp_release for that lease (37-10)" "$(tr '\n' ';' <"$t/calls")"
  fi

  for name in vm1 52:54:00:00:00:01; do
    rm -rf "${t:?}"/*
    write_lease_fixture "$t"
    cp "$t/br.status" "$t/status.orig"
    out=$(run_dhcp_fixture "$t" "$nostub" clear "$name")
    rc=$?
    if [ "$rc" = 1 ] && cmp -s "$t/br.status" "$t/status.orig" &&
      echo "$out" | grep -qF "dhcp_release not found" && echo "$out" | grep -qF "dnsmasq-utils" &&
      ! echo "$out" | grep -q 'No matching DHCP lease'; then
      log_test "PASS" "dhcp clear $name without dhcp_release: exits 1 with an install hint, status untouched (37-10)"
    else
      log_test "FAIL" "dhcp clear $name without dhcp_release: exits 1 with an install hint, status untouched (37-10)" "exit $rc; $(echo "$out" | tr '\n' ';')"
    fi
  done

  rm -rf "${t:?}"/*
  write_lease_fixture "$t"
  run_dhcp_fixture "$t" 'dhcp_release() { echo "dhcp_release $(status_hosts "$t")" >>"$t/calls"; }' clear vm1 >/dev/null
  if [ "$(grep '^dhcp_release' "$t/calls")" = 'dhcp_release ["vm10","vm1-copy","web","gone"]' ]; then
    log_test "PASS" "dhcp clear writes the status file before dhcp_release runs (37-12)"
  else
    log_test "FAIL" "dhcp clear writes the status file before dhcp_release runs (37-12)" "$(tr '\n' ';' <"$t/calls")"
  fi

  for args in "clear vm1" "clear --stale"; do
    rm -rf "${t:?}"/*
    write_lease_fixture "$t"
    printf '[{"ip-address": "10.10.10.11"' >"$t/br.status"
    # shellcheck disable=SC2086 # split the args on purpose
    out=$(run_dhcp_fixture "$t" "" $args)
    rc=$?
    if [ "$rc" = 1 ] && echo "$out" | grep -qF "$t/br.status" && ! grep -q '^dhcp_release' "$t/calls" 2>/dev/null; then
      log_test "PASS" "dhcp $args exits 1 on an unreadable status file (37-12)"
    else
      log_test "FAIL" "dhcp $args exits 1 on an unreadable status file (37-12)" "exit $rc; $(echo "$out" | tr '\n' ';')"
    fi
  done

  for name in nosuchvm 52:54:00:99:99:99; do
    rm -rf "${t:?}"/*
    write_lease_fixture "$t"
    cp "$t/br.status" "$t/status.orig"
    out=$(run_dhcp_fixture "$t" "" clear "$name")
    rc=$?
    if [ "$rc" = 0 ] && cmp -s "$t/br.status" "$t/status.orig" && echo "$out" | grep -qF "No matching DHCP lease found" &&
      ! grep -q '^dhcp_release' "$t/calls" 2>/dev/null; then
      log_test "PASS" "dhcp clear $name with no matching lease exits 0 and changes nothing (37-12)"
    else
      log_test "FAIL" "dhcp clear $name with no matching lease exits 0 and changes nothing (37-12)" "exit $rc; $(echo "$out" | tr '\n' ';')"
    fi
  done

  rm -rf "${t:?}"/*
  write_lease_fixture "$t"
  printf 'vm10\nvm1\nvm1-copy\n' >"$t/vms"
  run_dhcp_fixture "$t" "" clear --stale >/dev/null
  if [ "$(grep -c '^dhcp_release' "$t/calls")" = 2 ] &&
    grep -qxF "dhcp_release br 10.10.10.66 52:54:00:00:00:66" "$t/calls" &&
    [ "$(status_hosts "$t")" = '["vm10","vm1","vm1-copy"]' ]; then
    log_test "PASS" "dhcp clear --stale releases each expired or orphaned lease from the status file (37-10)"
  else
    log_test "FAIL" "dhcp clear --stale releases each expired or orphaned lease from the status file (37-10)" "$(status_hosts "$t"); $(tr '\n' ';' <"$t/calls")"
  fi
  rm -rf "$t"
}

# shellcheck disable=SC2016 # stub code is eval'd later
test_dhcp_stale_by_mac() {
  if ! command -v jq >/dev/null 2>&1; then
    log_test "SKIP" "dhcp cleanup decides by MAC (#76)" "jq not available"
    return
  fi
  local t n
  t=$(mktemp -d)
  write_lease_fixture "$t"
  cat >"$t/br.status" <<'EOF'
[
  {"ip-address": "10.10.10.254", "mac-address": "52:54:00:ab:c2:54", "hostname": "ubuntu", "expiry-time": 1893456000},
  {"ip-address": "10.10.10.11", "mac-address": "52:54:00:00:00:01", "hostname": "vm1", "expiry-time": 1000},
  {"ip-address": "10.10.10.77", "mac-address": "52:54:00:00:00:77", "expiry-time": 1893456000},
  {"ip-address": "10.10.10.88", "hostname": "olddeleted", "expiry-time": 1893456000},
  {"ip-address": "10.10.10.89", "hostname": "VM10", "expiry-time": 1893456000}
]
EOF
  echo ' 2030-01-01 00:00:00   52:54:00:00:00:77   ipv4       10.10.10.77/24    -          -' >>"$t/virsh-leases"
  cp "$t/br.status" "$t/status.orig"
  n=$(run_dhcp_fixture "$t" 'stale_leases | grep -c .; exit')
  run_dhcp_fixture "$t" "" cleanup >/dev/null
  if [ "$n" = 2 ] && [ "$(status_hosts "$t")" = '["ubuntu","vm1","VM10"]' ] &&
    [ "$(grep '^dhcp_release' "$t/calls")" = "dhcp_release br 10.10.10.77 52:54:00:00:00:77" ]; then
    log_test "PASS" "dhcp cleanup keeps leases of defined VMs' MACs whatever the hostname, frees MAC orphans, hostname only without a MAC (#76)"
  else
    log_test "FAIL" "dhcp cleanup keeps leases of defined VMs' MACs whatever the hostname, frees MAC orphans, hostname only without a MAC (#76)" "count $n; $(status_hosts "$t"); $(grep '^dhcp_release' "$t/calls" | tr '\n' ';')"
  fi
  cp "$t/status.orig" "$t/br.status"
  : >"$t/calls"
  if ! run_dhcp_fixture "$t" 'virsh() { return 1; }' cleanup >/dev/null && cmp -s "$t/br.status" "$t/status.orig" &&
    ! grep -q '^dhcp_release' "$t/calls"; then
    log_test "PASS" "dhcp cleanup releases nothing when libvirt does not answer (#76)"
  else
    log_test "FAIL" "dhcp cleanup releases nothing when libvirt does not answer (#76)" "$(status_hosts "$t")"
  fi
  rm -rf "$t"
}

# shellcheck disable=SC2034,SC2317,SC1090,SC1091 # stubs are called by the code under test
test_bulk_status_reset() {
  local t before after
  t=$(mktemp -d)

  write_lease_fixture "$t"
  chmod 640 "$t/br.status"
  before=$(stat -c '%i %a' "$t/br.status")
  (
    source "$SCRIPT_DIR/../core/delete-vm.sh" >/dev/null 2>&1
    DATACENTER_BASE="$t" NETWORK_NAME=net BRIDGE_NAME=br DNSMASQ_DIR="$t"
    virsh() {
      [ "$1" = list ] && echo " 1    vm1    running"
      return 0
    }
    is_vm_in_network() { [ ! -e "$t/deleted" ]; }
    get_vm_state() { echo running; }
    shuf() { echo 1234; }
    delete_single_vm() { : >"$t/deleted"; }
    get_port_mappings_file() { echo "$t/port-mappings.txt"; }
    iptables() { :; }
    command_exists() { return 1; }
    delete_all_vms
  ) <<<$'yes\n1234' >/dev/null 2>&1
  after=$(stat -c '%i %a' "$t/br.status")
  if [ "$(od -An -c "$t/br.status" | tr -s ' ')" = " [ ] \n" ] && [ "$before" = "$after" ]; then
    log_test "PASS" "delete --all writes [] to the status file, same inode and mode (#37)"
  else
    log_test "FAIL" "delete --all writes [] to the status file, same inode and mode (#37)" "$(od -An -c "$t/br.status" | head -2 | tr '\n' ' '); $before -> $after"
  fi

  if ! command -v script >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    log_test "SKIP" "dhcp clear --all releases every lease, no network restart (#37, #93)" "script or jq not available"
    rm -rf "$t"
    return
  fi
  write_lease_fixture "$t"
  chmod 640 "$t/br.status"
  before=$(stat -c '%i %a' "$t/br.status")
  cat >"$t/run.sh" <<EOF
source "$SCRIPT_DIR/../network/dhcp.sh" 2>/dev/null
load_dcvm_config() { :; }
require_root() { :; }
check_dependencies() { :; }
dhcp_release() { echo "dhcp_release \$*" >>"$t/calls"; }
virsh() { echo "virsh \$*" >>"$t/calls"; }
DNSMASQ_DIR="$t" BRIDGE_NAME=br NETWORK_NAME=net
main clear --all
EOF
  printf 'y\n' | script -qec "bash $t/run.sh" /dev/null >/dev/null 2>&1
  after=$(stat -c '%i %a' "$t/br.status")
  if [ "$(jq -c . "$t/br.status" 2>/dev/null)" = "[]" ] && [ "$before" = "$after" ] &&
    [ "$(grep -c '^dhcp_release br ' "$t/calls" 2>/dev/null)" = 5 ] && ! grep -qE '^virsh net-(destroy|start)' "$t/calls"; then
    log_test "PASS" "dhcp clear --all releases every lease in dnsmasq, status [] with the same inode and mode, no network restart (#37, #93)"
  else
    log_test "FAIL" "dhcp clear --all releases every lease in dnsmasq, status [] with the same inode and mode, no network restart (#37, #93)" "$(tr '\n' ' ' <"$t/br.status"); $before -> $after; $(tr '\n' ';' <"$t/calls" 2>/dev/null)"
  fi
  rm -rf "$t"
}

# shellcheck disable=SC2034,SC2317,SC1090,SC1091,SC2030 # stubs are called by delete_single_vm
test_delete_vm_exact_match() {
  if ! command -v jq >/dev/null 2>&1; then
    log_test "SKIP" "delete VM exact lease match (#37)" "jq not available"
    return
  fi
  local t out
  t=$(mktemp -d)
  write_lease_fixture "$t"
  run_delete() {
    (
      HOME="$t"
      source "$SCRIPT_DIR/../core/delete-vm.sh" >/dev/null 2>&1
      DATACENTER_BASE="$t" NETWORK_NAME=net BRIDGE_NAME=br DNSMASQ_DIR="$t"
      virsh() {
        echo "virsh $*" >>"$t/calls"
        [ "$1" = net-dhcp-leases ] && grep -v ' VM1 ' "$t/virsh-leases"
        return 0
      }
      systemctl() { echo "systemctl $*" >>"$t/calls"; }
      rm() {
        case "$*" in
        */etc/systemd/*) echo "rm $*" >>"$t/calls" ;;
        *) command rm "$@" ;;
        esac
      }
      dhcp_release() { echo "dhcp_release $*" >>"$t/calls"; }
      check_vm_exists() { return 0; }
      get_vm_disk_path() { :; }
      get_vm_ip() { :; }
      get_port_mappings_file() { echo "$t/port-mappings.txt"; }
      stop_vm_gracefully() { :; }
      cleanup_port_forwarding_for_vm() { :; }
      sleep() { :; }
      eval "get_vm_mac() { echo '$2'; }"
      delete_single_vm "$1" 2>&1
    )
  }
  out=$(run_delete vm1 52:54:00:00:00:01)
  if [ "$(status_hosts "$t")" = '["vm10","vm1-copy","web","gone"]' ] &&
    [ "$(grep '^dhcp_release' "$t/calls")" = "dhcp_release br 10.10.10.11 52:54:00:00:00:01" ]; then
    log_test "PASS" "delete vm1 releases and removes only its lease, vm10/vm1-copy kept (#37)"
  else
    log_test "FAIL" "delete vm1 releases and removes only its lease, vm10/vm1-copy kept (#37)" "$(status_hosts "$t")"
  fi
  if grep -qxF "virsh net-update net delete ip-dhcp-host <host mac='52:54:00:00:00:01'/> --config" "$t/calls" &&
    grep -qxF "virsh net-update net delete ip-dhcp-host <host mac='52:54:00:00:00:01'/> --live" "$t/calls"; then
    log_test "PASS" "delete vm1 removes the static DHCP reservation for its MAC, saved and live separately (#37)"
  else
    log_test "FAIL" "delete vm1 removes the static DHCP reservation for its MAC, saved and live separately (#37)" "$(grep '^virsh net' "$t/calls" | tr '\n' ';')"
  fi
  out=$(run_delete vm1 "")
  if echo "$out" | grep -q 'No DHCP leases found' && ! echo "$out" | grep -q 'DHCP leases still exist'; then
    log_test "PASS" "delete with no MAC: other VMs' leases are not reported as this VM's (#37)"
  else
    log_test "FAIL" "delete with no MAC: other VMs' leases are not reported as this VM's (#37)"
  fi
  : >"$t/calls"
  run_delete s "" >/dev/null
  if ! grep -qE '^systemctl|^rm .*/etc/systemd/' "$t/calls" &&
    ! grep -q '/etc/systemd/system/\*' "$SCRIPT_DIR/../core/delete-vm.sh"; then
    log_test "PASS" "delete never stops or removes host systemd units matching the VM name (X-4)"
  else
    log_test "FAIL" "delete never stops or removes host systemd units matching the VM name (X-4)" "$(grep -E '^(systemctl|rm)' "$t/calls" | head -3 | tr '\n' ';')"
  fi
  command rm -rf "$t"
}

# shellcheck disable=SC2034,SC2317 # globals read by cleanup_dhcp_lease; stubs
run_cleanup_fixture() {
  local t="$1" extra="$2"
  shift 2
  mkdir -p "$t/tmp"
  (
    DNSMASQ_DIR="$t" BRIDGE_NAME=br TMPDIR="$t/tmp"
    dhcp_release() { echo "dhcp_release $*" >>"$t/calls"; }
    virsh() { :; }
    eval "$extra"
    cleanup_dhcp_lease "$@"
  ) </dev/null 2>&1
}

# shellcheck disable=SC2016,SC2034,SC2317,SC1090,SC1091 # stub code is eval'd later; stubs
test_dhcp_lease_edge_cases() {
  if ! command -v jq >/dev/null 2>&1; then
    log_test "SKIP" "DHCP lease edge cases (#42, #43, #44)" "jq not available"
    return
  fi
  local t out rc lib="$SCRIPT_DIR/.."
  local inactive='virsh() { echo "virsh $*" >>"$t/calls"; [ "$1" = net-info ] && printf "Name:           net\nActive:         no\n"; return 0; }'
  local nostub='unset -f dhcp_release; command_exists() { [ "$1" != dhcp_release ] && command -v "$1" >/dev/null; }'
  t=$(mktemp -d)

  cat >"$t/br.status" <<'EOF'
[
  {"ip-address": "fd00::11", "mac-address": "52:54:00:00:00:01", "hostname": "vm1", "iaid": "1", "expiry-time": 1893456000},
  {"ip-address": "10.10.10.11", "mac-address": "52:54:00:00:00:01", "hostname": "vm1", "expiry-time": 1893456000},
  {"ip-address": "fd00::12", "mac-address": "52:54:00:00:00:02", "hostname": "vm1-copy", "iaid": "2", "expiry-time": 1893456000}
]
EOF
  out=$(run_cleanup_fixture "$t" "" 52:54:00:00:00:01 vm1)
  rc=$?
  if [ "$rc" = 2 ] && [ "$(status_hosts "$t")" = '["vm1-copy"]' ] &&
    [ "$(cat "$t/calls")" = "dhcp_release br 10.10.10.11 52:54:00:00:00:01" ] &&
    echo "$out" | grep -qF "1 lease(s) without an IPv4 address" && echo "$out" | grep -qF "1 released in dnsmasq"; then
    log_test "PASS" "cleanup_dhcp_lease: a matched IPv6 lease is dropped, reported as not released, exit 2; other IPv6 leases kept (#42)"
  else
    log_test "FAIL" "cleanup_dhcp_lease: a matched IPv6 lease is dropped, reported as not released, exit 2; other IPv6 leases kept (#42)" "exit $rc; $(status_hosts "$t"); $(echo "$out" | tr '\n' ';')"
  fi

  rm -rf "${t:?}"/*
  : >"$t/br.status"
  run_cleanup_fixture "$t" "" 52:54:00:00:00:01 vm1 >/dev/null
  rc=$?
  if [ "$rc" = 1 ] && [ "$(cat "$t/br.status")" = "[]" ]; then
    log_test "PASS" "cleanup_dhcp_lease rewrites a 0-byte status file as [] (#42)"
  else
    log_test "FAIL" "cleanup_dhcp_lease rewrites a 0-byte status file as [] (#42)" "exit $rc; $(wc -c <"$t/br.status") bytes"
  fi

  local extra label
  for extra in "$inactive" "$inactive; $nostub"; do
    label=""
    [ "$extra" = "$inactive" ] || label=", even without dhcp_release"
    rm -rf "${t:?}"/*
    write_lease_fixture "$t"
    out=$(run_dhcp_fixture "$t" "$extra" clear 52:54:00:00:00:01)
    rc=$?
    if [ "$rc" = 0 ] && [ "$(status_hosts "$t")" = '["vm10","vm1-copy","web","gone"]' ] &&
      ! grep -q '^dhcp_release' "$t/calls" && ! echo "$out" | grep -qi error; then
      log_test "PASS" "dhcp clear on a stopped network edits the status file only, exit 0$label (#42)"
    else
      log_test "FAIL" "dhcp clear on a stopped network edits the status file only, exit 0$label (#42)" "exit $rc; $(status_hosts "$t"); $(echo "$out" | tr '\n' ';')"
    fi
  done

  rm -rf "${t:?}"/*
  write_lease_fixture "$t"
  printf 'vm10\nvm1\nvm1-copy\n' >"$t/vms"
  out=$(run_dhcp_fixture "$t" 'dhcp_release() { echo "dhcp_release $*" >>"$t/calls"; [ "$2" != 10.10.10.254 ]; }' clear --stale)
  rc=$?
  if [ "$rc" = 1 ] && [ "$(grep -c '^dhcp_release' "$t/calls")" = 2 ] && echo "$out" | grep -qF "Released 1 of 2 stale leases"; then
    log_test "PASS" "dhcp cleanup goes on after a failed release, counts it and exits 1 (#42)"
  else
    log_test "FAIL" "dhcp cleanup goes on after a failed release, counts it and exits 1 (#42)" "exit $rc; $(tr '\n' ';' <"$t/calls"); $(echo "$out" | tr '\n' ';')"
  fi

  rm -rf "${t:?}"/*
  write_lease_fixture "$t"
  out=$(run_dhcp_fixture "$t" "$nostub" clear 52:54:00:99:99:99)
  rc=$?
  local hint
  hint=$(grep -o 'install dnsmasq-utils on [^)]*' "$lib/utils/common.sh")
  if [ "$rc" = 0 ] && echo "$out" | grep -qF "No matching DHCP lease found" && ! echo "$out" | grep -q "dhcp_release not found" &&
    [[ "$hint" == *Kali* && "$hint" == *Fedora* && "$hint" == *"dnsmasq on Arch"* ]]; then
    log_test "PASS" "dhcp clear without dhcp_release and no lease says none found; the install hint names every distro (#44)"
  else
    log_test "FAIL" "dhcp clear without dhcp_release and no lease says none found; the install hint names every distro (#44)" "exit $rc; $hint; $(echo "$out" | tr '\n' ';')"
  fi

  out=$(
    HOME="$t"
    source "$lib/core/delete-vm.sh" >/dev/null 2>&1
    DATACENTER_BASE="$t" NETWORK_NAME=net BRIDGE_NAME=br DNSMASQ_DIR="$t"
    virsh() {
      [ "$1" = undefine ] && : >"$t/gone"
      return 0
    }
    cleanup_dhcp_lease() { return 2; }
    check_vm_exists() { [ ! -e "$t/gone" ]; }
    registry_get() { :; }
    registry_remove() { :; }
    get_vm_mac() { echo 52:54:00:00:00:01; }
    get_vm_disk_path() { :; }
    get_vm_ip() { :; }
    get_port_mappings_file() { echo "$t/port-mappings.txt"; }
    stop_vm_gracefully() { :; }
    cleanup_port_forwarding_for_vm() { :; }
    sleep() { :; }
    delete_single_vm vm1 2>&1
  )
  if ! echo "$out" | grep -q "No DHCP leases found" && echo "$out" | grep -qF "DHCP lease may stay in dnsmasq"; then
    log_test "PASS" "delete with a failed lease release does not end with 'No DHCP leases found' (#44)"
  else
    log_test "FAIL" "delete with a failed lease release does not end with 'No DHCP leases found' (#44)" "$(echo "$out" | grep -i lease | tr '\n' ';')"
  fi

  printf '[{"ip-address": "10.10.10.11", "mac-address": "52:54:00:AB:00:01"}, {"ip-address": "fd00::2", "mac-address": "52:54:00:00:00:02"}]\n' >"$t/br.status"
  out=$(source "$SCRIPT_DIR/dcvm-completion.sh" && DNSMASQ_DIR="$t" BRIDGE_NAME=br _dcvm_lease_macs | tr '\n' ' ')
  if [ "$out" = "52:54:00:00:00:02 52:54:00:ab:00:01 " ] &&
    ! grep -rlF '.leases' "$lib" --include='*.sh' | grep -v test-suite.sh | grep -q .; then
    log_test "PASS" "completion reads lease MACs from the .status file; nothing reads .leases (#43)"
  else
    log_test "FAIL" "completion reads lease MACs from the .status file; nothing reads .leases (#43)" "macs '$out'; $(grep -rlF '.leases' "$lib" --include='*.sh' | grep -v test-suite.sh | tr '\n' ' ')"
  fi
  if ! grep -qE ':[[:space:]]*>[[:space:]]*"\$status_file"' "$lib/installation/uninstall-dcvm.sh"; then
    log_test "PASS" "uninstall leaves [] in the status file, not 0 bytes (#42)"
  else
    log_test "FAIL" "uninstall leaves [] in the status file, not 0 bytes (#42)"
  fi
  rm -rf "$t"
}

# shellcheck disable=SC2016 # stub code is eval'd later
test_cleanup_dhcp_lease_failures() {
  if ! command -v jq >/dev/null 2>&1; then
    log_test "SKIP" "cleanup_dhcp_lease failure handling (#37)" "jq not available"
    return
  fi
  local t out rc
  t=$(mktemp -d)
  printf '[{"ip-address": "10.10.10.11", "mac-address": "52:54:00:00:00:01", "hostname": "vm1"' >"$t/br.status"
  cp "$t/br.status" "$t/status.orig"
  out=$(run_cleanup_fixture "$t" "" 52:54:00:00:00:01 vm1)
  rc=$?
  if [ "$rc" = 2 ] && cmp -s "$t/br.status" "$t/status.orig" &&
    [ -z "$(ls -A "$t/tmp")" ] && [ ! -e "$t/calls" ]; then
    log_test "PASS" "cleanup_dhcp_lease: unreadable status file is left as it was, nothing released, exit 2 (#37)"
  else
    log_test "FAIL" "cleanup_dhcp_lease: unreadable status file is left as it was, nothing released, exit 2 (#37)" "exit $rc; $(echo "$out" | tr '\n' ';')"
  fi

  rm -rf "${t:?}"/*
  write_lease_fixture "$t"
  cp "$t/br.status" "$t/status.orig"
  out=$(run_cleanup_fixture "$t" 'mktemp() { return 1; }' 52:54:00:00:00:01 vm1)
  rc=$?
  if [ "$rc" = 2 ] && cmp -s "$t/br.status" "$t/status.orig" && [ ! -e "$t/calls" ]; then
    log_test "PASS" "cleanup_dhcp_lease: no temp file means nothing released or changed, exit 2 (#37)"
  else
    log_test "FAIL" "cleanup_dhcp_lease: no temp file means nothing released or changed, exit 2 (#37)" "exit $rc; $(echo "$out" | tr '\n' ';')"
  fi

  local codes="" args extra mac host want
  for args in "|52:54:00:00:00:01|vm1|0" "|52:54:00:99:99:99|nosuchvm|1" "|||1" "rm -f \"\$t/br.status\"|52:54:00:00:00:01|vm1|1" \
    ": >\"\$t/br.status\"|52:54:00:00:00:01|vm1|1" \
    'unset -f dhcp_release; command_exists() { [ "$1" != dhcp_release ] && command -v "$1" >/dev/null; }|52:54:00:00:00:01|vm1|2' \
    'command_exists() { [ "$1" != jq ] && command -v "$1" >/dev/null; }|52:54:00:00:00:01|vm1|2'; do
    rm -rf "${t:?}"/*
    write_lease_fixture "$t"
    IFS='|' read -r extra mac host want <<<"$args"
    run_cleanup_fixture "$t" "$extra" "$mac" "$host" >/dev/null
    rc=$?
    [ "$rc" = "$want" ] || codes+="${mac:-none}/${host:-none} [$extra]: got $rc, want $want; "
  done
  if [ -z "$codes" ]; then
    log_test "PASS" "cleanup_dhcp_lease exits 0 when cleared, 1 when nothing matched, 2 when dhcp_release or jq is missing (#37)"
  else
    log_test "FAIL" "cleanup_dhcp_lease exits 0 when cleared, 1 when nothing matched, 2 when dhcp_release or jq is missing (#37)" "$codes"
  fi

  rm -rf "${t:?}"/*
  write_lease_fixture "$t"
  cp "$t/br.status" "$t/status.orig"
  out=$(run_cleanup_fixture "$t" 'flock() { return 1; }' 52:54:00:00:00:01 vm1)
  rc=$?
  if [ "$rc" = 2 ] && cmp -s "$t/br.status" "$t/status.orig" && [ ! -e "$t/calls" ] &&
    echo "$out" | grep -qF "Timed out waiting for"; then
    log_test "PASS" "cleanup_dhcp_lease: lock timeout changes nothing, exit 2 (#37)"
  else
    log_test "FAIL" "cleanup_dhcp_lease: lock timeout changes nothing, exit 2 (#37)" "exit $rc; $(echo "$out" | tr '\n' ';')"
  fi

  rm -rf "${t:?}"/*
  write_lease_fixture "$t"
  out=$(run_cleanup_fixture "$t" 'dhcp_release() { echo "dhcp_release $*" >>"$t/calls"; return 1; }' 52:54:00:00:00:01 vm1)
  rc=$?
  if [ "$rc" = 2 ] && echo "$out" | grep -qF "dhcp_release failed for 10.10.10.11" &&
    ! echo "$out" | grep -q "Released and removed"; then
    log_test "PASS" "cleanup_dhcp_lease: a failed dhcp_release is reported and exits 2 (#37)"
  else
    log_test "FAIL" "cleanup_dhcp_lease: a failed dhcp_release is reported and exits 2 (#37)" "exit $rc; $(echo "$out" | tr '\n' ';')"
  fi
  rm -rf "$t"
}

test_cleanup_dhcp_lease_parallel() {
  if ! command -v jq >/dev/null 2>&1; then
    log_test "SKIP" "cleanup_dhcp_lease parallel (#37)" "jq not available"
    return
  fi
  local t i lost=0
  t=$(mktemp -d)
  for i in $(seq 50); do
    printf '[{"ip-address":"10.10.10.11","mac-address":"52:54:00:00:00:01","hostname":"a"},{"ip-address":"10.10.10.12","mac-address":"52:54:00:00:00:02","hostname":"b"}]\n' >"$t/br.status"
    run_cleanup_fixture "$t" "" 52:54:00:00:00:01 a >/dev/null &
    run_cleanup_fixture "$t" "" 52:54:00:00:00:02 b >/dev/null &
    wait
    [ "$(jq length "$t/br.status" 2>/dev/null)" = 0 ] || lost=$((lost + 1))
  done
  if [ "$lost" = 0 ]; then
    log_test "PASS" "cleanup_dhcp_lease: 50 parallel pairs lose no update (status file locked) (#37)"
  else
    log_test "FAIL" "cleanup_dhcp_lease: 50 parallel pairs lose no update (status file locked) (#37)" "$lost of 50 left a lease"
  fi
  rm -rf "$t"
}

# shellcheck disable=SC1091
test_dhcp_cleanup_nits() {
  local lib="$SCRIPT_DIR/.."
  if ! (
    source "$lib/network/dhcp.sh" >/dev/null 2>&1
    declare -F reload_dnsmasq >/dev/null
  ) && ! grep -rqE 'kill -HUP|reload_dnsmasq' "$lib/network/dhcp.sh" "$lib/utils/common.sh" "$lib/core/delete-vm.sh"; then
    log_test "PASS" "no dnsmasq SIGHUP reload left in dhcp.sh, common.sh or delete-vm.sh (37-12)"
  else
    log_test "FAIL" "no dnsmasq SIGHUP reload left in dhcp.sh, common.sh or delete-vm.sh (37-12)" "$(grep -nE 'kill -HUP|reload_dnsmasq' "$lib/network/dhcp.sh" "$lib/utils/common.sh" "$lib/core/delete-vm.sh" | head -3 | tr '\n' ';')"
  fi
  if ! grep -qF '.leases' "$lib/utils/common.sh" "$lib/core/delete-vm.sh" && ! (
    source "$lib/network/dhcp.sh" >/dev/null 2>&1
    declare -f clear_all_leases clear_stale_leases clear_vm_lease clear_lease_by_mac
  ) | grep -qF '.leases'; then
    log_test "PASS" "lease cleanup works on the .status file only, no .leases handling (37-12)"
  else
    log_test "FAIL" "lease cleanup works on the .status file only, no .leases handling (37-12)"
  fi
  if bash -c 'declare -F cleanup_dhcp_lease cleanup_dhcp_lease_unlocked' >/dev/null 2>&1; then
    log_test "PASS" "cleanup_dhcp_lease is exported to child shells"
  else
    log_test "FAIL" "cleanup_dhcp_lease is exported to child shells"
  fi
}

# shellcheck disable=SC2317,SC2030,SC2031 # stub; globals set for the call only
test_get_vm_ip_subnet_dots() {
  local got
  got=$(
    virsh() {
      [ "$1" = domifaddr ] && printf ' vnet0  52:54:00:00:00:01  ipv4  10x10y10.5/24\n'
      return 0
    }
    NETWORK_SUBNET=10.10.10 get_vm_ip vm1
  )
  if [ "$got" = "N/A" ]; then
    log_test "PASS" "get_vm_ip: subnet 10.10.10 does not match 10x10y10.5"
  else
    log_test "FAIL" "get_vm_ip: subnet 10.10.10 does not match 10x10y10.5" "got '$got'"
  fi
  if ! NETWORK_SUBNET=1.1.1 validate_ip_in_subnet 111.1.1.5 >/dev/null 2>&1 &&
    NETWORK_SUBNET=1.1.1 validate_ip_in_subnet 1.1.1.5 >/dev/null 2>&1; then
    log_test "PASS" "validate_ip_in_subnet: subnet 1.1.1 accepts 1.1.1.5, not 111.1.1.5"
  else
    log_test "FAIL" "validate_ip_in_subnet: subnet 1.1.1 accepts 1.1.1.5, not 111.1.1.5"
  fi
}

test_apache_exact_match() {
  local t pkg
  t=$(mktemp -d)
  for pkg in apache2-utils libapache2-mod-php nginx-extras python3-docker; do
    generate_test_userdata tester n "" "$t/u.yaml" "$pkg" pw1234 debian12
    if grep -qx "    for pkg in $pkg; do" "$t/u.yaml" &&
      ! grep -qE 'systemctl (enable|start) (apache2|httpd|nginx|docker)|usermod -aG docker|index\.html' "$t/u.yaml"; then
      log_test "PASS" "-k $pkg installs as typed, no service setup"
    else
      log_test "FAIL" "-k $pkg installs as typed, no service setup"
    fi
  done
  generate_test_userdata tester n "" "$t/u.yaml" "nginx, apache2, docker.io" pw1234 debian12
  if grep -qx '  - systemctl enable nginx' "$t/u.yaml" && grep -qx '  - systemctl enable apache2' "$t/u.yaml" &&
    grep -qx '  - systemctl enable docker' "$t/u.yaml" && grep -qx '  - usermod -aG docker tester' "$t/u.yaml"; then
    log_test "PASS" "-k nginx, apache2, docker.io set up their services"
  else
    log_test "FAIL" "-k nginx, apache2, docker.io set up their services"
  fi
  generate_test_userdata tester n "" "$t/u.yaml" docker pw1234 archlinux
  if grep -qx '  - systemctl enable docker' "$t/u.yaml"; then
    log_test "PASS" "-k docker on Arch sets up Docker"
  else
    log_test "FAIL" "-k docker on Arch sets up Docker"
  fi
  rm -rf "$t"
}

# shellcheck disable=SC2317 # stub
test_ip_forward_last_wins() {
  local r="" sysctl_text
  at_boot() {
    sysctl_text="$1"
    (
      systemd-analyze() { printf "%b" "$sysctl_text"; }
      ip_forward_at_boot
      ip_forwarding_persisted && echo persisted
    )
  }
  [ "$(at_boot '# /etc/sysctl.d/90-dcvm.conf\nnet.ipv4.ip_forward=1\n\n# /etc/sysctl.d/99-sysctl.conf\nnet.ipv4.ip_forward = 0\n')" = "0 /etc/sysctl.d/99-sysctl.conf" ] && r+="later-0 "
  [ "$(at_boot '# /etc/sysctl.d/10-x.conf\nnet.ipv4.ip_forward=0\n\n# /etc/sysctl.d/90-dcvm.conf\nnet.ipv4.ip_forward=1\n')" = $'1 /etc/sysctl.d/90-dcvm.conf\npersisted' ] && r+="later-1 "
  [ "$(at_boot '# /usr/lib/sysctl.d/50-x.conf\n# net.ipv4.ip_forward=1\n; net.ipv4.ip_forward=1\n')" = " " ] && r+="comments "
  [ "$(at_boot '# /etc/sysctl.d/90-dcvm.conf\nnet/ipv4/ip_forward=1\n')" = $'1 /etc/sysctl.d/90-dcvm.conf\npersisted' ] && r+="slashes "
  [ "$(at_boot '# /etc/sysctl.d/90-dcvm.conf\nnet.ipv4.ip_forward=1\n# /etc/sysctl.d/99-hardening.conf\n-net.ipv4.conf.all.forwarding = 0\n')" = "0 /etc/sysctl.d/99-hardening.conf" ] && r+="all-forwarding "
  if [ "$r" = "later-0 later-1 comments slashes all-forwarding " ]; then
    log_test "PASS" "IP forwarding at boot: the last sysctl.d assignment wins and names its file (#84)"
  else
    log_test "FAIL" "IP forwarding at boot: the last sysctl.d assignment wins and names its file (#84)" "$r"
  fi
}

# shellcheck disable=SC2016 # stub code is eval'd later
test_dhcp_release_client_id() {
  if ! command -v jq >/dev/null 2>&1; then
    log_test "SKIP" "dhcp_release gets the lease's client-id (#99)" "jq not available"
    return
  fi
  local t
  t=$(mktemp -d)
  write_lease_fixture "$t"
  jq '(.[] | select(.hostname == "vm1"))."client-id" = "01:52:54:00:00:00:01"' "$t/br.status" >"$t/s" && cat "$t/s" >"$t/br.status"
  run_dhcp_fixture "$t" "" clear vm1 >/dev/null
  run_dhcp_fixture "$t" "" clear web >/dev/null
  if [ "$(grep '^dhcp_release' "$t/calls")" = $'dhcp_release br 10.10.10.11 52:54:00:00:00:01 01:52:54:00:00:00:01\ndhcp_release br 10.10.10.254 52:54:00:ab:c2:54' ]; then
    log_test "PASS" "dhcp_release gets the lease's client-id, and none when the lease has none (#99)"
  else
    log_test "FAIL" "dhcp_release gets the lease's client-id, and none when the lease has none (#99)" "$(grep '^dhcp_release' "$t/calls" | tr '\n' ';')"
  fi
  rm -rf "$t"
}

# shellcheck disable=SC2016 # stub code is eval'd later
test_dhcp_renew_link() {
  if ! command -v jq >/dev/null 2>&1; then
    log_test "SKIP" "dhcp renew cuts the VMs' links and checks for new leases (#93)" "jq not available"
    return
  fi
  local t out rc
  t=$(mktemp -d)
  write_lease_fixture "$t"
  # The guest asking again while its link is down: only vm1 gets a lease back.
  jq '[.[] | select(.hostname == "vm1")]' "$t/br.status" >"$t/renewed"
  mkdir -p "$t/config/network"
  : >"$t/config/network/web.conf"
  out=$(run_dhcp_fixture "$t" 'DATACENTER_BASE="$t"
    confirm_release() { echo confirmed >>"$t/calls"; }
    is_vm_in_network() { :; }
    get_vm_mac() { [ "$1" = vm1-copy ] || awk -v d="$1" '\''$1 == d { print $2 }'\'' "$t/ifaces"; }
    sleep() { [ "$1" != 5 ] || cp "$t/renewed" "$t/br.status"; }
    ssh() { echo "ssh $*" >>"$t/calls"; }' renew)
  rc=$?
  if [ "$rc" != 0 ] && grep -qx confirmed "$t/calls" && ! grep -q '^ssh' "$t/calls" &&
    [ "$(grep '^dhcp_release' "$t/calls" | sort | tr '\n' ';')" = "dhcp_release br 10.10.10.10 52:54:00:00:00:10;dhcp_release br 10.10.10.11 52:54:00:00:00:01;" ] &&
    grep -q 'vm1-copy .*could not cut' <<<"$out" &&
    grep -qx 'virsh domif-setlink vm1 52:54:00:00:00:01 down' "$t/calls" &&
    grep -qx 'virsh domif-setlink vm1 52:54:00:00:00:01 up' "$t/calls" &&
    grep -qx 'virsh domif-setlink vm10 52:54:00:00:00:10 up' "$t/calls" &&
    ! grep -q 'domif-setlink web' "$t/calls" &&
    grep -q 'vm1 .*renewed: 10.10.10.11' <<<"$out" && grep -q 'vm10 .*no new lease' <<<"$out" &&
    grep -q 'web .*static IP' <<<"$out"; then
    log_test "PASS" "dhcp renew cuts DHCP VMs' links (not static ones), releases only the cut VMs' leases, reports which got a new lease, fails for the rest, no SSH (#93, #140)"
  else
    log_test "FAIL" "dhcp renew cuts DHCP VMs' links (not static ones), releases only the cut VMs' leases, reports which got a new lease, fails for the rest, no SSH (#93, #140)" "rc $rc; $(tr '\n' ';' <"$t/calls"); $(tr '\n' ';' <<<"$out")"
  fi
  rm -rf "$t"
}

# shellcheck disable=SC2034,SC2317 # globals read by save_static_ip; stubs
test_static_ip_reservation() {
  local t r="" out
  t=$(mktemp -d)
  save() {
    (
      DATACENTER_BASE="$t" NETWORK_NAME=net
      get_vm_mac() { echo "$mac"; }
      virsh() {
        echo "virsh $*" >>"$t/calls"
        [ "$*" != "$fail" ]
      }
      save_static_ip vm1 10.10.10.50
    ) 2>&1
  }
  local mac=52:54:00:00:00:01 fail=""
  local host="<host mac='52:54:00:00:00:01' ip='10.10.10.50'/>"
  save >/dev/null && grep -q '^IP="10.10.10.50"$' "$t/config/network/vm1.conf" &&
    [ "$(cat "$t/calls")" = "virsh net-update net add ip-dhcp-host $host --config"$'\n'"virsh net-update net add ip-dhcp-host $host --live" ] && r+="reserved "
  : >"$t/calls"
  fail="net-update net add ip-dhcp-host $host --config"
  ! out=$(save) && grep -q 'Could not reserve 10.10.10.50' <<<"$out" && [ "$(wc -l <"$t/calls")" = 1 ] && r+="refused "
  : >"$t/calls"
  mac="" fail=""
  ! out=$(save) && grep -q 'Could not reserve' <<<"$out" && [ ! -s "$t/calls" ] && r+="no-mac "
  if [ "$r" = "reserved refused no-mac " ]; then
    log_test "PASS" "static IP gets a DHCP reservation for the VM's MAC, saved and live; a refused one warns (#95)"
  else
    log_test "FAIL" "static IP gets a DHCP reservation for the VM's MAC, saved and live; a refused one warns (#95)" "$r"
  fi
  rm -rf "$t"
}

installer_packages() {
  local line
  line=$(grep -m1 "^  local $1_packages=(" "$SCRIPT_DIR/../installation/install-dcvm.sh") || return 1
  eval "${line#  local }"
  local -n list="$1_packages"
  printf '%s\n' "${list[@]}"
}

# shellcheck disable=SC2016,SC2034,SC2317 # stubs are eval'd and called by the installer functions
test_installer_network() {
  local t r="" out
  t=$(mktemp -d)
  echo 'NETWORK_NAME=datacenter-net' >"$t/conf"
  inst() {
    (
      eval "$(sed -n '/^valid_bridge_name()/p; /^unused_subnet()/,/^}/p; /^create_network()/,/^}/p; /^main()/,/^}/p; /^dcvm_init()/,/^}/p' "$SCRIPT_DIR/../installation/install-dcvm.sh")"
      CONFIG_FILE="$t/conf" LOG_FILE="$t/log" NETWORK_NAME=datacenter-net BRIDGE_NAME=virbr-dc NETWORK_ONLY=0 NETWORK_NAME_ARG="" NETWORK_SUBNET=10.10.10
      print_status_log() { echo "[$1] $2"; }
      check_root() { :; }
      install_required_packages() { :; }
      start_libvirtd() { :; }
      enable_ip_forwarding() { echo forwarding-on; }
      virsh() { return 1; }
      ip() { :; }
      eval "$1"
      shift
      "$@"
    ) </dev/null 2>&1
  }
  local net='create_network() { echo "net=$1 bridge=$2"; }'
  [ "$(inst "$net" dcvm_init --network-only --network-name staging-network | grep '^net=')" = "net=staging-network bridge=virbr-stagingne" ] && r+="space "
  [ "$(inst "$net" dcvm_init --network-only --network-name datacenter-net | grep '^net=')" = "net=datacenter-net bridge=virbr-dc" ] && r+="primary-bridge "
  out=$(inst 'create_network() { echo "net=$1 subnet=$NETWORK_SUBNET"; }
    ip() { [ "$2" = -o ] && echo "2: eth0    inet 10.10.0.5/24 brd 10.10.0.255 scope global eth0"; }
    virsh() { case $1 in net-list) printf "datacenter-net\nother\n" ;; net-dumpxml) [ "$2" = other ] && echo "ip address 10.10.1.1" ;; *) return 1 ;; esac; }' dcvm_init --network-only --network-name lab)
  grep -qx 'net=lab subnet=10.10.2' <<<"$out" && grep -qx forwarding-on <<<"$out" && r+="own-subnet-forwarding "
  inst 'virsh() { case $1 in net-info) return 1 ;; net-define) cat "$2" >"$t/xml" ;; esac; }; uuidgen() { echo u; }' create_network n virbr-n >/dev/null
  grep -q "<bridge name='virbr-n'" "$t/xml" 2>/dev/null && ! grep -q '<mac ' "$t/xml" && r+="no-fixed-mac "
  [ "$(inst "$net" dcvm_init --network-name=lab --network-only | grep '^net=')" = "net=lab bridge=virbr-lab" ] && r+="equals "
  ! out=$(inst "$net" dcvm_init --network-only --network-name) && grep -q 'requires a value' <<<"$out" && r+="no-value "
  ! out=$(inst 'virsh() { case $1 in net-info) return 1 ;; net-start) echo "error: bridge in use" >&2; return 1 ;; esac; }' create_network n virbr-n) &&
    grep -q 'could not start' <<<"$out" && grep -q 'bridge in use' <<<"$out" && r+="new-start-fails "
  ! out=$(inst 'virsh() { case $1 in net-info) echo "Active:         no" ;; net-list) echo " n-old  active  yes  yes" ;; net-start) return 1 ;; esac; }' create_network n virbr-n) &&
    grep -q 'could not start' <<<"$out" && r+="existing-start-fails "
  installer_packages debian | grep -qx iptables && r+="debian-iptables "
  if [ "$r" = "space primary-bridge own-subnet-forwarding no-fixed-mac equals no-value new-start-fails existing-start-fails debian-iptables " ]; then
    log_test "PASS" "installer: --network-name VALUE and =VALUE, bridge within 15 bytes, a new network gets a free subnet, libvirt's MAC and forwarding, failed net-start fails the step, iptables on Debian (#68, #86)"
  else
    log_test "FAIL" "installer: --network-name VALUE and =VALUE, bridge within 15 bytes, a new network gets a free subnet, libvirt's MAC and forwarding, failed net-start fails the step, iptables on Debian (#68, #86)" "$r"
  fi
  rm -rf "$t"
}

# shellcheck disable=SC2016 # the script runs in its own bash
test_network_status_no_bridge() {
  local t c out r=""
  t=$(mktemp -d)
  mkdir -p "$t/bin"
  printf '#!/bin/bash\ncase "$*" in *"addr show"*) exit 1 ;; esac\nexit 0\n' >"$t/bin/ip"
  printf '#!/bin/bash\n[ "$1" = net-info ] && echo "Autostart: yes"\nexit 0\n' >"$t/bin/virsh"
  chmod +x "$t/bin/ip" "$t/bin/virsh"
  for c in status bridge; do
    out=$(PATH="$t/bin:$PATH" bash -c 'source "$1/../network/network-manager.sh" >/dev/null
      load_dcvm_config() { :; }; require_root() { :; }; check_dependencies() { :; }
      BRIDGE_NAME=virbr-gone NETWORK_NAME=net; main "$2"' _ "$SCRIPT_DIR" "$c" 2>&1) &&
      grep -qE 'none|bridge not found' <<<"$out" && r+="$c "
  done
  if [ "$r" = "status bridge " ]; then
    log_test "PASS" "network status and bridge print their fallback when the bridge is missing (#69)"
  else
    log_test "FAIL" "network status and bridge print their fallback when the bridge is missing (#69)" "$r"
  fi
  rm -rf "$t"
}

test_published_checksum() {
  if ! command -v curl >/dev/null 2>&1 || ! command -v sha512sum >/dev/null 2>&1; then
    log_test "SKIP" "published checksum verification" "needs curl and sha512sum"
    return
  fi
  local t rc
  t=$(mktemp -d)
  mkdir -p "$t/m1" "$t/m2" "$t/m3"
  head -c 4096 /dev/urandom >"$t/m1/img.qcow2"
  cp "$t/m1/img.qcow2" "$t/m2/img.qcow2"
  cp "$t/m1/img.qcow2" "$t/m3/img.qcow2"
  (cd "$t/m1" && sha256sum img.qcow2 >SHA256SUMS)
  (
    # shellcheck source=mirror-manager.sh
    source "$SCRIPT_DIR/mirror-manager.sh" >/dev/null 2>&1
    get_mirrors() { printf '%s\n' "file://$t/m1/img.qcow2" "file://$t/m2/img.qcow2"; }
    verify_published_checksum x "file://$t/m1/img.qcow2" "$t/m1/img.qcow2" 2>/dev/null
    echo "same=$?"
    verify_published_checksum x "file://$t/m2/img.qcow2" "$t/m2/img.qcow2" 2>/dev/null
    echo "other=$?"
    echo tampered >>"$t/m2/img.qcow2"
    verify_published_checksum x "file://$t/m2/img.qcow2" "$t/m2/img.qcow2" 2>/dev/null
    echo "tampered=$?"
    check_download x "file://$t/m2/img.qcow2" "$t/m2/img.qcow2" "" 2>/dev/null
    echo "tampered_check=$?"
    (cd "$t/m2" && sha256sum img.qcow2 >SHA256SUMS)
    verify_published_checksum x "file://$t/m2/img.qcow2" "$t/m2/img.qcow2" 2>/dev/null
    echo "self_vouched=$?"
    get_mirrors() { :; }
    verify_published_checksum x "file://$t/m3/img.qcow2" "$t/m3/img.qcow2" 2>/dev/null
    echo "none=$?"
    check_download x "file://$t/m3/img.qcow2" "$t/m3/img.qcow2" "" 2>/dev/null
    echo "none_check=$?"
    get_mirrors() { printf '%s\n' "file://$t/gone/img.qcow2" "file://$t/m2/img.qcow2"; }
    verify_published_checksum x "file://$t/m2/img.qcow2" "$t/m2/img.qcow2" 2>/dev/null
    echo "official_down=$?"
    get_mirrors() { echo "file://$t/m3/img.qcow2"; }
    (cd "$t/m3" && sha512sum img.qcow2 | sed 's/  / */' >SHA512SUMS)
    verify_published_checksum x "file://$t/m3/img.qcow2" "$t/m3/img.qcow2" 2>/dev/null
    echo "sha512=$?"
  ) >"$t/out"
  for rc in same=0 other=0 tampered=1 tampered_check=1 self_vouched=1 none=2 none_check=1 official_down=2 sha512=0; do
    if grep -qx "$rc" "$t/out"; then
      log_test "PASS" "published checksum ($rc)"
    else
      log_test "FAIL" "published checksum ($rc)" "$(tr '\n' ' ' <"$t/out")"
    fi
  done
  rm -rf "$t"
}

# shellcheck disable=SC2317 # stubs
test_download_hardening() {
  local t r
  t=$(mktemp -d)
  r=$(
    source "$SCRIPT_DIR/mirror-manager.sh" >/dev/null 2>&1
    [ -z "$(get_mirrors 'Fedora-Cloud-Base-Generic-../../../../etc/x.x86_64.qcow2')" ] && echo "traversal-refused"
    [ -n "$(get_mirrors "Fedora-Cloud-Base-Generic-${FEDORA_VERSION}.x86_64.qcow2")" ] && echo "fedora-known"
    curl() {
      printf '%s\n' "$@" >"$t/args"
      return 1
    }
    test_mirror_speed https://m1/img.qcow2 "$t" 0
    grep -qx -- '--proto-redir' "$t/args" && echo "ranking-https-only"
    rank_mirrors() { :; }
    curl() {
      while [ $# -gt 0 ]; do
        [ "$1" = -o ] && echo "$2" >"$t/tmpname"
        shift
      done
      return 1
    }
    download_with_mirrors debian-13-genericcloud-amd64.qcow2 "$t/img.qcow2" 1024 >/dev/null 2>&1
    [[ "$(cat "$t/tmpname" 2>/dev/null)" == "$t/img.qcow2.tmp."* && "$(cat "$t/tmpname")" != "$t/img.qcow2.tmp.$$" ]] && echo "random-temp"
  )
  if [ "$(echo $r)" = "traversal-refused fedora-known ranking-https-only random-temp" ]; then
    log_test "PASS" "template download: exact image names, https-only mirror ranking, unpredictable temp file (#126, #193)"
  else
    log_test "FAIL" "template download: exact image names, https-only mirror ranking, unpredictable temp file (#126, #193)" "$(echo $r)"
  fi
  rm -rf "$t"
}

# shellcheck disable=SC2317 # stubs
test_repo_fetch_https() {
  local t
  t=$(mktemp -d)
  (
    curl() {
      echo "$*" >>"$t/curl"
      return 1
    }
    wget() {
      echo "$*" >>"$t/wget"
      return 1
    }
    fetch_repo_file dcvm "$t/x"
    repo_commit_sha
    list_repo_files
    command_exists() { [ "$1" != curl ]; }
    fetch_repo_file dcvm "$t/x"
    repo_commit_sha
    list_repo_files
    eval "$(sed -n '/^load_common()/,/^}/p' "$SCRIPT_DIR/../installation/install-dcvm.sh")"
    DCVM_CHECKOUT=""
    load_common
  ) >/dev/null 2>&1
  if [ "$(grep -c . "$t/curl")" = 5 ] && [ "$(grep -c -- '--proto =https --proto-redir =https' "$t/curl")" = 5 ] &&
    [ "$(grep -c . "$t/wget")" = 5 ] && [ "$(grep -c -- '--max-redirect=0' "$t/wget")" = 5 ]; then
    log_test "PASS" "installer and self-update fetch code over https only, without following redirects to http (#127)"
  else
    log_test "FAIL" "installer and self-update fetch code over https only, without following redirects to http (#127)" "$(cat "$t/curl" "$t/wget" 2>&1 | tr '\n' ';')"
  fi
  rm -rf "$t"
}

# shellcheck disable=SC2034,SC2317 # stubs and the paths do_revert reads
test_self_update_revert_and_lock() {
  local t r="" f="$SCRIPT_DIR/../installation/self-update.sh" post="$SCRIPT_DIR/../installation/post-update.sh"
  t=$(mktemp -d)
  mkdir -p "$t/lib/installation" "$t/backups/dcvm-backup-1/lib/installation"
  printf '#!/bin/sh\necho pre-revert >>"%s/calls"\n' "$t" >"$t/lib/installation/pre-revert.sh"
  printf '#!/bin/sh\necho post-update >>"%s/calls"\n' "$t" >"$t/backups/dcvm-backup-1/lib/installation/post-update.sh"
  chmod +x "$t/lib/installation/pre-revert.sh" "$t/backups/dcvm-backup-1/lib/installation/post-update.sh"
  echo old >"$t/backups/dcvm-backup-1/dcvm"
  (
    eval "$(sed -n '/^new_stage()/,/^}/p; /^do_revert()/,/^}/p' "$f")"
    INSTALL_BIN="$t" INSTALL_LIB="$t/lib" BACKUP_DIR="$t/backups"
    get_current_version() { echo 0.9.11; }
    create_backup_dir() { :; }
    validate_backup() { :; }
    install_dcvm_tree() { rm -rf "$3" && mv "$1/lib" "$3" && mv "$1/dcvm" "$2/dcvm"; }
    do_revert <<<1
  ) >"$t/out" 2>&1
  [ "$(tr '\n' ' ' <"$t/calls" 2>/dev/null)" = "pre-revert post-update " ] && r+="services-after-revert "
  (
    eval "$(sed -n '/^lock_self_update()/,/^}/p' "$f")"
    BACKUP_DIR="$t/backups"
    create_backup_dir() { :; }
    exec 8>>"$t/backups/.lock"
    flock 8
    (lock_self_update) && echo "second-update-ran"
    exec 8>&-
    (lock_self_update) && echo "lock-free-again"
  ) >"$t/lock" 2>&1
  grep -q 'Another dcvm self-update is running' "$t/lock" && ! grep -q second-update-ran "$t/lock" &&
    grep -q lock-free-again "$t/lock" && r+="one-at-a-time "
  ! grep -q -- '--fix' "$post" && grep -q 'install_dcvm_services' "$post" && r+="no-silent-fix "
  if [ "$r" = "services-after-revert one-at-a-time no-silent-fix " ]; then
    log_test "PASS" "self-update: revert reinstalls the services, one update at a time, no doctor --fix after an update (#125, #145, #194)"
  else
    log_test "FAIL" "self-update: revert reinstalls the services, one update at a time, no doctor --fix after an update (#125, #145, #194)" "$r; $(tr '\n' ';' <"$t/lock")"
  fi
  rm -rf "$t"
}

# shellcheck disable=SC2317 # stubs
test_build_lock() {
  local t b out
  t=$(mktemp -d)
  b="$t/storage/templates/builds"
  mkdir -p "$b"
  out=$(
    DATACENTER_BASE="$t" DCVM_CALLER_ROLE=root
    vm_disks() { :; }
    legacy_references() { return 1; }
    backup_builds() { :; }
    : >"$b/test-aaaaaaaaaaaa.img"
    exec 8>>"$b/.lock"
    flock -s 8
    [ -z "$(prune_builds)" ] && [ -f "$b/test-aaaaaaaaaaaa.img" ] && echo "kept while a create holds builds"
    exec 8>&-
    hold_builds
    [ "$(prune_builds)" = test-aaaaaaaaaaaa.img ] && echo "own hold prunes"
    (
      exec 9>>"$b/.lock"
      flock -n -s 9 && ! flock -n -x 9
    ) && echo "hold kept shared"
  )
  if [ "$(echo $out)" = "kept while a create holds builds own hold prunes hold kept shared" ]; then
    log_test "PASS" "builds: no prune while a create or restore holds builds (#137)"
  else
    log_test "FAIL" "builds: no prune while a create or restore holds builds (#137)" "$(echo $out)"
  fi
  rm -rf "$t"
}

# shellcheck disable=SC2317 # stubs
test_installer_base_owner() {
  local t r=""
  t=$(mktemp -d)
  mkdir -p "$t/dc"
  chmod 777 "$t/dc"
  run() {
    (
      eval "$(sed -n '/^check_directory_structure()/,/^}/p' "$SCRIPT_DIR/../installation/install-dcvm.sh")"
      print_status_log() { :; }
      chown() { echo "chown $*" >>"$t/calls"; }
      DATACENTER_BASE="$t/dc"
      eval "${1:-}"
      check_directory_structure
    ) >/dev/null 2>&1
  }
  run || [ -e "$t/dc/vms" ] || r+="open-base-refused "
  chmod 755 "$t/dc"
  run 'stat() { echo "0 755"; }' && grep -q "chown root:root $t/dc/vms " "$t/calls" 2>/dev/null && r+="root-base-used "
  if [ "$r" = "open-base-refused root-base-used " ]; then
    log_test "PASS" "installer refuses a data folder other users own or can write, and makes its folders root-owned (#191)"
  else
    log_test "FAIL" "installer refuses a data folder other users own or can write, and makes its folders root-owned (#191)" "$r"
  fi
  rm -rf "$t"
}

# Functions only, never main: it would uninstall the test host.
# shellcheck disable=SC2317 # stubs
test_uninstall_survivors_and_pools() {
  local t f="$SCRIPT_DIR/../installation/uninstall-dcvm.sh" out
  t=$(mktemp -d)
  mkdir -p "$t/rec" "$t/dc/vms" "$t/dc/storage"
  touch "$t/rec/a" "$t/rec/b"
  (
    eval "$(sed -n '/^removable_data_dir()/,/^}/p; /^delete_network_vms()/,/^}/p; /^bridge_zone()/,/^}/p; /^remove_dcvm_pools()/,/^}/p' "$f")"
    ui_step() { :; }
    vm_on_network() { :; }
    virsh() {
      case "$1" in
      list) printf 'a\nb\n' ;;
      undefine) [ "$2" = a ] ;;
      pool-list) printf 'p1\np2\n' ;;
      pool-dumpxml) if [ "$2" = p1 ]; then echo "<path>$t/dc/storage/pool</path>"; else echo "<path>/var/lib/libvirt/images</path>"; fi ;;
      pool-undefine) echo "$2" >>"$t/pools" ;;
      esac
    }
    delete_network_vms net "$t/rec"
    [ "$DELETED_VMS/$KEPT_VMS" = 1/b ] && [ ! -e "$t/rec/a" ] && [ -e "$t/rec/b" ] && echo "survivor keeps its record"
    remove_dcvm_pools ""
    remove_dcvm_pools /
    [ ! -e "$t/pools" ] && echo "empty base removes no pool"
    remove_dcvm_pools "$t/dc"
    [ "$(cat "$t/pools" 2>/dev/null)" = p1 ] && echo "only the dcvm pool"
    virsh() { [ "$1" != list ]; }
    delete_network_vms net "$t/rec"
    [ -e "$t/rec/b" ] && echo "unlisted keeps records"
    virsh() { [ "$1" != list ] || echo b; }
    delete_network_vms net "$t/rec"
    [ ! -e "$t/rec" ] && echo "records go with the last VM"
    firewall-cmd() { echo "no zone"; }
    [ "$(bridge_zone virbr-dc)" = libvirt ] && echo "no zone falls back"
    firewall-cmd() { echo trusted; }
    [ "$(bridge_zone virbr-dc)" = trusted ] && echo "bound zone kept"
  ) >"$t/out" 2>/dev/null
  out=$(cat "$t/out")
  if [ "$(echo $out)" = "survivor keeps its record empty base removes no pool only the dcvm pool unlisted keeps records records go with the last VM no zone falls back bound zone kept" ] &&
    grep -q 'load_dcvm_config "$CONFIG_FILE"' "$f"; then
    log_test "PASS" "uninstall keeps surviving VMs' owner records, removes only dcvm's pools, falls back from 'no zone' (#154, #155, #192)"
  else
    log_test "FAIL" "uninstall keeps surviving VMs' owner records, removes only dcvm's pools, falls back from 'no zone' (#154, #155, #192)" "$(echo $out)"
  fi
  rm -rf "$t"
}

test_disable_root_and_nfs_subnet() {
  local t out
  t=$(mktemp -d)
  out=$(
    source "$SCRIPT_DIR/../core/create-vm.sh" >/dev/null 2>&1
    FORCE_MODE=true VM_USERNAME=tester VM_PASSWORD=testpass123 FLAG_DISABLE_ROOT=true
    setup_root_access >/dev/null 2>&1
    echo "$ENABLE_ROOT"
  )
  if [ "$out" = n ]; then
    log_test "PASS" "create --disable-root (force mode: root off)"
  else
    log_test "FAIL" "create --disable-root (force mode: root off)" "ENABLE_ROOT=$out"
  fi
  out=$(
    source "$SCRIPT_DIR/../core/create-vm.sh" >/dev/null 2>&1
    FORCE_MODE=true VM_USERNAME=tester VM_PASSWORD=testpass123
    setup_root_access >/dev/null 2>&1
    echo "$ENABLE_ROOT"
  )
  if [ "$out" = y ]; then
    log_test "PASS" "create -f without --disable-root (root on, unchanged)"
  else
    log_test "FAIL" "create -f without --disable-root (root on, unchanged)" "ENABLE_ROOT=$out"
  fi
  if (
    source "$SCRIPT_DIR/../core/create-vm.sh" >/dev/null 2>&1
    FORCE_MODE=true VM_USERNAME=tester VM_PASSWORD=testpass123 FLAG_DISABLE_ROOT=true
    FLAG_ROOT_PASSWORD=rootpass123 FLAG_ENABLE_ROOT=y
    setup_root_access
  ) >/dev/null 2>&1; then
    log_test "FAIL" "create --disable-root with -r (rejected)" "Expected failure but got success"
  else
    log_test "PASS" "create --disable-root with -r (rejected)"
  fi

  generate_test_userdata tester n "" "$t/default.yaml"
  NETWORK_SUBNET=192.168.100 generate_test_userdata tester n "" "$t/subnet.yaml"
  if grep -q '"10.10.10.1:.*/nfs-share /mnt/shared nfs' "$t/default.yaml" &&
    grep -q '"192.168.100.1:.*/nfs-share /mnt/shared nfs' "$t/subnet.yaml"; then
    log_test "PASS" "guest NFS mount uses NETWORK_SUBNET"
  else
    log_test "FAIL" "guest NFS mount uses NETWORK_SUBNET" "$(grep -h 'mnt/shared nfs' "$t"/*.yaml | tr '\n' ' ')"
  fi
  rm -rf "$t"
}

# shellcheck disable=SC2317 # stubs
test_installer_checkout_trust() {
  local base t r=""
  local parent=$HOME
  # Every folder above the checkout must be the caller's; CI containers mount HOME from another uid.
  [ "$(id -u)" = 0 ] && parent=/root
  base=$(mktemp -d "$parent/.dcvm-trust-test.XXXXXX") || return
  t=$(mktemp -d)
  mk_checkout() {
    mkdir -p "$1/lib/installation" "$1/lib/utils"
    : >"$1/dcvm"
    : >"$1/lib/installation/install-dcvm.sh"
    echo "echo sourced >>'$t/marker'" >"$1/lib/utils/common.sh"
    chmod -R go-w "$1"
  }
  trust_sourced() {
    rm -f "$t/marker"
    (
      eval "$(sed -n '/^checkout_root()/,/^}/p; /^load_common()/,/^}/p' "$SCRIPT_DIR/../installation/install-dcvm.sh")"
      DCVM_REPO_SLUG=x/y DCVM_REPO_BRANCH=main SUDO_UID=$(id -u)
      curl() { return 1; }
      wget() { return 1; }
      DCVM_CHECKOUT=$(checkout_root "$1") || DCVM_CHECKOUT=""
      load_common
    ) >/dev/null 2>&1
    [ -f "$t/marker" ]
  }
  mk_checkout "$base/good"
  mkdir -p "$base/ww/dl" "$base/ww/utils"
  mk_checkout "$base/ww/repo"
  echo "echo sourced >>'$t/marker'" >"$base/ww/utils/common.sh"
  : >"$base/ww/dl/install-dcvm.sh"
  chmod 777 "$base/ww"
  mk_checkout "$base/gw"
  chmod g+w "$base/gw/lib/utils/common.sh"
  trust_sourced "$base/good/lib/installation/install-dcvm.sh" && r+="checkout "
  trust_sourced "$base/ww/repo/lib/installation/install-dcvm.sh" && r+="world-writable-parent "
  trust_sourced "$base/ww/dl/install-dcvm.sh" && r+="planted-next-to-download "
  trust_sourced "" && r+="bash-c "
  trust_sourced "$base/gw/lib/installation/install-dcvm.sh" && r+="group-writable-file "
  if [ "$r" = "checkout " ]; then
    log_test "PASS" "installer sources only a checkout no other user can write to"
  else
    log_test "FAIL" "installer sources only a checkout no other user can write to" "sourced: $r"
  fi
  rm -rf "$base" "$t"
}

# shellcheck disable=SC2317 # stubs
test_uninstall_exact_matches() {
  local t
  t=$(mktemp -d)
  mkdir -p "$t/dc/vms" "$t/dc/storage" "$t/other"
  (
    eval "$(sed -n '/^vm_on_network()/,/^}/p; /^removable_data_dir()/,/^}/p; /^domains_using_dir()/,/^}/p' "$SCRIPT_DIR/../installation/uninstall-dcvm.sh")"
    virsh() {
      echo " Interface   Type      Source            Model    MAC"
      echo "-------------------------------------------------------------"
      echo " vnet0       network   datacenter-net2   virtio   52:54:00:00:00:01"
    }
    vm_on_network a datacenter-net && echo "matched datacenter-net"
    vm_on_network a datacenter-net2 || echo "missed datacenter-net2"
    removable_data_dir "$t/dc" >/dev/null || echo "refused $t/dc"
    for d in "" / /var /etc/ "$t/other" "$t/dc/../other"; do
      removable_data_dir "$d" >/dev/null && echo "accepted '$d'"
    done
    virsh() { case "$1" in list) echo keep ;; domblklist) printf ' Type Device Target Source\n file disk vda %s/dc/vms/keep/keep-disk.qcow2\n' "$t" ;; esac }
    [ "$(domains_using_dir "$t/dc")" = keep ] || echo "missed a VM still using $t/dc"
    [ -z "$(domains_using_dir "$t/other")" ] || echo "flagged $t/other"
  ) >"$t/out" 2>&1
  if [ ! -s "$t/out" ]; then
    log_test "PASS" "uninstall matches the network exactly and deletes only a dcvm data folder"
  else
    log_test "FAIL" "uninstall matches the network exactly and deletes only a dcvm data folder" "$(tr '\n' ';' <"$t/out")"
  fi
  rm -rf "$t"
}

# Read, never run: a missing root check would make main uninstall the test host.
test_uninstall_root_and_leftovers() {
  local f="$SCRIPT_DIR/../installation/uninstall-dcvm.sh" r
  r=$(awk '/^main\(\) \{/,/^}/ { if (/^  require_root$/) print "root"; else if (/require_confirmation|systemctl|virsh|rm -|groupdel/) print "acts" }' "$f" | head -1)
  if [ "$r" = root ] && grep -q 'userdel "$NFS_SQUASH_USER"' "$f" && grep -q 'pool-undefine' "$f" &&
    grep -q -- '--remove-service=nfs' "$f"; then
    log_test "PASS" "uninstall needs root first, removes the NFS user, pools and firewalld services (#101)"
  else
    log_test "FAIL" "uninstall needs root first, removes the NFS user, pools and firewalld services (#101)" "$(tr '\n' ' ' <<<"$r")"
  fi
}

test_suite_installs_only_on_request() {
  local calls
  calls=$(grep -n 'install_missing_test_deps$' "${BASH_SOURCE[0]}" | grep -v 'INSTALL_DEPS" = true ] &&')
  if [ -z "$calls" ]; then
    log_test "PASS" "test suite installs packages only with --install-deps (#103)"
  else
    log_test "FAIL" "test suite installs packages only with --install-deps (#103)" "$calls"
  fi
}

# shellcheck disable=SC2317 # stubs
test_network_name_exact() {
  local r
  r=$(
    virsh() {
      printf ' Interface   Type      Source    Model    MAC\n----------------------------------------\n'
      case "${*: -1}" in
      other) echo ' vnet0       network   default   virtio   52:54:00:00:00:09' ;;
      two) printf ' vnet1       network   net       virtio   52:54:00:00:00:01\n vnet2       network   net       virtio   52:54:00:00:00:02\n' ;;
      esac
    }
    NETWORK_NAME=net
    is_vm_in_network other && echo "other-matched"
    is_vm_in_network two || echo "two-missed"
    echo "mac=$(get_vm_mac two)"
  )
  if [ "$r" = "mac=52:54:00:00:00:01" ]; then
    log_test "PASS" "NETWORK_NAME=net matches only VMs on 'net', and one MAC per VM (#90)"
  else
    log_test "FAIL" "NETWORK_NAME=net matches only VMs on 'net', and one MAC per VM (#90)" "$(tr '\n' ' ' <<<"$r")"
  fi
}

# shellcheck disable=SC2317 # stubs
test_backup_console_password() {
  local t ts=20260101_120000 mode
  t=$(mktemp -d)
  : >"$t/disk.qcow2"
  printf ' 1    vm1    shut off\n' >"$t/list"
  echo "shut off" >"$t/state"
  (
    load_backup_sh_for_test "$t"
    stub_backup_tools "$t"
    eval "stub_$(declare -f virsh)"
    virsh() {
      if [ "$1" = dumpxml ]; then
        [[ " $* " == *" --security-info "* ]] && pw=" passwd='s3cret'"
        echo "<domain><name>vm1</name><devices><graphics type='vnc' port='-1'${pw:-} listen='127.0.0.1'/></devices></domain>"
      else
        stub_virsh "$@"
      fi
    }
    DATE=$ts COMPRESSION_ENABLED=false
    free_bytes() { echo $((1 << 40)); }
    get_vm_disk_path() { echo "$t/disk.qcow2"; }
    prepare_vm_disk() { :; }
    write_base_record() { :; }
    vm_owner_uid() { echo 1000; }
    vm_login() { :; }
    backup_vm vm1
    export_backup vm1 latest "$t/out" </dev/null
  ) >/dev/null 2>&1
  local cfg="$t/backups/vm1-$ts/vm1-config-$ts.xml"
  mode="$(stat -c %a "$cfg" 2>/dev/null) $(stat -c %a "$t/backups/vm1-$ts" 2>/dev/null)"
  [ -z "$(find "$t/backups/vm1-$ts" -type f ! -perm 600)" ] || mode+=" open-files"
  if grep -q "passwd='s3cret'" "$cfg" 2>/dev/null && [ "$mode" = "600 700" ] &&
    tar -xzOf "$t/out/vm1-$ts.tar.gz" "./vm1-config-$ts.xml" 2>/dev/null | grep -q "<graphics type='vnc' port='-1' listen=" &&
    ! tar -xzOf "$t/out/vm1-$ts.tar.gz" 2>/dev/null | grep -q s3cret; then
    log_test "PASS" "backup keeps the console password (600 files, 700 folder), export drops it"
  else
    log_test "FAIL" "backup keeps the console password (600 files, 700 folder), export drops it" "modes: $mode; $(head -c 200 "$cfg" 2>/dev/null)"
  fi
  rm -rf "$t"
}

# shellcheck disable=SC2317 # stubs
test_backup_delete_ids_and_user_export() {
  local t r="" a=20260101_100000 b=20260101_120000 ts
  t=$(mktemp -d)
  mkdir -p "$t/bin" "$t/pkg"
  for ts in $a $b; do
    mkdir -p "$t/backups/vm1-$ts"
    echo disk >"$t/backups/vm1-$ts/vm1-disk-$ts.qcow2"
    echo '<domain><name>vm1</name></domain>' >"$t/backups/vm1-$ts/vm1-config-$ts.xml"
  done
  cp "$t/backups/vm1-$a/"* "$t/pkg/"
  echo test >"$t/pkg/login"
  tar -czf "$t/pkg.tar.gz" -C "$t/pkg" .
  printf '#!/bin/sh\necho opened >>"%s/guestfish"\n' "$t" >"$t/bin/guestfish"
  chmod +x "$t/bin/guestfish"
  run() { (PATH="$t/bin:$PATH" && load_backup_sh_for_test "$t" && stub_backup_tools "$t" && wget() { :; } && prune_builds() { :; } && "$@") </dev/null >"$t/log" 2>&1; }
  run eval 'DCVM_CALLER_ROLE=user DCVM_CALLER_UID=0 export_backup vm1 latest "$t/u"'
  [ -f "$t/u/vm1-$b.tar.gz" ] && [ ! -e "$t/guestfish" ] && grep -q 'your keys' "$t/log" && r+="user-export-no-guestfish "
  run export_backup vm1 latest "$t/r"
  [ -f "$t/r/vm1-$b.tar.gz" ] && [ -e "$t/guestfish" ] && r+="root-export-scrubs "
  run main delete vm1 latest && [ ! -d "$t/backups/vm1-$b" ] && [ -d "$t/backups/vm1-$a" ] && r+="latest "
  ! run main delete vm1 02.01.2026 && [ -d "$t/backups/vm1-$a" ] && r+="no-match-fails "
  run main delete vm1 vm1-01.01.2026-1 --yes && [ ! -d "$t/backups/vm1-$a" ] && r+="two-args "
  ! run main delete vm1 01.01.2026 && r+="nothing-left-fails "
  run eval 'restore_vm() { :; }; import_backup "$t/pkg.tar.gz"'
  [ "$(stat -c %a "$t/backups/vm1-$a" 2>/dev/null)" = 700 ] && [ -n "$(ls "$t/backups/vm1-$a")" ] &&
    [ -z "$(find "$t/backups/vm1-$a" -type f ! -perm 600)" ] && r+="import-700-600 "
  if [ "$r" = "user-export-no-guestfish root-export-scrubs latest no-match-fails two-args nothing-left-fails import-700-600 " ]; then
    log_test "PASS" "backup delete <vm> <id|latest> without asking, fails when nothing matches; user exports never open the disk; imports are 700/600"
  else
    log_test "FAIL" "backup delete <vm> <id|latest> without asking, fails when nothing matches; user exports never open the disk; imports are 700/600" "$r | $(tail -2 "$t/log" | tr '\n' ' ')"
  fi
  rm -rf "$t"
}

test_installer_starts_dcvm_vms_only() {
  local t
  t=$(mktemp -d)
  if (
    set -e
    eval "$(sed -n '/^start_existing_vms()/,/^}/p' "$SCRIPT_DIR/../installation/install-dcvm.sh")"
    print_status_log() { :; }
    virsh() {
      case "$1" in
      list) [ "${2:-}" = --all ] && printf 'dcvm1\nother1\n' ;;
      domiflist)
        echo " Interface   Type      Source           Model    MAC"
        if [ "$2" = dcvm1 ]; then echo " vnet0       network   datacenter-net   virtio   52:54:00:00:00:01"; else echo " vnet1       network   default          virtio   52:54:00:00:00:02"; fi
        ;;
      start) echo "$2" >>"$t/started" ;;
      esac
    }
    NETWORK_NAME=datacenter-net
    start_existing_vms
    echo done >"$t/finished"
  ) >/dev/null 2>&1 && [ -f "$t/finished" ] && [ "$(cat "$t/started" 2>/dev/null)" = dcvm1 ]; then
    log_test "PASS" "installer starts only dcvm-network VMs (and survives set -e)"
  else
    log_test "FAIL" "installer starts only dcvm-network VMs (and survives set -e)" "started: $(tr '\n' ' ' <"$t/started" 2>/dev/null)"
  fi
  rm -rf "$t"
}

test_ui_output() {
  local out
  out=$(TERM=xterm-256color LANG=C.UTF-8 NO_COLOR=1 bash -c 'source "$1" >/dev/null 2>&1
    printf "A\tBB\nx\t✓\nyyy\tz\n" | ui_table
    ui_box "web is booting" "Address    10.10.10.50" "Login      ubuntu"
    ui_step ok Disk 30G' _ "$SCRIPT_DIR/common.sh")
  if ! grep -q $'\033' <<<"$out"; then
    log_test "PASS" "ui output has no escape codes with NO_COLOR"
  else
    log_test "FAIL" "ui output has no escape codes with NO_COLOR"
  fi
  if [ "$(sed -n 1p <<<"$out")" = "  A    BB" ] && [ "$(sed -n 2p <<<"$out")" = "  x    ✓" ] &&
    [ "$(sed -n 3p <<<"$out")" = "  yyy  z" ]; then
    log_test "PASS" "ui_table aligns columns by characters"
  else
    log_test "FAIL" "ui_table aligns columns by characters" "$(sed -n 1,3p <<<"$out" | tr '\n' '|')"
  fi
  local widths
  widths=$(sed -n '5,8p' <<<"$out" | LC_ALL=C.UTF-8 bash -c 'while IFS= read -r l; do echo "${#l}"; done' | sort -u | wc -l)
  if [ "$widths" -eq 1 ] && grep -q '╭─ web is booting ─' <<<"$out"; then
    log_test "PASS" "ui_box lines have the same width"
  else
    log_test "FAIL" "ui_box lines have the same width" "$(sed -n '5,8p' <<<"$out" | tr '\n' '|')"
  fi
  if grep -qx '  ✓ Disk            30G' <<<"$out"; then
    log_test "PASS" "ui_step layout"
  else
    log_test "FAIL" "ui_step layout" "$(tail -1 <<<"$out")"
  fi
  out=$(TERM=xterm-256color LANG=C LC_ALL=C bash -c 'source "$1" >/dev/null 2>&1; ui_step ok Disk 30G; ui_step fail Copy x' _ "$SCRIPT_DIR/common.sh")
  if grep -q '^  + Disk' <<<"$out" && grep -q '^  x Copy' <<<"$out"; then
    log_test "PASS" "ui symbols fall back to ASCII outside UTF-8"
  else
    log_test "FAIL" "ui symbols fall back to ASCII outside UTF-8" "$out"
  fi
}

test_ui_columns() {
  local out
  out=$(TERM=xterm-256color LANG=C.UTF-8 NO_COLOR=1 bash -c 'source "$1" >/dev/null 2>&1
    printf "NAME\tIP\tVCPU\nweb\t\t2\nctf\t10.10.10.5\t\n" | ui_table
    ui_next "dcvm backup restore dcvm-selftest-long" "put it back" "dcvm list" "all VMs"' _ "$SCRIPT_DIR/common.sh")
  if [ "$(sed -n 2p <<<"$out")" = "  web   —           2" ] && [ "$(sed -n 3p <<<"$out")" = "  ctf   10.10.10.5  —" ]; then
    log_test "PASS" "ui_table keeps empty cells in their column"
  else
    log_test "FAIL" "ui_table keeps empty cells in their column" "$(sed -n 1,3p <<<"$out" | tr '\n' '|')"
  fi
  if grep -qx '    dcvm backup restore dcvm-selftest-long  put it back' <<<"$out" &&
    grep -qx '    dcvm list                               all VMs' <<<"$out"; then
    log_test "PASS" "ui_next sizes the command column to the longest command (#56)"
  else
    log_test "FAIL" "ui_next sizes the command column to the longest command (#56)" "$(grep 'dcvm ' <<<"$out" | tr '\n' '|')"
  fi
}

# shellcheck disable=SC2317 # stubs
test_backup_list_columns() {
  local out
  out=$(
    TERM=xterm-256color LANG=C.UTF-8 NO_COLOR=1
    load_backup_sh_for_test /nonexistent >/dev/null 2>&1
    list_backup_timestamps_desc() { printf '20261104_100133\n20261103_090000\n'; }
    get_backup_disk_path() { echo "/b/$1-disk-$2.qcow2.gz"; }
    get_backup_config_path() { echo "/b/$1-config-$2.xml"; }
    file_bytes() { echo 7408779264; }
    check_vm_exists() { return 1; }
    list_backups maintainer-peer-long-name
  )
  local h r
  h=$(grep -m1 'TAKEN' <<<"$out" | awk '{ print index($0, "TAKEN") }')
  r=$(grep -m1 'maintainer-peer-long-name-04.11.2026-1 ' <<<"$out" | awk '{ print index($0, "2026-11-04 10:01") }')
  if [ -n "$h" ] && [ "$h" -gt 0 ] && [ "$h" = "$r" ] && grep -q 'newest' <<<"$out" && grep -q '6.9 GB' <<<"$out" && grep -q '14 GB' <<<"$out"; then
    log_test "PASS" "backup list columns line up with long IDs (#56)"
  else
    log_test "FAIL" "backup list columns line up with long IDs (#56)" "$(tr '\n' '|' <<<"$out")"
  fi
}

# shellcheck disable=SC2317 # stubs
test_delete_without_iptables_dir() {
  local t out
  t=$(mktemp -d)
  out=$(
    source "$SCRIPT_DIR/../core/delete-vm.sh" >/dev/null 2>&1
    IPTABLES_RULES_FILE="$t/missing/rules.v4"
    command_exists() { return 0; }
    iptables() { return 0; }
    iptables-save() { echo "# rules"; }
    cleanup_port_forwarding_for_vm 10.10.10.50 2221 8081 2>&1
    IPTABLES_RULES_FILE="$t/rules.v4"
    cleanup_port_forwarding_for_vm 10.10.10.50 2221 8081 2>&1
  )
  if ! grep -q 'No such file' <<<"$out" && [ ! -e "$t/missing" ] && [ "$(cat "$t/rules.v4" 2>/dev/null)" = "# rules" ]; then
    log_test "PASS" "delete saves iptables rules only where iptables-persistent keeps them (#54)"
  else
    log_test "FAIL" "delete saves iptables rules only where iptables-persistent keeps them (#54)" "$(tr '\n' '|' <<<"$out")"
  fi
  rm -rf "$t"
}

# shellcheck disable=SC2317,SC2034 # stubs; globals read by do_update
# shellcheck disable=SC2317 # helpers used in subshells
test_socket_policy() {
  if ! command -v python3 >/dev/null 2>&1; then
    log_test "SKIP" "socket server policy (python3 not installed)"
    return
  fi
  local t r="" uid srv
  t=$(mktemp -d)
  uid=$(id -u)
  mkdir -p "$t/base/backups" "$t/state/vms"
  printf 'DATACENTER_BASE="%s"\n' "$t/base" >"$t/conf"
  printf 'vms=2\n' >"$t/limits"
  printf 'owner_uid=99999\nowner=someone\n' >"$t/state/vms/rootvm"
  echo "iso data" >"$t/x.iso"
  start_srv() {
    python3 -I -S "$SCRIPT_DIR/../server/dcvm-server.py" --listen "$t/sock" --dry-run --state "$t/state" \
      --config "$t/conf" --limits "$t/limits" --role "$uid=$1" 2>"$t/server.log" &
    srv=$!
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      [ -S "$t/sock" ] && break
      sleep 0.2
    done
  }
  stop_srv() {
    kill "$srv" 2>/dev/null
    wait "$srv" 2>/dev/null
    rm -f "$t/sock"
  }
  ask() { DCVM_SOCKET="$t/sock" DCVM_ORIGIN="${ORIGIN:-agent}" DATACENTER_BASE=/evil python3 -I -S "$SCRIPT_DIR/../server/dcvm-client.py" "$@" 2>&1 </dev/null | tee -a "$t/answers"; }
  start_srv user
  grep -q '"argv": \["list"\]' <<<"$(ask list)" && grep -q '"DCVM_CALLER_ROLE": "user"' <<<"$(ask list)" && r+="list "
  local out
  out=$(ask create web -f -p s3cret -m 1024 --json)
  grep -q '"argv": \["create", "web", "-f", "-m", "1024", "--json"\]' <<<"$out" && grep -q '"secrets": \["password"\]' <<<"$out" &&
    ! grep -q s3cret <<<"$out" && grep -q '^state=ready' "$t/state/vms/web" && grep -q "^owner_uid=$uid" "$t/state/vms/web" &&
    grep -q '"DCVM_QUOTA_LIMITS": "8 16384 200"' <<<"$out" && r+="create "
  grep -q 'invalid VM name' <<<"$(ask create all -f)" && r+="reserved "
  grep -q 'graphics must be' <<<"$(ask create web2 --graphics vnc,listen=0.0.0.0)" && r+="graphics "
  grep -q 'os must be 1-9' <<<"$(ask create web2 --os 12)" && r+="os-path "
  grep -q 'you have no VM named rootvm' <<<"$(ask start rootvm)" && r+="foreign "
  grep -q '"argv": \["start", "web"\]' <<<"$(ask start web)" && r+="own "
  grep -q 'needs --yes' <<<"$(ask delete web)" && r+="yes-needed "
  grep -q '"argv": \["delete", "web"\]' <<<"$(ask delete web --yes)" && r+="delete "
  grep -q 'needs --yes' <<<"$(ORIGIN=terminal ask delete web)" && r+="origin "
  mkdir -p "$t/base/backups/rootvm-x-20260101_120000" "$t/base/backups/web-20260101_120000"
  echo "$uid" >"$t/base/backups/rootvm-x-20260101_120000/owner"
  echo "$uid" >"$t/base/backups/web-20260101_120000/owner"
  grep -q 'no backups of rootvm' <<<"$(ask backup export rootvm 20260101_120000 "$t")" && r+="backup-prefix "
  grep -q '"argv": \["backup", "delete", "web", "01.01.2026-1"\]' <<<"$(ask backup delete web 01.01.2026-1)" &&
    grep -q '"argv": \["backup", "delete", "web", "01.01.2026-12:00:00"\]' <<<"$(ask backup delete web 20260101_120000)" &&
    grep -q '"argv": \["backup", "delete", "web", "01.01.2026"\]' <<<"$(ask backup delete web-01.01.2026)" &&
    grep -q '"argv": \["backup", "delete", "web", "latest"\]' <<<"$(ask backup delete web latest --yes)" && r+="backup-delete "
  out=$(ask backup restore web web-01.01.2026-1)
  grep -q '"argv": \["backup", "restore", "web", "01.01.2026-1"\]' <<<"$out" &&
    grep -q '"argv": \["backup", "restore", "web", "latest", "--yes"\]' <<<"$(ask backup restore web --yes latest)" && r+="restore-id "
  grep -q '"DCVM_QUOTA_LIMITS": "8 16384 200"' <<<"$out" && r+="restore-quota "
  grep -q '"argv": \["backup", "export", "web", "20260101_120000", "--full"\]' <<<"$(ask backup export web --full 20260101_120000 "$t")" &&
    grep -q '"argv": \["backup", "export", "web", "--full"\]' <<<"$(ask backup export web "$t" --full)" && r+="export-full "
  raw_export() {
    python3 -I -S -c 'import json, os, socket, struct, sys
fd = os.open(sys.argv[2], getattr(os, "O_PATH", 0) if sys.argv[3] == "path" else os.O_RDONLY)
d = json.dumps({"v": 1, "argv": ["backup", "export", "web", "20260101_120000", "fd:3"], "stdin": 0, "stdout": 1, "stderr": 2}).encode()
s = socket.socket(socket.AF_UNIX)
s.connect(sys.argv[1])
s.sendmsg([struct.pack(">I", len(d)) + d], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, struct.pack("4i", 0, 1, 2, fd))])
n = struct.unpack(">I", s.recv(4))[0]
print(json.loads(s.recv(n))["exit"])' "$t/sock" "$@" 2>/dev/null | tail -1
  }
  [ "$(raw_export "$t/x.iso" path)" = 77 ] && [ "$(raw_export "$t/x.iso" read)" = 77 ] &&
    grep -q '"DCVM_EXPORT_FD"' <<<"$(ask backup export web 20260101_120000 "$t")" && r+="export-fd "
  grep -q 'only goes with create' <<<"$(ask start web -p hunter2)" && ! grep -q hunter2 "$t/state/audit.log" &&
    grep -q '"secrets": \["password"\]' <<<"$(ask create web5 -p=hunter2 --os 4)" && grep -q 'write -p VALUE' <<<"$(ask create web6 -phunter2)" &&
    grep -q 'does nothing with an ISO' <<<"$(ask create-iso web7 --iso "$t/x.iso" -p hunter2)" && ! grep -q hunter2 "$t/state/audit.log" && r+="secret-forms "
  grep -q '"argv": \["fix-lock", "web", "--verbose"\]' <<<"$(ask fix-lock web --verbose)" &&
    grep -q '"argv": \["info", "web", "--json"\]' <<<"$(ask info --json web)" && r+="arg-order "
  grep -q 'help is shown by your dcvm command' <<<"$(ask delete web --help)" && r+="help-deny "
  rm -f "$t/state/vms/web5"
  grep -q 'needs a dcvm admin' <<<"$(ask self-update)" && r+="admin-only "
  out=$(ask create isovm -o "$t/x.iso")
  grep -q "\"-o\", \"$t/base/vms/isovm/installer.iso\"" <<<"$out" && [ "$(cat "$t/base/vms/isovm/installer.iso" 2>/dev/null)" = "iso data" ] && r+="iso-fd "
  grep -q 'over your VM quota' <<<"$(ask create web3 -f)" && r+="quota "
  if [ "$uid" -eq 0 ]; then r+="iso-unreadable "; else grep -q 'cannot open ISO' <<<"$(ask create isovm2 -o /etc/shadow)" && r+="iso-unreadable "; fi
  grep -q '"decision": "deny"' "$t/state/audit.log" && grep -q '"argv": \["list"\], "decision": "start"' "$t/state/audit.log" && r+="audit "
  stop_srv
  start_srv none
  grep -q 'not in the dcvm group' <<<"$(ask list)" && r+="no-group "
  stop_srv
  start_srv admin
  grep -q '"argv": \["self-update"\]' <<<"$(ask self-update)" && r+="admin "
  mkdir -p "$t/home/.ssh" && echo "ssh-ed25519 AAAAtest test@x" >"$t/home/.ssh/id_ed25519.pub"
  grep -q '"DCVM_SSH_PUBKEY_FILE"' <<<"$(HOME="$t/home" ask create adminvm -f)" && r+="admin-key "
  mkdir -p "$t/base/vms/leftover" && echo keep >"$t/base/vms/leftover/disk.qcow2"
  grep -q 'left over' <<<"$(ask create-iso leftover --iso "$t/x.iso")" && [ -f "$t/base/vms/leftover/disk.qcow2" ] && r+="admin-leftover "
  stop_srv
  out=$(
    python3 -I -S - "$SCRIPT_DIR/../server" "$t" 2>&1 <<'PY'
import importlib.util, json, os, signal, socket, struct, sys, threading, time
def load(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), os.path.join(sys.argv[1], name + ".py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m
s, c, t = load("dcvm-server"), load("dcvm-client"), sys.argv[2]
s.STATE, s.RUN, s.CONFIG, s.LIMITS = t + "/h", t + "/h/run", t + "/conf", t + "/limits"
real_run = s.run_module
defined = set()
def fake_run(ctx, _conn, argv, *_a):
    os.makedirs(os.path.join(ctx["staged_dir"], "installer.iso"))
    defined.update(argv[1:2] if argv[1] == "real" else [])
    return 0
s.run_module, s.domain_known = fake_run, lambda vm: vm in defined
for vm in ("ghost", "real"):
    ctx = {"uid": 4242, "user": "u", "role": "user", "origin": "agent", "files": {}}
    s.execute(ctx, None, ["create"] + s.parse_create(ctx, [vm, "-f"], False), {}, {})
ghost = s.registry_read("ghost") is None and not os.path.exists(t + "/base/vms/ghost")
if ghost and (s.registry_read("real") or {}).get("state") == "ready":
    print("create-release")
s.DCVM = "/bin/sh"
if real_run(ctx, socket.socketpair()[0], ["-c", "kill -TERM $$"], {}, {}) == 143:
    print("signal-rc")
srv = socket.socket(socket.AF_UNIX)
srv.bind(t + "/fake.sock")
srv.listen(1)
def serve():
    conn, _ = srv.accept()
    conn.recv(65536)
    time.sleep(0.5)
    os.kill(os.getpid(), signal.SIGINT)
    while conn.recv(64):
        pass
    d = json.dumps({"exit": -15}).encode()
    conn.sendall(struct.pack(">I", len(d)) + d)
threading.Thread(target=serve, daemon=True).start()
c.SOCKET = t + "/fake.sock"
if c.talk(b'{"v": 1}', c.Files(), c.connect()) == 130:
    print("client-int")
real_socket = socket.socket
class Refused(socket.socket):
    def connect(self, _addr):
        raise PermissionError
c.socket.socket = Refused
try:
    c.connect()
except SystemExit as e:
    if e.code == 77:
        print("client-group")
os.environ["HOME"] = t + "/nokey"
try:
    c.main(["create", "k1", "-f"])
except SystemExit as e:
    if e.code == 77 and not os.path.exists(t + "/nokey/.ssh"):
        print("client-nokey")
srv2 = real_socket(socket.AF_UNIX)
srv2.bind(t + "/deny.sock")
srv2.listen(1)
def deny():
    conn, _ = srv2.accept()
    conn.recv(65536)
    d = json.dumps({"exit": 77, "error": "over your VM quota", "show": True}).encode()
    conn.sendall(struct.pack(">I", len(d)) + d)
threading.Thread(target=deny, daemon=True).start()
socket.socket = real_socket
c.SOCKET = t + "/deny.sock"
os.environ["HOME"] = t + "/denied"
try:
    c.main(["create", "k2", "-f"])
except SystemExit as e:
    if e.code == 77 and not os.listdir(t + "/denied/.ssh"):
        print("client-refused-key")
PY
  )
  for w in create-release signal-rc client-int client-group client-nokey client-refused-key; do grep -qx "$w" <<<"$out" && r+="$w "; done
  echo "$out" >>"$t/answers"
  local want="list create reserved graphics os-path foreign own yes-needed delete origin backup-prefix backup-delete restore-id restore-quota export-full export-fd secret-forms arg-order help-deny admin-only iso-fd quota iso-unreadable audit no-group admin admin-key admin-leftover create-release signal-rc client-int client-group client-nokey client-refused-key "
  if [ "$r" = "$want" ]; then
    log_test "PASS" "socket server: roles, ownership, quotas, secrets, files and --yes enforced"
  else
    log_test "FAIL" "socket server: roles, ownership, quotas, secrets, files and --yes enforced" "missing: $(comm -13 <(tr ' ' '\n' <<<"$r" | sort) <(tr ' ' '\n' <<<"$want" | sort) | tr '\n' ' ') | $(tr '\n' ' ' <"$t/answers" | cut -c1-600)"
  fi
  rm -rf "$t"
}

test_socket_hardening() {
  if ! command -v python3 >/dev/null 2>&1; then
    log_test "SKIP" "socket server hardening (python3 not installed)"
    return
  fi
  local t out r="" w
  t=$(mktemp -d)
  mkdir -p "$t/h/vms" "$t/base/backups/web-20260101_120000"
  printf 'DATACENTER_BASE="%s"\n' "$t/base" >"$t/conf"
  : >"$t/limits"
  echo 4242 >"$t/base/backups/web-20260101_120000/owner"
  printf 'owner_uid=9999\nowner=bob\n' >"$t/h/vms/web"
  printf 'owner_uid=9999\nowner=bob\n' >"$t/h/vms/taken"
  out=$(
    timeout 120 python3 -I -S - "$SCRIPT_DIR/../server" "$t" 2>&1 <<'PY'
import importlib.util, json, os, signal, socket, struct, sys, threading, time
spec = importlib.util.spec_from_file_location("dcvm_server", os.path.join(sys.argv[1], "dcvm-server.py"))
s = importlib.util.module_from_spec(spec)
spec.loader.exec_module(s)
t = sys.argv[2]
s.STATE, s.RUN, s.CONFIG, s.LIMITS, s.AUDIT = t + "/h", t + "/h/run", t + "/conf", t + "/limits", t + "/h/audit.log"
real_run, s.domain_known = s.run_module, lambda vm: False
user = lambda: {"uid": 4242, "user": "u", "role": "user", "origin": "agent", "files": {}}
def answer(sock):
    n = struct.unpack(">I", sock.recv(4))[0]
    return json.loads(sock.recv(n))
if not s.IPV4.match("10.10.10.050") and not s.IPV4.match("10.10.10.256") and s.IPV4.match("10.10.10.50") \
        and s.IPV4.match("10.0.0.0") and not s.OS_VARIANT.match("-x") and s.OS_VARIANT.match("win10"):
    print("regex")
s.REQUEST_TIMEOUT = 1
a, b = socket.socketpair()
def trickle():
    b.send(struct.pack(">I", 100))
    for _ in range(10):
        time.sleep(0.3)
        b.send(b"x")
    b.close()
threading.Thread(target=trickle, daemon=True).start()
t0, msg = time.monotonic(), ""
try:
    s.recv_request(a)
except s.Denied as e:
    msg = str(e)
if time.monotonic() - t0 < 2 and "too long" in msg:
    print("deadline")
s.REQUEST_TIMEOUT = 5
s.ROLE_MAP[os.getuid()] = None
a, b = socket.socketpair()
t0 = time.monotonic()
s.handle(a)
resp = answer(b)
if time.monotonic() - t0 < 1 and resp.get("show") and "not in the dcvm group" in resp["error"]:
    print("role-first")
s.ROLE_MAP[os.getuid()] = "user"
slots = [s.take_slot(os.getuid()) for _ in range(s.MAX_PER_UID)]
a, b = socket.socketpair()
s.handle(a)
if "already have" in answer(b).get("error", ""):
    print("slots")
for fd in slots:
    os.close(fd)
def denied(f, *a):
    try:
        return "allowed %s" % f(*a)
    except s.Denied as e:
        return str(e)
def frame(payload, extra=b"", fds=()):
    a, b = socket.socketpair()
    b.sendmsg([struct.pack(">I", len(payload)) + payload + extra],
              [(socket.SOL_SOCKET, socket.SCM_RIGHTS, struct.pack("%di" % len(fds), *fds))] if fds else [])
    return a, b
bad = [denied(s.recv_request, frame(p, x)[0]) for p, x in ((b"", b""), (b"{", b""), (b"\xff\xfe", b""),
                                                            (b'{"v": 1, "argv": []}', b"x"), (b"[" * 5000, b""))]
if bad == ["malformed request"] * 5 and "don't match" in denied(s.recv_request, frame(b'{"v": true, "argv": []}')[0]):
    print("malformed")
a, b = frame(b"{")
s.handle(a)
resp = answer(b)
r, w = os.pipe()
a, b = frame(json.dumps({"v": 1, "argv": ["bogus"], "stdin": 0, "stdout": 1, "stderr": 3}).encode(), fds=(0, 1, 2, r))
s.handle(a)
resp2 = answer(b)
if resp["exit"] == 77 and resp["error"] == "malformed request" and resp2.get("show") and "unknown command: bogus" in resp2["error"]:
    print("deny-shown")
du = lambda *argv: denied(s.decide_user, user(), list(argv))
if "unknown command: bogus" in du("bogus") and du("list", "extra").startswith("usage: dcvm list") and \
        du("list", "--bogus").startswith("usage: dcvm list") and du("info", "web", "--json", "extra").startswith("usage: dcvm info") and \
        du("backup", "restore", "a", "b", "c", "extra").startswith("usage: dcvm backup restore") and \
        du("owner", "vm1", "alice") == "'owner' needs a dcvm admin" and "unknown command: dcvm template bogus" in du("template", "bogus") and \
        du("network", "ports", "setup") == "'network ports setup' needs a dcvm admin":
    print("typos")
ctx = user()
if s.decide_user(ctx, ["backup", "delete", "web"]) == ["backup", "delete", "web"] and ctx.get("interactive") and \
        ctx["lock"] == "backup-4242-web" and "HH:MM:SS" in du("backup", "delete", "web", "bogus"):
    print("backup-picker")
pc = lambda *a, iso=False: denied(s.parse_create, dict(user(), files={3: 0}), list(a), iso)
if "invalid package list" in pc("xvm", "-k", "nginx apache2") and "'-k', 'nginx,curl'" in pc("xvm", "-k", " nginx , curl") and \
        all(pc(*a) == "give -o once" for a in (("xvm", "-o", "4", "-o", "5"), ("xvm", "-o=fd:3", "--os", "4"), ("xvm", "-o", "4", "-o", "fd:3"))) and \
        "at most 3650d" in pc("xvm", "--ttl", "99999d") and pc("xvm", "--ttl", "3650d").startswith("allowed") and \
        "does nothing with an ISO" in pc("xvm", "-k", "vim", iso=True) and "does nothing with an ISO" in pc("xvm", "--enable-root", iso=True) and \
        "like 20G" in pc("xvm", "-d", "10", iso=True) and \
        s.redact(["create", "--password=SECRET", "-pSECRET", "--tailscale-authkey=K"]) == ["create", "--password=***", "-p***", "--tailscale-authkey=***"]:
    print("create-args")
s.run_module = lambda *_a: 0
ctx = user()
argv = s.decide_user(ctx, ["backup", "delete", "web", "01.01.2026-1"])
held, t0 = s.lock("vm-web"), time.monotonic()
if s.execute(ctx, None, argv, {"argv": ["backup", "delete", "web", "01.01.2026-1"]}, {}) == 0 and time.monotonic() - t0 < 5:
    print("backup-lock")
def queued(change):
    with open(t + "/h/vms/mine", "w") as f:
        f.write("owner_uid=4242\nowner=u\n")
    ctx, req = user(), {"argv": ["delete", "mine", "--yes"]}
    argv, held = s.decide_user(ctx, req["argv"]), s.lock("vm-mine")
    def admin():
        with open(t + "/h/vms/mine", "a") as f:
            f.write(change)
        os.close(held)
    threading.Timer(0.5, admin).start()
    try:
        return "ran %s" % s.execute(ctx, None, argv, req, {})
    except s.Denied as e:
        return str(e)
if "no VM named mine" in queued("owner_uid=9999\n") and "is protected" in queued("protected=1\n"):
    print("recheck")
adm = {"uid": 0, "user": "a", "role": "admin", "origin": "agent", "files": {}}
s.admin_argv(adm, ["delete", "--yes", "web"])
if adm.get("vm") == "web" and s.admin_argv(adm, ["owner", "web", "bob"]) and adm["vm"] == "web":
    print("admin-lock")
ctx = user()
argv = ["create"] + s.parse_create(ctx, ["taken", "-f"], False)
held, t0 = s.lock("vm-taken"), time.monotonic()
try:
    s.execute(ctx, None, argv, {}, {})
except s.Denied as e:
    if "taken" in str(e) and time.monotonic() - t0 < 5:
        print("taken-first")
up = [False]
def fake_run(ctx, *_a):
    os.makedirs(ctx["staged_dir"])
    up[0] = None
    return 0
s.run_module, s.domain_known = fake_run, lambda vm: up[0]
ctx = user()
r, w = os.pipe()
rc = s.execute(ctx, None, ["create"] + s.parse_create(ctx, ["limbo", "-f"], False), {}, {"stderr": w})
if rc == 70 and s.registry_read("limbo") and os.path.isdir(t + "/base/vms/limbo") and b"libvirt did not answer" in os.read(r, 4096):
    print("libvirt-down")
s.audit(user(), ["create", "x" * 5000] + ["y"] * 100, "deny", reason="z" * 5000)
with open(s.AUDIT) as f:
    line = f.read().splitlines()[-1]
if len(line) < 2000 and "(5000 bytes)" in line and "(38 more)" in line:
    print("audit-clip")
s.DCVM = "/bin/sh"
out_r, out_w = os.pipe()
err_r, err_w = os.pipe()
conn, peer = socket.socketpair()
script = "head -c 3000000 /dev/zero; echo done >&2; exit 3"
pid = os.fork()
if pid == 0:
    os._exit(real_run(dict(user(), vm="web"), conn, ["-c", script], {}, {"stdout": out_w, "stderr": err_w}))
for _ in range(300):
    done, status = os.waitpid(pid, os.WNOHANG)
    if done:
        break
    time.sleep(0.1)
os.set_blocking(err_r, False)
if done and os.waitstatus_to_exitcode(status) == 3 and b"done" in os.read(err_r, 4096):
    print("relay")
def cancelled(script, tty=True):
    master, slave = os.openpty()
    _r, w = os.pipe()
    conn, peer = socket.socketpair()
    t0, pid = time.monotonic(), os.fork()
    if pid == 0:
        peer.close()
        signal.signal(signal.SIGINT, signal.default_int_handler)
        ctx = dict(user(), vm="web", mutating=True, interactive=tty)
        os._exit(real_run(ctx, conn, ["-c", script], {}, {"stdin": slave, "stdout": w, "stderr": w}))
    time.sleep(0.5)
    peer.close()
    for _ in range(150):
        done, status = os.waitpid(pid, os.WNOHANG)
        if done:
            os.close(master)
            return os.waitstatus_to_exitcode(status), time.monotonic() - t0
        time.sleep(0.1)
    os.kill(pid, signal.SIGKILL)
    return None, None
rc, took = cancelled("read x; exit 5")
if rc == 130 and took < 3:
    print("tty-cancel")
s.CANCEL_GRACE = 1
if cancelled("trap '' INT; read x; exit 5")[0] == 143 and cancelled("sleep 2; exit 5", tty=False)[0] == 5:
    print("tty-escalate")
PY
  )
  for w in regex deadline role-first slots malformed deny-shown typos backup-picker create-args backup-lock recheck admin-lock taken-first libvirt-down audit-clip relay tty-cancel tty-escalate; do grep -qx "$w" <<<"$out" && r+="$w "; done
  if [ "$r" = "regex deadline role-first slots malformed deny-shown typos backup-picker create-args backup-lock recheck admin-lock taken-first libvirt-down audit-clip relay tty-cancel tty-escalate " ]; then
    log_test "PASS" "socket server: request deadline, per-user slots, locks and re-checks under them, libvirt down, audit size, output relay, abandoned terminal, --ip/--os-variant"
  else
    log_test "FAIL" "socket server: request deadline, per-user slots, locks and re-checks under them, libvirt down, audit size, output relay, abandoned terminal, --ip/--os-variant" "$r | $(tr '\n' ' ' <<<"$out" | cut -c1-600)"
  fi
  rm -rf "$t"
}

test_socket_admin_locks_and_iso() {
  if ! command -v python3 >/dev/null 2>&1; then
    log_test "SKIP" "socket server admin locks and ISO quota (python3 not installed)"
    return
  fi
  local t out r="" w want="admin-vms admin-locks short-write iso-quota iso-charged restore-new-quota late-alarm running-kept create-iso-o early-deny "
  t=$(mktemp -d)
  mkdir -p "$t/h/vms" "$t/base/backups/web-20260101_120000"
  printf 'DATACENTER_BASE="%s"\n' "$t/base" >"$t/conf"
  echo 4242 >"$t/base/backups/web-20260101_120000/owner"
  printf 'owner_uid=4242\nowner=u\n' >"$t/h/vms/web"
  echo "iso data" >"$t/x.iso"
  head -c 5000 /dev/zero >"$t/big.iso"
  out=$(
    timeout 120 python3 -I -S - "$SCRIPT_DIR/../server" "$t" 2>&1 <<'PY'
import importlib.util, json, os, signal, socket, struct, subprocess, sys, threading, time
def load(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), os.path.join(sys.argv[1], name + ".py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m
s, c, t = load("dcvm-server"), load("dcvm-client"), sys.argv[2]
s.STATE, s.RUN, s.CONFIG, s.LIMITS, s.AUDIT = t + "/h", t + "/h/run", t + "/conf", t + "/limits", t + "/h/audit.log"
user = lambda: {"uid": 4242, "user": "u", "role": "user", "origin": "agent", "files": {}}
admin = lambda: {"uid": 0, "user": "a", "role": "admin", "origin": "agent", "files": {}}
def denied(f, *a):
    try:
        return "allowed %s" % (f(*a),)
    except s.Denied as e:
        return str(e)
av = s.admin_vms
if av(["backup", "restore", "web", "01.01.2026", "copy", "--yes"]) == ["copy"] and av(["restore", "--base", "x", "web"]) == ["web"] and \
        av(["start", "web"]) == ["web"] and av(["network", "ports", "add", "web"]) == ["web"] and av(["fix-lock", "--verbose", "web"]) == ["web"] and \
        av(["backup", "import", "/proc/self/fd/5", "new1"]) == ["new1"] and av(["create", "zz1,web", "-f"]) == ["zz1", "web"] and av(["stop", "--all"]) == []:
    print("admin-vms")
s.domain_known = lambda vm: False
ran = []
s.run_module = lambda ctx, *_a: ran.append(time.monotonic()) or 0
def waits(argv):
    ctx, held = admin(), s.lock("vm-web")
    final = s.admin_argv(ctx, argv)
    threading.Timer(0.6, os.close, [held]).start()
    t0 = time.monotonic()
    s.execute(ctx, None, final, {"argv": argv}, {})
    return ran[-1] - t0 >= 0.5
if waits(["create", "zz1,web", "-f"]) and waits(["backup", "restore", "web", "--yes"]) and waits(["start", "web"]):
    print("admin-locks")
real_write = os.write
os.write = lambda fd, b: real_write(fd, bytes(b[:1000]))
try:
    fd = os.open(t + "/big.iso", os.O_RDONLY)
    path = s.stage_iso(dict(admin(), reserved="iso1"), fd, "iso1")
finally:
    os.write = real_write
if os.path.getsize(path) == 5000:
    print("short-write")
with open(t + "/sparse.iso", "wb") as f:
    f.truncate(1024 ** 3 + 1)
with open(t + "/limits", "w") as f:
    f.write("disk_gb=21\n")
sparse = os.open(t + "/sparse.iso", os.O_RDONLY)
pc = lambda *a, iso=False: denied(s.parse_create, dict(user(), files={3: sparse}), list(a), iso)
if "over your disk (GB) quota: 0 used + 22 requested > 21" in pc("isovm", "--iso", "fd:3", iso=True) and pc("cloudvm", "-f", "-d", "20G").startswith("allowed"):
    print("iso-quota")
if "allowed" in denied(s.decide_backup, user(), ["restore", "web", "20260101_120000", "copy"]):
    print("restore-new-quota")
os.unlink(t + "/limits")
def module(ctx, *_a):
    s.registry_write("isovm", dict(s.registry_read("isovm"), state="ready", disk_gb=20))
    return 0
s.run_module, s.domain_known = module, lambda vm: s.registry_read(vm) is not None
ctx, small = user(), os.open(t + "/x.iso", os.O_RDONLY)
ctx["files"] = {3: small}
s.execute(ctx, None, ["create-iso"] + s.parse_create(ctx, ["isovm", "--iso", "fd:3"], True), {}, {})
if s.registry_read("isovm").get("disk_gb") == "21":
    print("iso-charged")
s.WRITING = False
try:
    s._alarm(signal.SIGALRM, None)
    print("late-alarm")
except TimeoutError:
    pass
def crash(ctx, *_a):
    os.makedirs(ctx["staged_dir"])
    ctx["proc"] = subprocess.Popen(["sleep", "5"])
    raise RuntimeError("relay broke")
s.run_module, s.domain_known = crash, lambda vm: False
ctx = user()
try:
    s.execute(ctx, None, ["create"] + s.parse_create(ctx, ["busy", "-f"], False), {}, {})
except RuntimeError:
    pass
ctx["proc"].kill()
if s.registry_read("busy") and os.path.isdir(t + "/base/vms/busy"):
    print("running-kept")
files = c.Files()
argv = c.attach_files(["create-iso", "ovm", "-o", t + "/x.iso"], files)
if argv == ["create-iso", "ovm", "--iso", "fd:3"] and pc("ovm", "-o", "fd:3", iso=True).startswith("allowed"):
    print("create-iso-o")
srv = socket.socket(socket.AF_UNIX)
srv.bind(t + "/deny.sock")
srv.listen(1)
def deny():
    conn, _ = srv.accept()
    d = json.dumps({"exit": 77, "error": "you already have 8 dcvm commands running", "show": True}).encode()
    conn.sendall(struct.pack(">I", len(d)) + d)
    conn.close()
th = threading.Thread(target=deny, daemon=True)
th.start()
c.SOCKET = t + "/deny.sock"
conn = c.connect()
th.join()
try:
    if c.talk(b'{"v": 1}', c.Files(), conn) == 77:
        print("early-deny")
except OSError as e:
    print("client raised %r" % e)
PY
  )
  for w in $want; do grep -qx "$w" <<<"$out" && r+="$w "; done
  if [ "$r" = "$want" ]; then
    log_test "PASS" "socket server: admins take every named VM's lock, ISO copy and quota, restore-as-new quota, late alarms, early denials (#119 #120 #135 #143 #186 #187 #188 #189)"
  else
    log_test "FAIL" "socket server: admins take every named VM's lock, ISO copy and quota, restore-as-new quota, late alarms, early denials (#119 #120 #135 #143 #186 #187 #188 #189)" "$r | $(tr '\n' ' ' <<<"$out" | cut -c1-600)"
  fi
  rm -rf "$t"
}

# shellcheck disable=SC2016,SC2034 # snippets are evaluated in q; the quota vars are read by within_quota
test_quota_atomic() {
  local t r="" start
  t=$(mktemp -d)
  mkdir -p "$t/vms"
  printf 'owner_uid=1001\ncpus=4\nmemory_mb=4096\ndisk_gb=50\n' >"$t/vms/old"
  printf 'owner_uid=1002\ncpus=8\nmemory_mb=4096\ndisk_gb=50\n' >"$t/vms/other"
  printf 'owner_uid=1001\nstate=creating\ncpus=2\nmemory_mb=2048\ndisk_gb=30\n' >"$t/vms/new1"
  q() { (DCVM_STATE_DIR="$t" DCVM_CALLER_UID=1001 DCVM_QUOTA_LIMITS="8 16384 200" && eval "$1") >"$t/out" 2>&1; }
  g() { DCVM_STATE_DIR="$t" registry_get "$@"; }
  q 'within_quota 4 1024 10 new1' && [ "$(g new1 cpus)/$(g new1 memory_mb)" = 4/2048 ] && r+="record "
  printf 'owner_uid=1001\nstate=creating\ncpus=0\nmemory_mb=0\ndisk_gb=0\n' >"$t/vms/new2"
  ! q 'within_quota 2 1024 10 new2' && grep -q "Over your quota" "$t/out" && [ "$(g new2 cpus)" = 0 ] && r+="refuse "
  rm -f "$t/vms/new2"
  q 'within_quota 3 8192 60 old && echo "$(registry_get old memory_mb)" && quota_release old' &&
    [ "$(head -1 "$t/out")" = 8192 ] && [ "$(g old memory_mb)/$(g old disk_gb)" = 4096/50 ] && r+="restore-release "
  if command -v flock >/dev/null 2>&1; then
    mkdir -p "$t/run/locks"
    flock "$t/run/locks/global" sleep 2 &
    sleep 0.5
    start=$SECONDS
    q 'within_quota 0 0 0 new1'
    [ $((SECONDS - start)) -ge 1 ] && r+="locked "
    wait
  else
    r+="locked "
  fi
  (DCVM_STATE_DIR="$t" && unset DCVM_QUOTA_LIMITS && within_quota 100 100000 1000 rootvm) && [ ! -e "$t/vms/rootvm" ] && r+="root "
  if [ "$r" = "record refuse restore-release locked root " ]; then
    log_test "PASS" "quota: real sizes checked and recorded under the global lock; a failed restore gives the charge back"
  else
    log_test "FAIL" "quota: real sizes checked and recorded under the global lock; a failed restore gives the charge back" "$r | $(tr '\n' ' ' <"$t/out")"
  fi
  rm -rf "$t"
}

test_services_hardening() {
  local units
  units=$(declare -f install_dcvm_services dcvm_services_ok)
  if grep -q '^TriggerLimitIntervalSec=0' <<<"$units" && grep -q "TriggerLimitIntervalSec=0' /etc/systemd/system/dcvm.socket" <<<"$units" &&
    grep -q 'create 0640 root root' <<<"$units" && grep -q '/etc/logrotate.d/dcvm' <<<"$DCVM_UNITS"; then
    log_test "PASS" "dcvm.socket has no trigger limit (doctor --fix upgrades it); the audit log is rotated"
  else
    log_test "FAIL" "dcvm.socket has no trigger limit (doctor --fix upgrades it); the audit log is rotated"
  fi
}

test_forward_cleanup_exact_ip() {
  local t out
  t=$(mktemp -d)
  mkdir -p "$t/bin"
  cat >"$t/bin/iptables" <<'STUB'
#!/bin/bash
case "$*" in
*"-L PREROUTING"*) printf 'num target prot opt source destination\n1 DNAT tcp -- 0.0.0.0/0 0.0.0.0/0 tcp dpt:2221 to:10.10.10.20:22\n2 DNAT tcp -- 0.0.0.0/0 0.0.0.0/0 tcp dpt:2222 to:10.10.10.2:22\n' ;;
*"-L FORWARD"*) printf 'num target prot opt source destination\n1 ACCEPT tcp -- 0.0.0.0/0 10.10.10.200 tcp dpt:22\n2 ACCEPT tcp -- 0.0.0.0/0 10.10.10.2 tcp dpt:22\n' ;;
*"-D"*) echo "$*" >>"${0%/*}/deleted" ;;
esac
STUB
  chmod +x "$t/bin/iptables"
  (PATH="$t/bin:$PATH" && save_iptables_rules() { :; } && cleanup_port_forwarding_for_vm 10.10.10.2 "" "") >/dev/null 2>&1
  out=$(cat "$t/bin/deleted" 2>/dev/null)
  if [ "$out" = "$(printf -- '-w -t nat -D PREROUTING 2\n-w -D FORWARD 2')" ]; then
    log_test "PASS" "deleting a VM removes only its own forwards, not those of .20 or .200"
  else
    log_test "FAIL" "deleting a VM removes only its own forwards, not those of .20 or .200" "$(tr '\n' '|' <<<"$out")"
  fi
  rm -rf "$t"
}

# shellcheck disable=SC1090,SC1091,SC2016 # stub scripts are written literally
test_forward_rules_scope() {
  local t out r=""
  t=$(mktemp -d)
  mkdir -p "$t/bin"
  cat >"$t/bin/iptables" <<'STUB'
#!/bin/bash
case "$*" in
*"-S PREROUTING"*) printf '%s\n' '-P PREROUTING ACCEPT' \
  '-A PREROUTING -p tcp -m tcp --dport 2221 -j DNAT --to-destination 10.10.10.5:22' \
  '-A PREROUTING ! -i virbr-dc -p tcp -m addrtype --dst-type LOCAL -m tcp --dport 8081 -j DNAT --to-destination 10.10.10.5:80' \
  '-A PREROUTING ! -i virbr-dc -p tcp -m addrtype --dst-type LOCAL -m tcp --dport 2222 -j DNAT --to-destination 10.10.10.50:22' \
  '-A PREROUTING -p tcp -m tcp --dport 2221 -j DNAT --to-destination 10.10.10.55:22' ;;
*"-I PREROUTING"* | *"-D"*) echo "$*" >>"${0%/*}/calls" ;;
esac
STUB
  chmod +x "$t/bin/iptables"
  (PATH="$t/bin:$PATH" && source "$SCRIPT_DIR/../network/port-forward.sh" && BRIDGE_NAME=virbr-dc &&
    setup_vm_forwarding web 10.10.10.5 2221 8081 192.0.2.1) >/dev/null 2>&1
  [ "$(cat "$t/bin/calls" 2>/dev/null)" = "$(printf '%s\n' \
    '-w -t nat -I PREROUTING ! -i virbr-dc -p tcp -m addrtype --dst-type LOCAL --dport 2221 -j DNAT --to-destination 10.10.10.5:22' \
    '-w -t nat -I PREROUTING ! -i virbr-dc -p tcp -m addrtype --dst-type LOCAL --dport 8081 -j DNAT --to-destination 10.10.10.5:80')" ] && r+="local-only "
  rm -f "$t/bin/calls"
  (PATH="$t/bin:$PATH" && save_iptables_rules() { :; } && cleanup_port_forwarding_for_vm 10.10.10.5 2221 8081) >/dev/null 2>&1
  out=$(grep -- '-t nat' "$t/bin/calls" 2>/dev/null)
  [ "$out" = "$(printf '%s\n' \
    '-w -t nat -D PREROUTING -p tcp -m tcp --dport 2221 -j DNAT --to-destination 10.10.10.5:22' \
    '-w -t nat -D PREROUTING ! -i virbr-dc -p tcp -m addrtype --dst-type LOCAL -m tcp --dport 8081 -j DNAT --to-destination 10.10.10.5:80')" ] && r+="remove-old-and-new "
  if [ "$r" = "local-only remove-old-and-new " ]; then
    log_test "PASS" "port forwards DNAT only traffic to the host, not from the bridge; removal matches old and new rules (#77)"
  else
    log_test "FAIL" "port forwards DNAT only traffic to the host, not from the bridge; removal matches old and new rules (#77)" "$r; $(tr '\n' '|' <<<"$out")"
  fi
  rm -rf "$t"
}

# shellcheck disable=SC2034,SC2317,SC1090,SC1091,SC2016 # stubs are written literally or called by the module
test_port_forward_records() {
  local t r="" out c pf="$SCRIPT_DIR/../network/port-forward.sh"
  t=$(mktemp -d)
  mkdir -p "$t/bin"
  cat >"$t/bin/iptables" <<'STUB'
#!/bin/bash
echo "$*" >>"${0%/*}/calls"
case "$*" in
*"-I PREROUTING"*"--dport 9001 "*) exit 1 ;;
*"-S PREROUTING"*) printf '%s\n' '-P PREROUTING ACCEPT' \
  '-A PREROUTING -m addrtype --dst-type LOCAL -j DOCKER' \
  '-A PREROUTING ! -i virbr-dc -p tcp -m addrtype --dst-type LOCAL -m tcp --dport 3000 -j DNAT --to-destination 10.10.10.5:22' \
  '-A PREROUTING -p tcp -m tcp --dport 2230 -j DNAT --to-destination 10.10.10.6:80' \
  '-A PREROUTING -p tcp -m tcp --dport 2222 -j DNAT --to-destination 110.10.10.5:22' \
  '-A PREROUTING -p tcp -j DNAT --to-destination 10.10.10.9:22' \
  '-A PREROUTING -p tcp -m tcp --dport 19000 -j DNAT --to-destination 10.10.10.7:22' ;;
*"-S FORWARD"*) printf '%s\n' '-P FORWARD ACCEPT' \
  '-A FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT' \
  '-A FORWARD -d 10.10.10.5/32 -p tcp -m tcp --dport 22 -m conntrack --ctstate DNAT -j ACCEPT' \
  '-A FORWARD -d 10.10.10.6/32 -p tcp -m tcp --dport 80 -j ACCEPT' \
  '-A FORWARD -d 10.10.10.0/24 -o virbr-dc -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT' \
  '-A FORWARD -d 110.10.10.5/32 -p tcp -m tcp --dport 22 -j ACCEPT' \
  '-A FORWARD -s 192.0.2.9/32 -d 10.10.10.5/32 -p tcp -m tcp --dport 22 -j ACCEPT' \
  '-A FORWARD -d 10.10.10.7/32 -p tcp -m tcp --dport 22 -j ACCEPT' ;;
*" -D "*) exit 1 ;;
esac
exit 0
STUB
  chmod +x "$t/bin/iptables"

  echo "old 10.10.10.6 4000 2230" >"$t/cmap"
  (PATH="$t/bin:$PATH" NETWORK_SUBNET=10.10.10 BRIDGE_NAME=virbr-dc SSH_PORT_START=3000 && get_port_mappings_file() { echo "$t/cmap"; } && cleanup_port_forwarding) >/dev/null 2>&1
  [ "$(grep -- ' -D ' "$t/bin/calls")" = "$(printf '%s\n' \
    '-w -t nat -D PREROUTING ! -i virbr-dc -p tcp -m addrtype --dst-type LOCAL -m tcp --dport 3000 -j DNAT --to-destination 10.10.10.5:22' \
    '-w -t nat -D PREROUTING -p tcp -m tcp --dport 2230 -j DNAT --to-destination 10.10.10.6:80' \
    '-w -D FORWARD -d 10.10.10.5/32 -p tcp -m tcp --dport 22 -m conntrack --ctstate DNAT -j ACCEPT' \
    '-w -D FORWARD -d 10.10.10.6/32 -p tcp -m tcp --dport 80 -j ACCEPT')" ] && r+="cleanup-exact "

  rm -f "$t/bin/calls"
  out=$(
    PATH="$t/bin:$PATH" BRIDGE_NAME=virbr-dc MAPPINGS_TMP="$t/tmp"
    source "$pf"
    cleanup_port_forwarding_for_vm() { echo "rollback $*" >>"$t/bin/calls"; }
    setup_vm_forwarding web 10.10.10.5 2221 9001 192.0.2.1 >/dev/null 2>&1
    echo "rc=$?"
  )
  [ "$out" = rc=1 ] && [ ! -s "$t/tmp" ] && grep -qx 'rollback 10.10.10.5 2221 9001' "$t/bin/calls" &&
    ! grep -qv -e '^-w ' -e '^rollback' "$t/bin/calls" && r+="half-forward-undone "

  printf '# VM_NAME VM_IP SSH_PORT HTTP_PORT\nold 10.10.10.7 3001 9001\n' >"$t/map"
  chmod 644 "$t/map"
  (
    PATH="$t/bin:$PATH" SSH_PORT_START=3000 HTTP_PORT_START=9000
    source "$pf"
    BRIDGE_NAME=virbr-dc NETWORK_SUBNET=10.10.10
    get_port_mappings_file() { echo "$t/map"; }
    check_vm_exists() { :; }
    is_vm_in_network() { :; }
    get_vm_state() { echo running; }
    get_vm_ip_trusted() { echo 10.10.10.5; }
    ip_held_by_other_vm() { return 1; }
    ss() { [[ "$*" != *":9000"* ]] || echo LISTEN; }
    detect_host_ip() { echo 192.0.2.1; }
    vm_login() { :; }
    save_iptables_rules() { :; }
    cmd_add web
  ) >/dev/null 2>&1
  grep -qx 'web 10.10.10.5 3002 9002' "$t/map" && [ "$(stat -c %a "$t/map")" = 600 ] && r+="custom-range-free-port "

  : >"$t/swept"
  for c in clear apply setup; do
    (
      source "$pf"
      flock() { return 1; }
      cleanup_port_forwarding() { echo "$c" >>"$t/swept"; }
      get_port_mappings_file() { echo "$t/map"; }
      virsh() { return 1; }
      "cmd_$c"
    ) >/dev/null 2>&1 && echo "$c ran" >>"$t/swept"
  done
  [ ! -s "$t/swept" ] && r+="locked "
  if [ "$r" = "cleanup-exact half-forward-undone custom-range-free-port locked " ]; then
    log_test "PASS" "port forwards: cleanup takes only dcvm's rules in its ranges or mappings, a half-made forward is undone and not recorded, custom ranges and busy ports, every writer locks (#85, #87, #156)"
  else
    log_test "FAIL" "port forwards: cleanup takes only dcvm's rules in its ranges or mappings, a half-made forward is undone and not recorded, custom ranges and busy ports, every writer locks (#85, #87, #156)" "$r; $(tr '\n' '|' <"$t/bin/calls" 2>/dev/null) $(tr '\n' '|' <"$t/swept")"
  fi

  r=""
  out=$(PATH="$t/bin:$PATH" && source "$pf" && cmd_rules 2>&1)
  grep -qE 'any +10\.10\.10\.9:22' <<<"$out" && ! grep -qE '2222 +10\.10\.10\.9' <<<"$out" && r+="rules-paired "
  out=$(source "$pf" && get_port_mappings_file() { echo "$t/map"; } && vm_visible() { return 1; } && cmd_show 2>&1)
  grep -q 'No saved port mappings' <<<"$out" && ! grep -q 'HTTP PORT' <<<"$out" && r+="show-none "
  (BRIDGE_NAME=virbr-dc && nft() { printf 'table inet libvirt_network {\n\toifname "virbr-dc" counter reject\n}\n'; } && libvirt_nft_rejects_forwards) &&
    ! (BRIDGE_NAME=virbr-other && nft() { printf 'table inet libvirt_network {\n\toifname "virbr-dc" counter reject\n}\n'; } && libvirt_nft_rejects_forwards) && r+="nft-backend "
  if [ "$r" = "rules-paired show-none nft-backend " ]; then
    log_test "PASS" "ports rules pairs each port with its own rule, ports show says none to users without forwards, libvirt's nftables rules are detected (#88)"
  else
    log_test "FAIL" "ports rules pairs each port with its own rule, ports show says none to users without forwards, libvirt's nftables rules are detected (#88)" "$r"
  fi

  r=""
  mkdir -p "$t/config/network"
  chmod 755 "$t/config/network"
  (DATACENTER_BASE="$t" && save_static_ip web 10.10.10.5)
  [ "$(stat -c %a "$t/config/network")" = 700 ] && [ "$(stat -c %a "$t/config/network/web.conf")" = 600 ] && r+="static-ip "
  chmod 644 "$t/map"
  (get_port_mappings_file() { echo "$t/map"; } && drop_port_mapping old)
  ! grep -q '^old ' "$t/map" && [ "$(stat -c %a "$t/map")" = 600 ] && r+="drop "
  rm -f "$t/port-mappings.txt"
  echo "web 10.10.10.5 2221 8081" >"$t/tmp"
  (source "$pf" && DATACENTER_BASE="$t" MAPPINGS_TMP="$t/tmp" && save_mappings_tmp_to_file) >/dev/null 2>&1
  [ "$(stat -c %a "$t/port-mappings.txt" 2>/dev/null)" = 600 ] && r+="setup "
  if [ "$r" = "static-ip drop setup " ]; then
    log_test "PASS" "port mappings and static IP records are readable by root only (#106)"
  else
    log_test "FAIL" "port mappings and static IP records are readable by root only (#106)" "$r"
  fi
  rm -rf "$t"
}

# shellcheck disable=SC2034,SC2317,SC1090,SC1091 # stubs are called by the module
test_port_mappings_kept_and_checked() {
  local t r="" out pf="$SCRIPT_DIR/../network/port-forward.sh"
  t=$(mktemp -d)
  printf '# VM_NAME VM_IP SSH_PORT HTTP_PORT\nweb 10.10.10.5 2221 8081\ndb 10.10.10.6 2222 8082\ngone 10.10.10.7 2223 8083\n' >"$t/port-mappings.txt"
  : >"$t/tmp"
  out=$(
    source "$pf"
    iptables() { :; }
    ss() { :; }
    echo "$(free_port 2221 2299 3 web "$t/tmp" "$t/port-mappings.txt") $(free_port 2221 2299 3 new "$t/tmp" "$t/port-mappings.txt")"
  )
  [ "$out" = "2221 2224" ] && r+="ports-reserved "
  echo "web 10.10.10.5 2221 8081" >"$t/tmp"
  (
    source "$pf"
    DATACENTER_BASE="$t" MAPPINGS_TMP="$t/tmp"
    get_port_mappings_file() { echo "$t/port-mappings.txt"; }
    check_vm_exists() { [ "$1" != gone ]; }
    save_mappings_tmp_to_file
  ) >/dev/null 2>&1
  [ "$(grep -v '^#' "$t/port-mappings.txt" | tr '\n' ';')" = "web 10.10.10.5 2221 8081;db 10.10.10.6 2222 8082;" ] && r+="rows-kept "
  printf 'web 10.10.10.5 2221 8081\ngone 10.10.10.7 2223 8083\nother 10.10.10.8 2224 8084\n' >"$t/port-mappings.txt"
  (
    source "$pf"
    get_port_mappings_file() { echo "$t/port-mappings.txt"; }
    lock_port_mappings() { :; }
    cleanup_port_forwarding() { :; }
    detect_host_ip() { echo 192.0.2.1; }
    allow_related() { :; }
    save_iptables_rules() { :; }
    check_vm_exists() { [ "$1" != gone ]; }
    ip_held_by_other_vm() { [ "$1" = 10.10.10.8 ]; }
    setup_vm_forwarding() { echo "forward $1" >>"$t/calls"; }
    cmd_apply
  ) >/dev/null 2>&1 || [ "$(cat "$t/calls" 2>/dev/null)" != "forward web" ] || r+="apply-checked "
  if [ "$r" = "ports-reserved rows-kept apply-checked " ]; then
    log_test "PASS" "ports setup keeps the rows of VMs it skipped and never gives their ports away, ports apply skips deleted VMs and addresses other VMs hold (#122, #123)"
  else
    log_test "FAIL" "ports setup keeps the rows of VMs it skipped and never gives their ports away, ports apply skips deleted VMs and addresses other VMs hold (#122, #123)" "$r; $out"
  fi
  rm -rf "$t"
}

# shellcheck disable=SC2034,SC2317,SC1090,SC1091 # stubs are called by the code under test
test_dhcp_hostile_and_partial() {
  local r="" out esc=$'\e'
  out=$( (
    set -euo pipefail
    NETWORK_NAME=net
    virsh() { return 1; }
    leases_table
    echo REACHED
  ) 2>&1)
  grep -q REACHED <<<"$out" && r+="inactive-network "
  out=$(
    NETWORK_NAME=net
    virsh() { printf ' h\n---\n 2030-01-01 00:00:00   52:54:00:00:00:01   ipv4   10.10.10.11/24   x%s[2Jy   -\n' "$esc"; }
    leases_table
    source "$SCRIPT_DIR/../network/dhcp.sh"
    cleanup_dhcp_lease() { return 0; }
    release_leases "52:54:00:00:00:01|10.10.10.11|a${esc}]52;c;eA==|no VM has this MAC" lease
  )
  grep -qF 'x?[2Jy' <<<"$out" && grep -qF 'a?]52;c;eA==' <<<"$out" && ! grep -qF "$esc" <<<"$out" && r+="no-escapes "
  (
    virsh() {
      case "$1" in
      list) printf 'a\nb\n' ;;
      domiflist)
        [ "$3" = a ] && return 1
        printf ' Interface Type Source Model MAC\n---\n vnet0 network net virtio 52:54:00:00:00:01\n'
        ;;
      esac
    }
    domain_macs
  ) >/dev/null 2>&1 || r+="partial-macs "
  if [ "$r" = "inactive-network no-escapes partial-macs " ]; then
    log_test "PASS" "DHCP lease tables survive an inactive network under set -e, guest hostnames reach the terminal without escapes, one unreadable VM stops stale-lease cleanup (#129, #138, #139)"
  else
    log_test "FAIL" "DHCP lease tables survive an inactive network under set -e, guest hostnames reach the terminal without escapes, one unreadable VM stops stale-lease cleanup (#129, #138, #139)" "$r"
  fi
}

# shellcheck disable=SC2034,SC2317,SC1090,SC1091,SC2016 # stubs are called by delete_all_vms
test_delete_all_shared_state() {
  local t r=""
  t=$(mktemp -d)
  run_delete_all() {
    (
      source "$SCRIPT_DIR/../core/delete-vm.sh" >/dev/null 2>&1
      DATACENTER_BASE="$t" NETWORK_NAME=net BRIDGE_NAME=br DNSMASQ_DIR="$t" NETWORK_SUBNET=10.10.10
      virsh() {
        [ "$1" = list ] && echo " 1    vm1    running"
        return 0
      }
      is_vm_in_network() { [ ! -e "$t/deleted" ]; }
      get_vm_state() { echo running; }
      shuf() { echo 1234; }
      get_port_mappings_file() { echo "$t/port-mappings.txt"; }
      save_iptables_rules() { :; }
      iptables() {
        case "$*" in
        "-w -t nat -S PREROUTING") printf '%s\n' '-A PREROUTING -p tcp -m tcp --dport 2230 -j DNAT --to-destination 10.10.10.5:22' \
          '-A PREROUTING -p tcp -m tcp --dport 18080 -j DNAT --to-destination 10.10.10.9:80' ;;
        "-t nat -L PREROUTING"*) printf 'num target prot opt source destination\n1 DNAT tcp -- 0.0.0.0/0 0.0.0.0/0 tcp dpt:2230 to:10.10.10.5:22\n2 DNAT tcp -- 0.0.0.0/0 0.0.0.0/0 tcp dpt:18080 to:10.10.10.9:80\n' ;;
        *"-L FORWARD"*) printf 'num target prot opt source destination\n1 ACCEPT all -- 0.0.0.0/0 110.10.10.7\n' ;;
        *-D*) echo "$*" >>"$t/calls" ;;
        esac
      }
      eval "$1"
      delete_all_vms
    ) <<<$'yes\n1234' >/dev/null 2>&1
  }
  printf '[{"ip-address": "10.10.10.5", "mac-address": "52:54:00:00:00:05"}]\n' >"$t/br.status"
  printf '# VM_NAME VM_IP SSH_PORT HTTP_PORT\nvm1 10.10.10.5 2230 8090\n' >"$t/port-mappings.txt"
  cp "$t/br.status" "$t/status.orig"
  cp "$t/port-mappings.txt" "$t/map.orig"
  run_delete_all 'delete_single_vm() { return 1; }'
  cmp -s "$t/br.status" "$t/status.orig" && cmp -s "$t/port-mappings.txt" "$t/map.orig" && [ ! -e "$t/calls" ] && r+="survivor-kept "
  run_delete_all 'delete_single_vm() { : >"$t/deleted"; }'
  [ "$(grep -c . "$t/port-mappings.txt")" = 1 ] && ! grep -q -- '-D FORWARD 1' "$t/calls" && [ "$(grep PREROUTING "$t/calls")" = \
    '-w -t nat -D PREROUTING -p tcp -m tcp --dport 2230 -j DNAT --to-destination 10.10.10.5:22' ] && r+="by-destination "
  if [ "$r" = "survivor-kept by-destination " ]; then
    log_test "PASS" "delete --all keeps a refused VM's lease, mapping and rules; removes rules by the mapping's destinations (#77)"
  else
    log_test "FAIL" "delete --all keeps a refused VM's lease, mapping and rules; removes rules by the mapping's destinations (#77)" "$r; $(tr '\n' '|' <"$t/calls" 2>/dev/null)"
  fi
  rm -rf "$t"
}

test_backup_exact_id_visibility() {
  local t r=""
  t=$(mktemp -d)
  mkdir -p "$t/backups/web-20260101_120000"
  : >"$t/backups/web-20260101_120000/web-disk-20260101_120000.qcow2"
  : >"$t/backups/web-20260101_120000/web-config-20260101_120000.xml"
  echo 1001 >"$t/backups/web-20260101_120000/owner"
  look() { (load_backup_sh_for_test "$t" >/dev/null 2>&1 && BACKUP_DIR="$t/backups" &&
    get_backup_disk_path web 20260101_120000 && get_backup_config_path web 20260101_120000) 2>/dev/null; }
  [ "$(DCVM_CALLER_ROLE=user DCVM_CALLER_UID=1001 look | grep -c .)" = 2 ] && r+="owner "
  [ -z "$(DCVM_CALLER_ROLE=user DCVM_CALLER_UID=1002 look)" ] && r+="other "
  [ "$(look | grep -c .)" = 2 ] && r+="root "
  if [ "$r" = "owner other root " ]; then
    log_test "PASS" "a backup id names only backups the caller owns"
  else
    log_test "FAIL" "a backup id names only backups the caller owns" "$r"
  fi
  rm -rf "$t"
}

test_iso_create_options() {
  local t r="" opts
  t=$(mktemp -d)
  mkdir -p "$t/bin"
  printf '#!/bin/bash\nprintf " Type Device Target Source\\n----\\n file cdrom hda /srv/iso/x.iso\\n file disk vda /srv/vm/vm-disk.qcow2\\n"\n' >"$t/bin/virsh"
  chmod +x "$t/bin/virsh"
  iso() { (source "$SCRIPT_DIR/../core/custom-iso.sh" >/dev/null 2>&1 && "$@") 2>&1; }
  opts=$(iso eval 'VM_NAME=vm DISK_PATH=/d INSTALL_ISO=/i NETWORK_NAME=n MEMORY=512 CPUS=1 DISK_SIZE=2G build_virt_install_opts && echo "${VIRT_INSTALL_OPTS[*]}"')
  grep -q -- '--disk path=/i,device=cdrom,readonly=on,format=raw ' <<<"$opts" && grep -q -- '--boot hd,cdrom' <<<"$opts" && grep -q -- '--import' <<<"$opts" &&
    ! grep -q -- '--cdrom' <<<"$opts" && r+="boot "
  opts=$(iso eval 'VM_NAME=vm DISK_PATH=/d INSTALL_ISO=/i NETWORK_NAME=n MEMORY=512 CPUS=1 DISK_SIZE=2G UEFI=true OS_VARIANT=win10 build_virt_install_opts && echo "${VIRT_INSTALL_OPTS[*]}"')
  grep -q -- '--boot uefi,hd,cdrom' <<<"$opts" && grep -q -- '--disk path=/d,format=qcow2 ' <<<"$opts" && grep -q -- '--network network=n ' <<<"$opts" && r+="uefi-win "
  grep -q 'needs a value' <<<"$(timeout 5 bash -c 'source "$1/../core/custom-iso.sh" >/dev/null 2>&1; parse_args web --iso' _ "$SCRIPT_DIR" 2>&1)" && r+="no-loop "
  grep -q 'Unknown option' <<<"$(iso parse_args web --bogus)" && r+="unknown "
  grep -q 'does nothing with an ISO' <<<"$(iso parse_args web -k vim)" && [ "$(iso ttl_seconds 3650d)" = 315360000 ] &&
    ! iso ttl_seconds 99999h >/dev/null && r+="cloud-opts-ttl "
  [ "$(PATH="$t/bin:$PATH" get_vm_disk_path vm)" = /srv/vm/vm-disk.qcow2 ] && r+="disk-not-iso "
  if [ "$r" = "boot uefi-win no-loop unknown cloud-opts-ttl disk-not-iso " ]; then
    log_test "PASS" "ISO VMs boot disk then ISO in one definition; UEFI, Windows devices, option errors"
  else
    log_test "FAIL" "ISO VMs boot disk then ISO in one definition; UEFI, Windows devices, option errors" "$r | $(tr '\n' ' ' <<<"$opts" | cut -c1-300)"
  fi
  rm -rf "$t"
}

# shellcheck disable=SC2034,SC2317 # stubs; globals are read by the sourced scripts
test_iso_and_display_safety() {
  local t r="" out
  t=$(mktemp -d)
  mkdir -p "$t/vms/vm"
  staged() {
    (
      source "$SCRIPT_DIR/../core/custom-iso.sh" >/dev/null 2>&1
      DCVM_CALLER_ROLE=user DATACENTER_BASE=$t VM_NAME=vm ISO_PATH=$t/vms/vm/installer.iso
      prompt_iso_path && echo accepted
    ) 2>&1
  }
  printf 'QFI\xfb\0\0\0\3' >"$t/vms/vm/installer.iso"
  grep -q 'the file you gave is a qcow2 disk image' <<<"$(staged)" && r+="qcow2 "
  { head -c 4096 /dev/zero && printf conectix && head -c 504 /dev/zero; } >"$t/vms/vm/installer.iso"
  grep -q 'vhd disk image' <<<"$(staged)" && r+="vhd-footer "
  head -c 40960 /dev/zero >"$t/vms/vm/installer.iso"
  [ "$(staged)" = accepted ] && r+="iso "
  (
    source "$SCRIPT_DIR/../core/create-vm.sh" >/dev/null 2>&1
    mkisofs() {
      umask >"$t/umask"
      : >cloud-init.iso
    }
    umask 022
    DATACENTER_BASE=$t VM_NAME=vm FORCE_MODE=true
    create_cloud_init_iso
  ) >/dev/null 2>&1
  [ "$(cat "$t/umask" 2>/dev/null)" = 0077 ] && r+="seed-umask "
  (
    source "$SCRIPT_DIR/../core/create-vm.sh" >/dev/null 2>&1
    caller_role() { echo root; }
    virt_install_with_vnc_password() { echo "$1" >"$t/create-pw"; }
    virt-install() { echo none >"$t/create-pw"; }
    virsh() { :; }
    FLAG_GRAPHICS=vnc DATACENTER_BASE=$t VM_NAME=vm VM_OS=debian12 FORCE_MODE=true
    install_vm
  ) >/dev/null 2>&1
  [[ "$(cat "$t/create-pw" 2>/dev/null)" =~ ^[A-Za-z0-9]{8}$ ]] && r+="create-pw "
  (
    source "$SCRIPT_DIR/../core/custom-iso.sh" >/dev/null 2>&1
    caller_role() { echo root; }
    ui_run() {
      shift
      "$@"
    }
    virt_install_with_vnc_password() { echo "$1" >"$t/iso-pw"; }
    virt-install() { echo none >"$t/iso-pw"; }
    virsh() { :; }
    register_vm() { :; }
    GRAPHICS=spice VM_NAME=vm VIRT_INSTALL_OPTS=()
    run_virt_install
  ) >/dev/null 2>&1
  [[ "$(cat "$t/iso-pw" 2>/dev/null)" =~ ^[A-Za-z0-9]{8}$ ]] && r+="iso-pw "
  out=$(
    source "$SCRIPT_DIR/../network/network-manager.sh" >/dev/null 2>&1
    caller_role() { echo root; }
    check_vm_exists() { :; }
    virsh() {
      case "$1" in
      dumpxml) echo "<domain><name>vm</name><devices></devices></domain>" ;;
      define) cp "$2" "$t/vnc.xml" ;;
      esac
    }
    cmd_vnc enable vm 2>&1
  )
  grep -q 'passwd="[A-Za-z0-9]\{8\}"' "$t/vnc.xml" 2>/dev/null && grep -q Password <<<"$out" && r+="vnc-enable-pw "
  if [ "$r" = "qcow2 vhd-footer iso seed-umask create-pw iso-pw vnc-enable-pw " ]; then
    log_test "PASS" "staged ISOs with disk-image headers refused, cloud-init seed made under umask 077, root's VNC/SPICE get a password"
  else
    log_test "FAIL" "staged ISOs with disk-image headers refused, cloud-init seed made under umask 077, root's VNC/SPICE get a password" "$r"
  fi
  rm -rf "$t"
}

# shellcheck disable=SC2034,SC2317,SC1090,SC1091,SC2030,SC2031 # stubs are called by the modules
test_stopped_vms_and_lifecycle_args() {
  local t r="" out
  t=$(mktemp -d)
  mkdir -p "$t/bin"
  printf '#!/bin/bash\necho "virsh $*" >>"%s/ran"\n' "$t" >"$t/bin/virsh"
  chmod +x "$t/bin/virsh"
  lease_virsh() {
    case "$1" in
    domstate) echo "$STATE" ;;
    domiflist) printf ' vnet0 network datacenter-net virtio 52:54:00:00:00:01\n' ;;
    net-dhcp-leases) printf ' 2026-01-01 00:00:00 52:54:00:00:00:01 ipv4 10.10.10.50/24 web -\n' ;;
    esac
    return 0
  }
  out=$(
    virsh() { lease_virsh "$@"; }
    STATE="shut off" NETWORK_SUBNET=10.10.10 get_vm_ip web
    STATE=running NETWORK_SUBNET=10.10.10 get_vm_ip_trusted web
  )
  [ "$out" = "$(printf 'N/A\n10.10.10.50')" ] && r+="ip "

  out=$(
    source "$SCRIPT_DIR/../network/port-forward.sh" >/dev/null 2>&1
    check_vm_exists() { :; }
    is_vm_in_network() { :; }
    lock_port_mappings() { :; }
    read_port_mappings() { :; }
    get_vm_state() { echo "shut off"; }
    get_vm_ip_trusted() { echo 10.10.10.50; }
    ip_held_by_other_vm() { return 1; }
    free_port() { echo 2221; }
    detect_host_ip() { echo 192.0.2.1; }
    setup_vm_forwarding() { echo FORWARDED; }
    allow_related() { :; }
    save_iptables_rules() { :; }
    vm_login() { :; }
    DATACENTER_BASE="$t" cmd_add web 2>&1
  )
  grep -q 'not running; start it first' <<<"$out" && ! grep -q FORWARDED <<<"$out" && r+="ports-add "

  out=$(
    source "$SCRIPT_DIR/../core/vm-manager.sh" >/dev/null 2>&1
    export DCVM_CALLER_ROLE=user DCVM_CALLER_UID=1001
    vm_owner_uid() { [ "$1" = web ] && echo 1001 || echo 0; }
    show_vm_table() { :; }
    read_port_mappings() { printf 'web 10.10.10.50 2221 8081\ndb 10.10.10.51 2222 8082\nlog 10.10.10.52 2223 8083\n'; }
    virsh() {
      [ "$1 ${2:-}" = "list --all" ] && echo " - web shut off"
      return 0
    }
    check_vm_exists() { :; }
    prepare_vm_disk() { :; }
    show_enhanced_status
    start_vms web
  )
  grep -q 'Port forwards.*1 VM ' <<<"$out" && grep -q 'dcvm network ports add web makes it' <<<"$out" && r+="user-hints "

  out=$(
    PATH="$t/bin:$PATH"
    source "$SCRIPT_DIR/../core/vm-manager.sh" >/dev/null 2>&1
    load_dcvm_config() { :; }
    check_vm_exists() { :; }
    get_vm_state() { echo "shut off"; }
    main console web 2>&1
  )
  grep -q 'web is shut off; start it first' <<<"$out" && [ ! -f "$t/ran" ] && r+="console "

  out=$(
    source "$SCRIPT_DIR/../core/vm-manager.sh" >/dev/null 2>&1
    load_dcvm_config() { :; }
    start_vms() { echo "start:$*"; }
    stop_vms() { echo "stop:$*"; }
    restart_vms() { echo "restart:$*"; }
    show_vm_table() { echo "list:$*"; }
    for a in "stop" "restart" "start" "stop --all --force" "stop web extra" "list --bogus" "stop web --force" "restart --all" "list --json" "stop all"; do
      # shellcheck disable=SC2086
      (main $a 2>&1) | grep -oE '^(start|stop|restart|list):.*|Usage' | tr '\n' ' '
      echo "|"
    done
  )
  [ "$out" = "$(printf '%s\n' 'Usage |' 'Usage |' 'Usage |' 'Usage |' 'Usage |' 'Usage |' 'stop:web true |' 'restart:--all false |' 'list:--json |' 'stop:all false |')" ] && r+="no-name "

  out=$(
    source "$SCRIPT_DIR/../core/vm-manager.sh" >/dev/null 2>&1
    check_vm_exists() { :; }
    get_vm_state() { echo running; }
    virsh() { echo "virsh $*" >&2; }
    stop_vms web true 2>&1
  )
  grep -q 'virsh destroy web' <<<"$out" && ! grep -q 'virsh shutdown' <<<"$out" && r+="force "

  out=$(
    source "$SCRIPT_DIR/../network/network-manager.sh" >/dev/null 2>&1
    set +e
    check_vm_exists() { return 1; }
    (main vnc --help)
    cmd_vnc bogus web 2>&1
  )
  grep -q 'dcvm network vnc - ' <<<"$out" && grep -q 'Unknown action: bogus' <<<"$out" && ! grep -q 'does not exist' <<<"$out" && r+="vnc "

  out=$(
    source "$SCRIPT_DIR/../core/delete-vm.sh" >/dev/null 2>&1
    load_dcvm_config() { :; }
    delete_single_vm() { echo "delete:$*"; }
    prune_builds() { :; }
    list_datacenter_vms() { :; }
    (main web --bogus 2>&1)
    (main web extra 2>&1)
    (main web --yes 2>&1)
  )
  [ "$(grep -c Usage <<<"$out")" = 2 ] && [ "$(grep -c '^delete:' <<<"$out")" = 1 ] && grep -q '^delete:web$' <<<"$out" && r+="delete-args "

  if command -v python3 >/dev/null 2>&1; then
    out=$(
      python3 -I -S - "$SCRIPT_DIR/../server/dcvm-server.py" <<'PY' 2>&1
import importlib.util, sys
spec = importlib.util.spec_from_file_location("srv", sys.argv[1])
s = importlib.util.module_from_spec(spec)
spec.loader.exec_module(s)
s.own_vm = lambda ctx, vm: vm
def ask(*argv):
    try:
        return " ".join(s.decide_user({"uid": 4242, "user": "u", "role": "user", "origin": "agent", "files": {}}, list(argv)))
    except s.Denied:
        return "denied"
print(ask("stop"), ask("restart"), ask("start"), ask("stop", "--all", "--force"), "|", ask("stop", "web", "--force"), "|", ask("restart", "--all"), "|", ask("start", "web", "--force"), "|", ask("stop", "all"))
PY
    )
    [ "$out" = "denied denied denied denied | stop web --force | restart --all | denied | stop all" ] && r+="server "
  else
    r+="server "
  fi

  if [ "$r" = "ip ports-add user-hints console no-name force vnc delete-args server " ]; then
    log_test "PASS" "stopped VMs have no IP and no port forward; start/stop/restart need a name or --all, stop --force; vnc and delete check their arguments"
  else
    log_test "FAIL" "stopped VMs have no IP and no port forward; start/stop/restart need a name or --all, stop --force; vnc and delete check their arguments" "$r; $(tr '\n' '|' <<<"$out" | cut -c1-300)"
  fi
  rm -rf "$t"
}

test_list_owner_column() {
  local t out_root out_user out_json
  t=$(mktemp -d)
  mkdir -p "$t/bin" "$t/state/vms"
  cat >"$t/bin/virsh" <<'STUB'
#!/bin/bash
case "$*" in
"list --all --name") printf 'web\ndb\n' ;;
domiflist*) printf ' Interface Type Source Model MAC\n vnet0 network datacenter-net virtio 52:54:00:00:00:01\n' ;;
domstate*) echo "shut off" ;;
dominfo*) printf 'CPU(s):         2\nMax memory:     2097152 KiB\n' ;;
esac
STUB
  chmod +x "$t/bin/virsh"
  printf 'owner_uid=1001\nowner=alice\n' >"$t/state/vms/web"
  table() { (PATH="$t/bin:$PATH" DCVM_STATE_DIR="$t/state" NETWORK_NAME=datacenter-net && source "$SCRIPT_DIR/../core/vm-manager.sh" >/dev/null && show_vm_table "$@") 2>/dev/null; }
  out_root=$(table)
  out_user=$(DCVM_CALLER_ROLE=user DCVM_CALLER_UID=1001 table)
  out_json=$(table --json)
  if grep -q 'OWNER' <<<"$out_root" && grep -qE 'web +alice' <<<"$out_root" && grep -qE 'db +root' <<<"$out_root" &&
    ! grep -q 'OWNER' <<<"$out_user" && grep -q 'web' <<<"$out_user" && ! grep -q 'db' <<<"$out_user" &&
    grep -q '"name":"web","owner":"alice"' <<<"$out_json" && grep -q '"name":"db","owner":"root"' <<<"$out_json"; then
    log_test "PASS" "dcvm list shows each VM's owner to root and admins, users see only theirs"
  else
    log_test "FAIL" "dcvm list shows each VM's owner to root and admins, users see only theirs" "$(tr '\n' '|' <<<"$out_root$out_user$out_json" | cut -c1-400)"
  fi
  rm -rf "$t"
}

test_help_never_acts() {
  local t f out bad=""
  t=$(mktemp -d)
  mkdir -p "$t/bin"
  for f in virsh virt-install iptables qemu-img ssh scp systemctl; do
    printf '#!/bin/bash\necho "%s $*" >>"%s/ran"\n' "$f" "$t" >"$t/bin/$f"
    chmod +x "$t/bin/$f"
  done
  for f in "delete web --help" "start web -h" "stop all --help" "backup create web --help" "restore web --help" \
    "network stop --help" "network ports clear --help" "network dhcp renew --help" "network vnc enable web -h" \
    "fix-lock web --help" "storage --help" "uninstall --help" "reap --help" "owner web bob --help" \
    "template download ubuntu --help" "create web -p x --help" "self-update --help" "list --help" \
    "delete web -- --help" "cp web:/etc/hosts --help" "exec web --help" "ssh web -h"; do
    # shellcheck disable=SC2086
    out=$(PATH="$t/bin:$PATH" DCVM_LIB_DIR="$SCRIPT_DIR/.." bash "$SCRIPT_DIR/../../dcvm" $f </dev/null 2>&1) &&
      grep -qi 'usage\|dcvm ' <<<"$out" || bad+="$f; "
  done
  [ -f "$t/ran" ] && bad+="ran: $(tr '\n' ' ' <"$t/ran")"
  if [ -z "$bad" ]; then
    log_test "PASS" "a help flag anywhere shows help and runs nothing"
  else
    log_test "FAIL" "a help flag anywhere shows help and runs nothing" "$bad"
  fi
  rm -rf "$t"
}

test_usage_matches_parsers() {
  local out bad=""
  out=$(NO_COLOR=1 bash "$SCRIPT_DIR/../../dcvm" help 2>&1)
  for f in "ssh-setup, troubleshoot" "check, best" "--force" "show, rules"; do
    grep -qF -- "$f" <<<"$out" || bad+="help lacks '$f'; "
  done
  out=$(NO_COLOR=1 bash "$SCRIPT_DIR/../storage/backup.sh" bogus 2>&1)
  grep -q 'ssh-setup' <<<"$out" || bad+="backup unknown-subcommand list lacks ssh-setup; "
  out=$(NO_COLOR=1 bash "$SCRIPT_DIR/../core/create-vm.sh" </dev/null 2>&1) && bad+="create without arguments exited 0; "
  grep -q 'Usage: dcvm create' <<<"$out" || bad+="create without arguments shows no usage; "
  out=$(NO_COLOR=1 bash "$SCRIPT_DIR/doctor.sh" --only 2>&1) && bad+="doctor --only without a value exited 0; "
  grep -q 'needs a value' <<<"$out" || bad+="doctor --only: $out; "
  NO_COLOR=1 bash "$SCRIPT_DIR/doctor.sh" --vm >/dev/null 2>&1 && bad+="doctor --vm without a value exited 0; "
  if [ -z "$bad" ]; then
    log_test "PASS" "help lists every subcommand; create without arguments and doctor --only/--vm without a value fail"
  else
    log_test "FAIL" "help lists every subcommand; create without arguments and doctor --only/--vm without a value fail" "$bad"
  fi
}

test_registry_visibility() {
  local t r=""
  t=$(mktemp -d)
  (
    DCVM_STATE_DIR="$t"
    DCVM_CALLER_ROLE=user DCVM_CALLER_UID=1001 DCVM_CALLER_USER=alice register_vm mine "cpus=2" "user=ubuntu"
    registry_set theirs "owner_uid=1002" "owner=bob"
    registry_set mine "protected=1"
    export DCVM_CALLER_ROLE=user DCVM_CALLER_UID=1001
    vm_visible mine && echo mine-visible
    vm_visible theirs || echo theirs-hidden
    vm_visible legacy || echo legacy-hidden
    [ "$(registry_get mine owner_uid)" = 1001 ] && [ "$(registry_get mine cpus)" = 2 ] && [ "$(registry_get mine protected)" = 1 ] && echo merged
    DCVM_CALLER_ROLE=admin vm_visible theirs && echo admin-sees
  ) >"$t/out"
  r=$(tr '\n' ' ' <"$t/out")
  if [ "$r" = "mine-visible theirs-hidden legacy-hidden merged admin-sees " ]; then
    log_test "PASS" "VM owner records: users see only their VMs, admins see all, keys merge"
  else
    log_test "FAIL" "VM owner records: users see only their VMs, admins see all, keys merge" "$r"
  fi
  rm -rf "$t"
}

test_self_update_keeps_backup() {
  local t
  t=$(mktemp -d)
  mkdir -p "$t/bin" "$t/lib/core" "$t/backups"
  printf 'echo "Version: 0.9.7"\n' >"$t/bin/dcvm"
  echo old >"$t/lib/core/x.sh"
  echo gone >"$t/lib/core/stale.sh"
  local d
  for d in 20260101000001 20260101000002 20260101000003 20260101000004; do mkdir "$t/backups/dcvm-backup-$d"; done
  update() {
    (
      eval "$(sed -n '/^stage_files()/,/^}/p; /^new_stage()/,/^}/p; /^version_older()/,/^}/p; /^prune_update_backups()/,/^}/p; /^do_update()/,/^}/p' "$SCRIPT_DIR/../installation/self-update.sh")"
      INSTALL_BIN="$t/bin" INSTALL_LIB="$t/lib" BACKUP_DIR="$t/backups" KEEP_UPDATE_BACKUPS=3
      get_current_version() { echo 0.9.7; }
      repo_commit_sha() { printf '%040d\n' 7; }
      get_remote_version() { echo "${REMOTE:-0.9.8}"; }
      create_backup_dir() { :; }
      dcvm_tree_permissions() { :; }
      list_repo_files() { printf 'dcvm\nlib/core/x.sh\nlib/core/new.py\n'; }
      fetch_repo_file() { echo "$DCVM_REPO_REF" >>"$t/refs" && [ "$1" != "${FAIL_ON:-}" ] && mkdir -p "${2%/*}" && echo "new $1" >"$2"; }
      do_update false
    ) >/dev/null 2>&1
  }
  FAIL_ON=lib/core/new.py update
  local failed_kept_old=false
  [ "$(cat "$t/lib/core/x.sh")" = old ] && [ -f "$t/lib/core/stale.sh" ] && failed_kept_old=true
  FAIL_ON="" update
  echo changed >"$t/lib/core/x.sh"
  REMOTE=0.9.6 update
  local kept newest
  kept=$(find "$t/backups" -maxdepth 1 -name 'dcvm-backup-*' | wc -l)
  newest=$(find "$t/backups" -maxdepth 1 -name 'dcvm-backup-*' | sort -r | head -1)
  if $failed_kept_old && [ "$(cat "$t/lib/core/x.sh")" = changed ] && [ -f "$t/lib/core/new.py" ] &&
    [ "$(sort -u "$t/refs")" = "$(printf '%040d' 7)" ] &&
    [ ! -e "$t/lib/core/stale.sh" ] && [ "$kept" -eq 3 ] && grep -q 'Version: 0.9.7' "$newest/dcvm" 2>/dev/null &&
    [ "$(cat "$newest/lib/core/x.sh" 2>/dev/null)" = old ] && [ -z "$(find "$t" -maxdepth 1 -name '.dcvm-stage.*' -o -name 'lib.old.*')" ]; then
    log_test "PASS" "self-update: one commit, whole tree swap only when every file arrived, 3 saved versions, no downgrade"
  else
    log_test "FAIL" "self-update: one commit, whole tree swap only when every file arrived, 3 saved versions, no downgrade" "failed run kept old: $failed_kept_old; kept $kept; x.sh: $(cat "$t/lib/core/x.sh")"
  fi
  rm -rf "$t"
}

# shellcheck disable=SC2034,SC2317 # stubs and the paths do_update reads
test_self_update_failure_paths() {
  local t r
  t=$(mktemp -d)
  mkdir -p "$t/lib/installation" "$t/backups/dcvm-backup-1/lib"
  printf '#!/bin/sh\necho pre-revert >>"%s/calls"\n' "$t" >"$t/lib/installation/pre-revert.sh"
  chmod +x "$t/lib/installation/pre-revert.sh"
  echo old >"$t/backups/dcvm-backup-1/dcvm"
  run() {
    (
      set -euo pipefail
      eval "$(sed -n '/^new_stage()/,/^}/p; /^version_older()/,/^}/p; /^do_update()/,/^}/p; /^do_revert()/,/^}/p' "$SCRIPT_DIR/../installation/self-update.sh")"
      INSTALL_BIN="$t" INSTALL_LIB="$t/lib" BACKUP_DIR="$t/backups"
      get_current_version() { echo 0.9.10; }
      repo_commit_sha() { echo abc; }
      get_remote_version() { echo 0.9.10.1; }
      list_repo_files() { return 1; }
      fetch_repo_file() { return 1; }
      create_backup_dir() { :; }
      validate_backup() { :; }
      install_dcvm_services() { echo restored >>"$t/calls"; }
      eval "$1"
      "${@:2}"
    ) >>"$t/out" 2>&1
  }
  run : do_update false </dev/null
  grep -q 'nothing was changed' "$t/out" && [ "$(find "$t/backups" -mindepth 1 -maxdepth 1 | wc -l)" -eq 1 ] && r+="list-failure-clean "
  run 'new_stage() { return 1; }' do_revert <<<1
  [ ! -e "$t/calls" ] && r+="no-pre-revert-without-stage "
  run 'install_dcvm_tree() { return 1; }' do_revert <<<1
  [ "$(tr '\n' ' ' <"$t/calls" 2>/dev/null)" = "pre-revert restored " ] && r+="services-restored "
  (
    eval "$(sed -n '/^version_older()/,/^}/p' "$SCRIPT_DIR/../installation/self-update.sh")"
    version_older 0.9.9 0.9.10 && version_older 0.9.10 0.9.10.1 && ! version_older 0.9.10.1 0.9.10 && ! version_older 0.9.10 0.9.10
  ) && r+="numeric "
  if [ "$r" = "list-failure-clean no-pre-revert-without-stage services-restored numeric " ]; then
    log_test "PASS" "self-update: failed file list exits cleanly, revert runs pre-revert only after staging and restores services (#100)"
  else
    log_test "FAIL" "self-update: failed file list exits cleanly, revert runs pre-revert only after staging and restores services (#100)" "$r; $(tr '\n' ';' <"$t/out" | tail -c 300)"
  fi
  rm -rf "$t"
}

test_ui_width_injection() {
  local t out
  t=$(mktemp -d)
  out=$(
    COLUMNS="1+a[\$(touch $t/ran)]" UI_COLS= ui_cols </dev/null 2>/dev/null
    UI_COLS="1+a[\$(touch $t/ran2)]" ui_cols </dev/null 2>/dev/null
    UI_COLS="1+a[\$(touch $t/ran3)]" ui_region "x" 2>/dev/null
  )
  if [ ! -e "$t/ran" ] && [ ! -e "$t/ran2" ] && [ ! -e "$t/ran3" ] && [ "$(head -1 <<<"$out")" = 80 ]; then
    log_test "PASS" "COLUMNS and UI_COLS cannot run commands through \$(( ))"
  else
    log_test "FAIL" "COLUMNS and UI_COLS cannot run commands through \$(( ))" "$(ls "$t") / $out"
  fi
  rm -rf "$t"
}

test_build_names_and_sums() {
  local t ok=true
  t=$(mktemp -d)
  mkdir -p "$t/storage/templates/builds" "$t/etc"
  echo payload >"$t/payload"
  (
    DATACENTER_BASE="$t"
    register_build "$t/payload" "../../../etc/x.sh" >/dev/null 2>&1 && exit 1
    register_build "$t/payload" ".hidden.img" >/dev/null 2>&1 && exit 1
    current_build "../../payload" >/dev/null 2>&1 && exit 1
    find_build '.*' >/dev/null 2>&1 && exit 1
    b=$(register_build "$t/payload" "ubuntu-24.04.img") || exit 1
    [ "$(find_build "$(sha256sum "$t/payload" | cut -d' ' -f1)")" = "$b" ] || exit 1
    registered_build "$b" && ! registered_build "$t/payload" && ! registered_build "$t/storage/templates/builds/../../../payload"
  ) || ok=false
  [ -z "$(find "$t/etc" "$t/storage" -name 'x-*')" ] || ok=false
  if $ok; then
    log_test "PASS" "base build names and checksums from backups cannot leave builds/"
  else
    log_test "FAIL" "base build names and checksums from backups cannot leave builds/"
  fi
  rm -rf "$t"
}

test_vm_name_reserved() {
  local n bad="" good=""
  for n in all latest help -x --all; do validate_vm_name "$n" >/dev/null 2>&1 && bad+="$n "; done
  for n in web_1 db-2 Lab3; do validate_vm_name "$n" >/dev/null 2>&1 || good+="$n "; done
  if [ -z "$bad$good" ]; then
    log_test "PASS" "VM names: keywords and leading hyphens refused, existing styles still valid"
  else
    log_test "FAIL" "VM names: keywords and leading hyphens refused, existing styles still valid" "accepted: $bad rejected: $good"
  fi
}

# shellcheck disable=SC2317 # stubs
test_vm_ip_sources() {
  local out
  out=$(
    NETWORK_SUBNET=10.10.10 NETWORK_NAME=datacenter-net DATACENTER_BASE=/nonexistent
    LEASE="" AGENT=""
    virsh() {
      case "$1 $*" in
      domiflist*) printf ' Interface Type Source Model MAC\n vnet0 network datacenter-net virtio 52:54:00:aa:bb:cc\n' ;;
      net-dhcp-leases*) [ -n "$LEASE" ] && printf ' x\n -\n 2026-01-01 00:00:00 52:54:00:aa:bb:cc ipv4 %s/24 web -\n' "$LEASE" ;;
      *"--source agent"*) [ -n "$AGENT" ] && printf ' vnet0 52:54:00:aa:bb:cc ipv4 %s/24\n' "$AGENT" ;;
      esac
    }
    AGENT=10.10.10.1
    printf '%s ' "$(get_vm_ip web)"
    AGENT="10.10.10.2;id"
    printf '%s ' "$(get_vm_ip web)"
    LEASE=10.10.10.50 AGENT=10.10.10.77
    printf '%s ' "$(get_vm_ip web)"
    LEASE="" AGENT=10.10.10.77
    printf '%s ' "$(get_vm_ip web)"
    printf '%s ' "$(get_vm_ip_trusted web)"
    LEASE=10.10.10.050
    printf '%s' "$(get_vm_ip_trusted web)"
  )
  if [ "$out" = "N/A N/A 10.10.10.50 10.10.10.77 N/A N/A" ]; then
    log_test "PASS" "VM addresses: host-side lease first, guest agent cannot claim the gateway or inject text; get_vm_ip_trusted never asks the agent"
  else
    log_test "FAIL" "VM addresses: host-side lease first, guest agent cannot claim the gateway or inject text; get_vm_ip_trusted never asks the agent" "$out"
  fi
}

# shellcheck disable=SC2034,SC2030,SC2031,SC2317,SC2329,SC2016,SC1090,SC1091 # stubs
test_network_trust() {
  local t out r=""
  t=$(mktemp -d)
  # The guest agent of vm1 claims 10.10.10.40, which vm2 holds.
  printf '# VM_NAME VM_IP SSH_PORT HTTP_PORT\nvm1 10.10.10.5 2221 8081\nvm2 10.10.10.40 2222 8082\n' >"$t/port-mappings.txt"
  run_delete() {
    (
      HOME="$t"
      source "$SCRIPT_DIR/../core/delete-vm.sh" >/dev/null 2>&1
      DATACENTER_BASE="$t" NETWORK_NAME=datacenter-net BRIDGE_NAME=br DNSMASQ_DIR="$t" NETWORK_SUBNET=10.10.10
      virsh() {
        case "$1 $*" in
        domiflist*) printf ' vnet0 network datacenter-net virtio 52:54:00:00:00:01\n' ;;
        *"--source agent"*) printf ' vnet0 52:54:00:00:00:01 ipv4 10.10.10.40/24\n' ;;
        esac
        return 0
      }
      cleanup_dhcp_lease() { return 1; }
      check_vm_exists() { return 0; }
      registry_get() { :; }
      registry_remove() { :; }
      get_vm_mac() { echo 52:54:00:00:00:01; }
      get_vm_disk_path() { :; }
      get_port_mappings_file() { echo "$t/port-mappings.txt"; }
      stop_vm_gracefully() { :; }
      cleanup_port_forwarding_for_vm() { echo "$*" >>"$t/cleanup"; }
      sleep() { :; }
      delete_single_vm "$1"
    ) >/dev/null 2>&1
  }
  run_delete vm1
  [ "$(cat "$t/cleanup" 2>/dev/null)" = "10.10.10.5 2221 8081" ] &&
    [ "$(grep -v '^#' "$t/port-mappings.txt")" = "vm2 10.10.10.40 2222 8082" ] && [ -e "$t/port-mappings.txt.lock" ] && r+="mapping-ip "
  rm -f "$t/cleanup"
  run_delete vm3
  [ ! -e "$t/cleanup" ] && r+="no-agent "
  if [ "$r" = "mapping-ip no-agent " ]; then
    log_test "PASS" "delete removes rules for the mapping's address under the mappings lock, never for what the guest agent reports"
  else
    log_test "FAIL" "delete removes rules for the mapping's address under the mappings lock, never for what the guest agent reports" "$r; $(tr '\n' '|' <"$t/cleanup" 2>/dev/null)"
  fi

  r=""
  rm -f "$t/ssh"
  out=$(
    source "$SCRIPT_DIR/../storage/storage-manager.sh" >/dev/null 2>&1
    LOG_FILE="$t/storage.log" NETWORK_NAME=datacenter-net NETWORK_SUBNET=10.10.10 DATACENTER_BASE="$t"
    LEASE=""
    virsh() {
      case "$1 $*" in
      domiflist*) printf ' vnet0 network datacenter-net virtio 52:54:00:00:00:01\n' ;;
      net-dhcp-leases*) [ -n "$LEASE" ] && printf ' 2026-01-01 00:00:00 52:54:00:00:00:01 ipv4 %s/24 web -\n' "$LEASE" ;;
      *"--source agent"*) printf ' vnet0 52:54:00:00:00:01 ipv4 10.10.10.40/24\n' ;;
      esac
      return 0
    }
    ssh() { echo "$*" >>"$t/ssh"; }
    timeout() {
      shift
      "$@"
    }
    registry_get() {
      [ "$2" = created ] && echo 123
      [ "$2" = owner ] && echo alice
      [ "$2" = user ] && echo ubuntu
      return 0
    }
    OWNER=1000
    vm_owner_uid() { echo "$OWNER"; }
    check_vm_storage web
    OWNER=0
    check_vm_storage web
    LEASE=10.10.10.50
    check_vm_storage web
  )
  [ "$(grep -c . "$t/ssh" 2>/dev/null)" = 1 ] && grep -q 'HostKeyAlias=dcvm-web-123 .*ubuntu@10.10.10.50' "$t/ssh" && grep -q 'owned by alice' <<<"$out" && r+="storage "
  if [ "$r" = "storage " ]; then
    log_test "PASS" "storage check skips users' VMs and the guest agent's address, pins host keys per VM"
  else
    log_test "FAIL" "storage check skips users' VMs and the guest agent's address, pins host keys per VM" "$(tr '\n' '|' <"$t/ssh" 2>/dev/null) $(tr '\n' '|' <<<"$out")"
  fi

  r=""
  mkdir -p "$t/bin"
  printf '#!/bin/bash\necho "$*" >>"${0%%/*}/calls"\n' >"$t/bin/iptables"
  chmod +x "$t/bin/iptables"
  (PATH="$t/bin:$PATH" && source "$SCRIPT_DIR/../network/port-forward.sh" && BRIDGE_NAME=br &&
    setup_vm_forwarding web 10.10.10.5 2221 8081 192.0.2.1) >/dev/null 2>&1
  [ "$(grep -cE -- '-I FORWARD -p tcp -d 10\.10\.10\.5 --dport (22|80) -m conntrack --ctstate DNAT -j ACCEPT' "$t/bin/calls")" = 2 ] && r+="dnat-only "
  rm -f "$t/bin/calls"
  (PATH="$t/bin:$PATH" && save_iptables_rules() { :; } && cleanup_port_forwarding_for_vm 10.10.10.5 2221 8081) >/dev/null 2>&1
  [ "$(grep -- '-D FORWARD' "$t/bin/calls")" = "$(printf '%s\n' \
    '-w -D FORWARD -p tcp -d 10.10.10.5 --dport 22 -j ACCEPT' \
    '-w -D FORWARD -p tcp -d 10.10.10.5 --dport 22 -m conntrack --ctstate DNAT -j ACCEPT' \
    '-w -D FORWARD -p tcp -d 10.10.10.5 --dport 80 -j ACCEPT' \
    '-w -D FORWARD -p tcp -d 10.10.10.5 --dport 80 -m conntrack --ctstate DNAT -j ACCEPT')" ] && r+="remove-both "
  ! grep -qE '^ *iptables -I FORWARD -m state' "$SCRIPT_DIR/../network/port-forward.sh" && r+="related-once "
  if [ "$r" = "dnat-only remove-both related-once " ]; then
    log_test "PASS" "forward ACCEPT rules match only DNATed traffic; removal takes old and new rules; RELATED,ESTABLISHED added once"
  else
    log_test "FAIL" "forward ACCEPT rules match only DNATed traffic; removal takes old and new rules; RELATED,ESTABLISHED added once" "$r; $(tr '\n' '|' <"$t/bin/calls" 2>/dev/null)"
  fi

  if grep -qF 'subtree_check,all_squash' "$SCRIPT_DIR/common.sh" && ! grep -q 'no_subtree_check' "$SCRIPT_DIR/common.sh" &&
    grep -qF '[(,]subtree_check[,)]' "$SCRIPT_DIR/common.sh"; then
    log_test "PASS" "NFS share is exported with subtree_check, and doctor requires it"
  else
    log_test "FAIL" "NFS share is exported with subtree_check, and doctor requires it"
  fi
  rm -rf "$t"
}

test_sanitize_domain_xml() {
  if ! command -v python3 >/dev/null 2>&1; then
    log_test "SKIP" "domain XML sanitizer (python3 not installed)"
    return
  fi
  local t out
  t=$(mktemp -d)
  cat >"$t/vm.xml" <<'XML'
<domain type='kvm' xmlns:qemu='http://libvirt.org/schemas/domain/qemu/1.0'>
  <name>old</name><uuid>1</uuid><memory unit='KiB'>1048576</memory><vcpu>1</vcpu>
  <metadata><x/></metadata><seclabel type='none'/>
  <memoryBacking><source type='file'/></memoryBacking>
  <sysinfo type='fwcfg'><entry name='opt/x' file='/etc/gshadow'/></sysinfo>
  <os><type arch='x86_64' machine='pc-q35-8.2'>hvm</type><boot dev='network'/><boot dev='hd'/><kernel>/etc/shadow</kernel><loader>/etc/passwd</loader><nvram>/var/lib/libvirt/qemu/nvram/old.fd</nvram></os>
  <devices>
    <emulator>/tmp/evil</emulator>
    <disk type='block' device='disk'><driver name='qemu' type='raw'/><source dev='/dev/sda'/><target dev='vda' bus='virtio'/></disk>
    <disk type='file' device='disk'><source file='/srv/datacenter/vms/bob/bob.qcow2'/><target dev='vdb' bus='virtio'/></disk>
    <disk type='file' device='cdrom'><source file='/etc/shadow'/><target dev='sda' bus='sata'/></disk>
    <hostdev mode='subsystem' type='pci'/><filesystem type='mount'><source dir='/'/><target dir='r'/></filesystem>
    <interface type='ethernet'><script path='/tmp/x'/></interface>
    <interface type='network'><mac address='52:54:00:11:22:33'/><source network='datacenter-net'/></interface>
    <interface type='bridge'><mac address='52:54:00:44:55:66'/><source bridge='br0'/><target dev='tapx'/><filterref filter='f'/><virtualport type='openvswitch'/><vlan><tag id='5'/></vlan><model type='vhost-user'/></interface>
    <input type='evdev'><source dev='/dev/input/event0' grab='all'/></input><input type='tablet' bus='usb'/>
    <video><driver name='vhostuser'/><model type='virtio' heads='1'><acceleration accel3d='yes' rendernode='/dev/dri/renderD128'/></model></video>
    <tpm model='tpm-crb'><backend type='emulator' version='2.0'><source type='file' path='/etc/tpmstate'/></backend></tpm>
    <serial type='file'><source path='/etc/cron.d/x'/></serial><serial type='pty'/>
    <channel type='unix'><source mode='bind' path='/etc/x'/><target type='virtio' name='org.qemu.guest_agent.0'/></channel>
    <graphics type='vnc' port='5901' autoport='no' passwd='knownpw' listen='0.0.0.0'><listen type='address' address='0.0.0.0'/></graphics>
    <audio id='1' type='file'><output path='/etc/y'/></audio>
    <controller type='ide' index='0'/><controller type='usb' index='0'/>
  </devices>
  <qemu:commandline><qemu:arg value='-x'/></qemu:commandline>
</domain>
XML
  # A planted xml.py in the working directory must not replace the sanitizer (#81).
  mkdir "$t/cwd" && echo 'raise SystemExit(0)' >"$t/cwd/xml.py"
  (cd "$t/cwd" && sanitize_domain_xml "$t/vm.xml" new "/srv/datacenter/vms/new/new-disk.qcow2" true) || {
    log_test "FAIL" "domain XML sanitizer" "returned an error"
    rm -rf "$t"
    return
  }
  out=$(cat "$t/vm.xml")
  local leaked
  leaked=$(grep -oE '/etc/[a-z.]+|/dev/sda|/tmp/[a-z]+|commandline|hostdev|filesystem|seclabel|memoryBacking|<emulator|ethernet|0\.0\.0\.0|type="ide"|<uuid|<metadata|bob\.qcow2|52:54:00:11:22:33|pc-q35|br0|tapx|filterref|virtualport|vlan|vhost|evdev|/dev/[a-z]+|accel|dev="network"|5901|knownpw|fwcfg' <<<"$out" | sort -u | tr '\n' ' ')
  if [ -z "$leaked" ] && grep -q '<name>new</name>' <<<"$out" && [ "$(grep -o '<disk ' <<<"$out" | wc -l)" -eq 1 ] &&
    grep -q 'file="/srv/datacenter/vms/new/new-disk.qcow2"' <<<"$out" && grep -q 'type="pty"' <<<"$out" &&
    grep -q 'machine="q35"' <<<"$out" && grep -q 'guest_agent' <<<"$out" && grep -q 'type="usb"' <<<"$out" &&
    [ "$(grep -o '<source network="datacenter-net" />' <<<"$out" | wc -l)" -eq 2 ] && grep -q '<boot dev="hd" />' <<<"$out" &&
    grep -qE '<graphics type="vnc" passwd="[A-Za-z0-9]{8}" autoport="yes" listen="127.0.0.1"><listen' <<<"$out" &&
    grep -q '<input type="tablet" bus="usb" />' <<<"$out" && grep -q '<model type="virtio" heads="1" />' <<<"$out" &&
    grep -q '<backend type="emulator" version="2.0" />' <<<"$out"; then
    log_test "PASS" "domain XML sanitizer keeps one dcvm disk, puts NICs on dcvm's network, drops every host path, device and override"
  else
    log_test "FAIL" "domain XML sanitizer keeps one dcvm disk, puts NICs on dcvm's network, drops every host path, device and override" "leaked: $leaked"
  fi
  rm -rf "$t"
}

# shellcheck disable=SC2034,SC2030,SC2031,SC2317,SC1091 # stubs; globals are read by create-vm.sh
test_create_network_by_mac() {
  local t r=""
  t=$(mktemp -d)
  (
    source "$SCRIPT_DIR/../core/create-vm.sh" >/dev/null 2>&1
    virt-install() { printf '%s\n' "$@" >"$t/args"; }
    virsh() { :; }
    DATACENTER_BASE="$t" VM_NAME=nettest VM_OS=debian12 NETWORK_NAME=datacenter-net NETWORK_SUBNET=10.10.10
    FORCE_MODE=true FLAG_GRAPHICS="" FLAG_UEFI=false VM_MEMORY=2048 VM_CPUS=2 OS_VARIANT=debian12
    mkdir -p "$t/vms/nettest/cloud-init"
    FLAG_STATIC_IP=10.10.10.50 generate_cloud_init_network && cp "$t/vms/nettest/cloud-init/network-config" "$t/static"
    FLAG_STATIC_IP="" generate_cloud_init_network && install_vm >/dev/null 2>&1
  )
  local nc="$t/vms/nettest/cloud-init/network-config" mac
  mac=$(sed -n 's/^      macaddress: "\(.*\)"$/\1/p' "$nc")
  for f in "$t/static" "$nc"; do
    grep -qE '^      macaddress: "52:54:00(:[0-9a-f]{2}){3}"$' "$f" && grep -q '^    set-name: enp1s0$' "$f" && ! grep -q 'name: "e\*"' "$f" && r+="config "
  done
  grep -q '^    dhcp4: false$' "$t/static" && grep -qxF -- "network=datacenter-net,mac=$mac" "$t/args" 2>/dev/null && r+="nic"
  if [ "$r" = "config config nic" ]; then
    log_test "PASS" "create: network-config matches the NIC by the MAC virt-install is given (cloud-init without netplan)"
  else
    log_test "FAIL" "create: network-config matches the NIC by the MAC virt-install is given (cloud-init without netplan)" "$r"
  fi
  rm -rf "$t"
}

# shellcheck disable=SC2034,SC2030,SC2031,SC2317,SC1091 # stubs; globals are read by create-vm.sh
test_create_scrubs_seed() {
  local t r=""
  t=$(mktemp -d)
  mkdir -p "$t/vms/seedtest/cloud-init"
  printf 'instance-id: seedtest-1\n' >"$t/vms/seedtest/cloud-init/meta-data"
  printf 'version: 2\n' >"$t/vms/seedtest/cloud-init/network-config"
  printf '#cloud-config\npasswd: secret-hash\n' >"$t/vms/seedtest/cloud-init/user-data"
  echo first-seed >"$t/vms/seedtest/cloud-init.iso"
  (
    source "$SCRIPT_DIR/../core/create-vm.sh" >/dev/null 2>&1
    mkisofs() { cat "${!#}"/* >"$2"; }
    wait_for_vm() { echo 10.10.10.9; }
    virsh() {
      if [ "$1" = domblklist ]; then printf ' Type   Device   Target   Source\n file   cdrom    sda      x\n'; else echo "$*" >>"$t/virsh"; fi
    }
    DATACENTER_BASE="$t" VM_NAME=seedtest
    scrub_cloud_init_seed
    wait
  )
  grep -q 'instance-id: seedtest-1' "$t/vms/seedtest/cloud-init.iso" && ! grep -q 'secret-hash\|first-seed' "$t/vms/seedtest/cloud-init.iso" &&
    grep -q secret-hash "$t/vms/seedtest/cloud-init/user-data" && r+="iso "
  [ "$(cat "$t/virsh" 2>/dev/null)" = "change-media seedtest sda --eject --live --force
change-media seedtest sda $t/vms/seedtest/cloud-init.iso --insert --live" ] && r+="swap "
  generate_test_userdata tester n "" "$t/ud"
  grep -q '^  - rm -f /var/lib/cloud/instance/user-data.txt\* .*obj.pkl' "$t/ud" && r+="guest"
  if [ "$r" = "iso swap guest" ]; then
    log_test "PASS" "create: the cloud-init seed loses its user-data once the guest has read it"
  else
    log_test "FAIL" "create: the cloud-init seed loses its user-data once the guest has read it" "$r"
  fi
  rm -rf "$t"
}

# shellcheck disable=SC2034,SC2030,SC2031,SC1091 # the quota vars are read by within_quota
test_numbers_leading_zeros() {
  local t r=""
  t=$(mktemp -d)
  mkdir -p "$t/vms"
  printf 'owner_uid=1001\nstate=creating\ncpus=0\nmemory_mb=0\ndisk_gb=0\n' >"$t/vms/z"
  [ "$(size_gb 08G)/$(size_gb 010T)/$(size_gb 0900M)" = "8/10240/1" ] 2>/dev/null && r+="size "
  (DCVM_STATE_DIR="$t" DCVM_CALLER_UID=1001 DCVM_QUOTA_LIMITS="8 1000 100" && within_quota 08 0800 09 z) >/dev/null 2>&1 &&
    [ "$(DCVM_STATE_DIR="$t" registry_get z cpus)/$(DCVM_STATE_DIR="$t" registry_get z memory_mb)" = 8/800 ] && r+="quota "
  ! (DCVM_STATE_DIR="$t" DCVM_CALLER_UID=1001 DCVM_QUOTA_LIMITS="8 900 100" && within_quota 1 01000 1 z) >/dev/null 2>&1 && r+="octal "
  (source "$SCRIPT_DIR/../core/create-vm.sh" >/dev/null 2>&1 && validate_disk_size 090G debian12) >/dev/null 2>&1 && r+="disk"
  if [ "$r" = "size quota octal disk" ]; then
    log_test "PASS" "sizes and quota read leading-zero numbers as decimal"
  else
    log_test "FAIL" "sizes and quota read leading-zero numbers as decimal" "$r"
  fi
  rm -rf "$t"
}

test_check_disk_image() {
  if ! command -v qemu-img >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
    log_test "SKIP" "disk image check (qemu-img or python3 not installed)"
    return
  fi
  local t r=""
  t=$(mktemp -d)
  qemu-img create -q -f qcow2 "$t/plain.qcow2" 16M
  qemu-img create -q -f qcow2 -o data_file="$t/hostfile" "$t/datafile.qcow2" 16M 2>/dev/null
  printf '# Disk DescriptorFile\nversion=1\ncreateType="monolithicFlat"\nRW 2048 FLAT "/etc/hostname" 0\n' >"$t/extent.qcow2"
  qemu-img create -q -f qcow2 -b 'json:{"file.filename":"/etc/hostname"}' -F raw "$t/json.qcow2" 16M 2>/dev/null
  check_disk_image "$t/plain.qcow2" && r+="plain:ok "
  check_disk_image "$t/datafile.qcow2" || r+="datafile:refused "
  check_disk_image "$t/extent.qcow2" || r+="extent:refused "
  check_disk_image "$t/json.qcow2" || r+="json:refused "
  qemu-img create -q -f qcow2 -b "$t/plain.qcow2" -F qcow2 "$t/overlay.qcow2" 16M
  (
    source "$SCRIPT_DIR/mirror-manager.sh" >/dev/null 2>&1
    cp "$t/plain.qcow2" "$t/dl1" && place_template x "$t/dl1" "$t/tmpl1"
    cp "$t/overlay.qcow2" "$t/dl2" && place_template x "$t/dl2" "$t/tmpl2"
    cp "$t/extent.qcow2" "$t/dl3" && place_template x "$t/dl3" "$t/tmpl3"
  ) 2>/dev/null
  [ -f "$t/tmpl1" ] && [ ! -e "$t/tmpl2" ] && [ ! -e "$t/dl2" ] && [ ! -e "$t/tmpl3" ] && r+="templates "
  if [ "$r" = "plain:ok datafile:refused extent:refused json:refused templates " ]; then
    log_test "PASS" "backup disks and downloaded templates: external data files, backing files, VMDK extents and json: refused"
  else
    log_test "FAIL" "backup disks and downloaded templates: external data files, backing files, VMDK extents and json: refused" "$r"
  fi
  rm -rf "$t"
}

# shellcheck disable=SC2317 # stubs
test_import_rejects_hostile_archives() {
  local t r=""
  t=$(mktemp -d)
  mkdir -p "$t/a" "$t/b" "$t/c"
  ln -s /etc/hostname "$t/a/web-disk-20260101_000000.qcow2"
  echo x >"$t/a/web-config-20260101_000000.xml"
  echo x >"$t/b/all-disk-20260101_000000.qcow2"
  echo x >"$t/b/all-config-20260101_000000.xml"
  echo x >"$t/c/web-disk-20260101_000000.qcow2"
  echo x >"$t/c/web-config-20260101_000000.xml"
  printf 'image=../../../etc/x.img\nsha256=%064d\nrm=-rf\n' 0 >"$t/c/base"
  tar -czf "$t/links.tar.gz" -C "$t/a" .
  tar -czf "$t/keyword.tar.gz" -C "$t/b" .
  tar -czf "$t/record.tar.gz" -C "$t/c" .
  (
    load_backup_sh_for_test "$t"
    BACKUP_DIR="$t/backups"
    restore_vm() { echo restored >"$t/restored-$1"; }
    import_backup "$t/links.tar.gz" >/dev/null 2>&1
    import_backup "$t/keyword.tar.gz" >/dev/null 2>&1
    import_backup "$t/record.tar.gz" >/dev/null 2>&1
  )
  [ -e "$t/restored-web" ] && r+="record-imported "
  [ -e "$t/restored-all" ] && r+="keyword-imported "
  ls "$t/backups"/web-* >/dev/null 2>&1 && [ -z "$(find "$t/backups" -type l)" ] && r+="no-links "
  grep -q '^image=' "$t/backups"/web-*/base 2>/dev/null && r+="bad-image-kept "
  grep -q '^rm=' "$t/backups"/web-*/base 2>/dev/null && r+="unknown-key-kept "
  if [ "$r" = "record-imported no-links " ]; then
    log_test "PASS" "import refuses links and keyword names, keeps only valid base record lines"
  else
    log_test "FAIL" "import refuses links and keyword names, keeps only valid base record lines" "$r"
  fi
  rm -rf "$t"
}

# shellcheck disable=SC2317 # stubs
test_aria2c_download() {
  local t out
  t=$(mktemp -d)
  out=$(
    source "$SCRIPT_DIR/mirror-manager.sh" >/dev/null 2>&1
    rank_mirrors() { printf 'https://m%s/img.qcow2\n' 1 2 3 4 5; }
    check_download() { return 0; }
    plain_template() { return 0; }
    aria2c() {
      printf '%s\n' "$@" >"$t/args"
      local dir out a
      for a in "$@"; do
        case "$a" in --dir=*) dir=${a#--dir=} ;; --out=*) out=${a#--out=} ;; esac
      done
      head -c 2048 /dev/zero >"$dir/$out"
    }
    curl() {
      echo curl >>"$t/curl"
      return 1
    }
    download_with_mirrors debian-13-genericcloud-amd64.qcow2 "$t/img.qcow2" 1024 2>/dev/null
  )
  if [ -f "$t/img.qcow2" ] && [ ! -f "$t/curl" ] && [ "$out" = https://m1/img.qcow2 ] &&
    [ "$(grep -c '^https://m' "$t/args" 2>/dev/null)" = 4 ] && ! grep -q m5 "$t/args"; then
    log_test "PASS" "downloads use aria2c with the 4 fastest mirrors when it is installed"
  else
    log_test "FAIL" "downloads use aria2c with the 4 fastest mirrors when it is installed" "out=$out; $(tr '\n' ' ' <"$t/args" 2>/dev/null)"
  fi
  printf '  %% Total    %% Received\r 42  327M   42  138M    0     0  10.0M      0  0:00:32  0:00:13  0:00:19 11.0M\r' >"$t/curl.log"
  printf '*** Download Progress Summary ***\n[#2089b0 138MiB/327MiB(42%%) CN:16 DL:11MiB ETA:1m16s]\n' >"$t/aria.log"
  out=$(
    source "$SCRIPT_DIR/mirror-manager.sh" >/dev/null 2>&1
    download_progress "$t/curl.log"
    download_progress "$t/aria.log"
  )
  if [ "$out" = $'42|144703488|342884352|11534336|19\n42|144703488|342884352|11534336|76' ]; then
    log_test "PASS" "download progress is read from curl and aria2c output"
  else
    log_test "FAIL" "download progress is read from curl and aria2c output" "$(tr '\n' ' ' <<<"$out")"
  fi
  rm -rf "$t"
}

test_ui_region_rows() {
  local out
  out=$(TERM=xterm-256color LANG=C.UTF-8 bash -c 'source "$1" >/dev/null 2>&1
    UI_COLS=20
    ui_region "  spinner" "      $(printf "%030d" 0)" 2>/dev/null
    echo "rows=$UI_REGION_ROWS"
    ui_region "next" 2>&1 >/dev/null | od -An -c | tr -d " \n"
    echo
    echo "fit=$(ui_fit 0 "a\\nb")"' _ "$SCRIPT_DIR/common.sh")
  if grep -qx 'rows=3' <<<"$out" && grep -q '^\\r033\[2A' <<<"$out" && grep -qx 'fit=a\\\\nb' <<<"$out"; then
    log_test "PASS" "live block counts wrapped rows and keeps tool output literal"
  else
    log_test "FAIL" "live block counts wrapped rows and keeps tool output literal" "$(tr '\n' '|' <<<"$out")"
  fi
}

test_distro_family() {
  local t out
  t=$(mktemp -d)
  printf 'NAME="Fedora Linux"\nID=fedora\n' >"$t/fedora"
  printf 'ID=ubuntu\nID_LIKE=debian\n' >"$t/ubuntu"
  printf 'ID=manjaro\nID_LIKE=arch\n' >"$t/manjaro"
  printf 'ID=opensuse-tumbleweed\nID_LIKE="opensuse suse"\n' >"$t/suse"
  out=$(set -u && for f in fedora ubuntu manjaro suse; do printf '%s=%s ' "$f" "$(distro_family "$t/$f")"; done)
  if [ "$out" = "fedora=fedora ubuntu=debian manjaro=arch suse= " ]; then
    log_test "PASS" "distro detection works without ID_LIKE (Fedora) under set -u"
  else
    log_test "FAIL" "distro detection works without ID_LIKE (Fedora) under set -u" "$out"
  fi
  rm -rf "$t"
}

test_remove_old_alias() {
  local t out
  t=$(mktemp -d)
  mkdir -p "$t/root" "$t/user"
  printf 'export A=1\nalias dcvm="/srv/datacenter/scripts/vm-manager.sh"\nalias ll="ls -l"\n' >"$t/root/.zshrc"
  printf '  alias dcvm=/srv/datacenter/scripts/vm-manager.sh\nsource /usr/local/share/dcvm/dcvm-completion.sh\n' >"$t/user/.bashrc"
  out=$(
    getent() { echo "user:x:1000:1000::$t/user:/bin/bash"; }
    HOME="$t/root" SUDO_USER=user remove_shell_lines "$DCVM_ALIAS_LINE"
  )
  if [ "$(grep -c . <<<"$out")" = 2 ] && ! grep -q 'alias dcvm' "$t/root/.zshrc" "$t/user/.bashrc" &&
    grep -q 'alias ll=' "$t/root/.zshrc" && grep -q 'dcvm-completion' "$t/user/.bashrc" && [ -f "$t/root/.zshrc.bak" ]; then
    log_test "PASS" "installer removes old 'alias dcvm=' lines (root and sudo user), keeps the rest"
  else
    log_test "FAIL" "installer removes old 'alias dcvm=' lines (root and sudo user), keeps the rest" "$(tr '\n' '|' <<<"$out")"
  fi
  rm -rf "$t"
}

# shellcheck disable=SC2317 # stubs
test_base_builds() {
  if ! command -v qemu-img >/dev/null 2>&1 || ! command -v qemu-io >/dev/null 2>&1; then
    log_test "SKIP" "base builds (qemu-img/qemu-io not installed)"
    return
  fi
  local t out
  t=$(mktemp -d)
  out=$(
    DATACENTER_BASE="$t"
    tpl="$t/storage/templates"
    mkdir -p "$tpl" "$t/vms/vm1"
    qemu-img create -q -f qcow2 "$tpl/test.img" 4M
    qemu-io -f qcow2 -c "write -P 0x11 0 1M" -c "write -P 0x22 1M 1M" "$tpl/test.img" >/dev/null
    old=$(current_build test.img)
    [ "$old" -ef "$tpl/test.img" ] && echo "hardlinked"
    [ "$(build_image "$old")" = test.img ] && echo "image name"
    vmdisk="$t/vms/vm1/vm1-disk.qcow2"
    qemu-img create -q -f qcow2 -F qcow2 -b "$old" "$vmdisk"
    qemu-io -f qcow2 -c "write -P 0x33 512K 4K" "$vmdisk" >/dev/null
    qemu-img create -q -f qcow2 "$tpl/new.img" 4M
    qemu-io -f qcow2 -c "write -P 0x11 0 1M" -c "write -P 0x44 1M 1M" "$tpl/new.img" >/dev/null
    mv -f "$tpl/new.img" "$tpl/test.img"
    new=$(current_build test.img)
    [ "$new" != "$old" ] && [ -f "$old" ] && echo "old build kept"
    get_vm_disk_path() { echo "$vmdisk"; }
    get_vm_state() { echo "shut off"; }
    virsh() {
      [ "$1 $2" = "list --all" ] && echo vm1
      return 0
    }
    vm_disk_outdated vm1 && echo "outdated"
    prepare_vm_disk vm1 >/dev/null
    [ "$(disk_backing "$vmdisk")" = "$new" ] && echo "moved"
    qemu-io -f qcow2 -c "read -P 0x22 1M 1M" -c "read -P 0x33 512K 4K" "$vmdisk" 2>&1 | grep -q 'Pattern verification failed' || echo "contents kept"
    [ ! -f "$old" ] && echo "old build deleted"
    qemu-img create -q -f qcow2 -F qcow2 -b "$tpl/test.img" "$t/vms/vm1/legacy.qcow2"
    get_vm_disk_path() { echo "$t/vms/vm1/legacy.qcow2"; }
    cp -p "$new" "$t/storage/templates/builds/test-000000000000.img"
    legacy_references && [ -z "$(prune_builds)" ] && echo "legacy keeps builds"
  ) 2>/dev/null
  local want="hardlinked image name old build kept outdated moved contents kept old build deleted legacy keeps builds"
  if [ "$(echo $out)" = "$want" ]; then
    log_test "PASS" "base builds: immutable build files, safe move to a new build, cleanup"
  else
    log_test "FAIL" "base builds: immutable build files, safe move to a new build, cleanup" "got: $(echo $out)"
  fi
  rm -rf "$t"
}

test_doctor_report() {
  local out
  out=$(
    source "$SCRIPT_DIR/doctor.sh" >/dev/null 2>&1
    TERM=dumb
    QUIET=true
    section "Host"
    report ok "KVM" "fine"
    report warn "Tools" "missing aria2c"
    report fixed "Shell alias" "removed"
    report skip "dcvm" "offline"
    echo "problems=$PROBLEMS"
    echo "pkg=$(package_for aria2c) $(package_for dhcp_release)"
  )
  if grep -q '^Host' <<<"$out" && grep -q 'Tools' <<<"$out" && grep -q 'Shell alias' <<<"$out" &&
    ! grep -qE 'KVM|offline' <<<"$out" && grep -qx 'problems=1' <<<"$out"; then
    log_test "PASS" "doctor --quiet shows only problems and fixes, and counts problems"
  else
    log_test "FAIL" "doctor --quiet shows only problems and fixes, and counts problems" "$(tr '\n' '|' <<<"$out")"
  fi
  if grep -qE '^pkg=aria2 (dnsmasq-utils|dnsmasq)$' <<<"$out"; then
    log_test "PASS" "doctor names the package of a missing tool"
  else
    log_test "FAIL" "doctor names the package of a missing tool" "$(grep pkg= <<<"$out")"
  fi
}

# shellcheck disable=SC2317,SC2030,SC2031,SC2034 # stubs; globals read by doctor.sh
test_doctor_lock_checks() {
  local t f out
  t=$(mktemp -d)
  mkdir -p "$t/bin" "$t/templates" "$t/state/vms"
  for f in good bad unreadable; do : >"$t/templates/$f.qcow2"; done
  : >"$t/locked.qcow2"
  : >"$t/denied.qcow2"
  cat >"$t/bin/qemu-img" <<'STUB'
#!/bin/bash
case "$1 ${*: -1}" in
"check "*bad*) exit 2 ;;
"check "*unreadable*) exit 1 ;;
"info "*locked*) echo "qemu-img: Could not open 'x': Failed to get shared \"write\" lock" >&2 && exit 1 ;;
"info "*denied*) echo "qemu-img: Could not open 'x': Permission denied" >&2 && exit 1 ;;
esac
STUB
  chmod +x "$t/bin/qemu-img"
  out=$(
    source "$SCRIPT_DIR/doctor.sh" >/dev/null 2>&1
    PATH="$t/bin:$PATH" TERM=dumb QUIET=true DATACENTER_BASE="$t" DCVM_STATE_DIR="$t/state"
    templates_dir() { echo "$t/templates"; }
    vm_disks() { printf 'locked\t%s\t-\ndenied\t%s\t-\n' "$t/locked.qcow2" "$t/denied.qcow2"; }
    is_vm_in_network() { :; }
    get_vm_state() { echo "shut off"; }
    base_status() { echo "ok|fine"; }
    virsh() { :; }
    check_vms
    check_storage
  ) 2>&1
  if grep -q 'locked.*disk is locked although the VM is off' <<<"$out" && grep -q 'denied.*cannot read its disk: .*Permission denied' <<<"$out" &&
    ! grep -q 'denied.*fix-lock' <<<"$out" && grep -q 'corrupt: bad.qcow2 ' <<<"$out" && grep -q 'could not check unreadable.qcow2' <<<"$out"; then
    log_test "PASS" "doctor calls a disk locked or a template corrupt only when qemu-img says so"
  else
    log_test "FAIL" "doctor calls a disk locked or a template corrupt only when qemu-img says so" "$(tr '\n' '|' <<<"$out" | cut -c1-400)"
  fi
  rm -rf "$t"
}

# shellcheck disable=SC2317,SC2030,SC2031,SC2034 # stubs; globals read by doctor.sh
test_doctor_fix_guards() {
  local t r="" out
  t=$(mktemp -d)
  mkdir -p "$t/storage/templates/builds" "$t/vms/web" "$t/vms/tpl" "$t/state/vms"
  : >"$t/storage/templates/builds/img-old.qcow2"
  : >"$t/storage/templates/img.qcow2"
  : >"$t/vms/tpl/base.pending"
  touch -d '2 days ago' "$t/vms/web/web-disk.qcow2.rebase"
  out=$(
    source "$SCRIPT_DIR/doctor.sh" >/dev/null 2>&1
    TERM=dumb DATACENTER_BASE="$t" DCVM_STATE_DIR="$t/state" FIX=true FAST=true
    (
      get_vm_disk_path() { echo "$t/storage/templates/img.qcow2"; }
      get_vm_state() { echo paused; }
      disk_backing() { echo "prepared paused" >>"$t/calls"; }
      prepare_vm_disk web
    )
    current_build() { echo "$t/storage/templates/builds/img-new.qcow2"; }
    disk_backing() { echo "$t/storage/templates/builds/img-old.qcow2"; }
    prepare_vm_disk() { echo "prepared $1" >>"$t/calls"; }
    echo "paused=$(base_status web "$t/vms/web/web-disk.qcow2" "$t/storage/templates/builds/img-old.qcow2" paused)"
    echo "failed=$(base_status web "$t/vms/web/web-disk.qcow2" "$t/storage/templates/builds/img-old.qcow2" "shut off")"
    echo "pending=$(FIX=false base_status tpl "$t/vms/tpl/tpl-disk.qcow2" "$t/storage/templates/img.qcow2" "shut off")"
    registry_set copy "autostart=off"
    vm_disks() { printf 'copy\t%s\t\n' "$t/vms/copy/copy-disk.qcow2"; }
    is_vm_in_network() { :; }
    get_vm_state() { echo "shut off"; }
    base_status() { echo "ok|fine"; }
    virsh() {
      echo "virsh $*" >>"$t/calls"
      [ "$1" = dominfo ] && echo "Autostart:      disable"
      [ "$1" = list ] && echo copy
      return 0
    }
    check_vms
    df() { return 1; }
    check_vm_exists() { :; }
    check_storage
  ) 2>&1
  grep -q '^paused=skip|' <<<"$out" && [ "$(grep -c prepared "$t/calls")" = 1 ] && r+="paused "
  grep -q '^failed=warn|on an older build: could not move' <<<"$out" && r+="failed "
  ! grep -q '^pending=ok|pinned' <<<"$out" && r+="pending "
  grep -q 'autostart left off' <<<"$out" && ! grep -q 'virsh autostart' "$t/calls" && r+="autostart "
  grep -q 'df could not read' <<<"$out" && grep -q 'no files from interrupted operations' <<<"$out" && [ -f "$t/vms/web/web-disk.qcow2.rebase" ] && r+="leftovers "
  if [ "$r" = "paused failed pending autostart leftovers " ]; then
    log_test "PASS" "doctor --fix leaves paused disks, copies in progress and restored static-IP copies alone, and reports failed repairs"
  else
    log_test "FAIL" "doctor --fix leaves paused disks, copies in progress and restored static-IP copies alone, and reports failed repairs" "$r; $(tr '\n' '|' <<<"$out" | cut -c1-400)"
  fi
  rm -rf "$t"
}

# shellcheck disable=SC2317,SC2034 # stubs; groups are read by manage_users
test_user_remove_and_owner_hint() {
  local r
  r=$(
    eval "$(sed -n '/^manage_users()/,/^}/p; /^set_owner()/,/^}/p' "$SCRIPT_DIR/../core/access.sh")"
    require_admin() { :; }
    gpasswd() { [ "$1 $2 $3" = "-d member dcvm" ]; }
    DCVM_USER_GROUP=dcvm DCVM_ADMIN_GROUP=dcvm-admin
    manage_users remove stranger >/dev/null 2>&1 || echo stranger-fails
    manage_users remove member >/dev/null 2>&1 && echo member-ok
    check_vm_exists() { :; }
    is_vm_in_network() { :; }
    registry_set() { :; }
    id() { echo 1001; }
    set_owner web bob 2>&1 | grep -q 'dcvm console web' && echo owner-hint
  )
  if [ "$(tr '\n' ' ' <<<"$r")" = "stranger-fails member-ok owner-hint " ]; then
    log_test "PASS" "user remove fails for a non-member; owner tells the new owner how to log in"
  else
    log_test "FAIL" "user remove fails for a non-member; owner tells the new owner how to log in" "$(tr '\n' ' ' <<<"$r")"
  fi
}

# shellcheck disable=SC2034,SC1091 # NETWORK_SUBNET is read by validate_ip_in_subnet
test_static_ip_reason() {
  local out
  out=$(
    source "$SCRIPT_DIR/../core/create-vm.sh" >/dev/null 2>&1
    NETWORK_SUBNET=10.10.10
    compute_incremental_ip 10.10.10.1 0 1 2>&1 >/dev/null
    compute_incremental_ip 127.0.0.5 0 1 2>&1 >/dev/null
    compute_incremental_ip 10.10.10.5 1 2 2>/dev/null
  )
  if grep -q 'Last octet' <<<"$out" && grep -q 'not in subnet' <<<"$out" && grep -qx '10.10.10.6' <<<"$out"; then
    log_test "PASS" "create --ip names why a base address is refused"
  else
    log_test "FAIL" "create --ip names why a base address is refused" "$(tr '\n' ' ' <<<"$out")"
  fi
}

# shellcheck disable=SC2317 # stubs
test_reap_needs_libvirt() {
  local t r=""
  t=$(mktemp -d)
  r=$(
    DCVM_STATE_DIR="$t"
    eval "$(sed -n '/^reap_expired()/,/^}/p' "$SCRIPT_DIR/../core/access.sh")"
    registry_set gone "expires=1"
    registry_set alive "expires=1"
    mkdir() { :; }
    flock() {
      echo "${*: -1}" >"$t/flocked"
      return 1
    }
    virsh() { return 1; }
    reap_expired 2>/dev/null
    [ -f "$t/vms/gone" ] && [ -f "$t/vms/alive" ] && echo kept
    virsh() { [ "$*" = "list --all --name" ] && echo alive; }
    reap_expired
    [ -f "$t/vms/gone" ] || echo gone-removed
    [ -f "$t/vms/alive" ] && [ "$(cat "$t/flocked")" = alive ] && echo alive-kept
  )
  if [ "$(tr '\n' ' ' <<<"$r")" = "kept gone-removed alive-kept " ]; then
    log_test "PASS" "the TTL reaper keeps every owner record while libvirt is not answering"
  else
    log_test "FAIL" "the TTL reaper keeps every owner record while libvirt is not answering" "$(tr '\n' ' ' <<<"$r")"
  fi
  rm -rf "$t"
}

# shellcheck disable=SC2317 # stubs
test_info_and_connect_exit() {
  local t r="" out
  t=$(mktemp -d)
  mkdir -p "$t/a/b" "$t/bin"
  printf '#!/bin/bash\n[ -n "$FAKE_OK" ] && echo %s && exit 0\necho "you have no VM named $2" >&2\nexit 77\n' \
    "'{\"name\":\"t1\",\"state\":\"running\",\"ip\":\"10.0.0.5\",\"user\":\"u\",\"created\":1}'" >"$t/dcvm"
  printf '#!/bin/bash\nprintf "%%s\\n" "$@" >"%s/argv"\n' "$t" >"$t/bin/ssh"
  chmod +x "$t/dcvm" "$t/bin/ssh"
  (
    eval "$(sed -n '/^show_info()/,/^}/p; /^main()/,/^}/p' "$SCRIPT_DIR/../core/access.sh")"
    load_dcvm_config() { :; }
    virsh() { return 1; }
    main info nosuch >/dev/null 2>&1 || echo missing-fails
    main info >/dev/null 2>&1 || echo usage-fails
  ) >"$t/out"
  conn() { (eval "$(sed -n '/^resolve_vm()/,/^}/p; /^ssh_opts()/,/^}/p; /^main()/,/^}/p' "$SCRIPT_DIR/../core/connect.sh")" &&
    SCRIPT_DIR="$t/a/b" HOME="$t" PATH="$t/bin:$PATH" && main "$@") 2>&1 </dev/null; }
  out=$(conn exec t1 -- true)
  [ $? -eq 77 ] && ! grep -qi 'json\|traceback' <<<"$out" && echo exit-77 >>"$t/out"
  (export FAKE_OK=1 && conn exec t1 -- -oProxyCommand=evil) >/dev/null
  [ "$(grep -A2 -x 'u@10.0.0.5' "$t/argv" | tr '\n' ' ')" = "u@10.0.0.5 -- -oProxyCommand=evil " ] && echo exec-ends-options >>"$t/out"
  rm -f "$t/argv"
  (export FAKE_OK=1 && conn ssh t1 -oProxyCommand=evil) >/dev/null
  [ "$(grep -A2 -x 'u@10.0.0.5' "$t/argv" | tr '\n' ' ')" = "u@10.0.0.5 -- -oProxyCommand=evil " ] && echo ssh-ends-options >>"$t/out"
  r=$(tr '\n' ' ' <"$t/out")
  if [ "$r" = "missing-fails usage-fails exit-77 exec-ends-options ssh-ends-options " ]; then
    log_test "PASS" "dcvm info fails for a missing VM; ssh/exec keep its exit code and pass nothing as an ssh option"
  else
    log_test "FAIL" "dcvm info fails for a missing VM; ssh/exec keep its exit code and pass nothing as an ssh option" "$r"
  fi
  rm -rf "$t"
}

test_fix_lock_definition() {
  if ! command -v python3 >/dev/null 2>&1; then
    log_test "SKIP" "fix-lock definition repair (python3 not installed)"
    return
  fi
  local t r="" out
  t=$(mktemp -d)
  cat >"$t/vm.xml" <<'XML'
<domain type='kvm'>
  <name>web</name>
  <metadata><libosinfo:libosinfo xmlns:libosinfo='http://libosinfo.org/xmlns/libvirt/domain/1.0'><libosinfo:os id='http://ubuntu.com/ubuntu/24.04'/></libosinfo:libosinfo></metadata>
  <devices>
    <disk type='file' device='disk'><driver name='qemu' type='raw' cache='writeback'/><source file='/srv/vms/web/web-disk.qcow2'/><target dev='sda' bus='sata'/><address type='drive' controller='0' bus='0' target='0' unit='0'/></disk>
    <disk type='file' device='disk'><driver name='qemu' type='raw' cache='none'/><source file='/srv/data.img'/><target dev='sdb' bus='sata'/></disk>
    <disk type='file' device='cdrom'><source file='/srv/vms/web/cloud-init.iso'/><target dev='sdc' bus='sata'/></disk>
  </devices>
</domain>
XML
  cp "$t/vm.xml" "$t/iso.xml"
  (
    source "$SCRIPT_DIR/fix-lock.sh" >/dev/null 2>&1
    cp "$t/vm.xml" "$t/raw.xml"
    [ "$(clean_definition "$t/raw.xml" /srv/vms/web/web-disk.qcow2 false raw)" = "cache setting removed" ] && grep -q "type=.raw. */><source file=./srv/vms/web/web-disk" "$t/raw.xml" && echo raw
    [ "$(clean_definition "$t/vm.xml" /srv/vms/web/web-disk.qcow2 true qcow2)" = "cache setting removed, disk read as qcow2, disk on virtio" ] && echo cloud
    cp "$t/vm.xml" "$t/again.xml"
    [ -z "$(clean_definition "$t/vm.xml" /srv/vms/web/web-disk.qcow2 true qcow2)" ] && cmp -s "$t/vm.xml" "$t/again.xml" && echo unchanged
    [ "$(clean_definition "$t/iso.xml" /srv/vms/web/web-disk.qcow2 false qcow2)" = "cache setting removed, disk read as qcow2" ] && echo iso
  ) >"$t/out"
  out=$(tr -d '\n' <"$t/vm.xml")
  grep -q "target dev=.vda. bus=.virtio." <<<"$out" && grep -q "cloud-init.iso" <<<"$out" && ! grep -q "writeback\|type=.drive." <<<"$out" &&
    grep -q "cache=.none.*target dev=.sdb. bus=.sata." <<<"$out" && grep -q "libosinfo:os" <<<"$out" && echo xml >>"$t/out"
  grep -q "cdrom" "$t/iso.xml" && grep -q "dev=.sda. bus=.sata." "$t/iso.xml" && echo iso-xml >>"$t/out"
  r=$(tr '\n' ' ' <"$t/out")
  if [ "$r" = "raw cloud unchanged iso xml iso-xml " ]; then
    log_test "PASS" "fix-lock repairs virsh's single-quoted definition, only the VM's own disk, never calls a raw disk qcow2, and says when nothing changed"
  else
    log_test "FAIL" "fix-lock repairs virsh's single-quoted definition, only the VM's own disk, never calls a raw disk qcow2, and says when nothing changed" "$r"
  fi
  rm -rf "$t"
}

# shellcheck disable=SC2034,SC2030,SC2031,SC2317,SC1091 # stubs; globals are read by create-vm.sh
test_create_os_choice_and_batch() {
  local t r="" f
  t=$(mktemp -d)
  mkdir -p "$t/cwd" "$t/storage/templates"
  : >"$t/cwd/4"
  for f in ubuntu-24.04-server-cloudimg-amd64.img ubuntu-22.04-server-cloudimg-amd64.img Fedora-Cloud-Base-Generic-44.x86_64.qcow2; do
    : >"$t/storage/templates/$f"
  done
  r=$(
    cd "$t/cwd" || exit 1
    source "$SCRIPT_DIR/../core/create-vm.sh" >/dev/null 2>&1
    DATACENTER_BASE="$t"
    iso_handoff_check() { exit 9; }
    osinfo-query() { printf ' Short ID             \n----------------------\n fedora44             \n'; }
    (FORCE_MODE=true FLAG_OS="" VM_OS_CHOICE=4 && select_os >/dev/null 2>&1 && echo "file4:$VM_OS")
    (FORCE_MODE=false FLAG_OS=5 VM_OS_CHOICE=5 && select_os >/dev/null 2>&1 <<<"" && echo "flag:$VM_OS")
    (FORCE_MODE=true FLAG_OS=9 VM_OS_CHOICE=9 && select_os >/dev/null 2>&1 && echo "fedora:$OS_VARIANT")
    (FORCE_MODE=false FLAG_OS=x VM_OS_CHOICE=x && select_os >/dev/null 2>&1 </dev/null) || echo "bad-flag-exits"
    (
      FORCE_MODE=true VM_USERNAME=tester VM_PASSWORD=testpass123 FLAG_DISABLE_ROOT=true
      setup_root_access >/dev/null 2>&1
      setup_root_access >/dev/null 2>&1
      echo "batch:${ENABLE_ROOT}[$FLAG_ENABLE_ROOT]"
    )
  )
  r=$(tr '\n' ' ' <<<"$r")
  if [ "$r" = "file4:ubuntu24.04 flag:ubuntu22.04 fedora:fedora44 bad-flag-exits batch:n[] " ]; then
    log_test "PASS" "create -o: a file named 4 is not an ISO, -o skips the prompt, fedora44 found in padded osinfo; --disable-root on every VM of a batch"
  else
    log_test "FAIL" "create -o: a file named 4 is not an ISO, -o skips the prompt, fedora44 found in padded osinfo; --disable-root on every VM of a batch" "$r"
  fi
  rm -rf "$t"
}

# shellcheck disable=SC2034,SC2030,SC2031,SC2317,SC1091 # stubs; globals are read by storage-manager.sh
test_storage_cleanup_reports() {
  local t r="" out
  t=$(mktemp -d)
  out=$(
    source "$SCRIPT_DIR/../storage/storage-manager.sh" >/dev/null 2>&1
    LOG_FILE="$t/storage.log" DATACENTER_BASE="$t" TERM=dumb
    RC=0
    ssh() {
      echo "$*" >>"$t/ssh"
      [[ "$*" != *"bash -s"* ]] || cat >"$t/script"
      return "$RC"
    }
    timeout() {
      echo "$1" >>"$t/timeout"
      shift
      "$@"
    }
    registry_get() {
      [ "$2" = created ] && echo 123
      [ "$2" = user ] && [ "$1" = imported ] && echo bob
      return 0
    }
    vm_owner_uid() { echo 0; }
    get_vm_ip_trusted() { echo 10.10.10.50; }
    check_vm_storage imported
    check_vm_storage isovm
    for RC in 0 3 1 255; do cleanup_old_files imported bob@10.10.10.50; done
  ) 2>&1
  grep -q 'bob@10.10.10.50 df -P /' "$t/ssh" && ! grep -q 'admin@' "$t/ssh" && r+="login "
  grep -q 'isovm.*login user unknown' <<<"$out" && r+="iso-skip "
  [ "$(grep -c 'old logs compressed and archived' <<<"$out")" = 1 ] && grep -q '/mnt/shared is not mounted' <<<"$out" &&
    grep -q 'cleanup failed (exit 1)' <<<"$out" && grep -q 'SSH to bob@10.10.10.50 did not connect' <<<"$out" && r+="status "
  grep -q 'find /var/log -type f -name "\*.gz"' "$t/script" && grep -q 'mv -f .* && ln -sf ' "$t/script" && r+="links "
  ! grep -qv 'ServerAliveInterval=15 -o ServerAliveCountMax=2' "$t/ssh" && [ "$(sort -u "$t/timeout")" = 600 ] && r+="bounded "
  if [ "$r" = "login iso-skip status links bounded " ]; then
    log_test "PASS" "dcvm storage logs in as the registry's user, uses df -P, reports cleanup by its exit status, never re-archives its links, never hangs on one guest"
  else
    log_test "FAIL" "dcvm storage logs in as the registry's user, uses df -P, reports cleanup by its exit status, never re-archives its links, never hangs on one guest" "$r; $(tr '\n' '|' <<<"$out" | cut -c1-400)"
  fi
  rm -rf "$t"
}

# shellcheck disable=SC2034,SC2030,SC2031,SC2317,SC2016,SC1091 # stubs; globals are read by fix-lock.sh
test_fix_lock_counts_and_spares() {
  local t r="" out
  t=$(mktemp -d)
  : >"$t/fixlocktest.qcow2"
  : >"$t/fixlocktest.qcow2.lock"
  out=$(
    source "$SCRIPT_DIR/fix-lock.sh" >/dev/null 2>&1
    exec 2>&1
    TERM=dumb DATACENTER_BASE="$t" DCVM_CALLER_ROLE=user
    HOLDER="" STATE="shut off"
    check_vm_exists() { :; }
    is_vm_in_network() { [ "$1" = fixlocktest ]; }
    get_vm_disk_path() { echo "$t/fixlocktest.qcow2"; }
    get_vm_state() { echo "$STATE"; }
    vm_qemu_pid() { return 1; }
    sleep() { :; }
    command_exists() { return 1; }
    kill() { echo "killed $*" >>"$t/kills"; }
    fuser() { echo "fuser $*" >>"$t/kills"; }
    chown() { :; }
    lsof() { [ -n "$HOLDER" ] && printf 'COMMAND PID\nqemu-img 2147483646\n'; }
    virsh() {
      echo "virsh $*" >>"$t/virsh"
      [ "$1" = dumpxml ] && echo "<domain><devices/></domain>"
      [ "$1" = list ] && echo " Id Name State"
      [ "$1" != destroy ]
    }
    rm() {
      [[ "$*" == *.lock* ]] && return 1
      command rm "$@"
    }
    fix_vm_locks fixlocktest
    echo "rc1=$?"
    HOLDER=1
    fix_vm_locks fixlocktest
    echo "rc2=$?"
    HOLDER="" STATE=paused
    vm_qemu_pid() { echo 2147483646; }
    fix_vm_locks fixlocktest
    echo "rc3=$?"
    : >"$t/virsh"
    fix_vm_locks foreign
    echo "rc4=$?"
    check_permissions() { :; }
    check_dependencies() { :; }
    (main --all </dev/null)
    echo "all=$?"
  ) 2>&1
  sed -n '1,/^rc1=/p' <<<"$out" | grep -q 'Locks cleared on fixlocktest with 1 problem' && grep -q '^rc1=1' <<<"$out" && r+="counted "
  grep -q 'Still using the disk: qemu-img(2147483646)' <<<"$out" && grep -q '^rc2=1' <<<"$out" && [ ! -e "$t/kills" ] && r+="spared "
  grep -q 'libvirt could not stop fixlocktest' <<<"$out" && grep -q '^rc3=1' <<<"$out" && [ ! -e "$t/kills" ] && r+="no-kill "
  grep -q "'foreign' is not a dcvm VM" <<<"$out" && grep -q '^rc4=1' <<<"$out" && ! grep -qv 'virsh list' "$t/virsh" && r+="foreign "
  grep -q 'add --yes' <<<"$out" && grep -q '^all=1' <<<"$out" && r+="all-asks "
  ! grep -q 'virsh shutdown' "$SCRIPT_DIR/fix-lock.sh" && grep -q 'stop_vm_gracefully "$vm_name"' "$SCRIPT_DIR/fix-lock.sh" && r+="no-3s "
  if [ "$r" = "counted spared no-kill foreign all-asks no-3s " ]; then
    log_test "PASS" "fix-lock counts a lock it could not remove, never kills another disk user or a VM libvirt could not stop, leaves other libvirt VMs alone, --all asks first"
  else
    log_test "FAIL" "fix-lock counts a lock it could not remove, never kills another disk user or a VM libvirt could not stop, leaves other libvirt VMs alone, --all asks first" "$r; $(tr '\n' '|' <<<"$out" | cut -c1-400)"
  fi
  rm -rf "$t"
}

# shellcheck disable=SC2034,SC2030,SC2031,SC2317,SC1091 # globals read by doctor.sh
test_doctor_seed_permissions() {
  local t r="" out
  t=$(mktemp -d)
  mkdir -p "$t/vms/web/cloud-init"
  chmod 755 "$t/vms"
  chmod 711 "$t/vms/web"
  chmod 755 "$t/vms/web/cloud-init"
  echo secret >"$t/vms/web/cloud-init/user-data"
  chmod 644 "$t/vms/web/cloud-init/user-data"
  : >"$t/vms/web/cloud-init.iso"
  : >"$t/vms/web/web-disk.qcow2"
  chmod 600 "$t/vms/web/cloud-init.iso" "$t/vms/web/web-disk.qcow2"
  out=$(
    source "$SCRIPT_DIR/doctor.sh" >/dev/null 2>&1
    TERM=dumb DATACENTER_BASE="$t"
    FIX=false vm_permissions
    echo "problems=$PROBLEMS"
    FIX=true vm_permissions
    FIX=false vm_permissions
  ) 2>&1
  grep -q 'open to other local users' <<<"$out" && grep -q '^problems=1' <<<"$out" && r+="found "
  # Without root the seed can't become root's, so the last check still reports it.
  grep -q 'closed VM disks, cloud-init seeds' <<<"$out" && { [ "$(id -u)" != 0 ] || grep -q '1 cloud-init seed, backups and network records closed' <<<"$out"; } && r+="fixed "
  [ "$(stat -c %a "$t/vms" "$t/vms/web/cloud-init" "$t/vms/web/cloud-init/user-data" | tr '\n' ' ')" = "711 700 600 " ] && r+="modes "
  if [ "$(id -u)" = 0 ]; then
    chown nobody "$t/vms/web/cloud-init/user-data"
    out=$(
      source "$SCRIPT_DIR/doctor.sh" >/dev/null 2>&1
      TERM=dumb DATACENTER_BASE="$t"
      FIX=true vm_permissions
    ) 2>&1
    grep -q 'closed VM disks' <<<"$out" && [ "$(stat -c %U "$t/vms/web/cloud-init/user-data")" = root ] || r+="owner-not-fixed "
  fi
  if [ "$r" = "found fixed modes " ]; then
    log_test "PASS" "doctor checks cloud-init seeds (700/600, root's) and the vms folder (711) and fixes them"
  else
    log_test "FAIL" "doctor checks cloud-init seeds (700/600, root's) and the vms folder (711) and fixes them" "$r; $(tr '\n' '|' <<<"$out" | cut -c1-400)"
  fi
  rm -rf "$t"
}

test_installer_packages() {
  local fam
  for fam in debian arch; do
    if installer_packages "$fam" | grep -qx jq; then
      log_test "PASS" "installer installs jq on $fam hosts"
    else
      log_test "FAIL" "installer installs jq on $fam hosts"
    fi
  done
  if installer_packages debian | grep -qx qemu-system-x86 && ! installer_packages debian | grep -qx qemu-kvm; then
    log_test "PASS" "installer installs qemu-system-x86, not the virtual qemu-kvm (no candidate on Ubuntu 26.04)"
  else
    log_test "FAIL" "installer installs qemu-system-x86, not the virtual qemu-kvm (no candidate on Ubuntu 26.04)"
  fi
  if installer_packages debian | grep -qx aria2 && installer_packages arch | grep -qx aria2; then
    log_test "PASS" "installer installs aria2 for image downloads"
  else
    log_test "FAIL" "installer installs aria2 for image downloads"
  fi
  if installer_packages debian | grep -qx dnsmasq-utils && installer_packages arch | grep -qx dnsmasq; then
    log_test "PASS" "installer installs dhcp_release (dnsmasq-utils on debian, dnsmasq on arch)"
  else
    log_test "FAIL" "installer installs dhcp_release (dnsmasq-utils on debian, dnsmasq on arch)"
  fi
}

# shellcheck disable=SC2317,SC2030 # stub; DATACENTER_BASE set for the call only
test_get_vm_ip_exact() {
  local t got
  t=$(mktemp -d)
  write_lease_fixture "$t"
  stub_virsh() {
    case "$1" in
    domiflist) printf ' Interface Type Source Model MAC\n vnet0 network datacenter-net virtio 52:54:00:00:00:01\n' ;;
    net-dhcp-leases) cat "$t/virsh-leases" ;;
    esac
    return 0
  }
  got=$(
    virsh() { stub_virsh "$@" | grep -v ' VM1 '; }
    DATACENTER_BASE="$t" get_vm_ip vm1
  )
  if [ "$got" = "N/A" ]; then
    log_test "PASS" "get_vm_ip vm1 ignores vm10's lease (#37)"
  else
    log_test "FAIL" "get_vm_ip vm1 ignores vm10's lease (#37)" "got '$got'"
  fi
  got=$(
    virsh() { stub_virsh "$@" | sed 's/ vm10 / vm1  /'; }
    DATACENTER_BASE="$t" get_vm_ip vm1
  )
  if [ "$got" = "10.10.10.11" ]; then
    log_test "PASS" "get_vm_ip vm1 finds its own lease by MAC, not by a hostname another guest sends (#37)"
  else
    log_test "FAIL" "get_vm_ip vm1 finds its own lease by MAC, not by a hostname another guest sends (#37)" "got '$got'"
  fi
  got=$(
    virsh() {
      case "$1" in
      net-dhcp-leases) cat "$t/virsh-leases" ;;
      domiflist) echo " vnet1  network  datacenter-net  virtio  52:54:00:AB:C2:54" ;;
      esac
      return 0
    }
    DATACENTER_BASE="$t" get_vm_ip renamed-vm
  )
  if [ "$got" = "10.10.10.254" ]; then
    log_test "PASS" "get_vm_ip falls back to its exact MAC (any case) (#37)"
  else
    log_test "FAIL" "get_vm_ip falls back to its exact MAC (any case) (#37)" "got '$got'"
  fi
  rm -rf "$t"
}

test_import_fd_readable() {
  command -v python3 >/dev/null 2>&1 || {
    log_test "SKIP" "admin import takes only a descriptor opened for reading" "python3 not available"
    return
  }
  local t out
  t=$(mktemp -d)
  echo data >"$t/a.tar.gz"
  out=$(
    python3 -I -S - "$SCRIPT_DIR/../server/dcvm-server.py" "$t/a.tar.gz" <<'PY' 2>&1
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("srv", sys.argv[1])
s = importlib.util.module_from_spec(spec)
spec.loader.exec_module(s)
def ask(flags):
    fd = os.open(sys.argv[2], flags)
    try:
        return " ".join(s.admin_argv({"uid": 0, "files": [fd]}, ["backup", "import", "fd:0", "vm1"]))
    except s.Denied:
        return "denied"
print(ask(getattr(os, "O_PATH", os.O_WRONLY)), "|", ask(os.O_WRONLY), "|", ask(os.O_RDONLY).split()[2][:14])
PY
  )
  rm -rf "$t"
  if [ "$out" = "denied | denied | /proc/self/fd/" ]; then
    log_test "PASS" "admin import takes only a descriptor opened for reading"
  else
    log_test "FAIL" "admin import takes only a descriptor opened for reading" "$out"
  fi
}

test_common_functions() {
  echo ""
  log_test "INFO" "═══ COMMON.SH FUNCTION TESTS ═══"

  run_test "print_info function" "print_info 'Test message' >/dev/null"
  run_test "print_success function" "print_success 'Test message' >/dev/null"
  run_test "print_warning function" "print_warning 'Test message' >/dev/null"
  run_test "print_error function" "print_error 'Test message' >/dev/null"
  run_test "validate_vm_name (valid)" "validate_vm_name 'qa-vm_1'"
  run_test_expect_fail "validate_vm_name (quote in name)" "validate_vm_name \"qa'vm\""
  run_test "trim+validate_vm_name (valid trimmed)" "n=\$(trim_whitespace ' qa-vm '); [ \"\$n\" = 'qa-vm' ] && validate_vm_name \"\$n\""
  run_test_expect_fail "trim+validate_vm_name (quote)" "n=\$(trim_whitespace \"qa'vm\"); validate_vm_name \"\$n\""
  run_test_expect_fail "trim+validate_vm_name (double quote)" "n=\$(trim_whitespace 'a\"b'); validate_vm_name \"\$n\""
  run_test_expect_fail "trim+validate_vm_name (backslash)" "n=\$(trim_whitespace 'qa\\vm'); validate_vm_name \"\$n\""
  run_test_expect_fail "validate_vm_name_list (quote in list)" "validate_vm_name_list \"good-vm,qa'vm\""
  run_test "validate_vm_name_list (valid trimmed)" "validate_vm_name_list ' qa-vm '"
  run_test "validate_vm_name_list (two names)" "validate_vm_name_list 'web1, web2'"
  run_test_expect_fail "validate_vm_name_list (duplicate)" "validate_vm_name_list 'web1,web2, web1'"
  run_test_expect_fail "validate_vm_name_list (newline)" "validate_vm_name_list \$'web1\\nweb2'"
  run_test_expect_fail "validate_vm_name_list (empty entry)" "validate_vm_name_list 'web1,,web2'"
  run_test_expect_fail "validate_vm_name_list (trailing comma)" "validate_vm_name_list 'web1,'"
  local pf_rules="iptables() { case \"\$*\" in '-w -t nat -C PREROUTING ! -i virbr-dc -p tcp -m addrtype --dst-type LOCAL --dport 2221 -j DNAT --to-destination 10.10.10.50:22' |'-w -C FORWARD -p tcp -d 10.10.10.50 --dport 22 -m conntrack --ctstate DNAT -j ACCEPT') return 0 ;; esac; return 1; }"
  run_test "check_port_forward (DNAT + FORWARD rules, VM port open)" "(BRIDGE_NAME=virbr-dc; $pf_rules; libvirt_nft_rejects_forwards() { return 1; }; check_port_connectivity() { [ \"\$1:\$2\" = '10.10.10.50:22' ]; }; check_port_forward 2221 10.10.10.50 22)"
  run_test_expect_fail "check_port_forward (libvirt's nftables rules reject forwards)" "(BRIDGE_NAME=virbr-dc; $pf_rules; libvirt_nft_rejects_forwards() { return 0; }; check_port_connectivity() { return 0; }; check_port_forward 2221 10.10.10.50 22)"
  run_test_expect_fail "check_port_forward (no DNAT rule)" "(iptables() { case \"\$*\" in '-w -t nat'*) return 1 ;; esac; return 0; }; check_port_connectivity() { return 0; }; check_port_forward 2221 10.10.10.50 22)"
  run_test_expect_fail "check_port_forward (no FORWARD rule)" "(iptables() { case \"\$*\" in '-w -C FORWARD'*) return 1 ;; esac; return 0; }; check_port_connectivity() { return 0; }; check_port_forward 2221 10.10.10.50 22)"
  run_test_expect_fail "check_port_forward (old FORWARD rule without the DNAT match)" "(BRIDGE_NAME=virbr-dc; iptables() { case \"\$*\" in '-w -t nat'* | '-w -C FORWARD -p tcp -d 10.10.10.50 --dport 22 -j ACCEPT') return 0 ;; esac; return 1; }; check_port_connectivity() { return 0; }; check_port_forward 2221 10.10.10.50 22)"
  run_test_expect_fail "check_port_forward (VM port closed)" "(iptables() { return 0; }; check_port_connectivity() { return 1; }; check_port_forward 2221 10.10.10.50 22)"
  run_test "validate_package_list (valid)" "validate_package_list 'nginx, python3-pip,g++,libc6.1'"
  run_test_expect_fail "validate_package_list (shell chars)" "validate_package_list 'nginx;reboot'"
  run_test_expect_fail "validate_package_list (space inside)" "validate_package_list 'nginx,my pkg'"
  run_test_expect_fail "validate_package_list (leading dash)" "validate_package_list '-y'"
  run_test_expect_fail "validate_package_list (newline)" "validate_package_list \$'curl\\nnginx'"
  run_test_expect_fail "validate_package_list (carriage return)" "validate_package_list \$'curl\\rnginx'"
  run_test "validate_username (valid)" "validate_username 'testuser'"
  run_test "validate_username (with number)" "validate_username 'user123'"
  run_test "validate_username (with underscore)" "validate_username 'test_user'"
  run_test "validate_username (with hyphen)" "validate_username 'test-user'"
  run_test_expect_fail "validate_username (too short)" "validate_username 'ab'"
  run_test_expect_fail "validate_username (invalid chars)" "validate_username 'test@user'"
  run_test_expect_fail "validate_username (starts with number)" "validate_username '1user'"
  run_test "validate_username (root)" "validate_username 'root'"
  run_test_expect_fail "validate_username (reserved admin)" "validate_username 'admin'"
  run_test_expect_fail "validate_username (reserved guest)" "validate_username 'guest'"
  run_test "validate_password (valid 8char)" "validate_password 'password123'"
  run_test "validate_password (valid long)" "validate_password 'verylongpassword123'"
  run_test "validate_password (valid min 4char)" "validate_password 'abcd'"
  run_test_expect_fail "validate_password (too short 3char)" "validate_password 'abc'"

  if type validate_ip_in_subnet &>/dev/null; then
    run_test "validate_ip_in_subnet (valid)" "NETWORK_SUBNET=10.10.10 validate_ip_in_subnet '10.10.10.50'"
    run_test "validate_ip_in_subnet (edge .2)" "NETWORK_SUBNET=10.10.10 validate_ip_in_subnet '10.10.10.2'"
    run_test "validate_ip_in_subnet (edge .254)" "NETWORK_SUBNET=10.10.10 validate_ip_in_subnet '10.10.10.254'"
    run_test_expect_fail "validate_ip_in_subnet (wrong subnet)" "NETWORK_SUBNET=10.10.10 validate_ip_in_subnet '192.168.1.50'"
    run_test_expect_fail "validate_ip_in_subnet (gateway .1)" "NETWORK_SUBNET=10.10.10 validate_ip_in_subnet '10.10.10.1'"
    run_test_expect_fail "validate_ip_in_subnet (broadcast .255)" "NETWORK_SUBNET=10.10.10 validate_ip_in_subnet '10.10.10.255'"
    run_test_expect_fail "validate_ip_in_subnet (network .0)" "NETWORK_SUBNET=10.10.10 validate_ip_in_subnet '10.10.10.0'"
    run_test_expect_fail "validate_ip_in_subnet (leading zero .050, octal .40 to iptables)" "NETWORK_SUBNET=10.10.10 validate_ip_in_subnet '10.10.10.050'"
    run_test_expect_fail "validate_ip_in_subnet (leading zero in subnet part)" "NETWORK_SUBNET=10.10.10 validate_ip_in_subnet '10.010.10.50'"
    run_test_expect_fail "valid_vm_ip (leading zero .050)" "NETWORK_SUBNET=10.10.10 valid_vm_ip '10.10.10.050'"
    run_test_expect_fail "valid_vm_ip (.00)" "NETWORK_SUBNET=10.10.10 valid_vm_ip '10.10.10.00'"
    run_test "valid_vm_ip (.50)" "NETWORK_SUBNET=10.10.10 valid_vm_ip '10.10.10.50'"
    run_test_expect_fail "claim_static_ip (leading zero .050)" "(NETWORK_SUBNET=10.10.10; ip_held_by_other_vm() { return 1; }; claim_static_ip vm1 '10.10.10.050')"
    run_test_expect_fail "valid_ipv4 (octet 256)" "valid_ipv4 10.10.10.256"
    run_test "valid_ipv4 (0.0.0.0 and 255.255.255.255)" "valid_ipv4 0.0.0.0 && valid_ipv4 255.255.255.255"
  else
    log_test "SKIP" "validate_ip_in_subnet tests" "Function not available"
  fi

  run_test "format_bytes (1 KB)" "[ \"\$(format_bytes 1024)\" = '1 KB' ]"
  run_test "format_bytes (147 MB)" "[ \"\$(format_bytes 154000000)\" = '147 MB' ]"
  run_test "format_bytes (6.9 GB)" "[ \"\$(format_bytes 7408779264)\" = '6.9 GB' ]"
  run_test "generate_random_mac format" "[[ \$(generate_random_mac) =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]"
  run_test "generate_random_mac uniqueness" "[ \"\$(generate_random_mac)\" != \"\$(generate_random_mac)\" ]"
  run_test "command_exists (bash)" "command_exists bash"
  run_test "command_exists (ls)" "command_exists ls"
  run_test_expect_fail "command_exists (nonexistent)" "command_exists nonexistent_command_xyz_123"

  if type default_username &>/dev/null; then
    run_test "default_username (ubuntu)" "[ \"\$(default_username ubuntu24.04)\" = 'ubuntu' ]"
    run_test "default_username (debian)" "[ \"\$(default_username debian12)\" = 'debian' ]"
    run_test "default_username (archlinux)" "[ \"\$(default_username archlinux)\" = 'archlinux' ]"
    run_test "default_username (kali)" "[ \"\$(default_username kali)\" = 'kali' ]"
    run_test "default_username (unknown)" "[ \"\$(default_username unknown_os)\" = 'osadmin' ]"
  fi

  if type get_vm_username &>/dev/null; then
    test_get_vm_username_lookup
  fi

  if type generate_password_hash &>/dev/null; then
    run_test "generate_password_hash" "[[ \$(generate_password_hash 'testpass') =~ ^\\\$6\\\$ ]]"
  fi

  test_dhcp_cleanup_dispatch
  test_delete_vm_keeps_network
  test_hosts_rename_sed_expr
  test_backup_restore_new_name
  test_backup_restore_in_place
  test_backup_restore_safety
  test_backup_export_selectors
  test_backup_create_streams_disk
  test_backup_export_recompress
  test_backup_builds_kept
  test_backup_ssh_setup_ip_wait
  test_create_extra_packages_userdata
  test_root_username_userdata
  test_root_username_setup
  test_root_mysql_userdata
  test_cloud_init_quoting
  test_create_cancel_and_failure_cleanup
  test_userdata_passwords
  test_userdata_per_os
  test_guest_setup_userdata
  test_dhcp_clear_exact
  test_cleanup_dhcp_lease_failures
  test_dhcp_lease_edge_cases
  test_cleanup_dhcp_lease_parallel
  test_dhcp_cleanup_nits
  test_get_vm_ip_subnet_dots
  test_apache_exact_match
  test_dhcp_release
  test_dhcp_release_client_id
  test_dhcp_renew_link
  test_static_ip_reservation
  test_ip_forward_last_wins
  test_installer_packages
  test_ui_output
  test_ui_columns
  test_ui_region_rows
  test_remove_old_alias
  test_distro_family
  test_ui_width_injection
  test_build_names_and_sums
  test_vm_name_reserved
  test_vm_ip_sources
  test_network_trust
  test_sanitize_domain_xml
  test_create_network_by_mac
  test_create_scrubs_seed
  test_numbers_leading_zeros
  test_check_disk_image
  test_import_rejects_hostile_archives
  test_socket_policy
  test_socket_hardening
  test_socket_admin_locks_and_iso
  test_quota_atomic
  test_services_hardening
  test_registry_visibility
  test_list_owner_column
  test_help_never_acts
  test_usage_matches_parsers
  test_stopped_vms_and_lifecycle_args
  test_import_fd_readable
  test_forward_cleanup_exact_ip
  test_dhcp_stale_by_mac
  test_forward_rules_scope
  test_port_forward_records
  test_port_mappings_kept_and_checked
  test_dhcp_hostile_and_partial
  test_delete_all_shared_state
  test_installer_network
  test_network_status_no_bridge
  test_backup_exact_id_visibility
  test_iso_create_options
  test_iso_and_display_safety
  test_base_builds
  test_doctor_report
  test_doctor_lock_checks
  test_doctor_fix_guards
  test_reap_needs_libvirt
  test_info_and_connect_exit
  test_fix_lock_definition
  test_create_os_choice_and_batch
  test_storage_cleanup_reports
  test_fix_lock_counts_and_spares
  test_doctor_seed_permissions
  test_backup_list_columns
  test_delete_without_iptables_dir
  test_self_update_keeps_backup
  test_self_update_failure_paths
  test_aria2c_download
  test_published_checksum
  test_download_hardening
  test_repo_fetch_https
  test_self_update_revert_and_lock
  test_build_lock
  test_installer_base_owner
  test_uninstall_survivors_and_pools
  test_disable_root_and_nfs_subnet
  test_installer_starts_dcvm_vms_only
  test_installer_checkout_trust
  test_uninstall_exact_matches
  test_uninstall_root_and_leftovers
  test_network_name_exact
  test_suite_installs_only_on_request
  test_backup_console_password
  test_backup_delete_ids_and_user_export
  test_user_remove_and_owner_hint
  test_static_ip_reason
  test_delete_vm_exact_match
  test_bulk_status_reset
  test_get_vm_ip_exact
}

test_cli_help() {
  echo ""
  log_test "INFO" "═══ CLI HELP TESTS ═══"

  local dcvm_cmd=$(get_dcvm_cmd)

  if [ -z "$dcvm_cmd" ]; then
    log_test "SKIP" "CLI help tests" "dcvm command not found"
    return
  fi

  run_test "dcvm --help" "$dcvm_cmd --help"
  run_test "dcvm help" "$dcvm_cmd help"
  run_test "dcvm -h" "$dcvm_cmd -h"
  run_test "dcvm --version" "$dcvm_cmd --version"
  run_test "dcvm version" "$dcvm_cmd version"
  run_test "dcvm -v" "$dcvm_cmd -v"
  run_test "dcvm create --help" "$dcvm_cmd create --help"
  run_test "dcvm backup --help" "$dcvm_cmd backup --help"
  run_test "dcvm network help" "$dcvm_cmd network help" || true
  run_test_output_contains "dcvm help contains 'create'" "create" "$dcvm_cmd help"
  run_test_output_contains "dcvm help contains 'delete'" "delete" "$dcvm_cmd help"
  run_test_output_contains "dcvm help contains 'network'" "network" "$dcvm_cmd help"
  run_test_output_contains "dcvm help contains 'backup'" "backup" "$dcvm_cmd help"
}

test_network_commands() {
  echo ""
  log_test "INFO" "═══ NETWORK COMMAND TESTS ═══"

  local dcvm_cmd=$(get_dcvm_cmd)

  if [ -z "$dcvm_cmd" ]; then
    log_test "SKIP" "Network command tests" "dcvm not available"
    return
  fi

  run_test "dcvm network help" "$dcvm_cmd network help" || true

  if require_root_for_test "network commands"; then
    run_test "dcvm network" "$dcvm_cmd network" || true
    run_test "dcvm network show" "$dcvm_cmd network show" || true
    run_test "dcvm network status" "$dcvm_cmd network status" || true
    run_test "dcvm network leases" "$dcvm_cmd network leases" || true
    run_test "dcvm network config" "$dcvm_cmd network config" || true
    run_test "dcvm network bridge" "$dcvm_cmd network bridge" || true
    run_test "dcvm network ip-forwarding" "$dcvm_cmd network ip-forwarding" || true
    run_test "dcvm network ports help" "$dcvm_cmd network ports help" || true
    run_test "dcvm network ports show" "$dcvm_cmd network ports show" || true
    run_test "dcvm network ports rules" "$dcvm_cmd network ports rules" || true
    run_test "dcvm network dhcp help" "$dcvm_cmd network dhcp help" || true
    run_test "dcvm network dhcp show" "$dcvm_cmd network dhcp show" || true
    run_test "dcvm network dhcp files" "$dcvm_cmd network dhcp files" || true

    local test_vm=$(virsh list --all --name 2>/dev/null | head -1)
    if [ -n "$test_vm" ]; then
      run_test "dcvm network vnc status (existing VM)" "$dcvm_cmd network vnc status $test_vm" || true
    else
      log_test "SKIP" "dcvm network vnc status" "No VMs available for testing"
    fi
  fi
}

test_storage_commands() {
  echo ""
  log_test "INFO" "═══ STORAGE COMMAND TESTS ═══"

  local dcvm_cmd=$(get_dcvm_cmd)

  if [ -z "$dcvm_cmd" ]; then
    log_test "SKIP" "Storage command tests" "dcvm not available"
    return
  fi

  run_test "dcvm backup help" "$dcvm_cmd backup --help"

  local backup_output
  backup_output=$($dcvm_cmd backup list 2>&1)
  local backup_exit=$?

  if [ $backup_exit -eq 0 ]; then
    log_test "PASS" "dcvm backup list"
  elif echo "$backup_output" | grep -qE "No backups found|No backup found"; then
    log_test "PASS" "dcvm backup list (no backups - expected)"
  else
    log_test "FAIL" "dcvm backup list" "Unexpected error"
  fi
  run_test "dcvm template list" "$dcvm_cmd template list" || true
  run_test "dcvm template status" "$dcvm_cmd template status" || true
}

test_vm_listing() {
  echo ""
  log_test "INFO" "═══ VM LISTING TESTS ═══"

  local dcvm_cmd=$(get_dcvm_cmd)

  if [ -z "$dcvm_cmd" ]; then
    log_test "SKIP" "VM listing tests" "dcvm not available"
    return
  fi

  if require_root_for_test "VM listing commands"; then
    run_test "dcvm list" "$dcvm_cmd list" || true
    run_test "dcvm status" "$dcvm_cmd status" || true

    local test_vm=$(virsh list --all --name 2>/dev/null | head -1)
    if [ -n "$test_vm" ]; then
      run_test "dcvm status <vm>" "$dcvm_cmd status $test_vm" || true
    fi
  fi
}

test_mirror_manager_functions() {
  echo ""
  log_test "INFO" "═══ MIRROR-MANAGER FUNCTION TESTS ═══"

  source "$SCRIPT_DIR/mirror-manager.sh" 2>/dev/null || {
    log_test "SKIP" "mirror-manager tests" "Could not source mirror-manager.sh"
    return
  }

  run_test "is_kali_image (kali qcow2)" "is_kali_image 'kali-linux-cloud-genericcloud-amd64.qcow2'"
  run_test_expect_fail "is_kali_image (ubuntu img)" "is_kali_image 'ubuntu-24.04-server-cloudimg-amd64.img'"
  run_test_expect_fail "is_kali_image (debian qcow2)" "is_kali_image 'debian-12-generic-amd64.qcow2'"
  run_test_expect_fail "is_kali_image (empty)" "is_kali_image ''"
  run_test_expect_fail "extract_kali_image (nonexistent file)" "extract_kali_image '/nonexistent/file.tar.xz' '/tmp/test.qcow2' 2>/dev/null"
  run_test_expect_fail "extract_kali_image (empty args)" "extract_kali_image '' '' 2>/dev/null"
}

test_template_commands() {
  echo ""
  log_test "INFO" "═══ TEMPLATE COMMAND TESTS ═══"

  local dcvm_cmd=$(get_dcvm_cmd)

  if [ -z "$dcvm_cmd" ]; then
    log_test "SKIP" "Template command tests" "dcvm not available"
    return
  fi

  run_test "dcvm template list" "$dcvm_cmd template list"
  run_test "dcvm template status" "$dcvm_cmd template status"

  local datacenter_base="${DATACENTER_BASE:-/srv/datacenter}"
  if [ -d "$datacenter_base/storage/templates" ]; then
    local template_count=$(find "$datacenter_base/storage/templates" -name "*.qcow2" -o -name "*.img" 2>/dev/null | wc -l)
    if [ "$template_count" -gt 0 ]; then
      log_test "PASS" "Templates installed: $template_count"
    else
      log_test "WARN" "No templates installed"
    fi
  fi
}

test_self_update() {
  echo ""
  log_test "INFO" "═══ SELF-UPDATE TESTS ═══"

  local dcvm_cmd=$(get_dcvm_cmd)

  if [ -z "$dcvm_cmd" ]; then
    log_test "SKIP" "Self-update tests" "dcvm not available"
    return
  fi

  if require_root_for_test "self-update --check"; then
    run_test "dcvm self-update --check" "$dcvm_cmd self-update --check" || true
  fi

  if [ -d "/var/lib/dcvm/backups" ]; then
    log_test "PASS" "Backup directory exists: /var/lib/dcvm/backups"
    local backup_owner=$(stat -c '%u' /var/lib/dcvm/backups 2>/dev/null)
    if [ "$backup_owner" = "0" ]; then
      log_test "PASS" "Backup directory owned by root"
    else
      log_test "WARN" "Backup directory not owned by root"
    fi
  else
    log_test "WARN" "Backup directory not created yet"
  fi
}

test_fix_lock() {
  echo ""
  log_test "INFO" "═══ FIX-LOCK TESTS ═══"

  local dcvm_cmd=$(get_dcvm_cmd)

  if [ -z "$dcvm_cmd" ]; then
    log_test "SKIP" "Fix-lock tests" "dcvm not available"
    return
  fi

  if require_root_for_test "fix-lock"; then
    local output
    output=$($dcvm_cmd fix-lock 2>&1)
    log_test "PASS" "dcvm fix-lock (executed)"
  fi
}

test_error_handling() {
  echo ""
  log_test "INFO" "═══ ERROR HANDLING TESTS ═══"

  local dcvm_cmd=$(get_dcvm_cmd)

  if [ -z "$dcvm_cmd" ]; then
    log_test "SKIP" "Error handling tests" "dcvm not available"
    return
  fi

  run_test_expect_fail "Invalid command" "$dcvm_cmd invalid_nonexistent_command_xyz"

  if require_root_for_test "error handling with root"; then
    run_test_expect_fail "dcvm delete (no args)" "$dcvm_cmd delete"
    run_test_expect_fail "dcvm create '' (empty name)" "$dcvm_cmd create ''"
    run_test_output_contains "dcvm create '' (error message)" "VM name required" "$dcvm_cmd create ''"
    run_test_expect_fail "dcvm start (invalid VM)" "$dcvm_cmd start nonexistent_vm_xyz_123"
    run_test_expect_fail "dcvm stop (invalid VM)" "$dcvm_cmd stop nonexistent_vm_xyz_123"
  fi
}

test_vm_lifecycle() {
  echo ""
  log_test "INFO" "═══ VM LIFECYCLE TESTS (Full Mode) ═══"

  if [ "$FULL_MODE" != true ]; then
    log_test "SKIP" "VM lifecycle tests" "Use --full flag to enable"
    return
  fi

  if ! require_root_for_test "VM lifecycle tests"; then
    return
  fi

  local dcvm_cmd=$(get_dcvm_cmd)

  if [ -z "$dcvm_cmd" ]; then
    log_test "SKIP" "VM lifecycle tests" "dcvm not available"
    return
  fi

  local datacenter_base="${DATACENTER_BASE:-/srv/datacenter}"
  if [ ! -d "$datacenter_base/storage/templates" ]; then
    log_test "SKIP" "VM creation" "No templates available"
    return
  fi

  local template_count=$(find "$datacenter_base/storage/templates" -name "*.qcow2" -o -name "*.img" 2>/dev/null | wc -l)
  if [ "$template_count" -eq 0 ]; then
    log_test "SKIP" "VM creation" "No templates downloaded"
    return
  fi

  log_test "INFO" "Creating test VM: $TEST_VM_NAME"

  if $dcvm_cmd create "$TEST_VM_NAME" -f -p "testpass123" -m 1024 -c 1 -d 10G -o 5 2>&1; then
    log_test "PASS" "VM creation"

    sleep 5

    if virsh list --all | grep -q "$TEST_VM_NAME"; then
      log_test "PASS" "VM exists in libvirt"
    else
      log_test "FAIL" "VM exists in libvirt"
    fi

    run_test "dcvm status $TEST_VM_NAME" "$dcvm_cmd status $TEST_VM_NAME" || true
    run_test "dcvm stop $TEST_VM_NAME" "$dcvm_cmd stop $TEST_VM_NAME" || true
    sleep 3
    run_test "dcvm start $TEST_VM_NAME" "$dcvm_cmd start $TEST_VM_NAME" || true
    sleep 3
    run_test "dcvm restart $TEST_VM_NAME" "$dcvm_cmd restart $TEST_VM_NAME" || true
    sleep 3
    run_test "dcvm backup create $TEST_VM_NAME" "$dcvm_cmd backup create $TEST_VM_NAME" || true

    log_test "INFO" "Cleaning up test VM"
    $dcvm_cmd stop "$TEST_VM_NAME" 2>/dev/null || true
    sleep 2

    if $dcvm_cmd delete "$TEST_VM_NAME" 2>&1; then
      log_test "PASS" "VM deletion"
    else
      log_test "FAIL" "VM deletion"
      virsh destroy "$TEST_VM_NAME" 2>/dev/null || true
      virsh undefine "$TEST_VM_NAME" --remove-all-storage 2>/dev/null || true
    fi
  else
    log_test "FAIL" "VM creation"
  fi
}

generate_report() {
  local end_time=$(date +%s)
  local duration=$((end_time - START_TIME))

  echo ""
  echo -e "${C_INFO}TEST RESULTS SUMMARY:${C_RESET}"
  echo "Total Tests: $((PASSED + FAILED + SKIPPED))"
  echo -e "  ${C_PASS}Passed:${C_RESET}   $PASSED"
  echo -e "  ${C_FAIL}Failed:${C_RESET}   $FAILED"
  echo -e "  ${C_SKIP}Skipped:${C_RESET}  $SKIPPED"
  echo -e "  ${C_WARN}Warnings:${C_RESET} $WARNINGS"
  echo ""
  echo "Duration: ${duration}s"
  echo ""

  if [ $FAILED -gt 0 ]; then
    echo -e "${C_FAIL}FAILED TESTS:${C_RESET}"
    for result in "${TEST_RESULTS[@]}"; do
      IFS='|' read -r status name message <<<"$result"
      if [ "$status" = "FAIL" ]; then
        echo -e "  ${C_FAIL}✗${C_RESET} $name"
        [ -n "$message" ] && echo "    → $message"
      fi
    done
    echo ""
  fi

  if [ $WARNINGS -gt 0 ]; then
    echo -e "${C_WARN}WARNINGS:${C_RESET}"
    for result in "${TEST_RESULTS[@]}"; do
      IFS='|' read -r status name message <<<"$result"
      if [ "$status" = "WARN" ]; then
        echo -e "  ${C_WARN}⚠${C_RESET} $name"
        [ -n "$message" ] && echo "    → $message"
      fi
    done
    echo ""
  fi

  if [ $FAILED -eq 0 ]; then
    echo -e "${C_PASS}✓ All tests passed!${C_RESET}"
    return 0
  else
    echo -e "${C_FAIL}✗ Some tests failed. Please review the output above.${C_RESET}"
    return 1
  fi
}

main() {
  # Tests that restore or create VMs write owner records; keep them off the host's real ones.
  export DCVM_STATE_DIR
  DCVM_STATE_DIR=$(mktemp -d)
  trap 'rm -rf "$DCVM_STATE_DIR"' EXIT
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --quick)
      QUICK_MODE=true
      shift
      ;;
    --full)
      FULL_MODE=true
      shift
      ;;
    --syntax)
      SYNTAX_ONLY=true
      shift
      ;;
    --unit)
      UNIT_ONLY=true
      shift
      ;;
    --integration)
      INTEGRATION_ONLY=true
      shift
      ;;
    --verbose | -v)
      VERBOSE=true
      shift
      ;;
    --install-deps)
      INSTALL_DEPS=true
      shift
      ;;
    --help | -h)
      show_test_usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      show_test_usage
      exit 1
      ;;
    esac
  done

  echo ""
  echo -e "${C_INFO}dcvm COMPREHENSIVE TEST SUITE${C_RESET}"
  echo ""
  echo "Date: $(date)"
  echo "Mode: ${FULL_MODE:+Full }${QUICK_MODE:+Quick }${SYNTAX_ONLY:+Syntax }${UNIT_ONLY:+Unit }${INTEGRATION_ONLY:+Integration }${FULL_MODE:-${QUICK_MODE:-${SYNTAX_ONLY:-${UNIT_ONLY:-${INTEGRATION_ONLY:-Default}}}}}"
  echo "User: $(whoami)"
  [ "$EUID" -eq 0 ] && echo "Privileges: Root" || echo "Privileges: Normal user"
  echo ""

  [ -f "/etc/dcvm-install.conf" ] && source /etc/dcvm-install.conf

  [ "$INSTALL_DEPS" = true ] && install_missing_test_deps
  if [ "$SYNTAX_ONLY" = true ]; then
    test_syntax_all_scripts
    test_shellcheck
    test_grep_count_fallback
  elif [ "$UNIT_ONLY" = true ]; then
    test_common_functions
  elif [ "$INTEGRATION_ONLY" = true ]; then
    test_libvirt
    test_network_commands
    test_storage_commands
    test_vm_listing
    test_vm_lifecycle
  else
    test_syntax_all_scripts
    test_shellcheck
    test_grep_count_fallback
    test_configuration
    test_dependencies
    test_common_functions

    if [ "$QUICK_MODE" != true ]; then
      test_libvirt
      test_directory_structure
      test_cli_help
      test_vm_listing
      test_network_commands
      test_storage_commands
      test_mirror_manager_functions
      test_template_commands
      test_self_update
      test_fix_lock
      test_error_handling
    fi

    if [ "$FULL_MODE" = true ]; then
      test_vm_lifecycle
    fi
  fi

  generate_report
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
