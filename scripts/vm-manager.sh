#!/bin/bash
CONFIG_FILE="/etc/dcvm-install.conf"
if [[ -f "$CONFIG_FILE" ]]; then
	source "$CONFIG_FILE"
else
	DATACENTER_BASE="/srv/datacenter"
	NETWORK_NAME="datacenter-net"
	BRIDGE_NAME="virbr-dc"
fi
SCRIPTS_PATH="$DATACENTER_BASE/scripts"

show_port_status() {
	echo "=== Datacenter VM Port Status ==="
	echo ""

	if [ -f $DATACENTER_BASE/port-mappings.txt ]; then
		echo "Current port mappings:"
		printf "%-15s  %-15s %-8s  %-8s\n" "VM_NAME" "VM_IP" "SSH_PORT" "HTTP_PORT"
		echo "------------------------------------------------"
		grep -v "^#" $DATACENTER_BASE/port-mappings.txt | grep -v "^$" | while read vm ip ssh_port http_port; do
			if [ -n "$vm" ]; then
				printf "%-15s  %-15s %-8s  %-8s\n" "$vm" "$ip" "$ssh_port" "$http_port"
			fi
		done
		echo ""
	else
		echo "No port mappings file found ($DATACENTER_BASE/port-mappings.txt)"
		echo "Run: $0 setup-forwarding"
		echo ""
	fi

	echo "VM Status:"
	printf "%-15s: %s\n" "VM_NAME" "STATE"
	echo "-------------------------"
	virsh list --all | grep -E "(running|shut off)" | while read line; do
		vm=$(echo "$line" | awk '{print $2}')
		state=$(echo "$line" | awk '{print $3" "$4}' | sed 's/ *$//')
		if [ -n "$vm" ] && [ "$vm" != "Name" ]; then
			if virsh domiflist "$vm" 2>/dev/null | grep -q "$NETWORK_NAME"; then
				printf "%-15s: %s\n" "$vm" "$state"
			fi
		fi
	done
	echo ""

	echo "Active port forwarding rules:"
	nat_rules=$(iptables -t nat -L PREROUTING -n --line-numbers | grep -E "(222[0-9]|808[0-9])")
	if [ -n "$nat_rules" ]; then
		echo "$nat_rules" | while read line; do
			echo "  $line"
		done
	else
		echo "  No datacenter port forwarding rules found"
	fi
	echo ""

	echo "Connectivity test:"
	printf "%-15s: %-4s  %-4s  %-4s\n" "VM_NAME" "Ping" "SSH" "HTTP"
	echo "-------------------------------------"
	if [ -f $DATACENTER_BASE/port-mappings.txt ]; then
		grep -v "^#" $DATACENTER_BASE/port-mappings.txt | grep -v "^$" | while read vm ip ssh_port http_port; do
			if [ -n "$vm" ]; then
				if ping -c 1 -W 2 "$ip" >/dev/null 2>&1; then
					ping_status="✓"
				else
					ping_status="✗"
				fi

				if timeout 3 bash -c "</dev/tcp/127.0.0.1/$ssh_port" 2>/dev/null; then
					ssh_status="✓"
				else
					ssh_status="✗"
				fi

				if timeout 3 bash -c "</dev/tcp/127.0.0.1/$http_port" 2>/dev/null; then
					http_status="✓"
				else
					http_status="✗"
				fi

				printf "%-15s: %-4s  %-4s  %-4s\n" "$vm" "$ping_status" "$ssh_status" "$http_status"
			fi
		done
	else
		echo "No port mappings available for testing"
	fi
	echo ""
	echo "Legend: ✓ = accessible, ✗ = not accessible"
}

