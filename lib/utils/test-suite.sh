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
    esac
    return 0
  }
  # shellcheck disable=SC2317
  qemu-img() { echo "qemu-img $*" >>"$t/calls"; }
  # shellcheck disable=SC2317
  check_disk_image() { :; }
  # shellcheck disable=SC2317
  virt-customize() { echo "virt-customize $*" >>"$t/calls"; }
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
    ! grep -qE 'virsh autostart vm1-static$' "$t/calls"; then
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

  if ! run running 'DCVM_QUOTA_LEFT="1 1024 20"' && untouched && grep -q 'Over your quota' "$t/out"; then
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
    grep -qxF "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$esc';" <<<"$sql" || ok=false
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
  if command -v openssl >/dev/null 2>&1 &&
    [ "$(printf '%s\n' -neE | openssl passwd -6 -salt "$(cut -d'$' -f3 <<<"$h")" -stdin)" = "$h" ]; then
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
      grep -qx "  - $svc < /root/dcvm-mysql-init.sql || true; rm -f /root/dcvm-mysql-init.sql" "$f" || ok=false
      grep -q "^CREATE USER 'tester'@'localhost'" <<<"$sql" || ok=false
      auth="IDENTIFIED VIA unix_socket OR mysql_native_password USING PASSWORD('pw1234')"
      [ "$svc" = mysql ] && auth="IDENTIFIED WITH mysql_native_password BY 'pw1234'"
      grep -qxF "ALTER USER 'root'@'localhost' $auth;" <<<"$sql" || ok=false
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

  if ! command -v script >/dev/null 2>&1; then
    log_test "SKIP" "dhcp clear --all writes [] to the status file (#37)" "script not available"
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
restart_network() { echo restart >>"$t/calls"; }
DNSMASQ_DIR="$t" BRIDGE_NAME=br NETWORK_NAME=net
main clear --all
EOF
  printf 'y\n' | script -qec "bash $t/run.sh" /dev/null >/dev/null 2>&1
  after=$(stat -c '%i %a' "$t/br.status")
  if [ "$(od -An -c "$t/br.status" | tr -s ' ')" = " [ ] \n" ] && [ "$before" = "$after" ] &&
    grep -qx restart "$t/calls" 2>/dev/null; then
    log_test "PASS" "dhcp clear --all writes [] to the status file, same inode and mode, then restarts (#37)"
  else
    log_test "FAIL" "dhcp clear --all writes [] to the status file, same inode and mode, then restarts (#37)" "$(od -An -c "$t/br.status" | head -2 | tr '\n' ' '); $before -> $after"
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
    eval "$extra"
    cleanup_dhcp_lease "$@"
  ) </dev/null 2>&1
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

installer_packages() {
  local line
  line=$(grep -m1 "^  local $1_packages=(" "$SCRIPT_DIR/../installation/install-dcvm.sh") || return 1
  eval "${line#  local }"
  local -n list="$1_packages"
  printf '%s\n' "${list[@]}"
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
    get_mirrors() { :; }
    verify_published_checksum x "file://$t/m3/img.qcow2" "$t/m3/img.qcow2" 2>/dev/null
    echo "none=$?"
    check_download x "file://$t/m3/img.qcow2" "$t/m3/img.qcow2" "" 2>/dev/null
    echo "none_check=$?"
    (cd "$t/m3" && sha512sum img.qcow2 | sed 's/  / */' >SHA512SUMS)
    verify_published_checksum x "file://$t/m3/img.qcow2" "$t/m3/img.qcow2" 2>/dev/null
    echo "sha512=$?"
  ) >"$t/out"
  for rc in same=0 other=0 tampered=1 tampered_check=1 none=2 none_check=0 sha512=0; do
    if grep -qx "$rc" "$t/out"; then
      log_test "PASS" "published checksum ($rc)"
    else
      log_test "FAIL" "published checksum ($rc)" "$(tr '\n' ' ' <"$t/out")"
    fi
  done
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
    grep -q '"DCVM_QUOTA_LEFT": "8 16384 200"' <<<"$out" && r+="create "
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
  grep -q '"argv": \["backup", "delete", "web-01.01.2026-1"\]' <<<"$(ask backup delete web 01.01.2026-1)" &&
    grep -q '"argv": \["backup", "delete", "web-01.01.2026-12:00:00"\]' <<<"$(ask backup delete web 20260101_120000)" &&
    grep -q '"argv": \["backup", "delete", "web-01.01.2026"\]' <<<"$(ask backup delete web-01.01.2026)" && r+="backup-delete "
  out=$(ask backup restore web web-01.01.2026-1)
  grep -q '"argv": \["backup", "restore", "web", "01.01.2026-1"\]' <<<"$out" && r+="restore-id "
  grep -q '"DCVM_QUOTA_LEFT": "8 16384 200"' <<<"$out" && r+="restore-quota "
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
  grep -q '"decision": "deny"' "$t/state/audit.log" && r+="audit "
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
s.run_module, s.vm_exists = fake_run, lambda vm: vm in defined
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
if c.talk(b'{"v": 1}', c.Files()) == 130:
    print("client-int")
