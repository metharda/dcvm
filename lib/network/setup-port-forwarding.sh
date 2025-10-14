#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../utils/common.sh"

load_dcvm_config
require_root
check_dependencies iptables virsh

get_vm_ip_advanced() {
	local vm_name="$1"
	local ip=""
	local attempts=0

	print_info "Looking for IP address of $vm_name"

	while [ -z "$ip" ] && [ $attempts -lt 15 ]; do
		ip=$(get_vm_ip "$vm_name" 1)
		
		if [ "$ip" = "N/A" ] || [ -z "$ip" ]; then
			local mac=$(get_vm_mac "$vm_name")
			if [ -n "$mac" ]; then
				ip=$(ip neigh show | grep "$mac" | grep -oE '10\.10\.10\.[0-9]+' | head -1)
				[ -z "$ip" ] && ip=$(arp -a | grep "$mac" | grep -oE '10\.10\.10\.[0-9]+' | head -1)
			fi
		fi

		if [ -z "$ip" ] || [ "$ip" = "N/A" ]; then
			if [ $attempts -eq 10 ]; then
				print_info "Attempting network scan as last resort"
				for i in {100..254}; do
					local test_ip="10.10.10.$i"
					if check_ping "$test_ip"; then
						local test_mac=$(ip neigh show "$test_ip" 2>/dev/null | awk '{print $5}')
						local vm_mac=$(get_vm_mac "$vm_name")
						if [ -n "$test_mac" ] && [ -n "$vm_mac" ] && [ "$test_mac" = "$vm_mac" ]; then
							ip="$test_ip"
							break
						fi
					fi
				done
			fi
		fi

		if [ -n "$ip" ] && [ "$ip" != "N/A" ] && [[ $ip =~ ^10\.10\.10\.[0-9]+$ ]]; then
			if check_ping "$ip"; then
				print_success "$vm_name IP found and reachable: $ip"
				break
			else
				print_warning "$vm_name IP found but not reachable: $ip (attempt $((attempts + 1)))"
				ip=""
			fi
		else
			[ $attempts -eq 0 ] && print_info "Attempt $((attempts + 1)): Waiting for $vm_name to get valid IP address"
		fi

		[ -z "$ip" ] || [ "$ip" = "N/A" ] && sleep 3
		attempts=$((attempts + 1))
	done

	echo "$ip"
}

cleanup_port_forwarding() {
	print_info "Cleaning up existing datacenter port forwarding rules"

	for port in {2220..2299} {8080..8179}; do
		while iptables -t nat -L PREROUTING -n --line-numbers 2>/dev/null | grep -q ":$port "; do
			local line=$(iptables -t nat -L PREROUTING -n --line-numbers | grep ":$port " | head -1 | awk '{print $1}')
			[ -n "$line" ] && iptables -t nat -D PREROUTING "$line" 2>/dev/null || break
		done
	done

	while iptables -L FORWARD -n --line-numbers 2>/dev/null | grep -q "10\.10\.10\."; do
		local line=$(iptables -L FORWARD -n --line-numbers | grep "10\.10\.10\." | head -1 | awk '{print $1}')
		[ -n "$line" ] && iptables -D FORWARD "$line" 2>/dev/null || break
	done

	print_success "Cleanup completed"
}

detect_host_ip() {
	local host_ip=""

	for interface in eth0 ens3 ens18 enp0s3 wlan0; do
		host_ip=$(ip addr show "$interface" 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1 | head -1)
		[ -n "$host_ip" ] && [[ ! "$host_ip" =~ ^127\. ]] && [[ ! "$host_ip" =~ ^10\.10\.10\. ]] && break
	done

	[ -z "$host_ip" ] && host_ip=$(ip route get 8.8.8.8 2>/dev/null | awk '{print $7; exit}')
	[ -z "$host_ip" ] && host_ip="YOUR_HOST_IP"

	echo "$host_ip"
}

setup_vm_forwarding() {
	local vm="$1"
	local vm_ip="$2"
	local ssh_port="$3"
	local http_port="$4"
	local host_ip="$5"

	print_info "Setting up port forwarding for $vm ($vm_ip)"

	if iptables -t nat -I PREROUTING -p tcp --dport "$ssh_port" -j DNAT --to-destination "$vm_ip:22" 2>/dev/null; then
		iptables -I FORWARD -p tcp -d "$vm_ip" --dport 22 -j ACCEPT 2>/dev/null
		print_success "  SSH: $host_ip:$ssh_port -> $vm_ip:22"
	else
		print_error "  Failed to setup SSH forwarding for $vm"
		return 1
	fi

	if iptables -t nat -I PREROUTING -p tcp --dport "$http_port" -j DNAT --to-destination "$vm_ip:80" 2>/dev/null; then
		iptables -I FORWARD -p tcp -d "$vm_ip" --dport 80 -j ACCEPT 2>/dev/null
		print_success "  HTTP: $host_ip:$http_port -> $vm_ip:80"
	else
		print_error "  Failed to setup HTTP forwarding for $vm"
	fi

	echo "$vm $vm_ip $ssh_port $http_port" >> /tmp/dcvm_port_mappings.tmp
	return 0
}

