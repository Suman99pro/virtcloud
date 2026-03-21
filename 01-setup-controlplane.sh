#!/usr/bin/env bash
# =============================================================================
# VirtCloud — Control Plane Setup Script
# Node OS : Ubuntu 24.04 LTS
# Run on  : CONTROL PLANE node only (as root or sudo)
# =============================================================================
set -euo pipefail

# ── Configurable Variables ────────────────────────────────────────────────────
K8S_VERSION="${K8S_VERSION:-1.30}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"          # KubeOVN default
SERVICE_CIDR="${SERVICE_CIDR:-10.96.0.0/12}"
CONTROL_PLANE_IP="${CONTROL_PLANE_IP:-}"         # Set this to your CP node IP
CLUSTER_NAME="${CLUSTER_NAME:-virtcloud}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()     { echo -e "${RED}[ERR]${NC} $*"; exit 1; }

[[ $EUID -ne 0 ]] && die "Run as root: sudo bash $0"
[[ -z "$CONTROL_PLANE_IP" ]] && die "Set CONTROL_PLANE_IP before running. e.g.: CONTROL_PLANE_IP=192.168.1.10 bash $0"

# ── 1. System prerequisites ───────────────────────────────────────────────────
info "Configuring system prerequisites..."

# Disable swap (required by kubeadm)
swapoff -a
sed -i '/\bswap\b/d' /etc/fstab

# Load required kernel modules
cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
vhost_vsock
kvm
kvm_intel
kvm_amd
EOF
modprobe overlay br_netfilter || true
modprobe kvm kvm_intel kvm_amd 2>/dev/null || modprobe kvm kvm_amd 2>/dev/null || true

# Kernel parameters
cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
net.ipv6.conf.all.forwarding        = 1
fs.inotify.max_user_watches         = 1048576
fs.inotify.max_user_instances       = 512
vm.max_map_count                    = 262144
EOF
sysctl --system > /dev/null
success "Kernel parameters applied"

# ── 2. Install containerd ──────────────────────────────────────────────────────
info "Installing containerd..."
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg lsb-release apt-transport-https

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update -qq
apt-get install -y -qq containerd.io

# Configure containerd with systemd cgroup driver
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd
success "containerd installed and configured"

# ── 3. Install kubeadm, kubelet, kubectl ──────────────────────────────────────
info "Installing Kubernetes ${K8S_VERSION} components..."
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
  https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list

apt-get update -qq
apt-get install -y -qq kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
success "Kubernetes components installed"

# ── 4. Initialize cluster with kubeadm ────────────────────────────────────────
info "Initializing Kubernetes cluster..."

cat > /tmp/kubeadm-config.yaml <<EOF
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: "${CONTROL_PLANE_IP}"
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///var/run/containerd/containerd.sock
  kubeletExtraArgs:
    node-labels: "node-role=control-plane"
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
clusterName: "${CLUSTER_NAME}"
kubernetesVersion: "v${K8S_VERSION}.0"
networking:
  podSubnet: "${POD_CIDR}"
  serviceSubnet: "${SERVICE_CIDR}"
apiServer:
  extraArgs:
    allow-privileged: "true"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
EOF

kubeadm init --config /tmp/kubeadm-config.yaml --upload-certs 2>&1 | tee /tmp/kubeadm-init.log

# ── 5. Configure kubectl ──────────────────────────────────────────────────────
SUDO_USER_HOME=$(eval echo ~${SUDO_USER:-root})
mkdir -p "${SUDO_USER_HOME}/.kube"
cp /etc/kubernetes/admin.conf "${SUDO_USER_HOME}/.kube/config"
chown -R "${SUDO_USER:-root}:${SUDO_USER:-root}" "${SUDO_USER_HOME}/.kube"

# Also configure for root
mkdir -p /root/.kube
cp /etc/kubernetes/admin.conf /root/.kube/config
export KUBECONFIG=/etc/kubernetes/admin.conf
success "kubectl configured"

# ── 6. Install Helm ───────────────────────────────────────────────────────────
info "Installing Helm..."
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
success "Helm installed"

# ── 7. Save join command ──────────────────────────────────────────────────────
JOIN_CMD=$(kubeadm token create --print-join-command)
echo "#!/bin/bash" > /tmp/worker-join.sh
echo "$JOIN_CMD" >> /tmp/worker-join.sh
chmod +x /tmp/worker-join.sh

success "====================================================="
success " Control plane initialized successfully!"
success "====================================================="
echo ""
info "Worker join command saved to: /tmp/worker-join.sh"
info "Copy and run on each worker node:"
echo ""
cat /tmp/worker-join.sh
echo ""
warn "Next: Run scripts/02-setup-workers.sh on each worker, then"
warn "      Run scripts/03-install-cni.sh (KubeOVN) on control plane"
