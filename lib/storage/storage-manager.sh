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
    report skip "$vm_name" "no IP address yet, skipped"
    return 1
  fi
  usage=$(ssh_vm "$vm_name" "$ip" "df / | awk 'NR==2 {print \$5}' | tr -d %" 2>/dev/null)
  if [[ ! "$usage" =~ ^[0-9]+$ ]]; then
    report fail "$vm_name" "could not check disk usage over SSH ($ip)"
    return 1
  fi
  if [ "$usage" -gt "$THRESHOLD" ]; then
    report warn "$vm_name" "root file system ${usage}% used, over ${THRESHOLD}%: archiving old files"
    cleanup_old_files "$vm_name" "$ip"
  else
    report ok "$vm_name" "root file system ${usage}% used"
  fi
}

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
  report ok "$vm_name" "old logs compressed and archived"
}

main() {
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
