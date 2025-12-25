#!/usr/bin/env bash

# DCVM Comprehensive Test Suite
# This script tests all DCVM commands and validates functionality.
# Run with: sudo ./test-suite.sh [options]
#
# Options:
#   --quick       Run quick tests only (no VM creation)
#   --full        Run full tests including VM creation/deletion
#   --syntax      Run syntax checks only
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

readonly C_PASS="${GREEN}"
readonly C_FAIL="${RED}"
readonly C_SKIP="${YELLOW}"
readonly C_WARN="${YELLOW}"
readonly C_INFO="${BLUE}"
readonly C_RESET="${NC}"

show_test_usage() {
  cat <<-EOF
	DCVM Test Suite
	
	Usage: $0 [options]
	
	Options:
	  --quick       Run quick tests only (no VM creation)
	  --full        Run full tests including VM creation/deletion
	  --syntax      Run syntax checks only
	  --help        Show this help
	
	Examples:
	  sudo $0 --quick     # Fast validation
	  sudo $0 --full      # Complete test with VM operations
	  $0 --syntax         # Check all scripts for syntax errors
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
    [ -n "$output" ] && echo "    Output: ${output:0:200}"
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

test_syntax_all_scripts() {
  echo ""
  log_test "INFO" "SYNTAX CHECKS"

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
    "$lib_dir/installation/install-dcvm.sh"
    "$lib_dir/installation/self-update.sh"
    "$lib_dir/installation/uninstall-dcvm.sh"
  )

  for script in "${scripts[@]}"; do
    if [ -f "$script" ]; then
      local name=$(basename "$script")
      if bash -n "$script" 2>/dev/null; then
        log_test "PASS" "Syntax: $name"
      else
        log_test "FAIL" "Syntax: $name" "Syntax error detected"
      fi
    else
      log_test "SKIP" "Syntax: $(basename "$script")" "File not found"
    fi
  done
}

test_shellcheck() {
  echo ""
  log_test "INFO" "SHELLCHECK ANALYSIS"

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
  log_test "INFO" "CONFIGURATION TESTS"

  if [ -f "/etc/dcvm-install.conf" ]; then
    log_test "PASS" "Config file exists"

    if [ -r "/etc/dcvm-install.conf" ]; then
      log_test "PASS" "Config file readable"
    else
      log_test "FAIL" "Config file readable"
    fi

    source /etc/dcvm-install.conf 2>/dev/null
    [ -n "$DATACENTER_BASE" ] && log_test "PASS" "DATACENTER_BASE defined: $DATACENTER_BASE" || log_test "WARN" "DATACENTER_BASE not defined"
    [ -n "$NETWORK_NAME" ] && log_test "PASS" "NETWORK_NAME defined: $NETWORK_NAME" || log_test "WARN" "NETWORK_NAME not defined"
    [ -n "$NETWORK_SUBNET" ] && log_test "PASS" "NETWORK_SUBNET defined: $NETWORK_SUBNET" || log_test "WARN" "NETWORK_SUBNET not defined"
  else
    log_test "SKIP" "Config file tests" "DCVM not installed"
  fi
}

test_dependencies() {
  echo ""
  log_test "INFO" "DEPENDENCY TESTS"

  local required_always=(
    "openssl"
    "bc"
    "curl"
    "wget"
  )
  local required_virtualization=(
    "virsh"
    "virt-install"
    "qemu-img"
  )

  local optional_commands=(
    "mkisofs"
    "genisoimage"
    "shellcheck"
  )

  for cmd in "${required_always[@]}"; do
    if check_command_exists "$cmd"; then
      log_test "PASS" "Required: $cmd"
    else
      log_test "FAIL" "Required: $cmd" "Not found"
    fi
  done

  for cmd in "${required_virtualization[@]}"; do
    if check_command_exists "$cmd"; then
      log_test "PASS" "Required (virtualization): $cmd"
    else
      if [ "$QUICK_MODE" = true ]; then
        log_test "WARN" "Required (virtualization): $cmd" "Not found (skipped in --quick)"
      else
        log_test "FAIL" "Required (virtualization): $cmd" "Not found"
      fi
    fi
  done

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
  log_test "INFO" "LIBVIRT TESTS"

  if systemctl is-active --quiet libvirtd 2>/dev/null; then
    log_test "PASS" "libvirtd service running"
  else
    log_test "FAIL" "libvirtd service running" "Service not active"
    return
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
  else
    log_test "WARN" "Network exists: $network_name" "Not found"
  fi
}

