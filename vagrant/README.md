# Kubernetes Lab — Vagrant

Automatically provisions a 3-node Kubernetes cluster (`controlplane`, `node01`, `node02`) using VMs.

> **VM OS:** Vagrant currently deploys **Ubuntu 22.04 LTS** (`ubuntu/jammy64`). There is no supported Ubuntu 24.04 Vagrant box at this time.

---

## Prerequisites

### Platform Support

| Platform | Provider | Cost |
|----------|---------|------|
| Intel/AMD Mac | VirtualBox | Free |
| Apple Silicon Mac | Parallels | ~$69/yr + free plugin |
| Apple Silicon Mac | VMware Fusion Pro | Free app + ~$79 one-time plugin |
| Linux | VirtualBox | Free |
| Windows | VirtualBox | Free |

> **Apple Silicon:** VirtualBox does not support ARM64. You must use either Parallels or VMware Fusion — both require a purchase for the Vagrant plugin. If you have physical Ubuntu machines available, the [bare metal path](../bare-metal-ubuntu/README.md) is a free alternative.

### Hardware

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| RAM | 8 GB | 16 GB |
| CPU | 4-core | 8-core |
| Disk | 50 GB free | — |

### Software

**Intel/AMD (all platforms):**
- **git** — pre-installed on Mac/Linux; [download](https://git-scm.com/download) for Windows
- **VirtualBox 7.x** — [Download](https://www.virtualbox.org/wiki/Downloads)
- **Vagrant 2.4+** — [Download](https://www.vagrantup.com/)

**Apple Silicon — Parallels:**
- **Parallels Desktop** — [Download](https://www.parallels.com/) (~$69/yr)
- **Vagrant 2.4+** — [Download](https://www.vagrantup.com/)
- **vagrant-parallels plugin** (free):
```bash
vagrant plugin install vagrant-parallels
```

**Apple Silicon — VMware Fusion:**
- **VMware Fusion Pro** — [Download](https://www.vmware.com/products/desktop-hypervisor/workstation-and-fusion) (free for personal use)
- **Vagrant 2.4+** — [Download](https://www.vagrantup.com/)
- **vagrant-vmware-desktop plugin** (~$79 one-time, includes license):
```bash
vagrant plugin install vagrant-vmware-desktop
```

---

## Quick Start

**Intel/AMD — VirtualBox (default):**
```bash
git clone https://github.com/watchtowersoft/kubernetes-lab.git
cd kubernetes-lab/vagrant
vagrant up
```

**Apple Silicon — Parallels:**
```bash
git clone https://github.com/watchtowersoft/kubernetes-lab.git
cd kubernetes-lab/vagrant
vagrant up --provider=parallels
```

**Apple Silicon — VMware Fusion:**
```bash
git clone https://github.com/watchtowersoft/kubernetes-lab.git
cd kubernetes-lab/vagrant
vagrant up --provider=vmware_desktop
```

Vagrant will provision the VMs. At the end it will print instructions for accessing NodePort services from your browser — make a note of this output.

---

## Networking

### Bridge vs NAT Mode

By default the VMs bridge to your local network (`BUILD_MODE = "BRIDGE"`), which allows you to reach NodePort services directly from your browser.

If Vagrant can't determine your network interface automatically, it will prompt you to choose. Pick the interface connected to your router — typically Wi-Fi on a laptop or wired Ethernet on a desktop. Avoid virtual adapters (Hyper-V, VMware, etc.).

If bridge mode causes issues, switch to NAT:

```bash
vagrant destroy -f
# Edit Vagrantfile line 10: BUILD_MODE = "BRIDGE"  →  BUILD_MODE = "NAT"
vagrant up
```

> In NAT mode, NodePort services are not reachable from your browser without manually configuring port forwarding in VirtualBox.

### Network Defaults

These are set at provisioning time. Changing them after VMs are up requires a full reset (`vagrant destroy -f && vagrant up`).

| Network | CIDR |
|---------|------|
| VM (NAT mode) | `192.168.56.0/24` |
| Pod network | `10.244.0.0/16` |
| Service network | `10.96.0.0/16` |

**Changing CIDRs:**
- VM network: Edit `Vagrantfile` line 17
- Pod network: Global find/replace `POD_CIDR=10.244.0.0/16` across `docs/`
- Service network: Global find/replace `SERVICE_CIDR=10.96.0.0/16` across `docs/`

None of these ranges should overlap. Don't submit a PR for personal network preference changes.

### `PRIMARY_IP`

Each VM has a `PRIMARY_IP` env variable set to the IP of the interface Kubernetes should bind to (the internal adapter, not the NAT one). This is used throughout the lab to ensure components bind to the right interface.

---

## SSH Access

### Option 1: Vagrant (easiest)

```bash
# Run from the vagrant/ directory
vagrant ssh controlplane
vagrant ssh node01
vagrant ssh node02
```

### Option 2: SSH client (PuTTY, MobaXTerm, etc.)

- **Username:** `vagrant`
- **Private key:** `.vagrant/machines/<vm-name>/<provider>/private_key`
  - VirtualBox: `.vagrant/machines/<vm-name>/virtualbox/private_key`
  - Parallels: `.vagrant/machines/<vm-name>/parallels/private_key`
  - VMware: `.vagrant/machines/<vm-name>/vmware_desktop/private_key`
- **Host:** IP address assigned to the VM

Password auth is disabled by default.

---

## Node-to-Node SSH

Set up passwordless SSH from `controlplane` to the worker nodes so you can copy files between them:

```bash
# Run on controlplane
ssh-keygen   # accept all defaults

ssh-copy-id -o StrictHostKeyChecking=no vagrant@node01
ssh-copy-id -o StrictHostKeyChecking=no vagrant@node02
```

Enter `vagrant` when prompted for a password. Confirm each returns `Number of key(s) added: 1`.

---

## Running Commands Across Multiple Nodes

Use `tmux` to run commands on multiple nodes simultaneously.

1. SSH into `controlplane` and start a tmux session
2. Split the window into panes (`CTRL+B` then `"`)
3. SSH to worker nodes from each additional pane
4. Press `CTRL+X` to enable pane sync — the dividing line turns red
5. Press `CTRL+X` again to disable sync

> To paste into a tmux pane: `SHIFT+RightMouseButton`

The `.tmux.conf` with the `CTRL+X` binding is automatically loaded onto the controlplane VM by the Vagrant provisioner.

---

## Lifecycle

```bash
vagrant halt        # graceful shutdown
vagrant up          # bring back up
vagrant destroy -f  # tear everything down
```

---

## Troubleshooting

**VM failed to provision:**
```bash
vagrant destroy <vm>
vagrant up
```

**VirtualBox VERR_ALREADY_EXISTS error:**
```bash
vagrant destroy <vm>
rmdir "<VirtualBox VMs path>\<vm>"
vagrant up
```

**Stuck at "Waiting for machine to reboot":**
1. `CTRL+C` to break out
2. Kill any running `ruby` process
3. `vagrant destroy <vm> && vagrant up`
