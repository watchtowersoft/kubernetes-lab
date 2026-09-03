#!/bin/bash
set -e

# Usage: ./upgrade_kubernetes.sh [target-version]
# Example: ./upgrade_kubernetes.sh 1.37      (latest patch in the 1.37 line)
#          ./upgrade_kubernetes.sh 1.37.1    (that exact patch release)
#
# With no argument, the latest upstream releases are fetched from the
# kubernetes/kubernetes GitHub repo and you are prompted to pick a target —
# including patch-only upgrades within the line you are already on.
#
# Run this script on each node. Control plane must be upgraded before workers.
# Worker drain/uncordon steps must be run from the control plane.

TARGET_VERSION="${1}"

# Detect current installed version (major.minor.patch)
CURRENT_VERSION=$(kubelet --version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 | tr -d 'v')
CURRENT_MAJOR=$(echo "$CURRENT_VERSION" | cut -d. -f1)
CURRENT_MINOR=$(echo "$CURRENT_VERSION" | cut -d. -f2)
CURRENT_LINE="${CURRENT_MAJOR}.${CURRENT_MINOR}"

# Compare two X.Y.Z versions. Echoes -1 if $1 < $2, 0 if equal, 1 if $1 > $2.
version_cmp() {
  local a b
  IFS=. read -r -a a <<< "$1"
  IFS=. read -r -a b <<< "$2"
  for i in 0 1 2; do
    if (( ${a[i]:-0} < ${b[i]:-0} )); then echo -1; return; fi
    if (( ${a[i]:-0} > ${b[i]:-0} )); then echo 1; return; fi
  done
  echo 0
}

# Query the GitHub releases API for stable (non alpha/beta/rc) tags.
# Prints one full "major.minor.patch" per line, highest first.
fetch_upstream_releases() {
  curl -fsSL \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/kubernetes/kubernetes/releases?per_page=100" \
    | grep -oE '"tag_name": *"v[0-9]+\.[0-9]+\.[0-9]+"' \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' \
    | sort -t. -k1,1nr -k2,2nr -k3,3nr \
    | uniq
}

# Highest published patch release in a given X.Y line
latest_patch_in_line() {
  echo "$UPSTREAM_RELEASES" | grep -E "^${1//./\\.}\." | head -1
}

if [[ -z "$TARGET_VERSION" ]]; then
  if [[ -z "$CURRENT_VERSION" ]]; then
    echo "Error: no version given and the current kubelet version could not be detected."
    echo "  Usage: $0 <target-version>   (e.g. $0 1.37 or $0 1.37.1)"
    exit 1
  fi

  echo "Current version: v${CURRENT_VERSION}"
  echo "Fetching available releases from github.com/kubernetes/kubernetes ..."

  UPSTREAM_RELEASES=$(fetch_upstream_releases) || true
  if [[ -z "$UPSTREAM_RELEASES" ]]; then
    echo "Error: could not reach the GitHub releases API."
    echo "  Pass a version explicitly instead: $0 1.37"
    exit 1
  fi

  # Newest release overall
  LATEST=$(echo "$UPSTREAM_RELEASES" | head -1)

  # Newest patch in the line this node is already on — only offered if it is ahead
  LATEST_PATCH=$(latest_patch_in_line "$CURRENT_LINE")
  if [[ -n "$LATEST_PATCH" && "$(version_cmp "$LATEST_PATCH" "$CURRENT_VERSION")" != "1" ]]; then
    LATEST_PATCH=""
  fi

  # The next sequential minor — the only hop kubeadm supports in a single run
  NEXT_MINOR=$(latest_patch_in_line "${CURRENT_MAJOR}.$((CURRENT_MINOR + 1))")

  echo ""
  echo "Latest upstream release: v${LATEST}"
  echo ""
  echo "Choose a target:"
  if [[ -n "$LATEST_PATCH" ]]; then
    echo "  1) Latest patch  v${LATEST_PATCH}  (same ${CURRENT_LINE} line — safest, picks up fixes)"
  else
    echo "  1) Latest patch  — already on the newest patch in the ${CURRENT_LINE} line"
  fi
  if [[ -n "$NEXT_MINOR" ]]; then
    echo "  2) Next minor    v${NEXT_MINOR}  (recommended for a version bump — kubeadm only supports one minor per upgrade)"
  else
    echo "  2) Next minor    — no ${CURRENT_MAJOR}.$((CURRENT_MINOR + 1)) release published yet"
  fi
  echo "  3) Latest minor  v${LATEST}"
  echo "  4) Enter a version manually"
  echo "  q) Quit"
  echo ""
  read -rp "Selection: " selection

  case "$selection" in
    1)
      if [[ -z "$LATEST_PATCH" ]]; then
        echo "Already on the newest patch in the ${CURRENT_LINE} line — nothing to do."
        exit 0
      fi
      TARGET_VERSION="$LATEST_PATCH"
      ;;
    2)
      if [[ -z "$NEXT_MINOR" ]]; then
        echo "No next minor release is published yet — already on the newest line."
        exit 0
      fi
      TARGET_VERSION="$NEXT_MINOR"
      ;;
    3) TARGET_VERSION="$LATEST" ;;
    4) read -rp "Target version (e.g. 1.37 or 1.37.1): " TARGET_VERSION ;;
    q|Q) echo "Aborted."; exit 0 ;;
    *) echo "Invalid selection."; exit 1 ;;
  esac
