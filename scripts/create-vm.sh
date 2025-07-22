#!/bin/bash

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

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

# Function to get host system information
get_host_info() {
    # Get total memory in MB
    HOST_MEMORY_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    HOST_MEMORY_MB=$((HOST_MEMORY_KB / 1024))
    
    # Get CPU count
    HOST_CPUS=$(nproc)
    
    # Get CPU model
    HOST_CPU_MODEL=$(grep "model name" /proc/cpuinfo | head -1 | cut -d: -f2 | sed 's/^ *//')
    
    # Calculate recommended maximums (leave some resources for host)
    MAX_VM_MEMORY=$((HOST_MEMORY_MB * 75 / 100))  # 75% of host memory
    MAX_VM_CPUS=$((HOST_CPUS - 1))  # Leave 1 CPU for host
    if [ $MAX_VM_CPUS -lt 1 ]; then
        MAX_VM_CPUS=1
    fi
}

# Function to read password securely
read_password() {
    local prompt="$1"
    local var_name="$2"
    local password=""
    
    echo -n "$prompt"
    
    # Use read with -s flag for silent input
    read -s password
    echo  # Add newline after password input
    
    # Use declare to set the variable in the calling scope
    printf -v "$var_name" '%s' "$password"
}

# Function to validate username
validate_username() {
    local username="$1"
    
    # Check if username is empty
    if [ -z "$username" ]; then
        return 1
    fi
    
    # Check if username contains only valid characters (alphanumeric, underscore, hyphen)
    if [[ ! "$username" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        return 1
    fi
    
    # Check if username starts with a letter or underscore
    if [[ ! "$username" =~ ^[a-zA-Z_] ]]; then
        return 1
    fi
    
    # Check length (3-32 characters)
    if [ ${#username} -lt 3 ] || [ ${#username} -gt 32 ]; then
        return 1
    fi
    
    return 0
}

# Function to validate password
validate_password() {
    local password="$1"
    
    # Check minimum length
    if [ ${#password} -lt 4 ]; then
        echo "Password must be at least 4 characters long"
        return 1
    fi
    
    # Check maximum length
    if [ ${#password} -gt 128 ]; then
        echo "Password must be less than 128 characters"
        return 1
    fi
    
    return 0
}

# Function to generate password hash
generate_password_hash() {
    local password="$1"
    local salt=$(openssl rand -base64 16 | tr -d "=+/" | cut -c1-16)
    echo "$password" | openssl passwd -6 -salt "$salt" -stdin
}

# Check if required commands exist
check_dependencies() {
    local missing_deps=()
    
    # Check for required commands
    for cmd in virsh virt-install qemu-img genisoimage openssl bc; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_deps+=("$cmd")
        fi
    done
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        print_error "Missing required dependencies: ${missing_deps[*]}"
        echo "Please install them first and try again."
        exit 1
    fi
}

# Usage information
if [ $# -lt 1 ]; then
    echo "VM Creation Script"
    echo "Usage: $0 <vm_name> [additional_packages]"
    echo ""
    echo "Examples:"
    echo "  $0 datacenter-vm1"
    echo "  $0 web-server nginx"
    echo "  $0 db-server mysql-server,phpmyadmin"
    echo ""
    echo "Available packages: nginx, apache2, mysql-server, postgresql, php, nodejs, docker.io"
    exit 1
fi

VM_NAME=$1
ADDITIONAL_PACKAGES=${2:-""}

# Check dependencies
check_dependencies

# Get host system information
get_host_info

echo "=================================================="
echo "VM Creation Wizard"
echo "=================================================="
echo ""
echo "Host System Information:"
echo "  CPU: $HOST_CPU_MODEL"
echo "  Total CPUs: $HOST_CPUS"
echo "  Total Memory: ${HOST_MEMORY_MB}MB ($(echo "scale=1; $HOST_MEMORY_MB/1024" | bc -l)GB)"
echo "  Recommended VM Limits: ${MAX_VM_CPUS} CPUs, ${MAX_VM_MEMORY}MB RAM"
echo ""

print_info "Creating VM: $VM_NAME"

# Get user credentials
echo ""
print_info "Setting up user account..."
echo ""

# Get username with validation
while true; do
    read -p "Enter username for VM (default: admin): " VM_USERNAME
    VM_USERNAME=${VM_USERNAME:-admin}
    
    if validate_username "$VM_USERNAME"; then
        break
    else
        print_error "Invalid username! Requirements:"
        echo "  - 3-32 characters long"
        echo "  - Start with letter or underscore"
        echo "  - Only letters, numbers, underscore, hyphen allowed"
        echo "  - Examples: admin, user1, my_user, test-vm"
        echo ""
    fi
done

print_success "Username set to: $VM_USERNAME"

# Get password with validation
echo ""
print_info "Setting password for user '$VM_USERNAME'..."
while true; do
    read_password "Password: " VM_PASSWORD
    
    # Check if password is empty
    if [ -z "$VM_PASSWORD" ]; then
        print_error "Password cannot be empty!"
        echo ""
        continue
    fi
    
    # Validate password
    validation_result=$(validate_password "$VM_PASSWORD")
    if [ $? -ne 0 ]; then
        print_error "$validation_result"
        echo ""
        continue
    fi
    
    read_password "Retype password: " VM_PASSWORD_CONFIRM
    if [ "$VM_PASSWORD" = "$VM_PASSWORD_CONFIRM" ]; then
        print_success "User '$VM_USERNAME' password configured successfully"
        break
    else
        print_error "Passwords do not match! Please try again."
        echo ""
    fi
done

# Ask about root access
echo ""
print_info "Root access configuration..."
while true; do
    read -p "Enable root login? (y/N): " ENABLE_ROOT
    ENABLE_ROOT=${ENABLE_ROOT:-n}
    
    if [[ "$ENABLE_ROOT" =~ ^[YyNn]$ ]]; then
        break
    else
        print_error "Please enter 'y' for yes or 'n' for no"
    fi
done

ROOT_PASSWORD=""
if [[ "$ENABLE_ROOT" =~ ^[Yy]$ ]]; then
    while true; do
        read -p "Use same password for root? (Y/n): " SAME_ROOT_PASSWORD
        SAME_ROOT_PASSWORD=${SAME_ROOT_PASSWORD:-y}
        
        if [[ "$SAME_ROOT_PASSWORD" =~ ^[YyNn]$ ]]; then
            break
        else
            print_error "Please enter 'y' for yes or 'n' for no"
        fi
    done
    
    if [[ "$SAME_ROOT_PASSWORD" =~ ^[Yy]$ ]]; then
        ROOT_PASSWORD="$VM_PASSWORD"
        print_success "Root will use the same password"
    else
        echo ""
        print_info "Setting password for root user..."
        while true; do
            read_password "Password: " ROOT_PASSWORD
            
            # Check if password is empty
            if [ -z "$ROOT_PASSWORD" ]; then
                print_error "Password cannot be empty!"
                echo ""
                continue
            fi
            
            # Validate password
            validation_result=$(validate_password "$ROOT_PASSWORD")
            if [ $? -ne 0 ]; then
                print_error "$validation_result"
                echo ""
                continue
            fi
            
            read_password "Retype password: " ROOT_PASSWORD_CONFIRM
            if [ "$ROOT_PASSWORD" = "$ROOT_PASSWORD_CONFIRM" ]; then
                print_success "Root password configured successfully"
                break
            else
                print_error "Passwords do not match! Please try again."
                echo ""
            fi
        done
    fi
    print_success "Root access enabled"
else
    print_success "Root access disabled"
fi

# SSH Key setup (automatic - RSA only)
echo ""
print_info "Setting up SSH Key Authentication (RSA)..."

SSH_KEY=""
if [ -f ~/.ssh/id_rsa.pub ]; then
    SSH_KEY=$(cat ~/.ssh/id_rsa.pub)
    print_success "Using existing RSA SSH key from ~/.ssh/id_rsa.pub"
else
    print_info "No RSA SSH key found. Creating new RSA SSH key..."
    if ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N "" -C "$VM_USERNAME@$(hostname)" >/dev/null 2>&1; then
        SSH_KEY=$(cat ~/.ssh/id_rsa.pub)
        print_success "Created new RSA SSH key at ~/.ssh/id_rsa"
    else
        print_error "Failed to create SSH key"
        exit 1
    fi
fi

# VM Resources with validation
echo ""
print_info "VM Resource Configuration..."
echo ""

# Memory validation
while true; do
    read -p "Memory in MB (default: 2048, available: ${HOST_MEMORY_MB}MB, max recommended: ${MAX_VM_MEMORY}MB): " VM_MEMORY
    VM_MEMORY=${VM_MEMORY:-2048}
    
    # Check if it's a number
    if [[ ! "$VM_MEMORY" =~ ^[0-9]+$ ]]; then
        print_error "Memory must be a number"
        continue
    fi
    
    # Check minimum
    if [ "$VM_MEMORY" -lt 512 ]; then
        print_error "Memory must be at least 512MB"
        continue
    fi
    
    # Check against host memory
    if [ "$VM_MEMORY" -gt "$MAX_VM_MEMORY" ]; then
        print_warning "Warning: Requested ${VM_MEMORY}MB exceeds recommended ${MAX_VM_MEMORY}MB"
        read -p "Continue anyway? (y/N): " continue_anyway
        if [[ ! "$continue_anyway" =~ ^[Yy]$ ]]; then
            continue
        fi
    fi
    
    break
done

# CPU validation
while true; do
    read -p "Number of CPUs (default: 2, available: ${HOST_CPUS}, max recommended: ${MAX_VM_CPUS}): " VM_CPUS
    VM_CPUS=${VM_CPUS:-2}
    
    # Check if it's a number
    if [[ ! "$VM_CPUS" =~ ^[0-9]+$ ]]; then
        print_error "CPU count must be a number"
        continue
    fi
    
    # Check minimum
    if [ "$VM_CPUS" -lt 1 ]; then
        print_error "CPU count must be at least 1"
        continue
    fi
    
    # Check against host CPUs
    if [ "$VM_CPUS" -gt "$MAX_VM_CPUS" ]; then
        print_warning "Warning: Requested ${VM_CPUS} CPUs exceeds recommended ${MAX_VM_CPUS}"
        read -p "Continue anyway? (y/N): " continue_anyway
        if [[ ! "$continue_anyway" =~ ^[Yy]$ ]]; then
            continue
        fi
    fi
    
    break
done

# Disk size validation
while true; do
    read -p "Disk size (default: 20G, format: 10G, 500M, 2T): " VM_DISK_SIZE
    VM_DISK_SIZE=${VM_DISK_SIZE:-20G}
    
    # Check format (number followed by G, M, or T)
    if [[ ! "$VM_DISK_SIZE" =~ ^[0-9]+[GMT]$ ]]; then
        print_error "Disk size format: number + G/M/T (e.g., 20G, 512M, 1T)"
        continue
    fi
    
    # Extract number and unit
    size_num=$(echo "$VM_DISK_SIZE" | sed 's/[GMT]$//')
    size_unit=$(echo "$VM_DISK_SIZE" | sed 's/^[0-9]*//')
    
    # Basic range check
    case "$size_unit" in
        "M")
            if [ "$size_num" -lt 100 ]; then
                print_error "Minimum disk size is 100M"
                continue
            fi
            ;;
        "G")
            if [ "$size_num" -lt 1 ] || [ "$size_num" -gt 1000 ]; then
                print_error "Disk size must be between 1G and 1000G"
                continue
            fi
            ;;
        "T")
            if [ "$size_num" -gt 10 ]; then
                print_error "Maximum disk size is 10T"
                continue
            fi
            ;;
    esac
    
    break
done

print_success "VM resources configured: ${VM_MEMORY}MB RAM, ${VM_CPUS} CPUs, ${VM_DISK_SIZE} disk"

# Summary
echo ""
echo "=================================================="
print_info "VM Configuration Summary"
echo "=================================================="
echo "VM Name: $VM_NAME"
echo "Username: $VM_USERNAME"
echo "Password: $(echo "$VM_PASSWORD" | sed 's/./*/g')"
if [[ "$ENABLE_ROOT" =~ ^[Yy]$ ]]; then
    echo "Root Access: Enabled"
    echo "Root Password: $(echo "$ROOT_PASSWORD" | sed 's/./*/g')"
else
    echo "Root Access: Disabled"
fi
echo "SSH Key: Configured"
echo "Memory: ${VM_MEMORY}MB"
echo "CPUs: $VM_CPUS"
echo "Disk: $VM_DISK_SIZE"
if [ -n "$ADDITIONAL_PACKAGES" ]; then
    echo "Packages: $ADDITIONAL_PACKAGES"
fi
echo ""

# Final confirmation with clear exit option
echo ""
while true; do
    read -p "Proceed with VM creation? (Y/n): " CONFIRM
    CONFIRM=${CONFIRM:-y}
    
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        break
    elif [[ "$CONFIRM" =~ ^[Nn]$ ]]; then
        print_info "VM creation cancelled by user."
        exit 0
    else
        print_error "Please enter 'y' to proceed or 'n' to cancel"
    fi
done

# Check if VM already exists
if virsh list --all 2>/dev/null | grep -q " $VM_NAME "; then
    print_error "VM $VM_NAME already exists"
    echo "Use: dcvm delete $VM_NAME (to delete it first)"
    exit 1
fi

print_info "Starting VM creation process..."

# Check if required directories and base image exist
if [ ! -d "/srv/datacenter/vms" ]; then
    print_error "Directory /srv/datacenter/vms does not exist"
    exit 1
fi

if [ ! -f "/srv/datacenter/storage/templates/debian-12-generic-amd64.qcow2" ]; then
    print_error "Base template /srv/datacenter/storage/templates/debian-12-generic-amd64.qcow2 not found"
    exit 1
fi

# Create VM directory structure
if ! mkdir -p /srv/datacenter/vms/$VM_NAME/cloud-init; then
    print_error "Failed to create VM directory structure"
    exit 1
fi

# Generate password hash
print_info "Generating secure password hash..."
PASSWORD_HASH=$(generate_password_hash "$VM_PASSWORD")
if [ -z "$PASSWORD_HASH" ]; then
    print_error "Failed to generate password hash"
    exit 1
fi

# Parse additional packages (handle comma-separated list)
PACKAGE_LIST=""
if [ -n "$ADDITIONAL_PACKAGES" ]; then
    # Convert comma-separated packages to YAML list format
    IFS=',' read -ra PACKAGES <<< "$ADDITIONAL_PACKAGES"
    for package in "${PACKAGES[@]}"; do
        package=$(echo "$package" | xargs) # trim whitespace
        PACKAGE_LIST="${PACKAGE_LIST}  - ${package}\n"
    done
fi

# Determine root login setting
ROOT_LOGIN_SETTING="no"
if [[ "$ENABLE_ROOT" =~ ^[Yy]$ ]]; then
    ROOT_LOGIN_SETTING="yes"
fi

# Create user-data with SSH key, password, and optional additional packages
cat > /srv/datacenter/vms/$VM_NAME/cloud-init/user-data << USERDATA_EOF
#cloud-config
hostname: $VM_NAME
users:
  - name: $VM_USERNAME
    sudo: ['ALL=(ALL) NOPASSWD:ALL']
    shell: /bin/bash
    lock_passwd: false
    passwd: '$PASSWORD_HASH'
    ssh_authorized_keys:
      - $SSH_KEY

ssh_pwauth: true
disable_root: $([ "$ROOT_LOGIN_SETTING" = "yes" ] && echo "false" || echo "true")
package_update: true
packages:
  - openssh-server
  - openssh-sftp-server
  - nfs-common
  - htop
  - curl
  - wget
  - net-tools
  - rsync
  - nano
  - vim
  - tree
  - unzip
$(if [ -n "$PACKAGE_LIST" ]; then echo -e "$PACKAGE_LIST"; fi)

bootcmd:
  - echo '$VM_USERNAME:$VM_PASSWORD' | chpasswd
$(if [[ "$ENABLE_ROOT" =~ ^[Yy]$ ]]; then echo "  - echo 'root:$ROOT_PASSWORD' | chpasswd"; fi)

write_files:
  - content: |
      # SSH Configuration for VM: $VM_NAME
      Port 22
      Protocol 2
      
      # Authentication
      PermitRootLogin $ROOT_LOGIN_SETTING
      PasswordAuthentication yes
      PubkeyAuthentication yes
      AuthorizedKeysFile .ssh/authorized_keys
      
      # Security settings
      UsePAM yes
      ChallengeResponseAuthentication no
      
      # SFTP subsystem (required for scp/sftp)
      Subsystem sftp /usr/lib/openssh/sftp-server
      
      # Connection settings
      ClientAliveInterval 300
      ClientAliveCountMax 2
      MaxAuthTries 6
      
      # Logging
      SyslogFacility AUTH
      LogLevel INFO
    path: /etc/ssh/sshd_config
    owner: root:root
    permissions: '0644'
  - content: |
      # VM Information - Created $(date)
      VM_NAME="$VM_NAME"
      VM_USERNAME="$VM_USERNAME"
      VM_MEMORY="${VM_MEMORY}MB"
      VM_CPUS="$VM_CPUS"
      VM_DISK="$VM_DISK_SIZE"
      ROOT_ACCESS="$ROOT_LOGIN_SETTING"
      SSH_KEY_AUTH="enabled"
      CREATED="$(date)"
      
      # Connection examples:
      # SSH: ssh $VM_USERNAME@<vm_ip>
      # SCP: scp file $VM_USERNAME@<vm_ip>:/path/
      # SFTP: sftp $VM_USERNAME@<vm_ip>
    path: /etc/vm-info
    owner: root:root
    permissions: '0644'

runcmd:
  # SSH setup
  - systemctl enable ssh
  - systemctl restart ssh
  - systemctl status ssh --no-pager
  
  # Network setup
  - mkdir -p /mnt/shared
  - chown $VM_USERNAME:$VM_USERNAME /mnt/shared
  - echo "10.10.10.1:/srv/datacenter/nfs-share /mnt/shared nfs defaults 0 0" >> /etc/fstab
  - mount -a || true
  
  # Create user directories
  - mkdir -p /home/$VM_USERNAME/{Documents,Downloads,Scripts}
  - chown -R $VM_USERNAME:$VM_USERNAME /home/$VM_USERNAME
  
$(if echo "$ADDITIONAL_PACKAGES" | grep -q "nginx"; then cat << 'NGINX_EOF'
  # Nginx setup
  - systemctl enable nginx
  - systemctl start nginx
  - echo "<h1>Welcome to $VM_NAME</h1><p>Nginx server running!</p><p>User: $VM_USERNAME</p>" > /var/www/html/index.html
  - chown www-data:www-data /var/www/html/index.html
NGINX_EOF
fi)

$(if echo "$ADDITIONAL_PACKAGES" | grep -q "apache2"; then cat << 'APACHE_EOF'
  # Apache setup
  - systemctl enable apache2
  - systemctl start apache2
  - echo "<h1>Welcome to $VM_NAME</h1><p>Apache server running!</p><p>User: $VM_USERNAME</p>" > /var/www/html/index.html
  - chown www-data:www-data /var/www/html/index.html
APACHE_EOF
fi)

$(if echo "$ADDITIONAL_PACKAGES" | grep -q "mysql-server"; then cat << 'MYSQL_EOF'
  # MySQL setup
  - systemctl enable mysql
  - systemctl start mysql
  - mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$VM_PASSWORD';"
  - mysql -e "CREATE USER '$VM_USERNAME'@'localhost' IDENTIFIED BY '$VM_PASSWORD';"
  - mysql -e "GRANT ALL PRIVILEGES ON *.* TO '$VM_USERNAME'@'localhost' WITH GRANT OPTION;"
  - mysql -e "FLUSH PRIVILEGES;"
MYSQL_EOF
fi)

$(if echo "$ADDITIONAL_PACKAGES" | grep -q "docker"; then cat << 'DOCKER_EOF'
  # Docker setup
  - systemctl enable docker
  - systemctl start docker
  - usermod -aG docker $VM_USERNAME
DOCKER_EOF
fi)
  
  # Final setup
  - echo "VM $VM_NAME setup completed successfully" >> /var/log/cloud-init-final.log
  - echo "User: $VM_USERNAME configured" >> /var/log/cloud-init-final.log
  - echo "SSH/SCP/SFTP ready for connections" >> /var/log/cloud-init-final.log
  - wall "VM $VM_NAME is ready! Login as $VM_USERNAME"

final_message: |
  VM $VM_NAME setup completed!
  Username: $VM_USERNAME
  SSH ready for connections.
USERDATA_EOF

# Check if user-data was created successfully
if [ ! -f "/srv/datacenter/vms/$VM_NAME/cloud-init/user-data" ]; then
    print_error "Failed to create cloud-init user-data file"
    exit 1
fi

# Create meta-data
cat > /srv/datacenter/vms/$VM_NAME/cloud-init/meta-data << METADATA_EOF
instance-id: $VM_NAME-$(date +%s)
local-hostname: $VM_NAME
METADATA_EOF

# Create network-config
cat > /srv/datacenter/vms/$VM_NAME/cloud-init/network-config << 'NETWORK_EOF'
version: 2
ethernets:
  enp1s0:
    dhcp4: true
    dhcp-identifier: mac
NETWORK_EOF

# Create cloud-init ISO
print_info "Creating cloud-init configuration..."
cd /srv/datacenter/vms/$VM_NAME
if ! genisoimage -output cloud-init.iso -volid cidata -joliet -rock cloud-init/ >/dev/null 2>&1; then
    print_error "Failed to create cloud-init ISO"
    exit 1
fi

# Create VM disk
print_info "Creating VM disk ($VM_DISK_SIZE)..."
if ! qemu-img create -f qcow2 -F qcow2 -b /srv/datacenter/storage/templates/debian-12-generic-amd64.qcow2 ${VM_NAME}-disk.qcow2 $VM_DISK_SIZE >/dev/null 2>&1; then
    print_error "Failed to create VM disk"
    exit 1
fi

# Create and start VM
print_info "Installing VM with $VM_MEMORY MB RAM and $VM_CPUS CPUs..."
if ! virt-install \
    --name $VM_NAME \
    --virt-type kvm \
    --memory $VM_MEMORY \
    --vcpus $VM_CPUS \
    --boot hd,menu=on \
    --disk path=/srv/datacenter/vms/$VM_NAME/${VM_NAME}-disk.qcow2,device=disk \
    --disk path=/srv/datacenter/vms/$VM_NAME/cloud-init.iso,device=cdrom \
    --graphics none \
    --os-variant debian12 \
    --network network=datacenter-net \
    --console pty,target_type=serial \
    --import \
    --noautoconsole >/dev/null 2>&1; then
    print_error "Failed to create VM"
    exit 1
fi

# Set VM to autostart
if ! virsh autostart $VM_NAME >/dev/null 2>&1; then
    print_warning "Failed to set VM autostart (VM created successfully)"
fi

echo ""
echo "=================================================="
print_success "VM $VM_NAME created successfully!"
echo "=================================================="
echo ""
echo "Connection Methods:"
echo "   Console: virsh console $VM_NAME"
echo "   SSH: ssh $VM_USERNAME@<vm_ip>"
echo "   SCP: scp file $VM_USERNAME@<vm_ip>:/path/"
echo "   SFTP: sftp $VM_USERNAME@<vm_ip>"
echo ""
echo "Quick Commands:"
echo "   Check status: dcvm status"
echo "   Get IP: dcvm network"
echo "   Setup ports: dcvm setup-forwarding"
echo "   Delete VM: dcvm delete $VM_NAME"
echo ""
echo "Wait 2-3 minutes for cloud-init to complete setup"
echo "   Monitor: virsh console $VM_NAME"
echo "   Check logs: tail -f /var/log/cloud-init-output.log (inside VM)"
