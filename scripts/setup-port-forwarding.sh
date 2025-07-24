#!/bin/bash

if [ -f /etc/dcvm-install.conf ]; then
	source /etc/dcvm-install.conf
else
	echo "${RED:-}[ERROR]${NC:-} /etc/dcvm-install.conf bulunamadı!"
	exit 1
fi

DATACENTER_BASE="${DATACENTER_BASE:-/srv/datacenter}"
NETWORK_NAME="${NETWORK_NAME:-datacenter-net}"
BRIDGE_NAME="${BRIDGE_NAME:-virbr-dc}"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

print_info() {
	echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
	echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
	echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
	echo -e "${RED}[ERROR]${NC} $1"
}

get_vm_ip() {
	local vm_name=$1
	local ip=""
	local attempts=0

	print_info "Looking for IP address of $vm_name..."

	while [ -z "$ip" ] && [ $attempts -lt 15 ]; do
		ip=$(virsh domifaddr "$vm_name" --source agent 2>/dev/null | awk '/ipv4/ {print $4}' | cut -d'/' -f1 | grep '^10\.10\.10\.' | head -1)

		if [ -z "$ip" ]; then
			ip=$(virsh domifaddr "$vm_name" --source lease 2>/dev/null | awk '/ipv4/ {print $4}' | cut -d'/' -f1 | grep '^10\.10\.10\.' | head -1)
		fi

		if [ -z "$ip" ]; then
			ip=$(virsh net-dhcp-leases $NETWORK_NAME 2>/dev/null | grep "$vm_name" | awk '{print $5}' | cut -d'/' -f1 | grep '^10\.10\.10\.' | head -1)
		fi

		if [ -z "$ip" ]; then
			local mac=$(virsh domiflist "$vm_name" 2>/dev/null | grep $NETWORK_NAME | awk '{print $5}')
			if [ -n "$mac" ]; then
				ip=$(virsh net-dhcp-leases $NETWORK_NAME 2>/dev/null | grep "$mac" | awk '{print $5}' | cut -d'/' -f1 | grep '^10\.10\.10\.' | head -1)
			fi
		fi

		if [ -z "$ip" ]; then
			local mac=$(virsh domiflist "$vm_name" 2>/dev/null | grep $NETWORK_NAME | awk '{print $5}')
			if [ -n "$mac" ]; then
				ip=$(ip neigh show | grep "$mac" | grep -oE '10\.10\.10\.[0-9]+' | head -1)
				if [ -z "$ip" ]; then
					ip=$(arp -a | grep "$mac" | grep -oE '10\.10\.10\.[0-9]+' | head -1)
				fi
			fi
		fi

		if [ -z "$ip" ] && [ $attempts -eq 10 ]; then
			print_info "Attempting network scan as last resort..."
			for i in {100..254}; do
				local test_ip="10.10.10.$i"
				if ping -c 1 -W 1 "$test_ip" >/dev/null 2>&1; then
					local test_mac=$(ip neigh show "$test_ip" 2>/dev/null | awk '{print $5}')
					local vm_mac=$(virsh domiflist "$vm_name" 2>/dev/null | grep $NETWORK_NAME | awk '{print $5}')
					if [ -n "$test_mac" ] && [ -n "$vm_mac" ] && [ "$test_mac" = "$vm_mac" ]; then
						ip="$test_ip"
						break
					fi
				fi
			done
		fi

		if [ -n "$ip" ] && [[ $ip =~ ^10\.10\.10\.[0-9]+$ ]]; then
			if ping -c 1 -W 3 "$ip" >/dev/null 2>&1; then
				print_success "$vm_name IP found and reachable: $ip"
				break
			else
				print_warning "$vm_name IP found but not reachable: $ip (attempt $((attempts + 1)))"
				ip=""
			fi
		else
			if [ $attempts -eq 0 ]; then
				print_info "Attempt $((attempts + 1)): Waiting for $vm_name to get valid IP address..."
			fi
		fi

		if [ -z "$ip" ]; then
			sleep 3
		fi
		attempts=$((attempts + 1))
	done

	echo "$ip"
}

