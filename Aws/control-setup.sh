#!/bin/bash

# ==============================================================================
# CONTROL PLANE SETUP SCRIPT — Self-Managed Kubernetes on AWS EC2
# ==============================================================================
# Purpose : Full automated setup for Control Plane (Master) node
# Target  : Ubuntu 22.04 / 24.04 LTS
# K8s Ver : v1.29
# Runtime : containerd
# CNI     : Calico v3.27.0
# ==============================================================================
# USAGE:
#   chmod +x control-setup.sh
#   sudo ./control-setup.sh <MASTER_PRIVATE_IP>
#
# Example:
#   sudo ./control-setup.sh 10.0.1.139
# ==============================================================================

set -euo pipefail
trap 'echo "[ERROR] Script failed at line $LINENO. Exiting." >&2; exit 1' ERR

# ------------------------------------------------------------------------------
# STEP 0 : Pre-flight checks
# ------------------------------------------------------------------------------

if [ "$EUID" -ne 0 ]; then
    echo "[ERROR] This script must be run with sudo/root privileges."
    echo "Usage: sudo ./control-setup.sh <MASTER_PRIVATE_IP>"
    exit 1
fi

if [ -z "${1:-}" ]; then
    echo "[ERROR] Master private IP not provided."
    echo "Usage: sudo ./control-setup.sh <MASTER_PRIVATE_IP>"
    exit 1
fi

MASTER_PRIVATE_IP="$1"
POD_CIDR="192.168.0.0/16"
K8S_VERSION="v1.29"
CALICO_VERSION="v3.27.0"
REAL_USER="${SUDO_USER:-$(whoami)}"
REAL_HOME=$(eval echo "~$REAL_USER")

echo "=============================================================="
echo " Starting Control Plane Setup"
echo " Master Private IP : $MASTER_PRIVATE_IP"
echo " Kubernetes Version: $K8S_VERSION"
echo " Running as        : $REAL_USER"
echo "=============================================================="

# ------------------------------------------------------------------------------
# STEP 1 : System Pre-Checks
# ------------------------------------------------------------------------------
echo "[STEP 1/12] Running system pre-checks..."
uname -a
nproc
free -h
hostname

CPU_COUNT=$(nproc)
if [ "$CPU_COUNT" -lt 2 ]; then
    echo "[WARNING] Detected only $CPU_COUNT vCPU. Kubernetes control plane requires minimum 2 vCPUs. Proceeding anyway, but kubeadm init may fail."
fi

# ------------------------------------------------------------------------------
# STEP 2 : Disable Swap
# ------------------------------------------------------------------------------
echo "[STEP 2/12] Disabling swap..."
swapoff -a || true
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# ------------------------------------------------------------------------------
# STEP 3 : Verify OS and Network
# ------------------------------------------------------------------------------
echo "[STEP 3/12] Verifying OS and network configuration..."
cat /etc/os-release
ip addr show | grep "inet " | grep -v 127.0.0.1 || echo "[WARNING] No non-loopback IP found. Check network config."

# ------------------------------------------------------------------------------
# STEP 4 : Install Prerequisite Packages
# ------------------------------------------------------------------------------
echo "[STEP 4/12] Installing prerequisite packages..."
apt-get update -y
apt-get install -y apt-transport-https ca-certificates curl gnupg

# ------------------------------------------------------------------------------
# STEP 5 : Add Kubernetes Repository GPG Key
# ------------------------------------------------------------------------------
echo "[STEP 5/12] Adding Kubernetes repository GPG key..."
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
echo "[STEP 6/12] Adding Kubernetes APT repository..."
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/ /" | \
    tee /etc/apt/sources.list.d/kubernetes.list

# ------------------------------------------------------------------------------
# STEP 7 : Install kubelet, kubeadm, kubectl
# ------------------------------------------------------------------------------
echo "[STEP 7/12] Installing kubelet, kubeadm, kubectl..."
apt-get update -y
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

# ------------------------------------------------------------------------------
# STEP 8 : Install and Configure containerd
# ------------------------------------------------------------------------------
echo "[STEP 8/12] Installing and configuring containerd..."
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
echo "[STEP 9/12] Loading kernel modules and applying sysctl settings..."

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
# STEP 10 : Initialize the Cluster
# ------------------------------------------------------------------------------
echo "[STEP 10/12] Initializing Kubernetes control plane..."

if [ -f /etc/kubernetes/admin.conf ]; then
    echo "[WARNING] /etc/kubernetes/admin.conf already exists. Cluster may already be initialized."
    echo "[INFO] Skipping kubeadm init. Delete /etc/kubernetes and re-run if you want a fresh init."
else
    kubeadm init \
        --pod-network-cidr="${POD_CIDR}" \
        --apiserver-advertise-address="${MASTER_PRIVATE_IP}" \
        | tee /root/kubeadm-init-output.log

    echo "[INFO] kubeadm init output saved to /root/kubeadm-init-output.log"
fi

# ------------------------------------------------------------------------------
# STEP 11 : Configure kubectl Access
# ------------------------------------------------------------------------------
echo "[STEP 11/12] Configuring kubectl access for user '${REAL_USER}'..."

mkdir -p "${REAL_HOME}/.kube"
cp -f /etc/kubernetes/admin.conf "${REAL_HOME}/.kube/config"
chown "$(id -u "$REAL_USER")":"$(id -g "$REAL_USER")" "${REAL_HOME}/.kube/config"

# Also configure for root, in case script is re-run under sudo directly
mkdir -p /root/.kube
cp -f /etc/kubernetes/admin.conf /root/.kube/config

export KUBECONFIG=/etc/kubernetes/admin.conf

# ------------------------------------------------------------------------------
# STEP 12 : Install CNI Plugin (Calico)
# ------------------------------------------------------------------------------
echo "[STEP 12/12] Installing CNI plugin (Calico ${CALICO_VERSION})..."

kubectl --kubeconfig=/etc/kubernetes/admin.conf apply -f \
    "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"

echo "[INFO] Waiting 30 seconds for Calico pods to initialize..."
sleep 30

# ------------------------------------------------------------------------------
# FINAL VERIFICATION
# ------------------------------------------------------------------------------
echo "=============================================================="
echo " VERIFICATION"
echo "=============================================================="

kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes -o wide
echo "--------------------------------------------------------------"
kubectl --kubeconfig=/etc/kubernetes/admin.conf get pods -n kube-system

echo "=============================================================="
echo " CONTROL PLANE SETUP COMPLETE"
echo "=============================================================="
echo ""
echo "Next steps:"
echo "  1. Run the following on this master to get the worker join command:"
echo "       kubeadm token create --print-join-command"
echo "  2. Run the printed 'kubeadm join ...' command on each worker node."
echo "  3. Verify cluster status with:"
echo "       kubectl get nodes -o wide"
echo ""
echo "kubeadm init log saved at: /root/kubeadm-init-output.log (if freshly initialized)"
echo "=============================================================="