show_enhanced_console() {
	echo "=== VM Access Information ==="
	echo ""

	if [ -f $DATACENTER_BASE/port-mappings.txt ]; then
		echo "SSH Access:"
		grep -v "^#" $DATACENTER_BASE/port-mappings.txt | grep -v "^$" | while read vm ip ssh_port http_port; do
			if [ -n "$vm" ]; then
				echo "  ssh $vm"
				echo "    or: ssh -p $ssh_port admin@10.8.8.223"
			fi
		done
		echo ""

		echo "HTTP Access:"
		grep -v "^#" $DATACENTER_BASE/port-mappings.txt | grep -v "^$" | while read vm ip ssh_port http_port; do
			if [ -n "$vm" ]; then
				echo "  $vm: http://10.8.8.223:$http_port"
			fi
		done
		echo ""

		echo "Console Access:"
		grep -v "^#" $DATACENTER_BASE/port-mappings.txt | grep -v "^$" | while read vm ip ssh_port http_port; do
			if [ -n "$vm" ]; then
				echo "  virsh console $vm  (Press Ctrl+] to exit)"
			fi
		done
	else
		echo "No port mappings found. Run: $0 setup-forwarding"
		echo ""
		echo "Legacy access (if VMs exist):"
		echo "Connect to VM1: ssh datacenter-vm1"
		echo "Connect to VM2: ssh datacenter-vm2"
		echo "VM1 HTTP: http://10.8.8.223:8081"
		echo "VM2 HTTP: http://10.8.8.223:8082"
	fi
	echo ""
	echo "Default login: admin / admin123"
}

start_vms() {
	local target="$1"

	if [ "$target" = "all" ] || [ -z "$target" ]; then
		echo "Starting all datacenter VMs..."
		vm_count=0

		stopped_vms=$(virsh list --all | grep -E "shut off" | while read line; do
			vm=$(echo "$line" | awk '{print $2}')
			if [ -n "$vm" ] && virsh domiflist "$vm" 2>/dev/null | grep -q "$NETWORK_NAME"; then
				echo "$vm"
			fi
		done)

		if [ -n "$stopped_vms" ]; then
			echo "$stopped_vms" | while read vm; do
				if [ -n "$vm" ]; then
					echo "Starting $vm..."
					virsh start "$vm"
					vm_count=$((vm_count + 1))
				fi
			done
			echo "VM startup completed. Wait 30-60 seconds, then run: $0 setup-forwarding"
		else
			echo "No stopped VMs found or all VMs already running"
		fi
	else
		if ! virsh list --all | grep -q " $target "; then
			echo "VM '$target' does not exist"
			echo ""
			echo "Available VMs:"
			virsh list --all | grep -E "(running|shut off)" | while read line; do
				vm=$(echo "$line" | awk '{print $2}')
				state=$(echo "$line" | awk '{print $3}')
				if [ -n "$vm" ] && [ "$vm" != "Name" ]; then
					printf "  %-15s: %s\n" "$vm" "$state"
				fi
			done
			return 1
		fi

		if virsh list | grep -q " $target .*running"; then
			echo "VM '$target' is already running"
		elif virsh list --all | grep -q " $target .*shut"; then
			echo "Starting VM '$target'..."
			if virsh start "$target"; then
				echo "VM '$target' started successfully"
				echo "Wait 30-60 seconds for full boot, then run: $0 setup-forwarding"
			else
				echo "Failed to start VM '$target'"
			fi
		else
			echo "VM '$target' is in unknown state"
		fi
	fi
}

stop_vms() {
	local target="$1"

	if [ "$target" = "all" ] || [ -z "$target" ]; then
		echo "Stopping all datacenter VMs..."
		vm_count=0

		running_vms=$(virsh list | grep -E "running" | while read line; do
			vm=$(echo "$line" | awk '{print $2}')
			if [ -n "$vm" ] && virsh domiflist "$vm" 2>/dev/null | grep -q "$NETWORK_NAME"; then
				echo "$vm"
			fi
		done)

		if [ -n "$running_vms" ]; then
			echo "$running_vms" | while read vm; do
				if [ -n "$vm" ]; then
					echo "Stopping $vm..."
					virsh shutdown "$vm"
					vm_count=$((vm_count + 1))
				fi
			done
			echo "Shutdown initiated for all VMs"
		else
			echo "No running VMs found"
		fi
	else
		if ! virsh list --all | grep -q " $target "; then
			echo "VM '$target' does not exist"
			echo ""
			echo "Available VMs:"
			virsh list --all | grep -E "(running|shut off)" | while read line; do
				vm=$(echo "$line" | awk '{print $2}')
				state=$(echo "$line" | awk '{print $3}')
				if [ -n "$vm" ] && [ "$vm" != "Name" ]; then
					printf "  %-15s: %s\n" "$vm" "$state"
				fi
			done
			return 1
		fi

		if virsh list | grep -q " $target .*running"; then
			echo "Stopping VM '$target'..."
			if virsh shutdown "$target"; then
				echo "Shutdown initiated for VM '$target'"
			else
				echo "Failed to stop VM '$target'"
			fi
		else
			echo "VM '$target' is not running"
		fi
	fi
}

