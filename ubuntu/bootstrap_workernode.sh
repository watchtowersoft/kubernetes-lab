## ALL NODES
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gpg
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.35/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.35/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update
sudo apt-get install -y containerd kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
sudo systemctl enable --now kubelet

#configure containerd
sudo mkdir /etc/containerd
containerd config default | sed 's/SystemdCgroup = false/SystemdCgroup = true/' | sed 's/pause:3.8/pause:3.10.1/' | sudo tee /etc/containerd/config.toml
sudo systemctl restart containerd

sudo modprobe br_netfilter
cat <<EOF | sudo tee /etc/sysctl.d/k8s-flannel.conf
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF

sudo sysctl --system

#sudo sysctl -w net.ipv4.ip_forward=1
#sudo nano /etc/sysctl.conf #net.ipv4.ip_forward = 1
#sudo sudo sysctl -p