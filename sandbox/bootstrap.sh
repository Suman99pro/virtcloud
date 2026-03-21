#!/usr/bin/env bash
# =============================================================================
# VirtCloud Sandbox — Bootstrap Script
# Creates a full 3-node Kubernetes cluster in Docker on your laptop/VM
# Requirements: Docker 20+, 8 GB RAM free, 20 GB disk free
# Usage: bash sandbox/bootstrap.sh
# =============================================================================

# NOTE: We intentionally do NOT use "set -e" so that individual wait timeouts
# do not abort the entire script. Each step handles its own errors.
set -uo pipefail

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

# Helper: poll for a pod phase rather than using kubectl wait (more reliable)
wait_for_pod() {
  local ns="$1" label="$2" desc="$3" max="${4:-40}"
  info "Waiting for ${desc}..."
  for i in $(seq 1 "$max"); do
    STATUS=$(kubectl get pods -n "$ns" -l "$label" \
      -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
    if [[ "$STATUS" == "Running" ]]; then
      success "${desc} is Running"
      return 0
    fi
    info "  ${desc}: ${STATUS:-Pending} (${i}/${max}) — retrying in 10s..."
    sleep 10
  done
  warn "${desc} did not reach Running in time. Check: kubectl get pods -n ${ns}"
  return 1
}

echo -e "${BOLD}${CYAN}"
echo "  VirtCloud Sandbox Bootstrap"
echo "  3-Node Kubernetes in Docker"
echo -e "${NC}"

# ── Requirements check ────────────────────────────────────────────────────────
info "Checking requirements..."
command -v docker &>/dev/null || die "Docker not found. Install from https://docs.docker.com/get-docker/"
docker info &>/dev/null       || die "Docker daemon not running. Start Docker first."
success "Docker $(docker --version | awk '{print $3}' | tr -d ',')"

TOTAL_MEM_GB=$(awk '/MemAvailable/{printf "%.0f", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo "0")
if [[ "$TOTAL_MEM_GB" -lt 5 ]]; then
  warn "Only ~${TOTAL_MEM_GB}GB RAM available. 8GB+ recommended for KubeVirt image pulls."
fi

# ── Install KinD ──────────────────────────────────────────────────────────────
if ! command -v kind &>/dev/null; then
  info "Installing KinD ${KIND_VERSION}..."
  OS=$(uname -s | tr '[:upper:]' '[:lower:]')
  ARCH=$(uname -m)
  [[ "$ARCH" == "x86_64" ]]  && ARCH="amd64"
  [[ "$ARCH" == "aarch64" ]] && ARCH="arm64"
  curl -fsSL --retry 3 \
    "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-${OS}-${ARCH}" \
    -o /tmp/kind
  chmod +x /tmp/kind
  sudo mv /tmp/kind /usr/local/bin/kind
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
  curl -fsSL --retry 3 \
    "https://dl.k8s.io/release/${KVER}/bin/${OS}/${ARCH}/kubectl" \
    -o /tmp/kubectl
  chmod +x /tmp/kubectl
  sudo mv /tmp/kubectl /usr/local/bin/kubectl
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

# No --wait: nodes stay NotReady until CNI is installed — that is expected
kind create cluster \
  --name "${CLUSTER_NAME}" \
  --config sandbox/kind-cluster.yaml

info "Cluster created. Nodes NotReady until CNI installs — this is normal."
kubectl get nodes

# ── Install CNI ───────────────────────────────────────────────────────────────
info "Installing CNI: ${CNI_PLUGIN}..."

case "$CNI_PLUGIN" in
  flannel)
    kubectl apply -f \
      https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
    # Fix Flannel to use eth0 (the correct interface inside KinD containers)
    kubectl -n kube-flannel patch daemonset kube-flannel-ds \
      --type json \
      -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--iface=eth0"}]' \
      2>/dev/null || true
    success "Flannel installed"
    ;;
  calico)
    kubectl apply -f \
      https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/calico.yaml
    success "Calico installed"
    ;;
  *)
    die "Sandbox CNI options: flannel | calico"
    ;;
esac

info "Waiting for all nodes to be Ready (up to 5 min)..."
kubectl wait --for=condition=Ready nodes --all --timeout=300s
kubectl get nodes

