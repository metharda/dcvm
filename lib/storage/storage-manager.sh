#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../utils/common.sh"

THRESHOLD=85
LOG_FILE="/var/log/datacenter-storage.log"

report() {
  log_to_file "$LOG_FILE" "$1"
  echo "$1"
}

# SSH straight to the VM on the dcvm network with the host's key. BatchMode:
# the hourly timer has no terminal, so never wait for a password.
ssh_vm() {
  local vm_name="$1" ip="$2"
  shift 2
  ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
    "$(get_vm_username "$vm_name")@$ip" "$@"
}

check_vm_storage() {
  local vm_name="$1" ip usage
  if ! ip=$(get_vm_ip "$vm_name"); then
    report "$vm_name: no IP address, skipped"
    return 1
  fi
  usage=$(ssh_vm "$vm_name" "$ip" "df / | awk 'NR==2 {print \$5}' | tr -d %" 2>/dev/null)
  if [[ ! "$usage" =~ ^[0-9]+$ ]]; then
    report "$vm_name: could not check disk usage over SSH ($ip)"
    return 1
  fi
  report "$vm_name: root file system ${usage}% used"
  if [ "$usage" -gt "$THRESHOLD" ]; then
    report "$vm_name: over ${THRESHOLD}%, archiving old files"
    cleanup_old_files "$vm_name" "$ip"
  fi
}

# Inside the guest, as root: gzip logs older than 7 days, and move /tmp files
# older than 30 days and compressed logs older than 30 days to the NFS share
# (leaving symlinks). Without the share mounted, only the gzip step runs.
cleanup_old_files() {
  local vm_name="$1" ip="$2"
  ssh_vm "$vm_name" "$ip" 'sudo -n bash -s' <<'EOSSH'
        find /var/log -name "*.log" -mtime +7 -exec gzip {} \;
        mountpoint -q /mnt/shared || exit 0
        mkdir -p /mnt/shared/archived-files/$(hostname)
        find /tmp -type f -mtime +30 -exec sh -c '
            for file do
                rel_path=${file#/}
                mkdir -p "/mnt/shared/archived-files/$(hostname)/$(dirname "$rel_path")"
                mv "$file" "/mnt/shared/archived-files/$(hostname)/$rel_path"
                ln -s "/mnt/shared/archived-files/$(hostname)/$rel_path" "$file"
            done
        ' sh {} +
        find /var/log -name "*.gz" -mtime +30 -exec sh -c '
            for file do
                rel_path=${file#/}
                mkdir -p "/mnt/shared/archived-files/$(hostname)/$(dirname "$rel_path")"
                mv "$file" "/mnt/shared/archived-files/$(hostname)/$rel_path"
                ln -s "/mnt/shared/archived-files/$(hostname)/$rel_path" "$file"
            done
        ' sh {} +
EOSSH
  report "$vm_name: cleanup finished"
}

main() {
  load_dcvm_config
  log_to_file "$LOG_FILE" "Starting storage management check"
  local vm_name checked=0
  while read -r vm_name; do
    [ -n "$vm_name" ] && is_vm_in_network "$vm_name" || continue
    check_vm_storage "$vm_name"
    checked=$((checked + 1))
  done < <(virsh list --name 2>/dev/null)
  [ "$checked" -gt 0 ] || report "No running dcvm VMs to check"
  log_to_file "$LOG_FILE" "Storage management check completed"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
