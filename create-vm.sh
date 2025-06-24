#!/usr/bin/env zsh

# VM Creation Script with Cloud-Init
# Usage: ./create-vm.zsh <VM_ID> <VM_NAME> <IP_ADDRESS>
# Example: ./create-vm.zsh 101 k8s-master 172.16.0.10

# Check arguments
if [[ $# -ne 3 ]]; then
    echo "❌ Usage: $0 <VM_ID> <VM_NAME> <IP_ADDRESS>"
    echo "   Example: $0 101 k8s-master 172.16.0.10"
    echo "   Example: $0 102 k8s-worker1 172.16.0.11"
    exit 1
fi

# Parse arguments
VM_ID=$1
VM_NAME=$2
IP_ADDRESS=$3
CLOUD_IMAGE="/var/lib/vz/vms/template/iso/debian-12-generic-amd64.qcow2"

# Validate VM_ID is numeric
if ! [[ "$VM_ID" =~ ^[0-9]+$ ]]; then
    echo "❌ VM_ID must be numeric"
    exit 1
fi

# Validate IP address format
if ! [[ "$IP_ADDRESS" =~ ^172\.16\.0\.[0-9]{1,3}$ ]]; then
    echo "❌ IP address must be in format 172.16.0.X"
    exit 1
fi

echo "🚀 Creating VM $VM_ID ($VM_NAME) with IP $IP_ADDRESS..."

# Get SSH public keys
if [[ ! -f /root/.ssh/id_ed25519.pub ]]; then
    echo "❌ SSH key not found at /root/.ssh/id_ed25519.pub"
    exit 1
fi

SSH_KEY1=$(cat /root/.ssh/id_ed25519.pub)
SSH_KEY2=$(cat /root/SSH2)

# Create cloud-init user-data file with unique name
CLOUDINIT_FILE="/var/lib/vz/snippets/vm-${VM_ID}-user-data.yaml"

cat > "$CLOUDINIT_FILE" << EOF
#cloud-config

# Set hostname
hostname: $VM_NAME
fqdn: ${VM_NAME}.tarams.org

# System updates
package_update: true
package_upgrade: true

# User configuration
users:
  - name: debian
    groups: sudo
    shell: /bin/bash
    sudo: ['ALL=(ALL) NOPASSWD:ALL']
    ssh_authorized_keys:
      - $SSH_KEY1
      - $SSH_KEY2

# Package installation
packages:
  - openssh-server
  - apt-transport-https
  - ca-certificates
  - curl
  - gpg
  - htop

# System configuration
ssh_pwauth: false
disable_root: false

# Fix repositories and disable IPv6 completely
write_files:
  - path: /etc/apt/sources.list
    content: |
      deb http://deb.debian.org/debian bookworm main
      deb http://deb.debian.org/debian bookworm-updates main
      deb http://deb.debian.org/debian bookworm-backports main
      deb http://security.debian.org/debian-security bookworm-security main
  - path: /etc/sysctl.d/01-disable-ipv6.conf
    content: |
      # Disable IPv6 completely
      net.ipv6.conf.all.disable_ipv6 = 1
      net.ipv6.conf.default.disable_ipv6 = 1
      net.ipv6.conf.lo.disable_ipv6 = 1
  - path: /etc/modprobe.d/blacklist-ipv6.conf
    content: |
      # Blacklist IPv6 module
      blacklist ipv6
  - path: /etc/default/grub.d/ipv6.cfg
    content: |
      # Disable IPv6 at kernel level
      GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT ipv6.disable=1"

# Disable IPv6 early in boot process
bootcmd:
  - echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6
  - echo 1 > /proc/sys/net/ipv6/conf/default/disable_ipv6
  - echo 1 > /proc/sys/net/ipv6/conf/lo/disable_ipv6

# Services configuration
runcmd:
  # Fix repository configuration first
  - rm -f /etc/apt/sources.list.d/*
  - rm -f /etc/apt/mirrors/*
  
  # Apply IPv6 disable immediately and permanently
  - sysctl -w net.ipv6.conf.all.disable_ipv6=1
  - sysctl -w net.ipv6.conf.default.disable_ipv6=1
  - sysctl -w net.ipv6.conf.lo.disable_ipv6=1
  - sysctl -p /etc/sysctl.d/01-disable-ipv6.conf
  
  # Clean DNS cache and force IPv4
  - echo 'nameserver 8.8.8.8' > /etc/resolv.conf
  - echo 'nameserver 8.8.4.4' >> /etc/resolv.conf
  
  # Update package cache
  - apt-get clean
  - apt-get update
  
  # Update GRUB to disable IPv6 at kernel level
  - update-grub
  
  # Ensure SSH is enabled and started
  - systemctl enable ssh
  - systemctl start ssh
  
  # Set proper permissions on debian user's home directory
  - chown -R debian:debian /home/debian
  - chmod 700 /home/debian/.ssh
  - chmod 600 /home/debian/.ssh/authorized_keys

# Final message
final_message: "Cloud-init setup complete! SSH ready on debian@$IP_ADDRESS"

# Power state
power_state:
  mode: reboot
  delay: 1
  condition: true
EOF

echo "✅ Created cloud-init file: $CLOUDINIT_FILE"

# Stop and destroy existing VM if it exists
echo "🔄 Cleaning up existing VM $VM_ID..."
qm stop $VM_ID 2>/dev/null && echo "   Stopped VM $VM_ID" || echo "   VM $VM_ID not running"
qm destroy $VM_ID --purge 2>/dev/null && echo "   Destroyed VM $VM_ID" || echo "   VM $VM_ID doesn't exist"

# Create VM
echo "📦 Creating VM $VM_ID..."
qm create $VM_ID \
    --name "$VM_NAME" \
    --net0 virtio,bridge=vmbr0 \
    --bootdisk scsi0 \
    --ostype l26 \
    --memory 32768 \
    --balloon 0 \
    --cores 8 \
    --cpu cputype=host

if [[ $? -ne 0 ]]; then
    echo "❌ Failed to create VM"
    exit 1
fi

# Import disk
echo "💾 Importing disk..."
qm importdisk $VM_ID "$CLOUD_IMAGE" local-vms

if [[ $? -ne 0 ]]; then
    echo "❌ Failed to import disk"
    exit 1
fi

# Configure VM hardware
echo "⚙️  Configuring VM hardware..."
qm set $VM_ID --scsi0 local-vms:$VM_ID/vm-$VM_ID-disk-0.raw
qm set $VM_ID --ide2 local-vms:cloudinit
qm set $VM_ID --boot c --bootdisk scsi0
qm set $VM_ID --agent enabled=1
qm set $VM_ID --serial0 socket --vga serial0

# Resize disk to 50GB
echo "📏 Resizing disk to 50GB..."
qm resize $VM_ID scsi0 +47G

# Apply cloud-init configuration
echo "☁️  Applying cloud-init configuration..."
qm set $VM_ID --cicustom "user=local:snippets/vm-${VM_ID}-user-data.yaml"
qm set $VM_ID --ipconfig0 ip=${IP_ADDRESS}/24,gw=172.16.0.1
qm set $VM_ID --nameserver 8.8.8.8

# Start VM
echo "🚀 Starting VM $VM_ID..."
qm start $VM_ID

if [[ $? -eq 0 ]]; then
    echo ""
    echo "✅ VM $VM_ID ($VM_NAME) created successfully!"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📋 VM Details:"
    echo "   ID:       $VM_ID"
    echo "   Name:     $VM_NAME"
    echo "   IP:       $IP_ADDRESS/24"
    echo "   Gateway:  172.16.0.1"
    echo "   Memory:   32GB"
    echo "   Cores:    4"
    echo "   Disk:     50GB"
    echo ""
    echo "🔗 SSH Access:"
    echo "   ssh debian@$IP_ADDRESS"
    echo "   ssh -p 2210 debian@pv1.tarams.org  # (if port forwarding enabled)"
    echo ""
    echo "⏱️  Wait 3-5 minutes for cloud-init to complete..."
    echo "   Monitor: qm status $VM_ID"
    echo "   Console: qm terminal $VM_ID"
    echo ""
    echo "🧪 Test connectivity:"
    echo "   ping $IP_ADDRESS"
else
    echo "❌ Failed to start VM $VM_ID"
    exit 1
fi