restart_vms() {
	local target="$1"

	if [ "$target" = "all" ] || [ -z "$target" ]; then
		echo "Restarting all datacenter VMs..."

		all_vms=$(virsh list --all | grep -E "(running|shut off)" | while read line; do
			vm=$(echo "$line" | awk '{print $2}')
			if [ -n "$vm" ] && [ "$vm" != "Name" ] && virsh domiflist "$vm" 2>/dev/null | grep -q "datacenter-net"; then
				state=$(echo "$line" | awk '{print $3}')
				echo "$vm:$state"
			fi
		done)

		if [ -n "$all_vms" ]; then
			echo "$all_vms" | while read vm_info; do
				vm=$(echo "$vm_info" | cut -d':' -f1)
				state=$(echo "$vm_info" | cut -d':' -f2)
				if [ -n "$vm" ]; then
					if [ "$state" = "running" ]; then
						echo "Restarting $vm..."
						virsh reboot "$vm"
					else
						echo "Starting $vm..."
						virsh start "$vm"
					fi
				fi
			done
			echo "Restart completed. Wait 30-60 seconds, then run: $0 setup-forwarding"
		else
			echo "No VMs found"
		fi
	else
		if ! virsh list --all | grep -q " $target "; then
			echo "VM '$target' does not exist"
			echo ""
			echo "Available VMs:"
			virsh list --all | grep -E "(running|shut off)" | while read line; do
				vm=$(echo "$line" | awk '{print $2}')
				state=$(echo "$line" | awk '{print $3}')
				if [ -n "$vm" ] && [ "$vm" != "Name" ]; then
					printf "  %-15s: %s\n" "$vm" "$state"
				fi
			done
			return 1
		fi

		if virsh list | grep -q " $target .*running"; then
			echo "Restarting VM '$target'..."
			if virsh reboot "$target"; then
				echo "Restart initiated for VM '$target'"
			else
				echo "Failed to restart VM '$target'"
			fi
		elif virsh list --all | grep -q " $target .*shut"; then
			echo "VM '$target' is stopped, starting it..."
			if virsh start "$target"; then
				echo "VM '$target' started"
			else
				echo "Failed to start VM '$target'"
			fi
		else
			echo "VM '$target' is in unknown state"
		fi

		echo "Wait 30-60 seconds for full boot, then run: $0 setup-forwarding"
	fi
}

show_enhanced_status() {
	echo "=== Enhanced VM Status ==="
	echo ""

	echo "All VMs:"
	virsh list --all
	echo ""

	echo "Port forwarding status:"
	port_rules=$(iptables -t nat -L PREROUTING -n --line-numbers | grep -E "(222[0-9]|808[0-9])")
	if [ -n "$port_rules" ]; then
		echo "$port_rules"
	else
		echo "No datacenter port forwarding rules found"
	fi
	echo ""

	echo "Network status:"
	virsh net-list
	echo ""

	echo "VM IP addresses:"
	virsh list --all | grep -E "(running|shut off)" | while read line; do
		vm=$(echo "$line" | awk '{print $2}')
		if [ -n "$vm" ] && [ "$vm" != "Name" ]; then
			if virsh domiflist "$vm" 2>/dev/null | grep -q "$NETWORK_NAME"; then
				ip=$(virsh domifaddr "$vm" --source lease 2>/dev/null | awk '/ipv4/ {print $4}' | cut -d'/' -f1 | head -1)
				if [ -n "$ip" ]; then
					printf "%-15s: %s\n" "$vm" "$ip"
				else
					printf "%-15s: IP not available\n" "$vm"
				fi
			fi
		fi
	done
}

case $1 in
"start")
	start_vms "$2"
	;;
"stop")
	stop_vms "$2"
	;;
"restart")
	restart_vms "$2"
	;;
"create")
	if [ -z "$2" ]; then
		echo "Usage: $0 create <vm_name> [additional_packages]"
		echo "Examples:"
		echo "  $0 create datacenter-vm1"
		echo "  $0 create datacenter-vm2 nginx"
		echo "  $0 create web-server apache2"
		exit 1
	fi
	"$SCRIPTS_PATH/create-vm.sh" "$2" "$3"
	;;
"delete")
	if [ -z "$2" ]; then
		echo "Usage: dcvm delete <vm_name>"
		echo "Example: dcvm delete datacenter-vm1"
		exit 1
	fi
	"$SCRIPTS_PATH/delete-vm.sh" "$2"
	;;