cleanup_port_forwarding() {
	print_info "Cleaning up existing datacenter port forwarding rules..."

	for port in {2220..2299} {8080..8179}; do
		while iptables -t nat -L PREROUTING -n --line-numbers 2>/dev/null | grep -q ":$port "; do
			local line=$(iptables -t nat -L PREROUTING -n --line-numbers | grep ":$port " | head -1 | awk '{print $1}')
			if [ -n "$line" ]; then
				iptables -t nat -D PREROUTING "$line" 2>/dev/null || break
			else
				break
			fi
		done
	done

	while iptables -L FORWARD -n --line-numbers 2>/dev/null | grep -q "10\.10\.10\."; do
		local line=$(iptables -L FORWARD -n --line-numbers | grep "10\.10\.10\." | head -1 | awk '{print $1}')
		if [ -n "$line" ]; then
			iptables -D FORWARD "$line" 2>/dev/null || break
		else
			break
		fi
	done

	print_success "Cleanup completed"
}

get_host_ip() {
	local host_ip=""

	for interface in eth0 ens3 ens18 enp0s3 wlan0; do
		host_ip=$(ip addr show "$interface" 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1 | head -1)
		if [ -n "$host_ip" ] && [[ ! "$host_ip" =~ ^127\. ]] && [[ ! "$host_ip" =~ ^10\.10\.10\. ]]; then
			break
		fi
	done

	if [ -z "$host_ip" ]; then
		host_ip=$(ip route get 8.8.8.8 2>/dev/null | awk '{print $7; exit}')
	fi

	if [ -z "$host_ip" ]; then
		host_ip="YOUR_HOST_IP"
	fi

	echo "$host_ip"
}

print_info "=== DCVM Port Forwarding Setup ==="

if [ "$EUID" -ne 0 ]; then
	print_error "This script must be run as root (use sudo)"
	exit 1
fi

if ! command -v iptables >/dev/null 2>&1; then
	print_error "iptables is not installed"
	exit 1
fi

if ! virsh net-list --all | grep -q "$NETWORK_NAME"; then
	print_error "$NETWORK_NAME network not found"
	print_info "Please run: dcvm status (to initialize the environment)"
	exit 1
fi

if ! virsh net-list | grep -q "$NETWORK_NAME.*active"; then
	print_warning "$NETWORK_NAME is not active, attempting to start..."
	if virsh net-start $NETWORK_NAME >/dev/null 2>&1; then
		print_success "$NETWORK_NAME started"
		sleep 3
	else
		print_error "Failed to start $NETWORK_NAME"
		exit 1
	fi
fi

print_info "Discovering VMs on $NETWORK_NAME..."
VM_LIST=$(virsh list --all | grep -E "(running|shut off)" | awk '{print $2}' | grep -v "^$" | while read vm; do
	if [ -n "$vm" ] && virsh domiflist "$vm" 2>/dev/null | grep -q "$NETWORK_NAME"; then
		echo "$vm"
	fi
done)

if [ -z "$VM_LIST" ]; then
	print_warning "No VMs found using $NETWORK_NAME"
	print_info "Create a VM first: dcvm create my-vm"
	exit 0
fi

print_success "Found VMs using $NETWORK_NAME:"
echo "$VM_LIST" | while read vm; do
	local state=$(virsh list --all | grep " $vm " | awk '{print $3}')
	echo "  - $vm ($state)"
done
echo ""

cleanup_port_forwarding

HOST_IP=$(get_host_ip)
print_info "Host IP detected: $HOST_IP"

SSH_PORT_START=2221
HTTP_PORT_START=8081
ssh_port=$SSH_PORT_START
http_port=$HTTP_PORT_START

declare -A vm_ips
declare -A vm_ssh_ports
declare -A vm_http_ports

print_info "Configuring port forwarding for discovered VMs..."

echo 1 >/proc/sys/net/ipv4/ip_forward

