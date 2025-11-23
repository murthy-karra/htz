#!/usr/bin/env zsh

# Multi-VM Creation Script with Cloud-Init
# Creates multiple VMs with different configurations
# Usage: ./create-multi-vm.zsh

# VM Configuration
declare -A VMS=(
    ["100"]="c1-c:172.16.0.100:16384:4:no"      # Control plane: 8GB RAM, 4 CPU, no 2nd disk
    ["101"]="c1-w1:172.16.0.101:32768:8:yes"    # Worker 1: 32GB RAM, 8 CPU, 200GB 2nd disk
    ["102"]="c1-w2:172.16.0.102:32768:8:yes"    # Worker 2: 32GB RAM, 8 CPU, 200GB 2nd disk
    ["103"]="c1-w3:172.16.0.103:32768:8:yes"    # Worker 3: 32GB RAM, 8 CPU, 200GB 2nd disk
    
    # ["110"]="c2-c:172.16.0.110:8192:4:no"      # Control plane: 8GB RAM, 4 CPU, no 2nd disk
    # ["111"]="c2-w1:172.16.0.111:32768:8:yes"    # Worker 1: 32GB RAM, 8 CPU, 200GB 2nd disk
    # ["112"]="c2-w2:172.16.0.112:32768:8:yes"    # Worker 2: 32GB RAM, 8 CPU, 200GB 2nd disk
    # ["113"]="c2-w3:172.16.0.113:32768:8:yes"    # Worker 3: 32GB RAM, 8 CPU, 200GB 2nd disk
    
    # ["120"]="c3-c:172.16.0.120:8192:4:no"      # Control plane: 8GB RAM, 4 CPU, no 2nd disk
    # ["121"]="c3-w1:172.16.0.121:32768:8:yes"    # Worker 1: 32GB RAM, 8 CPU, 200GB 2nd disk
    # ["122"]="c3-w2:172.16.0.122:32768:8:yes"    # Worker 2: 32GB RAM, 8 CPU, 200GB 2nd disk
    # ["123"]="c3-w3:172.16.0.123:32768:8:yes"    # Worker 3: 32GB RAM, 8 CPU, 200GB 2nd disk
)
STORAGE_ID="vmdata"     # The storage ID we created earlier
BRIDGE_ID="vmbr0"       # The private network bridge (172.16.0.1)
CLOUD_IMAGE="/var/lib/vz/template/iso/debian-12-genericcloud-amd64.qcow2"

# Check if SSH keys exist

if [[ ! -f /root/.ssh/id_ed25519.pub ]]; then
    echo "❌ SSH key not found at /root/.ssh/id_ed25519.pub"
    exit 1
fi

if [[ ! -f /root/htz/mbpssh ]]; then
    echo "❌ SSH key not found at /root/SSH2"
    exit 1
fi

SSH_KEY1=$(cat /root/.ssh/id_ed25519.pub)
SSH_KEY2=$(cat /root/htz/mbpssh)

