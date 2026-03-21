#!/usr/bin/env bash
# =============================================================================
# VirtCloud Sandbox — Bootstrap Script
# Creates a full 3-node Kubernetes cluster in Docker on your laptop/VM
# Requirements: Docker 20+, 8 GB RAM free, 20 GB disk free
# Usage: bash sandbox/bootstrap.sh
# =============================================================================
set -euo pipefail

CNI_PLUGIN="${CNI_PLUGIN:-flannel}"
STORAGE_PLUGIN="${STORAGE_PLUGIN:-local-path}"
KUBEVIRT_VERSION="${KUBEVIRT_VERSION:-v1.2.0}"
CDI_VERSION="${CDI_VERSION:-v1.58.1}"
KIND_VERSION="${KIND_VERSION:-v0.23.0}"
CLUSTER_NAME="virtcloud-sandbox"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()     { echo -e "${RED}[ERR]${NC}  $*"; exit 1; }

echo -e "${BOLD}${CYAN}"
echo "  VirtCloud Sandbox Bootstrap"
echo "  3-Node Kubernetes in Docker"
echo -e "${NC}"

# ── Requirements check ────────────────────────────────────────────────────────
info "Checking requirements..."
command -v docker &>/dev/null || die "Docker not found. Install from https://docs.docker.com/get-docker/"
docker info &>/dev/null       || die "Docker daemon not running. Start Docker first."
success "Docker available"

# ── Install KinD ──────────────────────────────────────────────────────────────
if ! command -v kind &>/dev/null; then
  info "Installing KinD ${KIND_VERSION}..."
  OS=$(uname -s | tr '[:upper:]' '[:lower:]')
  ARCH=$(uname -m)
  [[ "$ARCH" == "x86_64" ]]  && ARCH="amd64"
  [[ "$ARCH" == "aarch64" ]] && ARCH="arm64"
  curl -fsSL "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-${OS}-${ARCH}" \
    -o /usr/local/bin/kind
  chmod +x /usr/local/bin/kind
  success "KinD installed"
else
  success "KinD already installed: $(kind version)"
fi

# ── Install kubectl ───────────────────────────────────────────────────────────
if ! command -v kubectl &>/dev/null; then
  info "Installing kubectl..."
  OS=$(uname -s | tr '[:upper:]' '[:lower:]')
  ARCH=$(uname -m)
  [[ "$ARCH" == "x86_64" ]]  && ARCH="amd64"
  [[ "$ARCH" == "aarch64" ]] && ARCH="arm64"
  KVER=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
  curl -fsSL "https://dl.k8s.io/release/${KVER}/bin/${OS}/${ARCH}/kubectl" \
    -o /usr/local/bin/kubectl
  chmod +x /usr/local/bin/kubectl
  success "kubectl installed"
else
  success "kubectl already installed"
fi

# ── Install Helm ──────────────────────────────────────────────────────────────
if ! command -v helm &>/dev/null; then
  info "Installing Helm..."
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  success "Helm installed"
else
  success "Helm already installed"
fi

# ── Create KinD cluster ───────────────────────────────────────────────────────
info "Creating 3-node KinD cluster..."

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  warn "Cluster '${CLUSTER_NAME}' already exists."
  read -rp "Delete and recreate? [y/N] " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || die "Aborted."
  kind delete cluster --name "${CLUSTER_NAME}"
fi

mkdir -p /tmp/virtcloud-sandbox/{control-plane,worker-01,worker-02}

kind create cluster \
  --name "${CLUSTER_NAME}" \
  --config sandbox/kind-cluster.yaml \
  --wait 120s

success "3-node cluster created"
kubectl get nodes

# ── Install CNI ───────────────────────────────────────────────────────────────
info "Installing CNI: ${CNI_PLUGIN}..."

case "$CNI_PLUGIN" in
  flannel)
    kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
    kubectl -n kube-flannel patch daemonset kube-flannel-ds \
      --type json \
      -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--iface=eth0"}]' \
      2>/dev/null || true
    success "Flannel installed"
    ;;
  calico)
    kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/calico.yaml
    success "Calico installed"
    ;;
  *)
    die "Sandbox supports: flannel | calico. For kubeovn use production setup."
    ;;
esac

info "Waiting for nodes to be Ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=300s
kubectl get nodes

# ── Install Storage ───────────────────────────────────────────────────────────
info "Installing storage: ${STORAGE_PLUGIN}..."

