#!/bin/zsh

TEMPLATE_ID=9000

qm create $TEMPLATE_ID \
  --name talos-template \
  --memory 4096 \
  --cores 2 \
  --net0 virtio,bridge=vmbr0 \
  --scsihw virtio-scsi-pci \
  --scsi0 vmdata:32 \
  --boot c --bootdisk scsi0 --agent 1

qm importdisk $TEMPLATE_ID talos-amd64.iso vmdata
qm set $TEMPLATE_ID --ide2 vmdata:cloudinit
qm set $TEMPLATE_ID --boot order=scsi0
qm template $TEMPLATE_ID