test_cli_help() {
  echo ""
  log_test "INFO" "CLI HELP TESTS"

  local dcvm_cmd="${SCRIPT_DIR}/../../dcvm"

  if [ ! -x "$dcvm_cmd" ]; then
    if check_command_exists dcvm; then
      dcvm_cmd="dcvm"
    else
      log_test "SKIP" "CLI help tests" "dcvm command not found"
      return
    fi
  fi

  run_test "dcvm --help" "$dcvm_cmd --help"
  run_test "dcvm help" "$dcvm_cmd help"
  run_test "dcvm --version" "$dcvm_cmd --version"
  run_test "dcvm version" "$dcvm_cmd version"
  run_test "dcvm create --help" "$dcvm_cmd create --help"
  run_test "dcvm backup --help" "$dcvm_cmd backup --help"
}

test_common_functions() {
  echo ""
  log_test "INFO" "COMMON.SH FUNCTION TESTS"

  run_test "print_info function" "print_info 'Test message' >/dev/null"
  run_test "print_success function" "print_success 'Test message' >/dev/null"
  run_test "print_warning function" "print_warning 'Test message' >/dev/null"
  run_test "print_error function" "print_error 'Test message' >/dev/null"
  run_test "validate_username (valid)" "validate_username 'testuser'"
  run_test_expect_fail "validate_username (invalid short)" "validate_username 'ab'"
  run_test_expect_fail "validate_username (invalid chars)" "validate_username 'test@user'"
  run_test "validate_password (valid)" "validate_password 'password123'"
  run_test_expect_fail "validate_password (too short)" "validate_password 'abc'"

  if type validate_ip_in_subnet &>/dev/null; then
    run_test "validate_ip_in_subnet (valid)" "NETWORK_SUBNET=10.10.10 validate_ip_in_subnet '10.10.10.50'"
    run_test_expect_fail "validate_ip_in_subnet (wrong subnet)" "NETWORK_SUBNET=10.10.10 validate_ip_in_subnet '192.168.1.50'"
    run_test_expect_fail "validate_ip_in_subnet (gateway)" "NETWORK_SUBNET=10.10.10 validate_ip_in_subnet '10.10.10.1'"
  else
    log_test "SKIP" "validate_ip_in_subnet tests" "Function not available"
  fi

  run_test "format_bytes function" "[ \"\$(format_bytes 1024)\" = '1KB' ]"
  run_test "generate_random_mac function" "[[ \$(generate_random_mac) =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]"
  run_test "command_exists (bash)" "command_exists bash"
  run_test_expect_fail "command_exists (nonexistent)" "command_exists nonexistent_command_xyz"
}

test_network_commands() {
  echo ""
  log_test "INFO" "NETWORK COMMAND TESTS"

  local dcvm_cmd="${SCRIPT_DIR}/../../dcvm"
  [ ! -x "$dcvm_cmd" ] && dcvm_cmd="dcvm"

  if ! check_command_exists "$dcvm_cmd" && [ ! -x "${SCRIPT_DIR}/../../dcvm" ]; then
    log_test "SKIP" "Network command tests" "dcvm not available"
    return
  fi

  run_test "dcvm network" "$dcvm_cmd network" || true
  run_test "dcvm network show" "$dcvm_cmd network show" || true

  if require_root_for_test "dcvm network ports show"; then
    run_test "dcvm network ports show" "$dcvm_cmd network ports show" || true
  fi

  if require_root_for_test "dcvm network dhcp show"; then
    run_test "dcvm network dhcp show" "$dcvm_cmd network dhcp show" || true
  fi

  # VNC management tests
  if require_root_for_test "dcvm network vnc"; then
    local test_vm=$(virsh list --all --name | head -1)
    if [ -n "$test_vm" ]; then
      run_test "dcvm network vnc status" "$dcvm_cmd network vnc status $test_vm" || true
    else
      log_test "SKIP" "dcvm network vnc status" "No VMs available for testing"
    fi
  fi
}

