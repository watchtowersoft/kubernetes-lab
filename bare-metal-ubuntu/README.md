# Kubernetes Lab — Bare Metal

Sets up a Kubernetes cluster on physical Ubuntu hosts using kubeadm. Ideal for home labs and Apple Silicon Macs where VirtualBox is not an option.

---

## Prerequisites

### Hardware

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| RAM (per node) | 2 GB | 4 GB+ |
| CPU (per node) | 2-core | 4-core |
| Disk (per node) | 20 GB free | — |

### Hosts

- **Ubuntu 22.04 LTS** installed on each host
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
cd kubernetes-lab/bare-metal-ubuntu
```

### 1. Bootstrap the Control Plane

Copy and run the script on your `controlplane` host:

```bash
scp bootstrap_controlplane.sh graceful_shutdown.sh <user>@controlplane:~
ssh <user>@controlplane "bash ~/bootstrap_controlplane.sh"
```

At the end of the script, kubeadm will print a `kubeadm join` command. Copy it — you'll need it for the worker nodes.

### 2. Bootstrap the Worker Nodes

Copy and run the worker script on each worker node:

```bash
scp bootstrap_workernode.sh graceful_shutdown.sh <user>@node01:~
ssh <user>@node01 "bash ~/bootstrap_workernode.sh"
```

Then run the `kubeadm join` command from the previous step:

```bash
ssh <user>@node01
# paste the kubeadm join command here
```

Repeat for each additional worker node.

### 3. Verify the Cluster

From `controlplane`:

```bash
kubectl get nodes
```

All nodes should show `Ready` status within a few minutes.

---

## Reboots

By default a rebooting node kills its pods without warning and leaves them behind in a terminated state. On a single-node cluster nothing else can pick the workload up, so `graceful_shutdown.sh` configures the node to terminate pods cleanly first. The bootstrap scripts run it when it sits next to them; it is safe to re-run on any node at any time, including a cluster built before the script existed:

```bash
./graceful_shutdown.sh           # apply
./graceful_shutdown.sh --check   # report drift only, exit 1 if any
```

### What it manages

| Setting | Where | Why |
|---------|-------|-----|
| `shutdownGracePeriod: 2m0s`, `shutdownGracePeriodCriticalPods: 30s` | `/var/lib/kubelet/config.yaml` and the `kubelet-config` ConfigMap | Kubelet delays shutdown and terminates pods in order |
| `InhibitDelayMaxSec=120` | `/etc/systemd/logind.conf.d/unattended-upgrades-logind-maxdelay.conf` | logind must allow a delay as long as the kubelet's grace period |
| `--terminated-pod-gc-threshold=1` | `kube-controller-manager` static pod manifest and the `kubeadm-config` ConfigMap | Cleans up the terminated pods a shutdown leaves behind |
| `unattended-upgrades` purged, `apt-daily` timers disabled | Host | Nothing upgrades or restarts packages on its own schedule |
| `kubelet`, `kubeadm`, `kubectl`, `containerd` held | apt | These only change through the procedures below |

The two ConfigMaps (written on control plane nodes only) are the part that makes this stick: `kubeadm upgrade` regenerates the kubelet config and the static pod manifests from them, so settings that exist only in the node's files disappear on the next upgrade without any error. `upgrade_kubernetes.sh` runs the `--check` at the end for that reason.

The logind file keeps that odd name on purpose. The `unattended-upgrades` package ships a drop-in of the same name in `/usr/lib/systemd/logind.conf.d` that forces 30s, and because drop-ins are merged in filename order it beats the kubelet's own `99-kubelet.conf`. A file of the same name in `/etc` masks it, and keeps masking it if the package ever comes back.

With automatic upgrades off, OS patching is manual: run `sudo apt-get update && sudo apt-get upgrade` yourself on a schedule you choose.

### Reboot procedure

```bash
./graceful_shutdown.sh --check   # must be clean — do not reboot on drift
sudo systemctl reboot
```

Use `systemctl reboot` (or `shutdown -r`). Anything that bypasses logind, such as `reboot -f` or holding the power button, skips the grace period.

### Post-boot checks

```bash
kubectl get nodes                                         # Ready
kubectl get pods -A --field-selector status.phase!=Running   # nothing left over from before the reboot
./graceful_shutdown.sh --check                            # kubelet has its inhibitor lock again
```

### Upgrading containerd on its own

`upgrade_kubernetes.sh` upgrades containerd together with the kubelet. To upgrade it separately:

```bash
sudo apt-mark unhold containerd
sudo apt-get update && sudo apt-get install -y containerd
sudo crictl info >/dev/null && echo "runtime ok"
grep SystemdCgroup /etc/containerd/config.toml            # must still be true
sudo apt-mark hold containerd
```

Then reboot using the procedure above.

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