# ── Install Storage ───────────────────────────────────────────────────────────
info "Configuring storage: ${STORAGE_PLUGIN}..."

case "$STORAGE_PLUGIN" in
  local-path)
    # KinD ships both 'local-path' and 'standard' — both are marked default,
    # which causes provisioning ambiguity. Fix: keep only local-path as default.
    info "Fixing StorageClass defaults..."

    kubectl patch storageclass standard \
      -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' \
      2>/dev/null && info "Removed 'standard' as default" || true

    # Install local-path manually if KinD somehow didn't include it
    if ! kubectl get storageclass local-path &>/dev/null; then
      info "Installing local-path-provisioner..."
      kubectl apply -f \
        https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml
    fi

    kubectl patch storageclass local-path \
      -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' \
      2>/dev/null || true

    # Poll for provisioner pod rather than using kubectl wait (avoids false timeouts)
    wait_for_pod "local-path-storage" "app=local-path-provisioner" "local-path-provisioner" 24

    kubectl get storageclass
    success "local-path is the default StorageClass"
    ;;

  openebs)
    warn "OpenEBS requires 12GB+ RAM and 10-15 min in sandbox."
    warn "If it times out: STORAGE_PLUGIN=local-path bash sandbox/bootstrap.sh"
    helm repo add openebs https://openebs.github.io/charts --force-update
    helm repo update
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
    die "Sandbox storage options: local-path (default) | openebs"
    ;;
esac

# ── Install KubeVirt ──────────────────────────────────────────────────────────
info "Installing KubeVirt ${KUBEVIRT_VERSION} (software emulation — no KVM needed)..."
info "KubeVirt pulls ~600MB of images. This takes 5–15 min on first run."

kubectl apply -f \
  "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-operator.yaml"

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

# Wait for operator pod first before polling the CR
wait_for_pod "kubevirt" "kubevirt.io=virt-operator" "virt-operator" 30

info "Waiting for KubeVirt CR to become Available (up to 15 min)..."
if kubectl -n kubevirt wait kv kubevirt \
    --for condition=Available \
    --timeout=900s 2>/dev/null; then
  success "KubeVirt is ready!"
else
  warn "KubeVirt timed out — images still pulling. Check with:"
  warn "  kubectl -n kubevirt get pods"
  warn "Once all pods show Running, resume with:"
  warn "  bash sandbox/resume-sandbox.sh"
  exit 1
fi

# ── Install virtctl ───────────────────────────────────────────────────────────
info "Installing virtctl ${KUBEVIRT_VERSION}..."

OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)
[[ "$ARCH" == "x86_64" ]]  && ARCH="amd64"
[[ "$ARCH" == "aarch64" ]] && ARCH="arm64"

# Always download to /tmp first to avoid permission errors on /usr/local/bin
curl -fsSL --retry 3 \
  "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/virtctl-${KUBEVIRT_VERSION}-${OS}-${ARCH}" \
  -o /tmp/virtctl
chmod +x /tmp/virtctl
sudo mv /tmp/virtctl /usr/local/bin/virtctl
virtctl version --client 2>/dev/null || true
success "virtctl installed"

# ── Install CDI ───────────────────────────────────────────────────────────────
info "Installing CDI ${CDI_VERSION}..."

kubectl apply -f \
  "https://github.com/kubevirt/containerized-data-importer/releases/download/${CDI_VERSION}/cdi-operator.yaml"
kubectl apply -f \
  "https://github.com/kubevirt/containerized-data-importer/releases/download/${CDI_VERSION}/cdi-cr.yaml"

wait_for_pod "cdi" "name=cdi-operator" "cdi-operator" 20

if kubectl wait --for=condition=Available -n cdi cdi/cdi --timeout=300s 2>/dev/null; then
  success "CDI is ready!"
else
  warn "CDI timed out. Check: kubectl -n cdi get pods"
  warn "Resume with: bash sandbox/resume-sandbox.sh"
  exit 1
fi

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
  warn "Run: bash sandbox/deploy-ui.sh  (after placing ui/virtcloud-ui.html)"
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
echo -e "${GREEN}║  Create VM:                                          ║${NC}"
echo -e "${GREEN}║  kubectl apply -f sandbox/ubuntu-vm-sandbox.yaml    ║${NC}"
echo -e "${GREEN}║  Tear down: bash sandbox/teardown.sh                 ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