test_storage_commands() {
  echo ""
  log_test "INFO" "STORAGE COMMAND TESTS"

  local dcvm_cmd="${SCRIPT_DIR}/../../dcvm"
  [ ! -x "$dcvm_cmd" ] && dcvm_cmd="dcvm"

  if ! check_command_exists "$dcvm_cmd" && [ ! -x "${SCRIPT_DIR}/../../dcvm" ]; then
    log_test "SKIP" "Storage command tests" "dcvm not available"
    return
  fi

  run_test "dcvm storage" "$dcvm_cmd storage" || true

  local backup_output
  backup_output=$($dcvm_cmd backup list 2>&1)
  local backup_exit=$?

  if [ $backup_exit -eq 0 ]; then
    log_test "PASS" "dcvm backup list"
  elif echo "$backup_output" | grep -q "No backups found"; then
    log_test "PASS" "dcvm backup list (no backups - expected)"
  else
    log_test "FAIL" "dcvm backup list" "Unexpected error"
  fi
}

test_vm_listing() {
  echo ""
  log_test "INFO" "VM LISTING TESTS"

  local dcvm_cmd="${SCRIPT_DIR}/../../dcvm"
  [ ! -x "$dcvm_cmd" ] && dcvm_cmd="dcvm"

  if ! check_command_exists "$dcvm_cmd" && [ ! -x "${SCRIPT_DIR}/../../dcvm" ]; then
    log_test "SKIP" "VM listing tests" "dcvm not available"
    return
  fi

  run_test "dcvm list" "$dcvm_cmd list" || true
  run_test "dcvm status" "$dcvm_cmd status" || true
}

test_vm_lifecycle() {
  echo ""
  log_test "INFO" "VM LIFECYCLE TESTS (Full Mode)"

  if [ "$FULL_MODE" != true ]; then
    log_test "SKIP" "VM lifecycle tests" "Use --full flag to enable"
    return
  fi

  if ! require_root_for_test "VM lifecycle tests"; then
    return
  fi

  local dcvm_cmd="${SCRIPT_DIR}/../../dcvm"
  [ ! -x "$dcvm_cmd" ] && dcvm_cmd="dcvm"

  local datacenter_base="${DATACENTER_BASE:-/srv/datacenter}"
  if [ ! -d "$datacenter_base/storage/templates" ]; then
    log_test "SKIP" "VM creation" "No templates available"
    return
  fi

  log_test "INFO" "Creating test VM: $TEST_VM_NAME"

  if $dcvm_cmd create "$TEST_VM_NAME" -f -p "testpass123" -m 1024 -c 1 -d 5G -o 3 2>&1; then
    log_test "PASS" "VM creation"

    sleep 5

    if virsh list --all | grep -q "$TEST_VM_NAME"; then
      log_test "PASS" "VM exists in libvirt"
    else
      log_test "FAIL" "VM exists in libvirt"
    fi

    run_test "dcvm status $TEST_VM_NAME" "$dcvm_cmd status $TEST_VM_NAME" || true
    run_test "dcvm stop $TEST_VM_NAME" "$dcvm_cmd stop $TEST_VM_NAME" || true
    sleep 2

    run_test "dcvm start $TEST_VM_NAME" "$dcvm_cmd start $TEST_VM_NAME" || true
    sleep 2

    run_test "dcvm backup create $TEST_VM_NAME" "$dcvm_cmd backup create $TEST_VM_NAME" || true

    log_test "INFO" "Cleaning up test VM"
    if $dcvm_cmd delete "$TEST_VM_NAME" -f 2>&1; then
      log_test "PASS" "VM deletion"
    else
      log_test "FAIL" "VM deletion"
    fi
  else
    log_test "FAIL" "VM creation"
  fi
}

