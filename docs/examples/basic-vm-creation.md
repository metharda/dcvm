# Basic VM Creation Examples

This guide provides practical examples for creating VMs with DCVM.

## Example 1: Simple Web Server

Create a basic Ubuntu web server with nginx:

```bash
dcvm create webserver \
  -f \
  -p MySecurePass123 \
  -m 2048 \
  -c 2 \
  -d 30G \
  -o 3 \
  -k nginx,php
```

**What this does:**
- Creates a VM named "webserver"
- Uses force mode (no prompts)
- Sets password to "MySecurePass123"
- Allocates 2GB RAM
- Assigns 2 CPU cores
- Creates 30GB disk
- Uses Ubuntu 22.04 (option 3)
- Installs nginx and PHP

**After creation:**
```bash
# Get IP address
dcvm network | grep webserver

# SSH into the VM
ssh admin@<vm-ip>

# Test nginx
curl http://<vm-ip>
```

## Example 2: Database Server

Create a MySQL database server with more resources:

```bash
dcvm create dbserver \
  -f \
  -p DbPass456 \
  -u dbadmin \
  -m 4096 \
  -c 4 \
  -d 100G \
  -o 1 \
  -k mysql-server \
  --enable-root
```

**What this does:**
- Creates a VM named "dbserver"
- Custom username "dbadmin"
- 4GB RAM for database operations
- 4 CPU cores
- 100GB disk for data storage
- Uses Debian 12 (option 1)
- Installs MySQL server
- Enables root access

**Connect to MySQL:**
```bash
ssh dbadmin@<vm-ip>
mysql -u dbadmin -p
```

## Example 3: Docker Host

Create a VM optimized for running Docker containers:

```bash
dcvm create dockerhost \
  -f \
  -p Docker2024! \
  -m 8192 \
  -c 4 \
  -d 200G \
  -o 3 \
  -k docker.io
```

**What this does:**
- Creates a VM named "dockerhost"
- 8GB RAM for containers
- 4 CPU cores
- 200GB disk for container images
- Ubuntu 22.04
- Installs Docker

**Use Docker:**
```bash
ssh admin@<vm-ip>
docker --version
docker run hello-world
```

## Example 4: Development Environment

Interactive creation for a custom development environment:

```bash
dcvm create devbox
```

Then choose:
- OS: Ubuntu 22.04
- Username: developer
- Password: (enter securely)
- Root: enabled (same password)
- Memory: 4096 MB
- CPUs: 4
- Disk: 50G
- SSH key: yes
- Packages: none (install later as needed)

**Install development tools:**
```bash
ssh developer@<vm-ip>
sudo apt update
sudo apt install build-essential git vim nodejs npm
```

## Example 5: Multiple Web Servers

Create a cluster of web servers:

```bash
#!/bin/bash
# Create 3 web servers

for i in {1..3}; do
  dcvm create webserver$i \
    -f \
    -p WebPass123 \
    -m 2048 \
    -c 2 \
    -d 20G \
    -o 3 \
    -k nginx
done
```

**Load balancing:**
After creation, configure nginx on host to load balance across the three servers.

## Example 6: Minimal Test VM

Smallest possible VM for testing:

```bash
dcvm create testvm \
  -f \
  -p test123 \
  -m 512 \
  -c 1 \
  -d 10G \
  -o 3 \
  --without-ssh-key
```

**What this does:**
- Minimal resources
- Password-only authentication
- Quick creation for testing

## Example 7: High-Resource VM

VM with maximum resources:

```bash
dcvm create powervm \
  -f \
  -p PowerPass2024 \
  -u poweruser \
  -m 16384 \
  -c 8 \
  -d 500G \
  -o 3 \
  -k docker.io,build-essential \
  --enable-root
```

**What this does:**
- 16GB RAM
- 8 CPU cores
- 500GB disk
- Ready for heavy workloads

## Example 8: Secure Production Server

Create a production-ready secure server:

```bash
dcvm create prodserver \
  -f \
  -p $(openssl rand -base64 32) \
  -u prodadmin \
  -m 8192 \
  -c 4 \
  -d 200G \
  -o 3 \
  --with-ssh-key
```

**What this does:**
- Generates a strong random password
- SSH key authentication enabled
- Suitable for production use

**Important:** Save the generated password!

## Example 9: Interactive Configuration

For complex setups, use interactive mode:

```bash
dcvm create appserver
```

Benefits:
- See all available options
- Validate inputs interactively
- Confirm before creation
- Better for learning

## Example 10: Clone Configuration

Create multiple VMs with same configuration:

```bash
# Create template script
cat > create-standard-vm.sh << 'EOF'
#!/bin/bash
VM_NAME=$1
dcvm create $VM_NAME \
  -f \
  -p StandardPass123 \
  -m 4096 \
  -c 2 \
  -d 50G \
  -o 3 \
  -k nginx,php,mysql-server \
  --enable-root
EOF

chmod +x create-standard-vm.sh

# Create multiple VMs
./create-standard-vm.sh app1
./create-standard-vm.sh app2
./create-standard-vm.sh app3
```

## Tips

### 1. Resource Planning
```bash
# Check available resources before creating VM
free -h
nproc
df -h
```

### 2. Password Security
```bash
# Generate strong password
openssl rand -base64 32

# Use password manager
# Store passwords securely
```

### 3. Naming Convention
```bash
# Use descriptive names
dcvm create web-prod-01
dcvm create db-dev-mysql
dcvm create docker-staging
```

### 4. Documentation
Keep track of your VMs:
```bash
# Create a VM inventory file
cat > vm-inventory.txt << EOF
webserver1: 10.10.10.10 - nginx web server
dbserver: 10.10.10.11 - MySQL database
dockerhost: 10.10.10.12 - Docker container host
EOF
```

## Next Steps

- Learn about [Networking](../networking.md)
- Set up [Backups](../backup-restore.md)
- Read [Advanced Networking Examples](advanced-networking.md)
