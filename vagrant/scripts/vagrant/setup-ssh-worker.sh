#!/bin/bash

# Install the controlplane's public key into this worker node's
# authorized_keys so that the vagrant user on controlplane can SSH in
# without a password.

set -e

PUB_RELAY="/vagrant/vagrant_controlplane.pub"
SSH_DIR="/home/vagrant/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"

if [ ! -f "$PUB_RELAY" ]; then
    echo "ERROR: $PUB_RELAY not found. Ensure controlplane is provisioned before worker nodes." >&2
    exit 1
fi

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
chown vagrant:vagrant "$SSH_DIR"

# Append only if not already present
if ! grep -qF "$(cat $PUB_RELAY)" "$AUTH_KEYS" 2>/dev/null; then
    cat "$PUB_RELAY" >> "$AUTH_KEYS"
fi

chmod 600 "$AUTH_KEYS"
chown vagrant:vagrant "$AUTH_KEYS"
