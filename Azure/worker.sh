#!/usr/bin/env bash

set -euxo pipefail

exec > >(tee -a /var/log/kubeadm-worker-bootstrap.log) 2>&1

export DEBIAN_FRONTEND=noninteractive

echo "=========================================="
echo " Kubernetes Worker Bootstrap"
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
  kubeadm

apt-mark hold kubelet kubeadm

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
# Configuration
# ---------------------------------------------------------

CONTROLLER_IP="${CONTROLLER_IP:-}"

if [ -z "${CONTROLLER_IP}" ]; then
  echo "ERROR: CONTROLLER_IP is not set"
  exit 1
fi

echo "Controller IP: ${CONTROLLER_IP}"

# ---------------------------------------------------------
# Wait for Kubernetes API
# ---------------------------------------------------------

echo "Waiting for Kubernetes API..."

until timeout 3 bash -c "</dev/tcp/${CONTROLLER_IP}/6443"; do
  echo "Controller API port not ready..."
  sleep 10
done

until curl \
  --insecure \
  --silent \
  --fail \
  "https://${CONTROLLER_IP}:6443/version" \
  >/dev/null; do

  echo "Kubernetes API not ready..."
  sleep 10
done

echo "Kubernetes API is ready."

# ---------------------------------------------------------
# Worker join
# ---------------------------------------------------------
#
# The controller must expose a join command.
#
# For now this script expects:
#
#   /opt/k8s/kubeadm-join.sh
#
# to contain the generated kubeadm join command.
#
# ---------------------------------------------------------

JOIN_COMMAND="/opt/k8s/kubeadm-join.sh"

until [ -f "${JOIN_COMMAND}" ]; do
  echo "Waiting for kubeadm join command..."
  sleep 10
done

chmod +x "${JOIN_COMMAND}"

bash "${JOIN_COMMAND}"

# ---------------------------------------------------------
# Worker ready
# ---------------------------------------------------------

touch "/var/lib/kubeadm-worker-ready"

echo "=========================================="
echo " Kubernetes Worker READY"
echo "=========================================="