update_ssh_config() {
	local host_ip="$1"
	
	print_info "Updating SSH configuration for easy access"

	[ -f ~/.ssh/config ] && cp ~/.ssh/config ~/.ssh/config.backup.$(date +%s) 2>/dev/null

	if [ -f ~/.ssh/config ]; then
		grep -v "^Host.*datacenter\|^Host.*vm[0-9]" ~/.ssh/config > ~/.ssh/config.tmp 2>/dev/null || true
		mv ~/.ssh/config.tmp ~/.ssh/config 2>/dev/null || true
	fi

	read_port_mappings | while read vm ip ssh_port http_port; do
		if [ -n "$vm" ]; then
			mkdir -p ~/.ssh
			cat >> ~/.ssh/config <<EOF

Host $vm
    HostName $host_ip
    Port $ssh_port
    User admin
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
EOF
		fi
	done

	print_success "SSH configuration updated. You can now use:"
	read_port_mappings | while read vm ip ssh_port http_port; do
		[ -n "$vm" ] && echo "  ssh $vm"
	done
}

print_info "=== DCVM Port Forwarding Setup ==="

if ! virsh net-list --all | grep -q "$NETWORK_NAME"; then
	print_error "$NETWORK_NAME network not found"
	print_info "Please run: dcvm status (to initialize the environment)"
	exit 1
fi

if ! virsh net-list | grep -q "$NETWORK_NAME.*active"; then
	print_warning "$NETWORK_NAME is not active, attempting to start"
	if virsh net-start "$NETWORK_NAME" >/dev/null 2>&1; then
		print_success "$NETWORK_NAME started"
		sleep 3
	else
		print_error "Failed to start $NETWORK_NAME"
		exit 1
	fi
fi

print_info "Discovering VMs on $NETWORK_NAME"
VM_LIST=$(virsh list --all | grep -E "(running|shut off)" | awk '{print $2}' | grep -v "^$" | while read vm; do
	[ -n "$vm" ] && is_vm_in_network "$vm" && echo "$vm"
done)

if [ -z "$VM_LIST" ]; then
	print_warning "No VMs found using $NETWORK_NAME"
	print_info "Create a VM first: dcvm create my-vm"
	exit 0
fi

print_success "Found VMs using $NETWORK_NAME:"
echo "$VM_LIST" | while read vm; do
	local state=$(get_vm_state "$vm")
	echo "  - $vm ($state)"
done
echo ""

cleanup_port_forwarding

HOST_IP=$(detect_host_ip)
print_info "Host IP detected: $HOST_IP"

SSH_PORT_START=2221
HTTP_PORT_START=8081
ssh_port=$SSH_PORT_START
http_port=$HTTP_PORT_START

print_info "Configuring port forwarding for discovered VMs"

echo 1 > /proc/sys/net/ipv4/ip_forward

echo "$VM_LIST" | while read vm; do
	[ -z "$vm" ] && continue

	if ! virsh list | grep -q "$vm.*running"; then
		print_warning "Skipping $vm (not running - start it first)"
		continue
	fi

	vm_ip=$(get_vm_ip_advanced "$vm")

	if [ -n "$vm_ip" ] && [[ $vm_ip =~ ^10\.10\.10\.[0-9]+$ ]]; then
		setup_vm_forwarding "$vm" "$vm_ip" "$ssh_port" "$http_port" "$HOST_IP"
		ssh_port=$((ssh_port + 1))
		http_port=$((http_port + 1))
	else
		print_warning "Skipping $vm (no valid IP found or not reachable)"
	fi
done

iptables -I FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null

if [ -f /tmp/dcvm_port_mappings.tmp ]; then
	create_dir_safe "$DATACENTER_BASE"
	cat > "$DATACENTER_BASE/port-mappings.txt" <<EOF
# VM_NAME VM_IP SSH_PORT HTTP_PORT
EOF
	cat /tmp/dcvm_port_mappings.tmp >> "$DATACENTER_BASE/port-mappings.txt"
	rm -f /tmp/dcvm_port_mappings.tmp
	print_success "Port mappings saved to $DATACENTER_BASE/port-mappings.txt"
else
	print_warning "No successful port mappings to save"
fi

if command_exists iptables-save; then
	create_dir_safe /etc/iptables
	iptables-save > /etc/iptables/rules.v4 2>/dev/null && print_success "iptables rules saved to /etc/iptables/rules.v4"
fi

echo ""
print_success "=== Port forwarding configuration complete! ==="
echo "Host IP: $HOST_IP"
echo ""

if [ -f "$DATACENTER_BASE/port-mappings.txt" ]; then
	echo "VM Access Information:"
	read_port_mappings | while read vm ip ssh_port http_port; do
		if [ -n "$vm" ]; then
			echo ""
			echo "$vm ($ip):"
			echo "  SSH:  ssh -p $ssh_port admin@$HOST_IP"
			echo "  HTTP: http://$HOST_IP:$http_port"
		fi
	done
	echo ""

	update_ssh_config "$HOST_IP"
else
	print_warning "No VMs were successfully configured"
fi

echo ""
print_info "Note: Make sure your firewall allows the configured ports"
print_info "To check current mappings anytime: dcvm ports"
