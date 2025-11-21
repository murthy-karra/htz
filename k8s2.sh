#!/usr/bin/env zsh

# Multi-VM Creation Script with Cloud-Init
# Usage: ./create-multi-vm.zsh

# --- CONFIGURATION ---
STORAGE_ID="vmdata"     # The storage ID we created earlier
BRIDGE_ID="vmbr1"       # The private network bridge (172.16.0.1)
CLOUD_IMAGE="/var/lib/vz/template/iso/debian-12-genericcloud-amd64.qcow2"

# VM Definitions: "Name:IP:RAM:Cores:AddSecondDisk(yes/no)"
declare -A VMS=(
    #["100"]="c1-c:172.16.0.100:8192:4:no"      # Control plane
    ["101"]="c1-w1:172.16.0.101:32768:8:yes"    # Worker 1
    #["102"]="c1-w2:172.16.0.102:32768:8:yes"    # Worker 2
    #["103"]="c1-w3:172.16.0.103:32768:8:yes"    # Worker 3
)

# --- PRE-FLIGHT CHECKS ---
if [[ ! -f "$CLOUD_IMAGE" ]]; then
    echo "❌ Cloud image not found at $CLOUD_IMAGE"
    echo "   Run: cd /var/lib/vz/template/iso/ && wget https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
    exit 1
fi

# SSH Key checks (Adjust paths if needed)
if [[ ! -f /root/.ssh/id_ed25519.pub ]]; then
    echo "❌ SSH key not found at /root/.ssh/id_ed25519.pub"
    exit 1
fi

SSH_KEY1=$(cat /root/.ssh/id_ed25519.pub)
# Handling optional second key gracefully
if [[ -f /root/htz/mbpssh ]]; then
    SSH_KEY2=$(cat /root/htz/mbpssh)
else
    SSH_KEY2=""
fi

# --- FUNCTION ---
create_vm() {
    local VM_ID=$1
    local VM_NAME=$2
    local IP_ADDRESS=$3
    local MEMORY=$4
    local CORES=$5
    local SECOND_DISK=$6
    
    echo ""
    echo "🚀 Creating VM $VM_ID ($VM_NAME) on $STORAGE_ID..."
    
    # 1. Create Cloud-Init User Data
    CLOUDINIT_FILE="/var/lib/vz/snippets/vm-${VM_ID}-user-data.yaml"
    mkdir -p /var/lib/vz/snippets

    cat > "$CLOUDINIT_FILE" << EOF
#cloud-config
hostname: $VM_NAME
fqdn: ${VM_NAME}.tarams.org
package_update: true
package_upgrade: true
users:
  - name: debian
    groups: sudo
    shell: /bin/bash
    sudo: ['ALL=(ALL) NOPASSWD:ALL']
    ssh_authorized_keys:
      - $SSH_KEY1
      - $SSH_KEY2
packages:
  - openssh-server
  - curl
  - htop
  - zsh
ssh_pwauth: false
runcmd:
  - systemctl enable ssh
  - systemctl start ssh
final_message: "Ready on $IP_ADDRESS"
power_state:
  mode: reboot
  delay: 1
  condition: true
EOF

    # 2. Cleanup Old VM
    if qm status $VM_ID &>/dev/null; then
        echo "🔄 Destroying old VM $VM_ID..."
        qm stop $VM_ID 2>/dev/null
        qm destroy $VM_ID --purge 2>/dev/null
    fi

    # 3. Create VM Skeleton
    qm create $VM_ID \
        --name "$VM_NAME" \
        --net0 virtio,bridge=$BRIDGE_ID \
        --ostype l26 \
        --memory $MEMORY \
        --balloon 0 \
        --cores $CORES \
        --cpu cputype=host \
        --scsihw virtio-scsi-pci

    # 4. Import and Attach OS Disk
    echo "💾 Importing OS disk to $STORAGE_ID..."
    qm importdisk $VM_ID "$CLOUD_IMAGE" $STORAGE_ID
    
    # Attach the imported disk (it usually gets named vm-ID-disk-0)
    qm set $VM_ID --scsi0 $STORAGE_ID:vm-$VM_ID-disk-0
    
    # Resize OS disk to 50GB (+48G because base image is ~2G)
    qm resize $VM_ID scsi0 +48G

    # 5. Setup Cloud-Init Drive
    qm set $VM_ID --ide2 $STORAGE_ID:cloudinit
    
    # 6. Boot Options & Serial Console
    qm set $VM_ID --boot c --bootdisk scsi0
    qm set $VM_ID --serial0 socket --vga serial0
    qm set $VM_ID --agent enabled=1

    # 7. Add Second Disk (if requested)
    if [[ "$SECOND_DISK" == "yes" ]]; then
        echo "💾 Creating 200GB Data Disk on $STORAGE_ID..."
        # Create a 200GB disk on scsi1
        qm set $VM_ID --scsi1 $STORAGE_ID:200
    fi

    # 8. Apply Network & Cloud-Init
    # Note: Gateway set to 172.16.0.1 (Proxmox Host)
    qm set $VM_ID --cicustom "user=local:snippets/vm-${VM_ID}-user-data.yaml"
    qm set $VM_ID --ipconfig0 ip=${IP_ADDRESS}/24,gw=172.16.0.1
    qm set $VM_ID --nameserver 8.8.8.8

    # 9. Start
    qm start $VM_ID
    echo "✅ Started VM $VM_ID"
}

# --- EXECUTION ---
echo "🏗️  Starting Multi-VM Build on storage: $STORAGE_ID"

for VM_ID in "${(@k)VMS}"; do
    VM_CONFIG="${VMS[$VM_ID]}"
    IFS=':' read -A CONFIG_PARTS <<< "$VM_CONFIG"
    
    create_vm "$VM_ID" "${CONFIG_PARTS[1]}" "${CONFIG_PARTS[2]}" "${CONFIG_PARTS[3]}" "${CONFIG_PARTS[4]}" "${CONFIG_PARTS[5]}"
done

echo "🎉 Done! Wait ~2 minutes for Cloud-Init to finish."