#!/bin/bash
set -e

# Usage: ./upgrade_kubernetes.sh <target-minor-version>
# Example: ./upgrade_kubernetes.sh 1.37
#
# Run this script on each node. Control plane must be upgraded before workers.
# Worker drain/uncordon steps must be run from the control plane.

TARGET_VERSION="${1}"

if [[ -z "$TARGET_VERSION" ]]; then
  echo "Usage: $0 <target-minor-version>"
  echo "  Example: $0 1.37"
  exit 1
fi

# Validate format: must be 1.XX (e.g. 1.36, 1.37)
if [[ ! "$TARGET_VERSION" =~ ^1\.[0-9]+$ ]]; then
  echo "Error: version must be in the format 1.XX (e.g. 1.37)"
  exit 1
fi

# Detect current installed minor version and guard against downgrade/same
CURRENT_VERSION=$(kubelet --version 2>/dev/null | grep -oP '(?<=v1\.)\d+' | head -1)
TARGET_MINOR=$(echo "$TARGET_VERSION" | cut -d. -f2)

if [[ -z "$CURRENT_VERSION" ]]; then
  echo "Warning: could not detect current kubelet version — proceeding anyway."
elif [[ "$TARGET_MINOR" -le "$CURRENT_VERSION" ]]; then
  echo "Error: target v${TARGET_VERSION} is not an upgrade over current v1.${CURRENT_VERSION}."
  echo "This script only supports moving forward to a higher minor version."
  exit 1
fi

echo "Current version: v1.${CURRENT_VERSION}  →  Target: v${TARGET_VERSION}"

# Detect node role by presence of static pod manifests
if [[ -f /etc/kubernetes/manifests/kube-apiserver.yaml ]]; then
  NODE_ROLE="controlplane"
else
  NODE_ROLE="worker"
fi

echo "=== Kubernetes Upgrade to v${TARGET_VERSION} ==="
echo "Node role: $NODE_ROLE"
echo ""

# Update apt keyring and repo to the target minor version
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${TARGET_VERSION}/deb/Release.key" \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${TARGET_VERSION}/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update

# Upgrade kubeadm — same first step for both roles
sudo apt-mark unhold kubeadm
sudo apt-get install -y kubeadm
sudo apt-mark hold kubeadm

APPLY_VERSION=$(kubeadm version -o short)
echo "kubeadm upgraded to: $APPLY_VERSION"
echo ""

if [[ "$NODE_ROLE" == "controlplane" ]]; then
  echo "--- Upgrade plan ---"
  sudo kubeadm upgrade plan
  echo ""

  read -rp "Apply upgrade to ${APPLY_VERSION}? [y/N]: " confirm
  if [[ ! "${confirm,,}" =~ ^(y|yes)$ ]]; then
    echo "Upgrade aborted."
    exit 1
  fi

  sudo kubeadm upgrade apply "$APPLY_VERSION" --yes

  # Resolve node name by matching this host's primary IP
  NODE_NAME=$(kubectl get nodes -o wide --no-headers \
    | awk -v ip="$(hostname -I | awk '{print $1}')" '$6==ip {print $1}')
  [[ -z "$NODE_NAME" ]] && NODE_NAME=$(hostname)

  echo "Draining node: $NODE_NAME"
  kubectl drain "$NODE_NAME" --ignore-daemonsets --delete-emptydir-data

  sudo apt-mark unhold kubelet kubectl
  sudo apt-get install -y kubelet kubectl
  sudo apt-mark hold kubelet kubectl

  sudo systemctl daemon-reload
  sudo systemctl restart kubelet

  kubectl uncordon "$NODE_NAME"

  echo ""
  echo "Control plane upgrade complete."
  kubectl get nodes

else
  # Upgrade node configuration on the worker
  sudo kubeadm upgrade node

  echo ""
  echo "Drain this node from the control plane before proceeding:"
  echo "  kubectl drain $(hostname) --ignore-daemonsets --delete-emptydir-data"
  read -rp "Press Enter once the node has been drained from the control plane..."

  sudo apt-mark unhold kubelet kubectl
  sudo apt-get install -y kubelet kubectl
  sudo apt-mark hold kubelet kubectl

  sudo systemctl daemon-reload
  sudo systemctl restart kubelet

  echo ""
  echo "Worker node upgrade complete. Uncordon from the control plane:"
  echo "  kubectl uncordon $(hostname)"
fi

echo ""
echo "=== Upgrade to ${APPLY_VERSION} complete ==="
