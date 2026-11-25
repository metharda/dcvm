#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../utils/common.sh"

THRESHOLD=85
LOG_FILE="/var/log/datacenter-storage.log"

report() {
  log_to_file "$LOG_FILE" "$2: $3"
  ui_step "$1" "$2" "$3"
}

# SSH straight to the VM on the dcvm network with the host's key. BatchMode:
# the hourly timer has no terminal, so never wait for a password. The host key
# is pinned per VM, as dcvm ssh does, not per address: addresses are reused.
ssh_vm() {
  local vm_name="$1" target="$2"
  shift 2
  # A guest that stalls must not hold up the hourly check of every other VM: keepalives drop a dead link, timeout a hung command.
  timeout 600 ssh -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=15 -o ServerAliveCountMax=2 -o StrictHostKeyChecking=accept-new \
    -o "HostKeyAlias=dcvm-$vm_name-$(registry_get "$vm_name" created | grep . || echo 0)" \
    -o 'UserKnownHostsFile=~/.ssh/dcvm_known_hosts' \
    "$target" "$@"
}

check_vm_storage() {
  local vm_name="$1" ip login usage
  # Root's key is only in VMs root created.
  if [ "$(vm_owner_uid "$vm_name")" != 0 ]; then
    report skip "$vm_name" "owned by $(registry_get "$vm_name" owner | grep . || echo a user), skipped"
    return 0
  fi
  login=$(vm_login "$vm_name")
  if [ -z "$login" ]; then
    report skip "$vm_name" "login user unknown (installed from an ISO), skipped"
    return 0
  fi
  if ! ip=$(get_vm_ip_trusted "$vm_name"); then
    report skip "$vm_name" "no IP address yet, skipped"
    return 1
  fi
  # -P keeps a long device name from wrapping the line.
  usage=$(ssh_vm "$vm_name" "$login@$ip" "df -P / | awk 'NR==2 {print \$5}' | tr -d %" 2>/dev/null)
  if [[ ! "$usage" =~ ^[0-9]+$ ]]; then
    report fail "$vm_name" "could not check disk usage over SSH ($login@$ip)"
    return 1
  fi
  if [ "$usage" -gt "$THRESHOLD" ]; then
    report warn "$vm_name" "root file system ${usage}% used, over ${THRESHOLD}%: archiving old files"
    cleanup_old_files "$vm_name" "$login@$ip"
  else
    report ok "$vm_name" "root file system ${usage}% used"
  fi
}

# Old files are pulled into a root-only folder on the host: on the NFS share every VM could read them and plant links in their path.
cleanup_old_files() {
  local vm_name="$1" target="$2" rc=0 dir file names n
  dir="$DATACENTER_BASE/archived-files/$vm_name"
  file="$dir/$(date +%Y%m%d_%H%M%S).tar.gz"
  if ! mkdir -p -m 700 "$DATACENTER_BASE/archived-files" "$dir"; then
    report fail "$vm_name" "cleanup failed: cannot create $dir"
    return 1
  fi
  # The files are removed only after the host holds a readable archive of them.
  ssh_vm "$vm_name" "$target" 'sudo -n bash -s' >"$file.part" <<'EOSSH' || rc=$?
        rc=0
        find /var/log -xdev -type f -name "*.log" -mtime +7 -exec gzip {} + || rc=3
        cd / && find tmp var/log -xdev -type f \( -path "tmp/*" -o -name "*.gz" \) -mtime +30 -print0 >/run/dcvm-archive.list &&
          tar --null --no-recursion -T /run/dcvm-archive.list -czf - || exit 1
        exit $rc
EOSSH
  if [ "$rc" = 255 ]; then
    report fail "$vm_name" "cleanup failed: SSH to $target did not connect"
  elif { [ "$rc" != 0 ] && [ "$rc" != 3 ]; } || ! names=$(tar -tzf "$file.part" 2>/dev/null); then
    report fail "$vm_name" "cleanup failed (exit $rc): needs passwordless sudo in the VM, or the old files could not be archived"
  else
    n=$(grep -c . <<<"$names" || true)
    if [ "$n" -gt 0 ] && { ! mv -f "$file.part" "$file" ||
      ! ssh_vm "$vm_name" "$target" 'sudo -n sh -c "cd / && xargs -0 rm -f -- </run/dcvm-archive.list && rm -f /run/dcvm-archive.list"' </dev/null; }; then
      report fail "$vm_name" "$n old files archived to $file, but not removed from the VM"
    elif [ "$rc" = 3 ]; then
      report warn "$vm_name" "some logs could not be compressed; $n old files archived to $dir"
    else
      report ok "$vm_name" "old logs compressed; $n old files archived to $dir"
    fi
  fi
  rm -f "$file.part"
}

main() {
  if [ "${2:-}" = --help ]; then
    echo "Usage: dcvm storage     Disk usage inside each running VM over SSH; over the threshold, old logs move to a root-only folder on the host (admins)"
    exit 0
  fi
  load_dcvm_config
  log_to_file "$LOG_FILE" "Starting storage management check"
  ui_title "Disk usage" "root file system of each running VM, over SSH"
  local vm_name checked=0
  # ssh reads stdin, so the VM list comes in on fd 3.
  while read -r vm_name <&3; do
    [ -n "$vm_name" ] && is_vm_in_network "$vm_name" || continue
    check_vm_storage "$vm_name"
    checked=$((checked + 1))
  done 3< <(virsh list --name 2>/dev/null)
  [ "$checked" -gt 0 ] || echo -e "  ${DIM}No running dcvm VMs to check${NC}"
  echo -e "\n  ${DIM}Over ${THRESHOLD}%, old logs are compressed and moved to $DATACENTER_BASE/archived-files. Log: $LOG_FILE${NC}\n"
  log_to_file "$LOG_FILE" "Storage management check completed"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