class Refused(socket.socket):
    def connect(self, _addr):
        raise PermissionError
c.socket.socket = Refused
try:
    c.talk(b"{}", c.Files())
except SystemExit as e:
    if e.code == 77:
        print("client-group")
PY
  )
  for w in create-release signal-rc client-int client-group; do grep -qx "$w" <<<"$out" && r+="$w "; done
  echo "$out" >>"$t/answers"
  local want="list create reserved graphics os-path foreign own yes-needed delete origin backup-prefix backup-delete restore-id restore-quota export-full export-fd secret-forms arg-order help-deny admin-only iso-fd quota iso-unreadable audit no-group admin admin-key admin-leftover create-release signal-rc client-int client-group "
  if [ "$r" = "$want" ]; then
    log_test "PASS" "socket server: roles, ownership, quotas, secrets, files and --yes enforced"
  else
    log_test "FAIL" "socket server: roles, ownership, quotas, secrets, files and --yes enforced" "missing: $(comm -13 <(tr ' ' '\n' <<<"$r" | sort) <(tr ' ' '\n' <<<"$want" | sort) | tr '\n' ' ') | $(tr '\n' ' ' <"$t/answers" | cut -c1-600)"
  fi
  rm -rf "$t"
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
  if [ "$out" = "$(printf -- '-t nat -D PREROUTING 2\n-D FORWARD 2')" ]; then
    log_test "PASS" "deleting a VM removes only its own forwards, not those of .20 or .200"
  else
    log_test "FAIL" "deleting a VM removes only its own forwards, not those of .20 or .200" "$(tr '\n' '|' <<<"$out")"
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
  grep -q -- '--disk path=/i,device=cdrom,readonly=on' <<<"$opts" && grep -q -- '--boot hd,cdrom' <<<"$opts" && grep -q -- '--import' <<<"$opts" &&
    ! grep -q -- '--cdrom' <<<"$opts" && r+="boot "
  opts=$(iso eval 'VM_NAME=vm DISK_PATH=/d INSTALL_ISO=/i NETWORK_NAME=n MEMORY=512 CPUS=1 DISK_SIZE=2G UEFI=true OS_VARIANT=win10 build_virt_install_opts && echo "${VIRT_INSTALL_OPTS[*]}"')
  grep -q -- '--boot uefi,hd,cdrom' <<<"$opts" && grep -q -- '--disk path=/d,format=qcow2 ' <<<"$opts" && grep -q -- '--network network=n ' <<<"$opts" && r+="uefi-win "
  grep -q 'needs a value' <<<"$(timeout 5 bash -c 'source "$1/../core/custom-iso.sh" >/dev/null 2>&1; parse_args web --iso' _ "$SCRIPT_DIR" 2>&1)" && r+="no-loop "
  grep -q 'Unknown option' <<<"$(iso parse_args web --bogus)" && r+="unknown "
  [ "$(PATH="$t/bin:$PATH" get_vm_disk_path vm)" = /srv/vm/vm-disk.qcow2 ] && r+="disk-not-iso "
  if [ "$r" = "boot uefi-win no-loop unknown disk-not-iso " ]; then
    log_test "PASS" "ISO VMs boot disk then ISO in one definition; UEFI, Windows devices, option errors"
  else
    log_test "FAIL" "ISO VMs boot disk then ISO in one definition; UEFI, Windows devices, option errors" "$r | $(tr '\n' ' ' <<<"$opts" | cut -c1-300)"
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
      eval "$(sed -n '/^stage_files()/,/^}/p; /^new_stage()/,/^}/p; /^prune_update_backups()/,/^}/p; /^do_update()/,/^}/p' "$SCRIPT_DIR/../installation/self-update.sh")"
      INSTALL_BIN="$t/bin" INSTALL_LIB="$t/lib" BACKUP_DIR="$t/backups" KEEP_UPDATE_BACKUPS=3
      get_current_version() { echo 0.9.7; }
      get_remote_version() { echo 0.9.8; }
      create_backup_dir() { :; }
      dcvm_tree_permissions() { :; }
      list_repo_files() { printf 'dcvm\nlib/core/x.sh\nlib/core/new.py\n'; }
      fetch_repo_file() { [ "$1" != "${FAIL_ON:-}" ] && mkdir -p "${2%/*}" && echo "new $1" >"$2"; }
      do_update false
    ) >/dev/null 2>&1
  }
  FAIL_ON=lib/core/new.py update
  local failed_kept_old=false
  [ "$(cat "$t/lib/core/x.sh")" = old ] && [ -f "$t/lib/core/stale.sh" ] && failed_kept_old=true
  FAIL_ON="" update
  local kept newest
  kept=$(find "$t/backups" -maxdepth 1 -name 'dcvm-backup-*' | wc -l)
  newest=$(find "$t/backups" -maxdepth 1 -name 'dcvm-backup-*' | sort -r | head -1)
  if $failed_kept_old && [ "$(cat "$t/lib/core/x.sh")" = "new lib/core/x.sh" ] && [ -f "$t/lib/core/new.py" ] &&
    [ ! -e "$t/lib/core/stale.sh" ] && [ "$kept" -eq 3 ] && grep -q 'Version: 0.9.7' "$newest/dcvm" 2>/dev/null &&
    [ "$(cat "$newest/lib/core/x.sh" 2>/dev/null)" = old ] && [ -z "$(find "$t" -maxdepth 1 -name '.dcvm-stage.*')" ]; then
    log_test "PASS" "self-update swaps the whole tree only when every file arrived, keeps 3 saved versions"
  else
    log_test "FAIL" "self-update swaps the whole tree only when every file arrived, keeps 3 saved versions" "failed run kept old: $failed_kept_old; kept $kept; x.sh: $(cat "$t/lib/core/x.sh")"
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
    printf '%s' "$(get_vm_ip web)"
  )
  if [ "$out" = "N/A N/A 10.10.10.50" ]; then
    log_test "PASS" "VM addresses: host-side lease first, guest agent cannot claim the gateway or inject text"
  else
    log_test "FAIL" "VM addresses: host-side lease first, guest agent cannot claim the gateway or inject text" "$out"
  fi
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
  <os><type arch='x86_64' machine='pc-q35-8.2'>hvm</type><kernel>/etc/shadow</kernel><loader>/etc/passwd</loader><nvram>/var/lib/libvirt/qemu/nvram/old.fd</nvram></os>
  <devices>
    <emulator>/tmp/evil</emulator>
    <disk type='block' device='disk'><driver name='qemu' type='raw'/><source dev='/dev/sda'/><target dev='vda' bus='virtio'/></disk>
    <disk type='file' device='disk'><source file='/srv/datacenter/vms/bob/bob.qcow2'/><target dev='vdb' bus='virtio'/></disk>
    <disk type='file' device='cdrom'><source file='/etc/shadow'/><target dev='sda' bus='sata'/></disk>
    <hostdev mode='subsystem' type='pci'/><filesystem type='mount'><source dir='/'/><target dir='r'/></filesystem>
    <interface type='ethernet'><script path='/tmp/x'/></interface>
    <interface type='network'><mac address='52:54:00:11:22:33'/><source network='datacenter-net'/></interface>
    <serial type='file'><source path='/etc/cron.d/x'/></serial><serial type='pty'/>
    <channel type='unix'><source mode='bind' path='/etc/x'/><target type='virtio' name='org.qemu.guest_agent.0'/></channel>
    <graphics type='vnc' listen='0.0.0.0'><listen type='address' address='0.0.0.0'/></graphics>
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
  leaked=$(grep -oE '/etc/[a-z.]+|/dev/sda|/tmp/[a-z]+|commandline|hostdev|filesystem|seclabel|memoryBacking|emulator|ethernet|0\.0\.0\.0|type="ide"|<uuid|<metadata|bob\.qcow2|52:54:00:11:22:33|pc-q35' <<<"$out" | sort -u | tr '\n' ' ')
  if [ -z "$leaked" ] && grep -q '<name>new</name>' <<<"$out" && [ "$(grep -o '<disk ' <<<"$out" | wc -l)" -eq 1 ] &&
    grep -q 'file="/srv/datacenter/vms/new/new-disk.qcow2"' <<<"$out" && grep -q 'type="pty"' <<<"$out" &&
    grep -q 'machine="q35"' <<<"$out" && grep -q 'guest_agent' <<<"$out" && grep -q 'type="usb"' <<<"$out"; then
    log_test "PASS" "domain XML sanitizer keeps one dcvm disk and drops every host path, device and override"
  else
    log_test "FAIL" "domain XML sanitizer keeps one dcvm disk and drops every host path, device and override" "leaked: $leaked"
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
  if [ "$r" = "plain:ok datafile:refused extent:refused json:refused " ]; then
    log_test "PASS" "backup disks: external data files, VMDK extents and json: backing refused"
  else
    log_test "FAIL" "backup disks: external data files, VMDK extents and json: backing refused" "$r"
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
  local pf_rules="iptables() { case \"\$*\" in '-t nat -C PREROUTING -p tcp --dport 2221 -j DNAT --to-destination 10.10.10.50:22' | '-C FORWARD -p tcp -d 10.10.10.50 --dport 22 -j ACCEPT') return 0 ;; esac; return 1; }"
  run_test "check_port_forward (DNAT + FORWARD rules, VM port open)" "($pf_rules; check_port_connectivity() { [ \"\$1:\$2\" = '10.10.10.50:22' ]; }; check_port_forward 2221 10.10.10.50 22)"
  run_test_expect_fail "check_port_forward (no DNAT rule)" "(iptables() { case \"\$*\" in '-t nat'*) return 1 ;; esac; return 0; }; check_port_connectivity() { return 0; }; check_port_forward 2221 10.10.10.50 22)"
  run_test_expect_fail "check_port_forward (no FORWARD rule)" "(iptables() { case \"\$*\" in '-C FORWARD'*) return 1 ;; esac; return 0; }; check_port_connectivity() { return 0; }; check_port_forward 2221 10.10.10.50 22)"
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
  test_backup_ssh_setup_ip_wait
  test_create_extra_packages_userdata
  test_root_username_userdata
  test_root_username_setup
  test_root_mysql_userdata
  test_cloud_init_quoting
  test_create_cancel_and_failure_cleanup
  test_userdata_passwords
  test_userdata_per_os
  test_dhcp_clear_exact
  test_cleanup_dhcp_lease_failures
  test_cleanup_dhcp_lease_parallel
  test_dhcp_cleanup_nits
  test_get_vm_ip_subnet_dots
  test_apache_exact_match
  test_dhcp_release
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
  test_sanitize_domain_xml
  test_check_disk_image
  test_import_rejects_hostile_archives
  test_socket_policy
  test_registry_visibility
  test_list_owner_column
  test_help_never_acts
  test_forward_cleanup_exact_ip
  test_backup_exact_id_visibility
  test_iso_create_options
  test_base_builds
  test_doctor_report
  test_backup_list_columns
  test_delete_without_iptables_dir
  test_self_update_keeps_backup
  test_aria2c_download
  test_published_checksum
  test_disable_root_and_nfs_subnet
  test_installer_starts_dcvm_vms_only
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

  install_missing_test_deps
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