test_directory_structure() {
  echo ""
  log_test "INFO" "DIRECTORY STRUCTURE TESTS"

  local datacenter_base="${DATACENTER_BASE:-/srv/datacenter}"

  local dirs=(
    "$datacenter_base"
    "$datacenter_base/vms"
    "$datacenter_base/storage"
    "$datacenter_base/storage/templates"
    "$datacenter_base/backups"
  )

  for dir in "${dirs[@]}"; do
    if [ -d "$dir" ]; then
      log_test "PASS" "Directory exists: $dir"
    else
      log_test "WARN" "Directory exists: $dir" "Not found"
    fi
  done
}

test_self_update() {
  echo ""
  log_test "INFO" "SELF-UPDATE TESTS"

  local dcvm_cmd="${SCRIPT_DIR}/../../dcvm"
  [ ! -x "$dcvm_cmd" ] && dcvm_cmd="dcvm"

  if ! check_command_exists "$dcvm_cmd" && [ ! -x "${SCRIPT_DIR}/../../dcvm" ]; then
    log_test "SKIP" "Self-update tests" "dcvm not available"
    return
  fi

  run_test "dcvm self-update --check" "$dcvm_cmd self-update --check" || true
}

generate_report() {
  local end_time=$(date +%s)
  local duration=$((end_time - START_TIME))

  echo ""
  log_test "INFO" "TEST RESULTS SUMMARY"
  echo ""
  echo "Total Tests: $((PASSED + FAILED + SKIPPED))"
  echo -e "  ${C_PASS}Passed:${C_RESET}  $PASSED"
  echo -e "  ${C_FAIL}Failed:${C_RESET}  $FAILED"
  echo -e "  ${C_SKIP}Skipped:${C_RESET} $SKIPPED"
  echo -e "  ${C_WARN}Warnings:${C_RESET} $WARNINGS"
  echo ""
  echo "Duration: ${duration}s"
  echo ""

  if [ $FAILED -gt 0 ]; then
    echo -e "${C_FAIL}=============================================="
    echo "  FAILED TESTS"
    echo -e "==============================================${C_RESET}"
    echo ""
    for result in "${TEST_RESULTS[@]}"; do
      IFS='|' read -r status name message <<<"$result"
      if [ "$status" = "FAIL" ]; then
        echo -e "  ${C_FAIL}✗${C_RESET} $name"
        [ -n "$message" ] && echo "    → $message"
      fi
    done
    echo ""
  fi

  if [ $FAILED -eq 0 ]; then
    echo -e "${C_PASS}All tests passed!${C_RESET}"
    return 0
  else
    echo -e "${C_FAIL}Some tests failed. Please review the output above.${C_RESET}"
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
  log_test "INFO" "DCVM COMPREHENSIVE TEST SUITE"
  echo ""
  echo "Date: $(date)"
  echo "Mode: ${FULL_MODE:+Full }${QUICK_MODE:+Quick }${SYNTAX_ONLY:+Syntax Only}${FULL_MODE:-${QUICK_MODE:-${SYNTAX_ONLY:-Default}}}"
  echo "User: $(whoami)"
  [ "$EUID" -eq 0 ] && echo "Privileges: Root" || echo "Privileges: Normal user"
  echo ""

  [ -f "/etc/dcvm-install.conf" ] && source /etc/dcvm-install.conf

  if [ "$SYNTAX_ONLY" = true ]; then
    test_syntax_all_scripts
    test_shellcheck
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
      test_self_update
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
