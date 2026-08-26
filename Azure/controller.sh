#!/usr/bin/env bash

set -euxo pipefail

exec > >(tee -a /var/log/kubeadm-controller-bootstrap.log) 2>&1

export DEBIAN_FRONTEND=noninteractive

echo "=========================================="
echo " Kubernetes Controller Bootstrap"
echo "=========================================="

# ---------------------------------------------------------
# System preparation
# ---------------------------------------------------------

swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab

apt-get update

apt-get install -y \
  apt-transport-https \
  ca-certificates \
  curl \
  gpg \
  socat \
  conntrack \
  containerd

# ---------------------------------------------------------
# Kubernetes repository
# ---------------------------------------------------------

mkdir -p /etc/apt/keyrings

curl -fsSL \
  https://pkgs.k8s.io/core:/stable:/v1.34/deb/Release.key \
  | gpg --dearmor \
  -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.34/deb/ /' \
  > /etc/apt/sources.list.d/kubernetes.list

apt-get update

apt-get install -y \
  kubelet \
  kubeadm \
  kubectl

apt-mark hold kubelet kubeadm kubectl

# ---------------------------------------------------------
# Containerd
# ---------------------------------------------------------

mkdir -p /etc/containerd

containerd config default > /etc/containerd/config.toml

sed -i \
  's/SystemdCgroup = false/SystemdCgroup = true/' \
  /etc/containerd/config.toml

systemctl restart containerd
systemctl enable containerd
systemctl enable kubelet

# ---------------------------------------------------------
# Kubernetes networking prerequisites
# ---------------------------------------------------------

cat > /etc/sysctl.d/99-kubernetes.conf <<'EOF'
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.ip_forward=1
EOF

modprobe overlay
modprobe br_netfilter

sysctl --system

# ---------------------------------------------------------
# Initialize Kubernetes
# ---------------------------------------------------------

PRIVATE_IP=$(hostname -I | awk '{print $1}')

echo "Controller private IP: ${PRIVATE_IP}"

kubeadm init \
  --apiserver-advertise-address="${PRIVATE_IP}" \
  --pod-network-cidr=10.244.0.0/16

# ---------------------------------------------------------
# Configure kubectl for azureuser
# ---------------------------------------------------------

mkdir -p /home/azureuser/.kube

cp /etc/kubernetes/admin.conf \
  /home/azureuser/.kube/config

chown -R azureuser:azureuser \
  /home/azureuser/.kube

# ---------------------------------------------------------
# Install Flannel
# ---------------------------------------------------------

su - azureuser -c \
  'kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml'

# ---------------------------------------------------------
# Generate worker join command
# ---------------------------------------------------------

kubeadm token create \
  --ttl 0 \
  --print-join-command \
  > /home/azureuser/kubeadm-join.sh

chmod 700 /home/azureuser/kubeadm-join.sh

chown azureuser:azureuser \
  /home/azureuser/kubeadm-join.sh

# ---------------------------------------------------------
# Controller ready
# ---------------------------------------------------------

touch /var/lib/kubeadm-controller-ready

echo "=========================================="
echo " Kubernetes Controller READY"
echo "=========================================="

echo "Join command:"
cat /home/azureuser/kubeadm-join.sh