# Function to create a single VM
create_vm() {
    local VM_ID=$1
    local VM_NAME=$2
    local IP_ADDRESS=$3
    local MEMORY=$4
    local CORES=$5
    local SECOND_DISK=$6
    
    echo ""
    echo "🚀 Creating VM $VM_ID ($VM_NAME) with IP $IP_ADDRESS..."
    echo "   Memory: ${MEMORY}MB, Cores: $CORES, Second Disk: $SECOND_DISK"
    
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
  - zsh

# System configuration
ssh_pwauth: false
disable_root: false

# Services configuration
runcmd:
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

    # Create VM with minimal config
    echo "📦 Creating VM $VM_ID..."
    qm create $VM_ID \
        --name "$VM_NAME" \
        --memory $MEMORY \
        --balloon 0 \
        --cores $CORES \
        --cpu cputype=host \
        --net0 virtio,bridge=$BRIDGE_ID \
        --scsihw virtio-scsi-pci \
        --ostype l26

    if [[ $? -ne 0 ]]; then
        echo "❌ Failed to create VM $VM_ID"
        return 1
    fi

    # Import the cloud image disk
    echo "💾 Importing cloud image disk..."
    qm importdisk $VM_ID "$CLOUD_IMAGE" $STORAGE_ID
    
    if [[ $? -ne 0 ]]; then
        echo "❌ Failed to import disk for VM $VM_ID"
        return 1
    fi

    # Find the imported disk
    sleep 2
    DISK_PATH=$(pvesm list $STORAGE_ID | grep "vm-${VM_ID}-disk-0" | awk '{print $1}' | sed "s|${STORAGE_ID}:||")
    
    if [[ -z "$DISK_PATH" ]]; then
        echo "❌ Could not find imported disk for VM $VM_ID"
        pvesm list $STORAGE_ID | grep "vm-${VM_ID}"
        return 1
    fi
    
    echo "   Found disk: $DISK_PATH"

    # Attach the imported disk as scsi0
    echo "⚙️  Attaching boot disk..."
    qm set $VM_ID --scsi0 ${STORAGE_ID}:${DISK_PATH}
    
    if [[ $? -ne 0 ]]; then
        echo "❌ Failed to attach boot disk"
        return 1
    fi

    # Resize the boot disk to 50GB
    echo "📏 Resizing boot disk to 50GB..."
    qm resize $VM_ID scsi0 50G

    # Add second disk if required
    if [[ "$SECOND_DISK" == "yes" ]]; then
        echo "💾 Adding second SCSI disk (200GB)..."
        qm set $VM_ID --scsi1 ${STORAGE_ID}:200
        
        if [[ $? -eq 0 ]]; then
            echo "✅ Second disk (200GB) added as scsi1"
        else
            echo "❌ Failed to add second disk"
            return 1
        fi
    fi

    # Add cloud-init drive
    echo "☁️  Adding cloud-init drive..."
    qm set $VM_ID --ide2 ${STORAGE_ID}:cloudinit
    
    # Configure boot
    echo "⚙️  Configuring boot settings..."
    qm set $VM_ID --boot order=scsi0
    qm set $VM_ID --bootdisk scsi0
    
    # Configure serial console
    qm set $VM_ID --serial0 socket --vga serial0
    
    # Apply cloud-init network configuration
    echo "🌐 Configuring network..."
    qm set $VM_ID --ipconfig0 ip=${IP_ADDRESS}/24,gw=172.16.0.1
    qm set $VM_ID --nameserver 8.8.8.8
    qm set $VM_ID --searchdomain tarams.org
    
    # Apply custom cloud-init user-data
    qm set $VM_ID --cicustom "user=local:snippets/vm-${VM_ID}-user-data.yaml"
    
    # Enable qemu-guest-agent
    qm set $VM_ID --agent enabled=1

    # Verify configuration
    echo "🔍 Verifying VM configuration..."
    qm config $VM_ID | grep -E "^(scsi0|scsi1|boot|net0|ipconfig):"

    # Start VM
    echo "🚀 Starting VM $VM_ID..."
    qm start $VM_ID

    if [[ $? -eq 0 ]]; then
        echo "✅ VM $VM_ID ($VM_NAME) created successfully!"
        echo "   IP: $IP_ADDRESS"
        echo "   Memory: ${MEMORY}MB"
        echo "   Cores: $CORES"
        echo "   Second Disk: $SECOND_DISK"
    else
        echo "❌ Failed to start VM $VM_ID"
        return 1
    fi
    
    return 0
}

# Main execution
echo "🏗️  Multi-VM Creation Script"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Creating VMs with different configurations"
echo ""

# Create all VMs
FAILED_VMS=()
SUCCESSFUL_VMS=()

for VM_ID in "${(@k)VMS}"; do
    VM_CONFIG="${VMS[$VM_ID]}"
    IFS=':' read -A CONFIG_PARTS <<< "$VM_CONFIG"
    
    VM_NAME="${CONFIG_PARTS[1]}"
    IP_ADDRESS="${CONFIG_PARTS[2]}"
    MEMORY="${CONFIG_PARTS[3]}"
    CORES="${CONFIG_PARTS[4]}"
    SECOND_DISK="${CONFIG_PARTS[5]}"
    
    if create_vm "$VM_ID" "$VM_NAME" "$IP_ADDRESS" "$MEMORY" "$CORES" "$SECOND_DISK"; then
        SUCCESSFUL_VMS+=("$VM_ID ($VM_NAME)")
    else
        FAILED_VMS+=("$VM_ID ($VM_NAME)")
    fi
done

# Summary
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 CREATION SUMMARY"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ ${#SUCCESSFUL_VMS[@]} -gt 0 ]]; then
    echo "✅ Successfully created ${#SUCCESSFUL_VMS[@]} VM(s):"
    for vm in "${SUCCESSFUL_VMS[@]}"; do
        echo "   $vm"
    done
fi

if [[ ${#FAILED_VMS[@]} -gt 0 ]]; then
    echo "❌ Failed to create ${#FAILED_VMS[@]} VM(s):"
    for vm in "${FAILED_VMS[@]}"; do
        echo "   $vm"
    done
fi

echo ""
echo "⏱️  Wait 3-5 minutes for cloud-init to complete..."
echo "🧪 Test connectivity with: ssh debian@<IP>"
echo ""
echo "💾 VMs with second disk will have /dev/sdb (200GB, unformatted)"
echo "   Use 'lsblk' inside the VM to see all disks"

if [[ ${#FAILED_VMS[@]} -eq 0 ]]; then
    echo ""
    echo "🎉 All VMs created successfully!"
    exit 0
else
    echo ""
    echo "⚠️  Some VMs failed to create. Check the output above."
    exit 1
fi