"backup")
	if [ -z "$2" ]; then
		echo "Usage: dcvm backup create <vm_name>"
		echo "       dcvm backup restore <vm_name> [backup_date]"
		echo "       dcvm backup list [vm_name]"
		echo "       dcvm backup troubleshoot <vm_name>"
		echo "Examples:"
		echo "  dcvm backup create datacenter-vm1               	# Create backup"
		echo "  dcvm backup restore datacenter-vm1            		# Restore from latest backup"
		echo "  dcvm backup restore datacenter-vm1 20250722_143052  # Restore from specific backup"
		echo "  dcvm backup list                               		# List all backups"
		echo "  dcvm backup list datacenter-vm1                		# List backups of a VM"
		echo "  dcvm backup troubleshoot vm1                   		# Fix VM startup issues"
		exit 1
	fi
	shift
	"$SCRIPTS_PATH/backup.sh" "$@"
	;;
"status")
	show_enhanced_status
	;;
"ports")
	show_port_status
	;;
"console")
	show_enhanced_console
	;;
"list")
	echo "Available VMs:"
	virsh list --all
	echo ""

	echo "VMs using $NETWORK_NAME:"
	virsh list --all | grep -E "(running|shut off)" | while read line; do
		vm=$(echo "$line" | awk '{print $2}')
		state=$(echo "$line" | awk '{print $3}')
		if [ -n "$vm" ] && [ "$vm" != "Name" ]; then
			if virsh domiflist "$vm" 2>/dev/null | grep -q "$NETWORK_NAME"; then
				printf "  %-15s: %s\n" "$vm" "$state"
			fi
		fi
	done
	;;
"setup-forwarding")
	echo "Setting up port forwarding..."
	"$SCRIPTS_PATH/setup-port-forwarding.sh"
	;;
