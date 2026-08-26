#!/usr/bin/env bash

set -euxo pipefail

exec > >(tee -a /var/log/kubeadm-worker-bootstrap.log) 2>&1

export DEBIAN_FRONTEND=noninteractive

echo "=========================================="
echo " Kubernetes Worker Bootstrap"
echo "=========================================="

# =========================================================
# Validate parameters FIRST
# =========================================================

if [ "$#" -ne 3 ]; then
  echo "ERROR: Invalid number of parameters."
  echo
  echo "Usage:"
  echo "  sudo ./worker.sh <CONTROLLER_PRIVATE_IP> <TOKEN> <CA_CERT_HASH>"
  echo
  echo "Example:"
  echo "  sudo ./worker.sh \\\n    10.20.1.4 \\\n    'abcdef.0123456789abcdef' \\\n    'sha256:0123456789abcdef...'"
  echo
  exit 1
fi

CONTROLLER_IP="$1"
TOKEN="$2"
CA_CERT_HASH="$3"

# ---------------------------------------------------------
# Validate individual parameters
# ---------------------------------------------------------

if [ -z "${CONTROLLER_IP}" ]; then
  echo "ERROR: Controller private IP is missing."
  exit 1
fi

if [ -z "${TOKEN}" ]; then
  echo "ERROR: Kubernetes token is missing."
  exit 1
fi

if [ -z "${CA_CERT_HASH}" ]; then
  echo "ERROR: Kubernetes CA certificate hash is missing."
  exit 1
fi

# ---------------------------------------------------------
# Basic format validation
# ---------------------------------------------------------

if [[ ! "${TOKEN}" =~ ^[a-z0-9]{6}\.[a-z0-9]{16}$ ]]; then
  echo "ERROR: Invalid kubeadm token format."
  echo "Expected: abcdef.0123456789abcdef"
  exit 1
fi

if [[ ! "${CA_CERT_HASH}" =~ ^sha256:[a-f0-9]{64}$ ]]; then
  echo "ERROR: Invalid CA certificate hash format."
  echo "Expected: sha256:<64 hexadecimal characters>"
  exit 1
fi

echo "Controller IP: ${CONTROLLER_IP}"
echo "Kubernetes token: [REDACTED]"
echo "CA certificate hash: [REDACTED]"

echo "Parameters validated successfully."

# =========================================================
# System preparation
# =========================================================

echo "Preparing system..."

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

# =========================================================
# Kubernetes repository
# =========================================================

echo "Configuring Kubernetes repository..."

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

# =========================================================
# Containerd
# =========================================================

echo "Configuring containerd..."

mkdir -p /etc/containerd

containerd config default > /etc/containerd/config.toml

sed -i \
  's/SystemdCgroup = false/SystemdCgroup = true/' \
  /etc/containerd/config.toml

systemctl restart containerd

systemctl enable containerd

systemctl enable kubelet

# =========================================================
# Kubernetes networking prerequisites
# =========================================================

echo "Configuring Kubernetes networking..."

cat > /etc/sysctl.d/99-kubernetes.conf <<'EOF'
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.ip_forward=1
EOF

modprobe overlay

modprobe br_netfilter

sysctl --system

# =========================================================
# Wait for Kubernetes API
# =========================================================

echo "=========================================="
echo " Waiting for Kubernetes API"
echo "=========================================="

echo "Controller: ${CONTROLLER_IP}:6443"

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

# =========================================================
# Join Kubernetes cluster
# =========================================================

echo "=========================================="
echo " Joining Kubernetes Cluster"
echo "=========================================="

kubeadm join "${CONTROLLER_IP}:6443" \
  --token "${TOKEN}" \
  --discovery-token-ca-cert-hash "${CA_CERT_HASH}"

# =========================================================
# Worker ready
# =========================================================

touch /var/lib/kubeadm-worker-ready

echo "=========================================="
echo " Kubernetes Worker READY"

echo "=========================================="

echo "Controller: ${CONTROLLER_IP}"
echo "Worker successfully joined the cluster."
