#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

read -p "This will completely remove all installed components. Are you sure? (y/N): " CONFIRM
CONFIRM=${CONFIRM:-n}

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    print_info "Uninstallation cancelled."
    exit 0
fi

if [ -d "/srv/datacenter/vms" ]; then
    rm -rf /srv/datacenter/vms
    print_info "Removed /srv/datacenter/vms"
else
    print_info "/srv/datacenter/vms not found"
fi

if [ -d "/srv/datacenter/storage/templates" ]; then
    rm -rf /srv/datacenter/storage/templates
    print_info "Removed /srv/datacenter/storage/templates"
else
    print_info "/srv/datacenter/storage/templates not found"
fi

if virsh net-info datacenter-net >/dev/null 2>&1; then
    virsh net-destroy datacenter-net
    virsh net-undefine datacenter-net
    print_info "Destroyed and undefined datacenter-net"
else
    print_info "datacenter-net not found"
fi

if [ -f "/etc/libvirt/qemu/datacenter-net.xml" ]; then
    rm -f /etc/libvirt/qemu/datacenter-net.xml
    print_info "Removed /etc/libvirt/qemu/datacenter-net.xml"
else
    print_info "/etc/libvirt/qemu/datacenter-net.xml not found"
fi

if [ -f "/etc/libvirt/storage/datacenter-pool.xml" ]; then
    rm -f /etc/libvirt/storage/datacenter-pool.xml
    print_info "Removed /etc/libvirt/storage/datacenter-pool.xml"
else
    print_info "/etc/libvirt/storage/datacenter-pool.xml not found"
fi

if [ -d "/var/lib/libvirt/images/datacenter" ]; then
    rm -rf /var/lib/libvirt/images/datacenter
    print_info "Removed /var/lib/libvirt/images/datacenter"
else
    print_info "/var/lib/libvirt/images/datacenter not found"
fi

print_info "Uninstallation completed."
