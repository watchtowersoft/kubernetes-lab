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


## ONLY ON CONTROL PLANE
INTERFACE="enp0s8" # Replace with your interface name if different
IP_ADDRESS=$(ip addr show $INTERFACE | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)
echo "The IP address is: $IP_ADDRESS"

sudo kubeadm init --apiserver-advertise-address $IP_ADDRESS --pod-network-cidr "10.244.0.0/16" --upload-certs

mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown -R vagrant:vagrant $HOME/.kube

echo "source <(kubectl completion bash)" >> /home/vagrant/.bashrc
echo "alias k=kubectl" >> /home/vagrant/.bashrc
echo "complete -F __start_kubectl k" >> /home/vagrant/.bashrc

echo "source <(kubectl completion bash)" >> $HOME/.bashrc
echo "alias k=kubectl" >> $HOME/.bashrc
echo "complete -F __start_kubectl k" >> $HOME/.bashrc


#install flannel pod
sudo snap install yq
curl -LO https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
sleep 2
sudo chown vagrant:vagrant kube-flannel.yml
yq -i '.spec.template.spec.containers[].args += "--iface=enp0s8"' kube-flannel.yml
sleep 2
kubectl apply -f kube-flannel.yml

#flannel and coredns should now come up

## ADD NODES TO CLUSTER
#kubeadm join <controlplane ip>:6443 --token <tokenid> \
#        --discovery-token-ca-cert-hash sha256:<discovery-token-cert-hash>
