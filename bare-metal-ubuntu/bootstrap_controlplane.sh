#!/bin/bash
echo "Bootstrapping latest Kubernetes 1.35 version"
echo "Starting containerd installation for Ubuntu/Debian..."
# Configure kernel modules
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter
# Configure sysctl parameters
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF
sudo sysctl --system
# Install containerd
sudo apt-get update
sudo apt-get -y install containerd
# Generate containerd configuration
sudo mkdir -p /etc/containerd
# Configure systemd cgroup driver and sandbox pause image default
containerd config default | sed 's/SystemdCgroup = false/SystemdCgroup = true/' | sed 's/pause:3.8/pause:3.10.1/' | sudo tee /etc/containerd/config.toml

# Start and enable containerd
sudo systemctl restart containerd
sudo systemctl enable containerd
echo "Containerd installation complete!"
sudo systemctl status containerd --no-pager

# Disable swapfile for kubelet
sudo swapoff -a
sudo sed -i '/\/swap.img/s/^/#/' /etc/fstab

# Install latest version of kubeadm, kubelet, kubectl
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gpg
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.35/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.35/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
sudo systemctl enable --now kubelet

sudo echo "serverTLSBootstrap: true" >> /var/lib/kubelet/config.yaml
sudo systemctl daemon-reload
sudo systemctl restart kubelet


# Get interface and ip address
INTERFACE="wlp0s20f3" # Replace with your interface name if different
IP_ADDRESS=$(ip addr show $INTERFACE | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)
echo "The IP address is: $IP_ADDRESS"

sudo kubeadm init --apiserver-advertise-address $IP_ADDRESS --pod-network-cidr "10.244.0.0/16" --upload-certs

mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown -R k8s:k8s $HOME/.kube

echo "source <(kubectl completion bash)" >> $HOME/.bashrc
echo "alias k=kubectl" >> $HOME/.bashrc
echo "complete -F __start_kubectl k" >> $HOME/.bashrc

source $HOME/.bashrc

#install flannel pod
sudo snap install yq
curl -LO https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
sleep 1
sudo chown k8s:k8s kube-flannel.yml
# yq -i '.spec.template.spec.containers[].args += "--iface=wlp0s20f3"' kube-flannel.yml
sleep 1
kubectl apply -f kube-flannel.yml

# Install metrics server pod, remove taint for single node cluster
read -rp "Installing metric server pod. Is this a single node cluster? [y/N]: " answer
if [[ "${answer,,}" =~ ^(y|yes)$ ]]; then
  echo "disabling controlplane node taint"
  kubectl taint nodes controlplane node-role.kubernetes.io/control-plane:NoSchedule-
fi
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# Prevent laptop from going to sleep when lid is closed (this is a server)
cat <<EOF | sudo tee -a /etc/systemd/logind.conf >/dev/null
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
EOF

sudo systemctl daemon-reload
sudo systemctl restart systemd-logind

echo "bootstrap completed! take note of the kubeadm join command if you have workernodes to deploy"