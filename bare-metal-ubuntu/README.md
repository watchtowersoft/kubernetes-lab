# Kubernetes Lab — Bare Metal (Ubuntu)

Sets up a Kubernetes cluster on physical hosts using kubeadm.

> **Requirements:** All nodes must be running **Ubuntu 24.04 LTS**. The scripts in this directory use `apt` and are Ubuntu-specific. If your machines are running a different OS, this path will not work as-is.
>
> Any architecture supported by Ubuntu 22.04 is compatible — including x86_64 and ARM64. Apple Silicon Macs running Ubuntu (e.g. via [Asahi Linux](https://asahilinux.org/)) can be used as nodes.

---

## Prerequisites

### Hardware

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| RAM (per node) | 2 GB | 4 GB+ |
| CPU (per node) | 2-core | 4-core |
| Disk (per node) | 20 GB free | — |

### Hosts

- **Ubuntu 24.04 LTS** installed on each host
- Each host must be reachable over SSH from your admin machine
- Hosts must be able to reach each other over the network

### Admin Machine

- **git** — used to clone this repo
- SSH access to all nodes

---

## Cluster Layout

| Node | Role | Notes |
|------|------|-------|
| `controlplane` | Kubernetes control plane | At least 2 CPU, 2 GB RAM |
| `node01` | Worker node | |
| `node02` | Worker node | Add more by repeating the worker steps |

You can start with a single machine acting as both controlplane and worker (using `kubectl taint` to allow scheduling on the controlplane), then add nodes as hardware allows.

---

## Quick Start

```bash
git clone https://github.com/watchtowersoft/kubernetes-lab.git
cd kubernetes-lab/bare-metal
```

### 1. Prepare Each Host

Run the node setup script on **every host** (controlplane and workers):

```bash
scp setup-node.sh <user>@<host>:~
ssh <user>@<host> "bash ~/setup-node.sh"
```

### 2. Bootstrap the Control Plane

SSH into `controlplane` and run:

```bash
scp bootstrap-controlplane.sh <user>@controlplane:~
ssh <user>@controlplane "bash ~/bootstrap-controlplane.sh"
```

At the end of the script, kubeadm will print a `kubeadm join` command. Copy it — you'll need it for the worker nodes.

### 3. Bootstrap the Worker Nodes

SSH into each worker and run the `kubeadm join` command printed in the previous step:

```bash
ssh <user>@node01
# paste the kubeadm join command here
```

Repeat for each additional worker node.

### 4. Verify the Cluster

From `controlplane`:

```bash
kubectl get nodes
```

All nodes should show `Ready` status within a few minutes.

---

## SSH Access

SSH into any node directly from your admin machine:

```bash
ssh <user>@controlplane
ssh <user>@node01
ssh <user>@node02
```

---

## Node-to-Node SSH

Set up passwordless SSH from `controlplane` to the worker nodes:

```bash
# Run on controlplane
ssh-keygen   # accept all defaults

ssh-copy-id -o StrictHostKeyChecking=no <user>@node01
ssh-copy-id -o StrictHostKeyChecking=no <user>@node02
```

---

## Running Commands Across Multiple Nodes

### tmux

1. SSH into `controlplane` and start a tmux session: `tmux`
2. Split the window into panes: `CTRL+B` then `"`
3. SSH to worker nodes from each additional pane
4. Enable pane sync: `CTRL+B` then `:setw synchronize-panes on`
5. Disable sync: `CTRL+B` then `:setw synchronize-panes off`

### iTerm2 (macOS)

Use *Shell → Broadcast Input → Broadcast to All Panes in All Tabs* to send keystrokes to all open panes simultaneously.

---

## Networking

Kubernetes components need to bind to the correct network interface — especially if your hosts have multiple NICs or a loopback-only config.

Identify the primary interface IP on each host:

```bash
ip route | grep default | awk '{ print $9 }'
```

Use this IP when configuring kubeadm's `--apiserver-advertise-address` and throughout the lab.

| Network | CIDR |
|---------|------|
| Pod network | `10.244.0.0/16` |
| Service network | `10.96.0.0/16` |

These should not overlap with your host network.
