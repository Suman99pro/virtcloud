#!/usr/bin/env bash
# =============================================================================
# VirtCloud — CNI Plugin Installation Script
# Supports: KubeOVN (default), Flannel, Calico, Cilium
# Run on  : CONTROL PLANE node after all workers joined
# =============================================================================
set -euo pipefail

# ── Configurable ──────────────────────────────────────────────────────────────
CNI_PLUGIN="${CNI_PLUGIN:-kubeovn}"     # kubeovn | flannel | calico | cilium
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
KUBEOVN_VERSION="${KUBEOVN_VERSION:-1.12.6}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
die()     { echo -e "${RED}[ERR]${NC} $*"; exit 1; }

export KUBECONFIG=/etc/kubernetes/admin.conf

install_kubeovn() {
  info "Installing KubeOVN ${KUBEOVN_VERSION}..."

  # Label nodes for KubeOVN gateway
  for node in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
    kubectl label node "$node" ovn.kubernetes.io/ovs_dp_type=kernel --overwrite
  done

  curl -fsSL "https://raw.githubusercontent.com/kubeovn/kube-ovn/v${KUBEOVN_VERSION}/dist/images/install.sh" \
    -o /tmp/install-kubeovn.sh

  # Patch CIDR in install script
  sed -i "s|NETWORK_TYPE=.*|NETWORK_TYPE=geneve|g" /tmp/install-kubeovn.sh
  sed -i "s|POD_CIDR=.*|POD_CIDR=${POD_CIDR}|g" /tmp/install-kubeovn.sh

  bash /tmp/install-kubeovn.sh --with-hybrid-dpdk=false
  success "KubeOVN installed"
}

install_flannel() {
  info "Installing Flannel..."
  kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

  # Patch pod CIDR if custom
  if [[ "$POD_CIDR" != "10.244.0.0/16" ]]; then
    kubectl patch configmap -n kube-flannel kube-flannel-cfg \
      --type merge \
      -p "{\"data\":{\"net-conf.json\":\"{\\\"Network\\\": \\\"${POD_CIDR}\\\", \\\"Backend\\\": {\\\"Type\\\": \\\"vxlan\\\"}}\"}}"
  fi
  success "Flannel installed"
}

install_calico() {
  info "Installing Calico..."
  kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/tigera-operator.yaml

  cat <<EOF | kubectl apply -f -
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
    - blockSize: 26
      cidr: ${POD_CIDR}
      encapsulation: VXLANCrossSubnet
      natOutgoing: Enabled
      nodeSelector: all()
---
apiVersion: operator.tigera.io/v1
kind: APIServer
metadata:
  name: default
spec: {}
EOF
  success "Calico installed"
}

install_cilium() {
  info "Installing Cilium via Helm..."
  helm repo add cilium https://helm.cilium.io/
  helm install cilium cilium/cilium \
    --namespace kube-system \
    --set ipam.mode=kubernetes \
    --set kubeProxyReplacement=true \
    --set k8sServiceHost=$(kubectl get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}') \
    --set k8sServicePort=6443
  success "Cilium installed"
}

# ── Main ──────────────────────────────────────────────────────────────────────
info "Selected CNI plugin: ${CNI_PLUGIN}"

case "$CNI_PLUGIN" in
  kubeovn)  install_kubeovn ;;
  flannel)  install_flannel ;;
  calico)   install_calico ;;
  cilium)   install_cilium ;;
  *) die "Unknown CNI: $CNI_PLUGIN. Choose: kubeovn | flannel | calico | cilium" ;;
esac

info "Waiting for all nodes to be Ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=300s
kubectl get nodes -o wide
success "CNI installation complete!"
