#!/bin/bash

# ==============================================================================
# WORKER NODE SETUP SCRIPT — Self-Managed Kubernetes on AWS EC2
# ==============================================================================
# Purpose : Full automated setup for Worker node + cluster join
# Target  : Ubuntu 22.04 / 24.04 LTS
# K8s Ver : v1.29
# Runtime : containerd
# ==============================================================================
# USAGE:
#   chmod +x worker-setup.sh
#   sudo ./worker-setup.sh <MASTER_PRIVATE_IP>:6443 <TOKEN> <CA_CERT_HASH>
#
# Example:
#   sudo ./worker-setup.sh 10.0.1.139:6443 abcdef.0123456789abcdef sha256:1234...
#
# NOTE: Get the join command values by running on the MASTER node:
#       kubeadm token create --print-join-command
# ==============================================================================

set -euo pipefail
trap 'echo "[ERROR] Script failed at line $LINENO. Exiting." >&2; exit 1' ERR

# ------------------------------------------------------------------------------
# STEP 0 : Pre-flight checks
# ------------------------------------------------------------------------------

if [ "$EUID" -ne 0 ]; then
    echo "[ERROR] This script must be run with sudo/root privileges."
    echo "Usage: sudo ./worker-setup.sh <MASTER_IP:6443> <TOKEN> <CA_CERT_HASH>"
    exit 1
fi

if [ -z "${1:-}" ] || [ -z "${2:-}" ] || [ -z "${3:-}" ]; then
    echo "[ERROR] Missing required arguments."
    echo ""
    echo "Usage: sudo ./worker-setup.sh <MASTER_IP:6443> <TOKEN> <CA_CERT_HASH>"
    echo "Example: sudo ./worker-setup.sh 10.0.1.139:6443 abcdef.0123456789abcdef sha256:1234..."
    echo ""
    echo "Get these values by running on the MASTER node:"
    echo "  kubeadm token create --print-join-command"
    exit 1
fi

MASTER_ENDPOINT="$1"       # e.g. 10.0.1.139:6443
JOIN_TOKEN="$2"            # e.g. abcdef.0123456789abcdef
CA_CERT_HASH="$3"          # e.g. sha256:1234abcd...
K8S_VERSION="v1.29"

echo "=============================================================="
echo " Starting Worker Node Setup"
echo " Master Endpoint : $MASTER_ENDPOINT"
echo " Kubernetes Ver  : $K8S_VERSION"
echo "=============================================================="

# ------------------------------------------------------------------------------
# STEP 1 : System Pre-Checks
# ------------------------------------------------------------------------------
echo "[STEP 1/11] Running system pre-checks..."
uname -a
nproc
free -h
hostname

CPU_COUNT=$(nproc)
if [ "$CPU_COUNT" -lt 2 ]; then
    echo "[WARNING] Detected only $CPU_COUNT vCPU. Kubernetes recommends minimum 2 vCPUs."
fi

# ------------------------------------------------------------------------------
# STEP 2 : Disable Swap
# ------------------------------------------------------------------------------
echo "[STEP 2/11] Disabling swap..."
swapoff -a || true
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# ------------------------------------------------------------------------------
# STEP 3 : Verify OS and Network
# ------------------------------------------------------------------------------
echo "[STEP 3/11] Verifying OS and network configuration..."
cat /etc/os-release
ip addr show | grep "inet " | grep -v 127.0.0.1 || echo "[WARNING] No non-loopback IP found. Check network config."

# ------------------------------------------------------------------------------
# STEP 4 : Install Prerequisite Packages
# ------------------------------------------------------------------------------
echo "[STEP 4/11] Installing prerequisite packages..."
apt-get update -y
apt-get install -y apt-transport-https ca-certificates curl gnupg

# ------------------------------------------------------------------------------
# STEP 5 : Add Kubernetes Repository GPG Key
# ------------------------------------------------------------------------------
echo "[STEP 5/11] Adding Kubernetes repository GPG key..."
mkdir -p /etc/apt/keyrings

