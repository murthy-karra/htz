#!/bin/zsh

CONTROL_ID=200
qm clone 9000 $CONTROL_ID --name talos-cp-1 --full
qm set $CONTROL_ID --memory 16384 --cores 4
qm start $CONTROL_ID
