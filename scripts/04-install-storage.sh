#!/usr/bin/env bash
# =============================================================================
# VirtCloud — Storage Plugin Installation
# Supported: OpenEBS (default) | longhorn | rook-ceph
# Run on  : CONTROL PLANE node
# =============================================================================
set -euo pipefail

STORAGE_PLUGIN="${STORAGE_PLUGIN:-openebs}"
OPENEBS_VERSION="${OPENEBS_VERSION:-3.10.0}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
die()     { echo -e "${RED}[ERR]${NC}  $*"; exit 1; }

export KUBECONFIG=/etc/kubernetes/admin.conf

install_openebs() {
  info "Installing OpenEBS ${OPENEBS_VERSION}..."
  apt-get install -y -qq open-iscsi
  systemctl enable --now iscsid

  helm repo add openebs https://openebs.github.io/charts
  helm repo update
  helm install openebs openebs/openebs \
    --namespace openebs \
    --create-namespace \
    --set engines.replicated.mayastor.enabled=false \
    --version "${OPENEBS_VERSION}" \
    --wait --timeout 5m

  kubectl apply -f - <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: openebs-hostpath
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: openebs.io/local
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
parameters:
  StorageType: hostpath
  BasePath: /var/openebs/local
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: openebs-lvm
provisioner: local.csi.openebs.io
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
parameters:
  storage: lvm
  volgroup: "openebs-vg"
  fsType: ext4
EOF
  success "OpenEBS installed — StorageClasses: openebs-hostpath (default), openebs-lvm"
}

install_longhorn() {
  info "Installing Longhorn..."
  apt-get install -y -qq open-iscsi nfs-common
  helm repo add longhorn https://charts.longhorn.io
  helm repo update
  helm install longhorn longhorn/longhorn \
    --namespace longhorn-system \
    --create-namespace \
    --set defaultSettings.defaultReplicaCount=2 \
    --wait --timeout 10m

  kubectl apply -f - <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: longhorn
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: driver.longhorn.io
allowVolumeExpansion: true
reclaimPolicy: Delete
volumeBindingMode: Immediate
parameters:
  numberOfReplicas: "2"
  fsType: ext4
EOF
  success "Longhorn installed"
}

install_rook_ceph() {
  info "Installing Rook-Ceph..."
  helm repo add rook-release https://charts.rook.io/release
  helm repo update
  helm install rook-ceph rook-release/rook-ceph \
    --namespace rook-ceph \
    --create-namespace \
    --wait
  kubectl apply -f https://raw.githubusercontent.com/rook/rook/master/deploy/examples/cluster.yaml
  kubectl apply -f https://raw.githubusercontent.com/rook/rook/master/deploy/examples/storageclass.yaml
  success "Rook-Ceph installed (cluster provisioning takes ~5 min)"
}

info "Selected storage: ${STORAGE_PLUGIN}"
case "$STORAGE_PLUGIN" in
  openebs)   install_openebs ;;
  longhorn)  install_longhorn ;;
  rook-ceph) install_rook_ceph ;;
  *) die "Unknown storage: $STORAGE_PLUGIN. Choose: openebs | longhorn | rook-ceph" ;;
esac

kubectl get storageclass
success "Storage plugin '${STORAGE_PLUGIN}' installed!"