case "$STORAGE_PLUGIN" in
  local-path)
    # Lightweight Rancher local-path — no Helm, no heavy pods, installs in seconds
    info "Installing local-path-provisioner (lightweight, recommended for sandbox)..."
    kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml

    info "Waiting for local-path-provisioner to be ready..."
    kubectl wait --for=condition=Available \
      deployment/local-path-provisioner \
      -n local-path-storage \
      --timeout=120s

    kubectl patch storageclass local-path \
      -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
    success "local-path-provisioner installed and set as default StorageClass"
    ;;
  openebs)
    # Full OpenEBS — heavier, needs more RAM and time. Only use if you have 12GB+ RAM.
    warn "OpenEBS can take 10+ min and requires 12GB+ RAM in sandbox."
    warn "If it times out, re-run with: STORAGE_PLUGIN=local-path bash sandbox/bootstrap.sh"
    helm repo add openebs https://openebs.github.io/charts --force-update
    helm repo update

    # Install only the hostpath engine — skip mayastor, lvm, zfs (too heavy for sandbox)
    helm install openebs openebs/openebs \
      --namespace openebs \
      --create-namespace \
      --set engines.replicated.mayastor.enabled=false \
      --set engines.local.lvm.enabled=false \
      --set engines.local.zfs.enabled=false \
      --set localpv-provisioner.enabled=true \
      --set ndm.enabled=false \
      --set ndmOperator.enabled=false \
      --timeout 15m \
      --wait

    kubectl apply -f - <<'YAML'
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
YAML
    success "OpenEBS installed"
    ;;
  *)
    die "Sandbox supports: local-path (recommended) | openebs"
    ;;
esac

kubectl get storageclass

# ── Install KubeVirt ──────────────────────────────────────────────────────────
info "Installing KubeVirt ${KUBEVIRT_VERSION} (software emulation mode)..."

kubectl apply -f "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-operator.yaml"

kubectl apply -f - <<YAML
apiVersion: kubevirt.io/v1
kind: KubeVirt
metadata:
  name: kubevirt
  namespace: kubevirt
spec:
  configuration:
    developerConfiguration:
      useEmulation: true
      featureGates:
        - LiveMigration
  imagePullPolicy: IfNotPresent
  workloadUpdateStrategy:
    workloadUpdateMethods:
    - LiveMigrate
YAML

info "Waiting for KubeVirt (3–5 min)..."
kubectl -n kubevirt wait kv kubevirt --for condition=Available --timeout=600s
success "KubeVirt ready"

# ── Install virtctl ───────────────────────────────────────────────────────────
info "Installing virtctl..."
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)
[[ "$ARCH" == "x86_64" ]]  && ARCH="amd64"
[[ "$ARCH" == "aarch64" ]] && ARCH="arm64"
curl -fsSL "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/virtctl-${KUBEVIRT_VERSION}-${OS}-${ARCH}" \
  -o /usr/local/bin/virtctl
chmod +x /usr/local/bin/virtctl
success "virtctl installed"

# ── Install CDI ───────────────────────────────────────────────────────────────
info "Installing CDI ${CDI_VERSION}..."
kubectl apply -f "https://github.com/kubevirt/containerized-data-importer/releases/download/${CDI_VERSION}/cdi-operator.yaml"
kubectl apply -f "https://github.com/kubevirt/containerized-data-importer/releases/download/${CDI_VERSION}/cdi-cr.yaml"
kubectl wait --for=condition=Available -n cdi cdi/cdi --timeout=300s
success "CDI installed"

# ── Deploy UI ─────────────────────────────────────────────────────────────────
if [[ -f "ui/virtcloud-ui.html" ]]; then
  info "Deploying VirtCloud UI..."
  kubectl create namespace virtcloud-ui --dry-run=client -o yaml | kubectl apply -f -
  kubectl create configmap virtcloud-ui-html \
    --from-file=index.html=ui/virtcloud-ui.html \
    --namespace virtcloud-ui \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -f sandbox/virtcloud-ui-sandbox.yaml
  success "UI deployed → http://localhost:30080"
else
  warn "ui/virtcloud-ui.html not found — skipping UI."
  warn "To deploy UI later: bash sandbox/deploy-ui.sh"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║     VirtCloud Sandbox Ready! 🎉                     ║${NC}"
echo -e "${BOLD}${GREEN}╠══════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║  Nodes:    3 (1 control-plane + 2 workers)           ║${NC}"
echo -e "${GREEN}║  CNI:      ${CNI_PLUGIN}                                    ║${NC}"
echo -e "${GREEN}║  Storage:  ${STORAGE_PLUGIN}                             ║${NC}"
echo -e "${GREEN}║  KubeVirt: ${KUBEVIRT_VERSION} (emulation mode)             ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║  UI:       http://localhost:30080                    ║${NC}"
echo -e "${GREEN}║  VM SSH:   ssh ubuntu@localhost -p 30022             ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║  Create VM: kubectl apply -f sandbox/ubuntu-vm-sandbox.yaml ║${NC}"
echo -e "${GREEN}║  Tear down: bash sandbox/teardown.sh                 ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