"network")
	echo "=== Network Information ==="
	echo ""
	echo "Virtual Networks:"
	virsh net-list
	echo ""
	echo "Datacenter Network Details:"
	virsh net-info "$NETWORK_NAME" 2>/dev/null || echo "$NETWORK_NAME not found"
	echo ""
	echo "=== ALL DHCP LEASES ==="
	echo ""
	echo "Active DHCP Leases (via virsh):"
	dhcp_leases=$(virsh net-dhcp-leases "$NETWORK_NAME" 2>/dev/null)
	if [ -n "$dhcp_leases" ]; then
		echo "$dhcp_leases"
	else
		echo "No active DHCP leases found via virsh"
	fi
	echo ""
	echo "Raw DHCP Lease Files:"
	if [ -f /var/lib/libvirt/dnsmasq/${BRIDGE_NAME}.leases ]; then
		lease_count=$(wc -l </var/lib/libvirt/dnsmasq/${BRIDGE_NAME}.leases)
		echo "Lease file entries: $lease_count"
		if [ "$lease_count" -gt 0 ]; then
			echo "Raw lease file content:"
			cat /var/lib/libvirt/dnsmasq/${BRIDGE_NAME}.leases | while read line; do
				echo "  $line"
			done
		else
			echo "Lease file is empty"
		fi
	else
		echo "Lease file not found: /var/lib/libvirt/dnsmasq/virbr-dc.leases"
	fi
	echo ""
	if [ -f /var/lib/libvirt/dnsmasq/virbr-dc.status ]; then
		status_count=$(wc -l </var/lib/libvirt/dnsmasq/virbr-dc.status)
		echo "Status file entries: $status_count"
		if [ "$status_count" -gt 0 ]; then
			echo "Status file content:"
			cat /var/lib/libvirt/dnsmasq/virbr-dc.status | while read line; do
				echo "  $line"
			done
		else
			echo "Status file is empty"
		fi
	else
		echo "Status file not found: /var/lib/libvirt/dnsmasq/virbr-dc.status"
	fi
	echo ""
	echo "Additional DHCP lease locations:"
	for lease_file in /var/lib/dhcp/dhcpd.leases /var/lib/libvirt/dnsmasq/*.leases; do
		if [ -f "$lease_file" ]; then
			echo "Found: $lease_file"
			if [ -s "$lease_file" ]; then
				echo "  (Contains data - $(wc -l <"$lease_file") lines)"
			else
				echo "  (Empty file)"
			fi
		fi
	done
	;;
"clear-leases")
	if [ -z "$2" ]; then
		echo "DHCP Lease Management"
		echo ""
		echo "Usage: $0 clear-leases {show|clear-vm|clear-all|cleanup}"
		echo ""
		echo "Commands:"
		echo "  show        - Show current DHCP leases"
		echo "  clear-vm    - Clear lease for specific VM (requires VM name)"
		echo "  clear-all   - Clear ALL DHCP leases"
		echo "  cleanup     - Remove only expired leases"
		echo ""
		echo "Examples:"
		echo "  $0 clear-leases show"
		echo "  $0 clear-leases clear-vm datacenter-vm1"
		echo "  $0 clear-leases clear-all"
		echo ""
		echo "Current DHCP leases:"
		virsh net-dhcp-leases "$NETWORK_NAME" 2>/dev/null || echo "No leases found"
	elif [ "$2" = "show" ]; then
		echo "Current DHCP leases:"
		virsh net-dhcp-leases "$NETWORK_NAME" 2>/dev/null || echo "No leases found"
	elif [ "$2" = "clear-vm" ]; then
		if [ -z "$3" ]; then
			echo "Usage: $0 clear-leases clear-vm <vm_name>"
			echo "Example: $0 clear-leases clear-vm datacenter-vm1"
		else
			vm_name="$3"
			echo "Clearing DHCP lease for VM: $vm_name"

			mac_address=$(virsh domiflist "$vm_name" 2>/dev/null | grep "$NETWORK_NAME" | awk '{print $5}')

			if [ -n "$mac_address" ]; then
				echo "Found MAC address: $mac_address"

				if [ -f /var/lib/libvirt/dnsmasq/${BRIDGE_NAME}.leases ]; then
					sed -i "/$mac_address/d" /var/lib/libvirt/dnsmasq/${BRIDGE_NAME}.leases
					echo "Removed from lease file"
				fi

				if [ -f /var/lib/libvirt/dnsmasq/${BRIDGE_NAME}.status ]; then
					sed -i "/$mac_address/d" /var/lib/libvirt/dnsmasq/${BRIDGE_NAME}.status
					echo "Removed from status file"
				fi

				virsh net-destroy "$NETWORK_NAME"
				sleep 2
				virsh net-start "$NETWORK_NAME"
				echo "Network restarted"
				echo ""
				echo "Updated DHCP leases:"
				virsh net-dhcp-leases "$NETWORK_NAME" 2>/dev/null || echo "No leases found"
			else
				echo "Could not find MAC address for VM: $vm_name"
			fi
		fi
	elif [ "$2" = "clear-all" ]; then
		echo "WARNING: This will clear ALL DHCP leases!"
		echo "Current leases:"
		virsh net-dhcp-leases "$NETWORK_NAME" 2>/dev/null || echo "No leases found"
		echo ""
		read -p "Are you sure you want to clear all leases? (y/N): " confirm
		if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
			echo "Clearing all DHCP leases..."

			virsh net-destroy "$NETWORK_NAME" 2>/dev/null || true

			if [ -f /var/lib/libvirt/dnsmasq/${BRIDGE_NAME}.leases ]; then
				>/var/lib/libvirt/dnsmasq/${BRIDGE_NAME}.leases
				echo "Cleared lease file"
			fi

			if [ -f /var/lib/libvirt/dnsmasq/${BRIDGE_NAME}.status ]; then
				>/var/lib/libvirt/dnsmasq/${BRIDGE_NAME}.status
				echo "Cleared status file"
			fi

			virsh net-start "$NETWORK_NAME"
			echo "Network restarted with clean lease table"
			echo ""
			echo "New lease status:"
			virsh net-dhcp-leases "$NETWORK_NAME" 2>/dev/null || echo "No leases found"
		else
			echo "Cancelled"
		fi
	elif [ "$2" = "cleanup" ]; then
		echo "Cleaning up expired DHCP leases..."

		current_time=$(date +%s)
		temp_file="/tmp/dhcp_leases_clean"
		cleaned_count=0

		if [ -f /var/lib/libvirt/dnsmasq/${BRIDGE_NAME}.leases ]; then
			echo "Current leases before cleanup:"
			virsh net-dhcp-leases "$NETWORK_NAME" 2>/dev/null || echo "No leases found"
			echo ""

			while IFS=' ' read -r timestamp mac ip hostname client_id; do
				if [ -n "$timestamp" ] && [ "$timestamp" != "duid" ]; then
					if [ "$timestamp" -gt "$current_time" ]; then
						echo "$timestamp $mac $ip $hostname $client_id" >>"$temp_file"
					else
						echo "Removing expired lease: $ip ($hostname)"
						cleaned_count=$((cleaned_count + 1))
					fi
				fi
			done </var/lib/libvirt/dnsmasq/${BRIDGE_NAME}.leases

			if [ -f "$temp_file" ]; then
				mv "$temp_file" /var/lib/libvirt/dnsmasq/${BRIDGE_NAME}.leases
			else
				>/var/lib/libvirt/dnsmasq/${BRIDGE_NAME}.leases
			fi

			virsh net-destroy "$NETWORK_NAME"
			sleep 2
			virsh net-start "$NETWORK_NAME"

			echo "Cleaned $cleaned_count expired leases"
			echo ""
			echo "Leases after cleanup:"
			virsh net-dhcp-leases "$NETWORK_NAME" 2>/dev/null || echo "No leases found"
		else
			echo "No lease file found"
		fi
	else
		echo "Unknown command: $2"
		echo "Use: $0 clear-leases (without arguments) for help"
	fi
	;;
"uninstall")
	echo "This will completely remove all Datacenter VM files, VMs, networks, and this script."
	read -p "Are you sure? (y/N): " CONFIRM
	CONFIRM=${CONFIRM:-n}
	if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
		echo "Uninstallation cancelled."
		exit 0
	fi
	"$SCRIPTS_PATH/uninstall-dcvm.sh"
	;;
*)
	echo "VM Datacenter Manager"
	echo "Usage: dcvm {command} [options]"
	echo ""
	echo "VM Control:"
	echo "  start [vm|all]     - Start specific VM or all datacenter VMs"
	echo "  stop [vm|all]      - Stop specific VM or all datacenter VMs"
	echo "  restart [vm|all]   - Restart specific VM or all datacenter VMs"
	echo "  create <n> [pkg]   - Create new VM with optional package"
	echo "  delete <n>         - Delete specified VM"
	echo ""
	echo "Status & Monitoring:"
	echo "  status             - Show enhanced VM status and network info"
	echo "  ports              - Show detailed port mappings and connectivity"
	echo "  console            - Show connection instructions for all VMs"
	echo "  list               - List all VMs (with $NETWORK_NAME filter)"
	echo "  network            - Show network information and DHCP leases"
	echo ""
	echo "Backup & Restore:"
	echo "  backup create <vm_name>             - Create backup of VM"
	echo "  backup restore <vm_name> [date]     - Restore VM from backup"
	echo "  backup list [vm_name]               - List backups (all or per VM)"
	echo ""
	echo "Port & Network Management:"
	echo "  setup-forwarding   - Configure port forwarding for all VMs"
	echo "  clear-leases       - Manage DHCP leases (show/clear/cleanup)"
	echo "  uninstall          - Remove all datacenter files, VMs, networks, and this script"
	echo ""
	echo "Examples:"
	echo "  dcvm start web-server           	# Start specific VM"
	echo "  dcvm start all                  	# Start all VMs"
	echo "  dcvm start                      	# Start all VMs (default)"
	echo "  dcvm stop datacenter-vm1        	# Stop specific VM"
	echo "  dcvm restart all                	# Restart all VMs"
	echo "  dcvm create web-server nginx    	# Create VM with nginx"
	echo "  dcvm delete old-vm              	# Delete specific VM"
	echo "  dcvm backup create datacenter-vm1   # Create backup"
	echo "  dcvm backup restore datacenter-vm1  # Restore from latest backup"
	echo "  dcvm backup list vm1            	# List available backups"
	echo "  dcvm ports                      	# Check port status and connectivity"
	echo "  dcvm console                    	# Show how to access all VMs"
	echo "  dcvm clear-leases show          	# Show DHCP leases"
	echo "  dcvm clear-leases clear-vm vm1  	# Clear DHCP lease for VM"
	echo "  dcvm uninstall                  	# Remove all files and this script"
	echo ""
	echo "VM States:"
	echo "  running    - VM is currently active"
	echo "  shut off   - VM is stopped"
	echo "  paused     - VM is paused (can be resumed)"
	echo ""
	echo "Quick Reference:"
	echo "  dcvm start vm-name    # Start individual VM"
	echo "  dcvm stop vm-name     # Stop individual VM"
	echo "  dcvm backup vm-name   # Backup VM"
	echo "  dcvm ports            # Check connectivity"
	echo "  dcvm console          # Get access info"
	;;
esac
