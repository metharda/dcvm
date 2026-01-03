#!/usr/bin/env bash

# DCVM Comprehensive Test Suite
# This script tests all DCVM commands and validates functionality.
# Run with: ./test-suite.sh [options]
#
# Options:
#   --quick       Run quick tests only (no VM creation)
#   --full        Run full tests including VM creation/deletion
#   --syntax      Run syntax checks only
#   --unit        Run unit tests only (common.sh functions)
#   --integration Run integration tests only
#   --help        Show this help

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

readonly C_PASS="${GREEN}"
readonly C_FAIL="${RED}"
readonly C_SKIP="${YELLOW}"
readonly C_WARN="${YELLOW}"
readonly C_INFO="${BLUE}"
readonly C_RESET="${NC}"

show_test_usage() {
  cat <<-EOF
	DCVM Comprehensive Test Suite
	
	Usage: $0 [options]
	
	Options:
	  --quick        Run quick tests only (no VM creation, no root required)
	  --full         Run full tests including VM creation/deletion
	  --syntax       Run syntax checks only
	  --unit         Run unit tests only (common.sh functions)
	  --integration  Run integration tests only (requires root)
	  --verbose      Show detailed output
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
  local missing_pkgs=()
  local test_deps=(
    "openssl:openssl"
    "genisoimage:genisoimage"
  ) # Update this list as needed

  for dep in "${test_deps[@]}"; do
    local cmd="${dep%%:*}"
    local pkg="${dep##*:}"
    if ! command -v "$cmd" &>/dev/null; then
      missing_pkgs+=("$pkg")
    fi
  done

  if [ ${#missing_pkgs[@]} -eq 0 ]; then
    return 0
  fi

  echo -e "${C_INFO}[INFO]${C_RESET} Installing missing test dependencies: ${missing_pkgs[*]}"

  local apt_cmd=""
  if [ "$EUID" -eq 0 ]; then
    apt_cmd="apt-get"
  elif command -v sudo &>/dev/null; then
    apt_cmd="sudo apt-get"
  else
    echo -e "${C_WARN}[WARN]${C_RESET} Cannot install dependencies - not root and sudo unavailable"
    return 1
  fi

  if $apt_cmd update -qq &>/dev/null && $apt_cmd install -y -qq "${missing_pkgs[@]}" &>/dev/null; then
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
    log_test "SKIP" "Config file tests" "DCVM not installed"
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
    IFS=':' read -ra cmds <<< "$cmd_pair"
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

test_common_functions() {
  echo ""
  log_test "INFO" "═══ COMMON.SH FUNCTION TESTS ═══"

  run_test "print_info function" "print_info 'Test message' >/dev/null"
  run_test "print_success function" "print_success 'Test message' >/dev/null"
  run_test "print_warning function" "print_warning 'Test message' >/dev/null"
  run_test "print_error function" "print_error 'Test message' >/dev/null"
  run_test "validate_username (valid)" "validate_username 'testuser'"
  run_test "validate_username (with number)" "validate_username 'user123'"
  run_test "validate_username (with underscore)" "validate_username 'test_user'"
  run_test "validate_username (with hyphen)" "validate_username 'test-user'"
  run_test_expect_fail "validate_username (too short)" "validate_username 'ab'"
  run_test_expect_fail "validate_username (invalid chars)" "validate_username 'test@user'"
  run_test_expect_fail "validate_username (starts with number)" "validate_username '1user'"
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
  else
    log_test "SKIP" "validate_ip_in_subnet tests" "Function not available"
  fi

  run_test "format_bytes (1KB)" "[ \"\$(format_bytes 1024)\" = '1KB' ]"
  run_test "format_bytes (1MB)" "[ \"\$(format_bytes 1048576)\" = '1MB' ]"
  run_test "format_bytes (1GB)" "[ \"\$(format_bytes 1073741824)\" = '1GB' ]"
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

  if type generate_password_hash &>/dev/null; then
    run_test "generate_password_hash" "[[ \$(generate_password_hash 'testpass') =~ ^\\\$6\\\$ ]]"
  fi
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

  # Note: 'dcvm storage' is not tested here as it has a 30s delay
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

  if $dcvm_cmd create "$TEST_VM_NAME" -f -p "testpass123" -m 1024 -c 1 -d 10G -o 3 2>&1; then
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
  echo -e "${C_INFO}DCVM COMPREHENSIVE TEST SUITE${C_RESET}"
  echo ""
  echo "Date: $(date)"
  echo "Mode: ${FULL_MODE:+Full }${QUICK_MODE:+Quick }${SYNTAX_ONLY:+Syntax }${UNIT_ONLY:+Unit }${INTEGRATION_ONLY:+Integration }${FULL_MODE:-${QUICK_MODE:-${SYNTAX_ONLY:-${UNIT_ONLY:-${INTEGRATION_ONLY:-Default}}}}}"
  echo "User: $(whoami)"
  [ "$EUID" -eq 0 ] && echo "Privileges: Root" || echo "Privileges: Normal user"
  echo ""

  [ -f "/etc/dcvm-install.conf" ] && source /etc/dcvm-install.conf

  install_missing_test_deps
  if [ "$SYNTAX_ONLY" = true ]; then
    test_syntax_all_scripts
    test_shellcheck
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