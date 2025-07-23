#!/bin/bash

SHARED_STORAGE="/srv/datacenter/nfs-share"
THRESHOLD=85
LOG_FILE="/var/log/datacenter-storage.log"

log_message() {
	echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >>$LOG_FILE
}

check_vm_storage() {
	local vm_name=$1
	local ssh_port=$2

	usage=$(ssh -o ConnectTimeout=5 admin@10.8.8.223 -p $ssh_port "df / | awk 'NR==2 {print \$5}' | sed 's/%//'" 2>/dev/null)

	if [ -z "$usage" ]; then
		log_message "Failed to check disk usage for $vm_name"
		return 1
	fi

	log_message "$vm_name disk usage: $usage%"

	if [ $usage -gt $THRESHOLD ]; then
		log_message "$vm_name exceeds threshold ($THRESHOLD%), starting cleanup"
		cleanup_old_files $vm_name $ssh_port
	fi
}

cleanup_old_files() {
	local vm_name=$1
	local ssh_port=$2

	ssh admin@10.8.8.223 -p $ssh_port <<'EOSSH'
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

	log_message "Cleanup completed for $vm_name"
}

main() {
	log_message "Starting storage management check"
	sleep 30

	VM1_IP=$(virsh domifaddr datacenter-vm1 --source lease | grep -oE "10\.10\.10\.[0-9]+" | head -1)
	VM2_IP=$(virsh domifaddr datacenter-vm2 --source lease | grep -oE "10\.10\.10\.[0-9]+" | head -1)

	if [ -z "$VM1_IP" ]; then
		VM1_IP=$(virsh net-dhcp-leases datacenter-net | grep datacenter-vm1 | grep -oE "10\.10\.10\.[0-9]+" | head -1)
	fi
	if [ -z "$VM2_IP" ]; then
		VM2_IP=$(virsh net-dhcp-leases datacenter-net | grep datacenter-vm2 | grep -oE "10\.10\.10\.[0-9]+" | head -1)
	fi

	if [ -n "$VM1_IP" ]; then
		check_vm_storage "datacenter-vm1" 2221
	fi

	if [ -n "$VM2_IP" ]; then
		check_vm_storage "datacenter-vm2" 2222
	fi

	log_message "Storage management check completed"
}

main
