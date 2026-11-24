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

cleanup_old_files() {
  local vm_name="$1" target="$2" rc=0
  ssh_vm "$vm_name" "$target" 'sudo -n bash -s' <<'EOSSH' || rc=$?
        rc=0
        find /var/log -type f -name "*.log" -mtime +7 -exec gzip {} + || rc=1
        mountpoint -q /mnt/shared || exit 3
        dest="/mnt/shared/archived-files/$(hostname)"
        mkdir -p "$dest" || exit 1
        archive='dest=$1; shift; rc=0
            for file do
                rel_path=${file#/}
                mkdir -p "$dest/$(dirname "$rel_path")" && mv -f "$file" "$dest/$rel_path" && ln -sf "$dest/$rel_path" "$file" || rc=1
            done
            exit $rc'
        # -type f: the links an earlier run left behind must not be archived again.
        find /tmp -type f -mtime +30 -exec sh -c "$archive" sh "$dest" {} + || rc=1
        find /var/log -type f -name "*.gz" -mtime +30 -exec sh -c "$archive" sh "$dest" {} + || rc=1
        exit $rc
EOSSH
  case $rc in
  0) report ok "$vm_name" "old logs compressed and archived" ;;
  3) report warn "$vm_name" "old logs compressed; /mnt/shared is not mounted, nothing archived" ;;
  255) report fail "$vm_name" "cleanup failed: SSH to $target did not connect" ;;
  *) report fail "$vm_name" "cleanup failed (exit $rc): needs passwordless sudo in the VM, or a file could not be compressed or moved" ;;
  esac
}

main() {
  if [ "${2:-}" = --help ]; then
    echo "Usage: dcvm storage     Disk usage inside each running VM over SSH; over the threshold, old logs move to the NFS share (admins)"
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
  echo -e "\n  ${DIM}Over ${THRESHOLD}%, old logs are compressed and moved to the NFS share. Log: $LOG_FILE${NC}\n"
  log_to_file "$LOG_FILE" "Storage management check completed"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