if [ -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg ]; then
    echo "[INFO] Existing Kubernetes GPG key found. Removing to avoid conflict."
    rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
fi

curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/Release.key" | \
    gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

# ------------------------------------------------------------------------------
# STEP 6 : Add Kubernetes APT Repository
# ------------------------------------------------------------------------------
echo "[STEP 6/11] Adding Kubernetes APT repository..."
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/ /" | \
    tee /etc/apt/sources.list.d/kubernetes.list

# ------------------------------------------------------------------------------
# STEP 7 : Install kubelet, kubeadm, kubectl
# ------------------------------------------------------------------------------
echo "[STEP 7/11] Installing kubelet, kubeadm, kubectl..."
apt-get update -y
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

# ------------------------------------------------------------------------------
# STEP 8 : Install and Configure containerd
# ------------------------------------------------------------------------------
echo "[STEP 8/11] Installing and configuring containerd..."
apt-get install -y containerd
mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml > /dev/null
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd

if ! systemctl is-active --quiet containerd; then
    echo "[ERROR] containerd failed to start. Check: systemctl status containerd"
    exit 1
fi
echo "[INFO] containerd is active."

# ------------------------------------------------------------------------------
# STEP 9 : Load Kernel Modules and Apply Network Settings
# ------------------------------------------------------------------------------
echo "[STEP 9/11] Loading kernel modules and applying sysctl settings..."

cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system > /dev/null

if [ "$(sysctl -n net.ipv4.ip_forward)" -ne 1 ]; then
    echo "[ERROR] net.ipv4.ip_forward not set to 1. Networking will fail."
    exit 1
fi
echo "[INFO] Kernel modules and sysctl settings applied successfully."

# ------------------------------------------------------------------------------
# STEP 10 : Connectivity Check to Master (fail fast before join attempt)
# ------------------------------------------------------------------------------
echo "[STEP 10/11] Checking network connectivity to master API server..."

MASTER_IP="${MASTER_ENDPOINT%%:*}"
MASTER_PORT="${MASTER_ENDPOINT##*:}"

if command -v nc >/dev/null 2>&1; then
    if nc -z -w 5 "$MASTER_IP" "$MASTER_PORT"; then
        echo "[INFO] Successfully reached ${MASTER_ENDPOINT}."
    else
        echo "[ERROR] Cannot reach ${MASTER_ENDPOINT}."
        echo "        Check Security Group rules: worker-sg must allow control-plane-sg on port ${MASTER_PORT},"
        echo "        and control-plane-sg must allow inbound 6443 from this worker's SG."
        exit 1
    fi
else
    echo "[WARNING] 'nc' not installed, skipping pre-join connectivity check."
fi

# ------------------------------------------------------------------------------
# STEP 11 : Join the Cluster
# ------------------------------------------------------------------------------
echo "[STEP 11/11] Joining the Kubernetes cluster..."

if [ -f /etc/kubernetes/kubelet.conf ]; then
    echo "[WARNING] This node appears to already be part of a cluster (/etc/kubernetes/kubelet.conf exists)."
    echo "[INFO] Skipping kubeadm join. Run 'kubeadm reset' first if you want to rejoin fresh."
else
    kubeadm join "${MASTER_ENDPOINT}" \
        --token "${JOIN_TOKEN}" \
        --discovery-token-ca-cert-hash "${CA_CERT_HASH}" \
        | tee /root/kubeadm-join-output.log

    echo "[INFO] kubeadm join output saved to /root/kubeadm-join-output.log"
fi

# ------------------------------------------------------------------------------
# FINAL SUMMARY
# ------------------------------------------------------------------------------
echo "=============================================================="
echo " WORKER NODE SETUP COMPLETE"
echo "=============================================================="
echo ""
echo "Verify from the MASTER node with:"
echo "    kubectl get nodes -o wide"
echo ""
echo "This node should appear with STATUS = Ready within 30-60 seconds"
echo "(CNI/Calico pods need a moment to initialize on the new node)."
echo "=============================================================="
