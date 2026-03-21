#!/usr/bin/env bash
# =============================================================================
# VirtCloud — Worker Node Setup Script
# Node OS : Ubuntu 24.04 LTS
# Run on  : EACH WORKER node (as root or sudo)
# After this script: run the kubeadm join command from the control plane
# =============================================================================
set -euo pipefail

K8S_VERSION="${K8S_VERSION:-1.30}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()     { echo -e "${RED}[ERR]${NC}  $*"; exit 1; }

[[ $EUID -ne 0 ]] && die "Run as root: sudo bash $0"

info "Setting up worker node..."

# ── 1. System prerequisites ───────────────────────────────────────────────────
swapoff -a
sed -i '/\bswap\b/d' /etc/fstab

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

# ── 2. Install containerd ─────────────────────────────────────────────────────
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg apt-transport-https

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update -qq
apt-get install -y -qq containerd.io

mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd
success "containerd configured"

# ── 3. Install Kubernetes components ──────────────────────────────────────────
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
  https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list

apt-get update -qq
apt-get install -y -qq kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
success "Kubernetes components installed"

# ── 4. KVM check ──────────────────────────────────────────────────────────────
if grep -qE '(vmx|svm)' /proc/cpuinfo; then
  apt-get install -y -qq qemu-kvm libvirt-daemon-system
  success "KVM hardware virtualization detected and enabled"
else
  warn "No hardware virtualization detected — KubeVirt will use software emulation"
fi

success "================================================="
success " Worker node ready!"
success "================================================="
warn "Now run the join command from the control plane:"
warn "  sudo bash /tmp/worker-join.sh"
warn "  (copy /tmp/worker-join.sh from the control plane first)"
