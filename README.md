# Kubernetes Lab

A hands-on Kubernetes lab environment using kubeadm. Choose the path that matches your hardware:

| Path | Best For |
|------|---------|
| [Vagrant](./vagrant/README.md) | Automatically spin up VMs on a host machine |
| [Bare Metal (Ubuntu)](./bare-metal-ubuntu/README.md) | Physical machines running Ubuntu in a home lab |

---

## Platform Support

### Vagrant

| Host OS | Provider | Cost |
|---------|---------|------|
| Intel/AMD Mac | VirtualBox | Free |
| Apple Silicon Mac | Parallels | ~$69/yr + free plugin |
| Apple Silicon Mac | VMware Fusion Pro | Free app + ~$79 one-time plugin |
| Linux | VirtualBox | Free |
| Windows | VirtualBox | Free |

> **Apple Silicon:** VirtualBox does not support ARM64. Vagrant requires a paid provider on Apple Silicon — see the [Vagrant guide](./vagrant/README.md) for details.

### Bare Metal (Ubuntu)

| Requirement | Details |
|-------------|---------|
| OS | Ubuntu 24.04 LTS (latest) |
| Architecture | x86_64 or ARM64 |
| Package manager | `apt` |

> The bare metal scripts are Ubuntu-specific. Any physical machine running Ubuntu 24.04 can be used as a node, regardless of architecture — including Apple Silicon Macs running Ubuntu (e.g. via [Asahi Linux](https://asahilinux.org/)).
>
> **Note:** The Vagrant path currently deploys Ubuntu 22.04 VMs (`ubuntu/jammy64`). There is no supported Ubuntu 24.04 Vagrant box at this time.

---

## Hardware Requirements

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| RAM | 8 GB | 16 GB |
| CPU | 4-core | 8-core |
| Disk | 50 GB free | — |

> For bare metal: requirements apply per node.

---

## Cluster Topology

Both paths set up the same layout:

| Node | Role |
|------|------|
| `controlplane` | Kubernetes control plane |
| `node01` | Worker node |
| `node02` | Worker node |