fi

# Validate format: X.Y (release line) or X.Y.Z (exact patch release)
if [[ ! "$TARGET_VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
  echo "Error: version must be X.Y or X.Y.Z (e.g. 1.37 or 1.37.1)"
  exit 1
fi

TARGET_MAJOR=$(echo "$TARGET_VERSION" | cut -d. -f1)
TARGET_MINOR=$(echo "$TARGET_VERSION" | cut -d. -f2)
TARGET_LINE="${TARGET_MAJOR}.${TARGET_MINOR}"

# A bare X.Y means "newest patch in that line" — resolve it so the guards and the
# apt pin below have a concrete version to work with.
TARGET_PATCH=$(echo "$TARGET_VERSION" | cut -d. -f3)
if [[ -z "$TARGET_PATCH" ]]; then
  [[ -z "${UPSTREAM_RELEASES:-}" ]] && UPSTREAM_RELEASES=$(fetch_upstream_releases 2>/dev/null) || true
  RESOLVED=$(latest_patch_in_line "$TARGET_LINE")
  if [[ -n "$RESOLVED" ]]; then
    echo "Resolved v${TARGET_VERSION} to latest patch v${RESOLVED}"
    TARGET_VERSION="$RESOLVED"
  else
    # Could not reach GitHub — fall back to whatever apt offers in that line
    echo "Note: could not resolve a patch release for v${TARGET_VERSION}; apt will pick the newest available."
  fi
fi

# Guard against downgrade/same version
if [[ -z "$CURRENT_VERSION" ]]; then
  echo "Warning: could not detect current kubelet version — proceeding anyway."
elif [[ "$TARGET_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  if [[ "$(version_cmp "$TARGET_VERSION" "$CURRENT_VERSION")" != "1" ]]; then
    echo "Error: target v${TARGET_VERSION} is not an upgrade over current v${CURRENT_VERSION}."
    echo "This script only supports moving forward."
    exit 1
  fi
elif (( TARGET_MAJOR < CURRENT_MAJOR )) \
  || { (( TARGET_MAJOR == CURRENT_MAJOR )) && (( TARGET_MINOR < CURRENT_MINOR )); }; then
  echo "Error: target v${TARGET_VERSION} is not an upgrade over current v${CURRENT_VERSION}."
  exit 1
fi

# Warn when the jump skips minor releases — kubeadm refuses more than one at a time
if [[ -n "$CURRENT_VERSION" ]]; then
  if (( TARGET_MAJOR > CURRENT_MAJOR )); then
    echo ""
    echo "WARNING: v${CURRENT_VERSION} → v${TARGET_VERSION} crosses a major version."
    read -rp "Continue anyway? [y/N]: " skip_confirm
    [[ "$skip_confirm" =~ ^([yY]|[yY][eE][sS])$ ]] || { echo "Aborted."; exit 1; }
  elif (( TARGET_MINOR - CURRENT_MINOR > 1 )); then
    echo ""
    echo "WARNING: v${CURRENT_VERSION} → v${TARGET_VERSION} skips $((TARGET_MINOR - CURRENT_MINOR - 1)) minor release(s)."
    echo "kubeadm only supports upgrading one minor version at a time; this will likely fail."
    echo "Upgrade to v${CURRENT_MAJOR}.$((CURRENT_MINOR + 1)) first, then repeat."
    read -rp "Continue anyway? [y/N]: " skip_confirm
    [[ "$skip_confirm" =~ ^([yY]|[yY][eE][sS])$ ]] || { echo "Aborted."; exit 1; }
  fi
fi

if [[ "$TARGET_LINE" == "$CURRENT_LINE" ]]; then
  UPGRADE_KIND="patch"
else
  UPGRADE_KIND="minor"
fi

echo "Current version: v${CURRENT_VERSION}  →  Target: v${TARGET_VERSION}  (${UPGRADE_KIND} upgrade)"

# Detect node role by presence of static pod manifests
if [[ -f /etc/kubernetes/manifests/kube-apiserver.yaml ]]; then
  NODE_ROLE="controlplane"
else
  NODE_ROLE="worker"
fi

echo "=== Kubernetes Upgrade to v${TARGET_VERSION} ==="
echo "Node role: $NODE_ROLE"
echo ""

# Update apt keyring and repo — pkgs.k8s.io is organised by release line, and
# every patch in that line lives in the same repo.
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${TARGET_LINE}/deb/Release.key" \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${TARGET_LINE}/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update

# Resolve the exact deb version for the target patch (e.g. 1.37.1 -> 1.37.1-1.1)
# so a patch-level target is honoured rather than silently taking the newest.
PKG_SUFFIX=""
if [[ "$TARGET_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  PKG_VERSION=$(apt-cache madison kubeadm 2>/dev/null | awk '{print $3}' \
    | grep -E "^${TARGET_VERSION//./\\.}-" | head -1)
  if [[ -n "$PKG_VERSION" ]]; then
    PKG_SUFFIX="=${PKG_VERSION}"
    echo "Pinning packages to deb version ${PKG_VERSION}"
  else
    echo "Note: deb package for v${TARGET_VERSION} not found in the repo; installing newest in the ${TARGET_LINE} line."
  fi
fi

# Upgrade kubeadm — same first step for both roles
sudo apt-mark unhold kubeadm
sudo apt-get install -y "kubeadm${PKG_SUFFIX}"
sudo apt-mark hold kubeadm

APPLY_VERSION=$(kubeadm version -o short)
echo "kubeadm upgraded to: $APPLY_VERSION"
echo ""

if [[ "$NODE_ROLE" == "controlplane" ]]; then
  echo "--- Upgrade plan ---"
  sudo kubeadm upgrade plan
  echo ""

  read -rp "Apply upgrade to ${APPLY_VERSION}? [y/N]: " confirm
  if [[ ! "$confirm" =~ ^([yY]|[yY][eE][sS])$ ]]; then
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
  sudo apt-get install -y "kubelet${PKG_SUFFIX}" "kubectl${PKG_SUFFIX}"
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
  sudo apt-get install -y "kubelet${PKG_SUFFIX}" "kubectl${PKG_SUFFIX}"
  sudo apt-mark hold kubelet kubectl

  sudo systemctl daemon-reload
  sudo systemctl restart kubelet

  echo ""
  echo "Worker node upgrade complete. Uncordon from the control plane:"
  echo "  kubectl uncordon $(hostname)"
fi

echo ""
echo "=== Upgrade to ${APPLY_VERSION} complete ==="