echo "$VM_LIST" | while read vm; do
	if [ -z "$vm" ]; then
		continue
	fi

	if ! virsh list | grep -q "$vm.*running"; then
		print_warning "Skipping $vm (not running - start it first)"
		continue
	fi

	vm_ip=$(get_vm_ip "$vm")

	if [ -n "$vm_ip" ] && [[ $vm_ip =~ ^10\.10\.10\.[0-9]+$ ]]; then
		print_info "Setting up port forwarding for $vm ($vm_ip)..."

		if iptables -t nat -I PREROUTING -p tcp --dport "$ssh_port" -j DNAT --to-destination "$vm_ip:22" 2>/dev/null; then
			iptables -I FORWARD -p tcp -d "$vm_ip" --dport 22 -j ACCEPT 2>/dev/null
			print_success "  SSH: $HOST_IP:$ssh_port -> $vm_ip:22"
		else
			print_error "  Failed to setup SSH forwarding for $vm"
		fi

		if iptables -t nat -I PREROUTING -p tcp --dport "$http_port" -j DNAT --to-destination "$vm_ip:80" 2>/dev/null; then
			iptables -I FORWARD -p tcp -d "$vm_ip" --dport 80 -j ACCEPT 2>/dev/null
			print_success "  HTTP: $HOST_IP:$http_port -> $vm_ip:80"
		else
			print_error "  Failed to setup HTTP forwarding for $vm"
		fi

		vm_ips[$vm]=$vm_ip
		vm_ssh_ports[$vm]=$ssh_port
		vm_http_ports[$vm]=$http_port

		echo "$vm $vm_ip $ssh_port $http_port" >>/tmp/dcvm_port_mappings.tmp

		ssh_port=$((ssh_port + 1))
		http_port=$((http_port + 1))
	else
		print_warning "Skipping $vm (no valid IP found or not reachable)"
	fi
done

iptables -I FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null

if [ -f /tmp/dcvm_port_mappings.tmp ]; then
	mkdir -p $DATACENTER_BASE
	cat >$DATACENTER_BASE/port-mappings.txt <<EOF
EOF
	cat /tmp/dcvm_port_mappings.tmp >>$DATACENTER_BASE/port-mappings.txt
	rm -f /tmp/dcvm_port_mappings.tmp

	print_success "Port mappings saved to $DATACENTER_BASE/port-mappings.txt"
else
	print_warning "No successful port mappings to save"
fi

if command -v iptables-save >/dev/null 2>&1; then
	mkdir -p /etc/iptables
	if iptables-save >/etc/iptables/rules.v4 2>/dev/null; then
		print_success "iptables rules saved to /etc/iptables/rules.v4"
	fi
fi

echo ""
print_success "=== Port forwarding configuration complete! ==="
echo "Host IP: $HOST_IP"
echo ""

if [ -f $DATACENTER_BASE/port-mappings.txt ]; then
	echo "VM Access Information:"
	grep -v "^#" /srv/datacenter/port-mappings.txt | grep -v "^$" | while read vm ip ssh_port http_port; do
		if [ -n "$vm" ]; then
			echo ""
			echo "$vm ($ip):"
			echo "  SSH:  ssh -p $ssh_port admin@$HOST_IP"
			echo "  HTTP: http://$HOST_IP:$http_port"
		fi
	done
	echo ""

	print_info "Updating SSH configuration for easy access..."

	if [ -f ~/.ssh/config ]; then
		cp ~/.ssh/config ~/.ssh/config.backup.$(date +%s) 2>/dev/null || true
	fi

	if [ -f ~/.ssh/config ]; then
		grep -v "^Host.*datacenter\|^Host.*vm[0-9]" ~/.ssh/config >~/.ssh/config.tmp 2>/dev/null || true
		mv ~/.ssh/config.tmp ~/.ssh/config 2>/dev/null || true
	fi

	grep -v "^#" /srv/datacenter/port-mappings.txt | grep -v "^$" | while read vm ip ssh_port http_port; do
		if [ -n "$vm" ]; then
			mkdir -p ~/.ssh
			cat >>~/.ssh/config <<EOF

Host $vm
    HostName $HOST_IP
    Port $ssh_port
    User admin
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
EOF
		fi
	done

	echo ""
	print_success "SSH configuration updated. You can now use:"
	grep -v "^#" /srv/datacenter/port-mappings.txt | grep -v "^$" | while read vm ip ssh_port http_port; do
		if [ -n "$vm" ]; then
			echo "  ssh $vm"
		fi
	done
else
	print_warning "No VMs were successfully configured"
fi

echo ""
print_info "Note: Make sure your firewall allows the configured ports"
print_info "To check current mappings anytime: dcvm ports"
