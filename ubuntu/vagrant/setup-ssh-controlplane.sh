#!/bin/bash

# Generate SSH keypair for the vagrant user on the controlplane node.
# The public key is written to /vagrant/ (the synced host folder) so that
# worker nodes can pick it up during their own provisioning step.

set -e

SSH_DIR="/home/vagrant/.ssh"
KEY_FILE="$SSH_DIR/id_ed25519"
PUB_RELAY="/vagrant/vagrant_controlplane.pub"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
chown vagrant:vagrant "$SSH_DIR"

if [ ! -f "$KEY_FILE" ]; then
    ssh-keygen -t ed25519 -N "" -f "$KEY_FILE" -C "vagrant@controlplane"
    chown vagrant:vagrant "$KEY_FILE" "${KEY_FILE}.pub"
fi

# Copy public key to shared folder so workers can install it
cp "${KEY_FILE}.pub" "$PUB_RELAY"
