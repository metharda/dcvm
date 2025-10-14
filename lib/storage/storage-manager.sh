#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../utils/common.sh"

load_dcvm_config

SHARED_STORAGE="$DATACENTER_BASE/nfs-share"
THRESHOLD=85
LOG_FILE="/var/log/datacenter-storage.log"

check_vm_storage() {
	local vm_name="$1"
	local ssh_port="$2"

	local usage=$(ssh -o ConnectTimeout=5 admin@$(get_host_ip) -p "$ssh_port" "df / | awk 'NR==2 {print \$5}' | sed 's/%//'" 2>/dev/null)

	if [ -z "$usage" ]; then
		log_to_file "$LOG_FILE" "Failed to check disk usage for $vm_name"
		return 1
	fi

	log_to_file "$LOG_FILE" "$vm_name disk usage: $usage%"

	if [ $usage -gt $THRESHOLD ]; then
		log_to_file "$LOG_FILE" "$vm_name exceeds threshold ($THRESHOLD%), starting cleanup"
		cleanup_old_files "$vm_name" "$ssh_port"
	fi
}

cleanup_old_files() {
	local vm_name="$1"
	local ssh_port="$2"

	ssh admin@$(get_host_ip) -p "$ssh_port" <<'EOSSH'
        mkdir -p /mnt/shared/archived-files/$(hostname)
        
        find /tmp -type f -mtime +30 -exec sh -c '
            for file do
                rel_path=${file#/}
                mkdir -p "/mnt/shared/archived-files/$(hostname)/$(dirname "$rel_path")"
                mv "$file" "/mnt/shared/archived-files/$(hostname)/$rel_path"
                ln -s "/mnt/shared/archived-files/$(hostname)/$rel_path" "$file"
            done
        ' sh {} +
        
        find /var/log -name "*.log" -mtime +7 -exec gzip {} \;
        find /var/log -name "*.gz" -mtime +30 -exec sh -c '
            for file do
                rel_path=${file#/}
                mkdir -p "/mnt/shared/archived-files/$(hostname)/$(dirname "$rel_path")"
                mv "$file" "/mnt/shared/archived-files/$(hostname)/$rel_path"
                ln -s "/mnt/shared/archived-files/$(hostname)/$rel_path" "$file"
            done
        ' sh {} +
EOSSH

	log_to_file "$LOG_FILE" "Cleanup completed for $vm_name"
}

main() {
	log_to_file "$LOG_FILE" "Starting storage management check"
	sleep 30

	local vm_list=$(virsh list --all | grep -E "(running|shut off)" | awk '{print $2}' | grep -v "^$" | while read vm; do
		is_vm_in_network "$vm" && echo "$vm"
	done)

	echo "$vm_list" | while read vm_name; do
		if [ -n "$vm_name" ]; then
			local mapping=$(read_port_mappings | grep "^$vm_name ")
			if [ -n "$mapping" ]; then
				local ssh_port=$(echo "$mapping" | awk '{print $3}')
				[ -n "$ssh_port" ] && check_vm_storage "$vm_name" "$ssh_port"
			fi
		fi
	done

	log_to_file "$LOG_FILE" "Storage management check completed"
}

main
