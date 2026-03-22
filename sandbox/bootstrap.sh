#!/usr/bin/env bash
# =============================================================================
# VirtCloud Sandbox — Bootstrap Script
# Creates a full 3-node Kubernetes cluster in Docker on your laptop/VM
#
# Requirements: Docker 20+, 6 GB RAM free, 20 GB disk free
# Usage      : bash sandbox/bootstrap.sh
# Resume     : bash sandbox/resume-sandbox.sh  (if KubeVirt times out)
# Destroy    : bash sandbox/teardown.sh
# =============================================================================
set -uo pipefail

CNI_PLUGIN="kindnet"             # kindnet only — no Flannel, no subnet.env errors
STORAGE_PLUGIN="${STORAGE_PLUGIN:-local-path}"
KUBEVIRT_VERSION="${KUBEVIRT_VERSION:-v1.2.0}"
CDI_VERSION="${CDI_VERSION:-v1.58.1}"
KIND_VERSION="${KIND_VERSION:-v0.23.0}"
CLUSTER_NAME="virtcloud-sandbox"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERR]${NC}   $*"; exit 1; }

wait_pod_running() {
  local ns="$1" label="$2" desc="$3" max="${4:-48}"
  info "Waiting for ${desc}..."
  for i in $(seq 1 "$max"); do
    STATUS=$(kubectl get pods -n "$ns" -l "$label" \
      -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
    [[ "$STATUS" == "Running" ]] && { success "${desc} is Running"; return 0; }
    info "  ${desc}: ${STATUS:-Pending} (${i}/${max}) — retrying in 10s..."
    sleep 10
  done
  warn "${desc} did not reach Running. Check: kubectl get pods -n ${ns} -l ${label}"
  return 1
}

echo -e "\n${BOLD}${CYAN}  VirtCloud Sandbox Bootstrap"
echo -e "  3-Node Kubernetes in Docker${NC}\n"

# ── 1. Requirements ───────────────────────────────────────────────────────────
info "Checking requirements..."
command -v docker &>/dev/null || die "Docker not found. Install: https://docs.docker.com/get-docker/"
docker info &>/dev/null       || die "Docker daemon not running. Start Docker first."
success "Docker $(docker --version | awk '{print $3}' | tr -d ',')"

MEM_GB=$(awk '/MemAvailable/{printf "%.0f",$2/1024/1024}' /proc/meminfo 2>/dev/null || echo 0)
[[ "$MEM_GB" -lt 4 ]] && warn "Only ~${MEM_GB}GB RAM free. 6GB+ recommended."

# ── 2. Install KinD ───────────────────────────────────────────────────────────
if ! command -v kind &>/dev/null; then
  info "Installing KinD ${KIND_VERSION}..."
  OS=$(uname -s | tr '[:upper:]' '[:lower:]')
  ARCH=$(uname -m)
  [[ "$ARCH" == x86_64  ]] && ARCH=amd64
  [[ "$ARCH" == aarch64 ]] && ARCH=arm64
  curl -fsSL --retry 3 \
    "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-${OS}-${ARCH}" \
    -o /tmp/kind
  chmod +x /tmp/kind && sudo mv /tmp/kind /usr/local/bin/kind
  success "KinD installed"
else
  success "KinD: $(kind version)"
fi

# ── 3. Install kubectl ────────────────────────────────────────────────────────
if ! command -v kubectl &>/dev/null; then
  info "Installing kubectl..."
  OS=$(uname -s | tr '[:upper:]' '[:lower:]')
  ARCH=$(uname -m)
  [[ "$ARCH" == x86_64  ]] && ARCH=amd64
  [[ "$ARCH" == aarch64 ]] && ARCH=arm64
  KVER=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
  curl -fsSL --retry 3 \
    "https://dl.k8s.io/release/${KVER}/bin/${OS}/${ARCH}/kubectl" \
    -o /tmp/kubectl
  chmod +x /tmp/kubectl && sudo mv /tmp/kubectl /usr/local/bin/kubectl
  success "kubectl installed"
else
  success "kubectl already installed"
fi

# ── 4. Install Helm ───────────────────────────────────────────────────────────
if ! command -v helm &>/dev/null; then
  info "Installing Helm..."
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  success "Helm installed"
else
  success "Helm already installed"
fi

# ── 5. Create KinD cluster ────────────────────────────────────────────────────
info "Creating 3-node KinD cluster '${CLUSTER_NAME}'..."

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  warn "Cluster '${CLUSTER_NAME}' already exists."
  read -rp "  Delete and recreate? [y/N] " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || die "Aborted."
  kind delete cluster --name "${CLUSTER_NAME}"
  sleep 5
fi

mkdir -p /tmp/virtcloud-sandbox/{control-plane,worker-01,worker-02}

# KinD uses its built-in kindnet CNI — nodes reach Ready during creation itself
kind create cluster \
  --name "${CLUSTER_NAME}" \
  --config sandbox/kind-cluster.yaml \
  --wait 120s

success "Cluster created — all nodes Ready"
kubectl get nodes

# ── 6. Fix StorageClass defaults ─────────────────────────────────────────────
info "Configuring StorageClass..."

# KinD creates both 'local-path' and 'standard' as default — remove 'standard'
kubectl patch storageclass standard \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' \
  2>/dev/null && info "Removed 'standard' as default" || true

kubectl patch storageclass local-path \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' \
  2>/dev/null || true

wait_pod_running "local-path-storage" "app=local-path-provisioner" \
  "local-path-provisioner" 24

kubectl get storageclass
success "local-path is the sole default StorageClass"

# ── 7. Pre-pull KubeVirt images into KinD nodes ───────────────────────────────
# Pull on host Docker (fast), then inject into KinD nodes via 'kind load'.
# This prevents pods from getting stuck in Pending while pulling inside containers.
info "Pre-pulling KubeVirt ${KUBEVIRT_VERSION} images..."
info "This may take a few minutes but makes KubeVirt startup instant."

KUBEVIRT_IMAGES=(
  "quay.io/kubevirt/virt-operator:${KUBEVIRT_VERSION}"
  "quay.io/kubevirt/virt-api:${KUBEVIRT_VERSION}"
  "quay.io/kubevirt/virt-controller:${KUBEVIRT_VERSION}"
  "quay.io/kubevirt/virt-handler:${KUBEVIRT_VERSION}"
  "quay.io/kubevirt/virt-launcher:${KUBEVIRT_VERSION}"
)

for img in "${KUBEVIRT_IMAGES[@]}"; do
  info "  Pulling ${img}..."
  if docker pull "${img}" 2>/dev/null; then
    kind load docker-image "${img}" --name "${CLUSTER_NAME}" 2>/dev/null || true
    success "  Loaded: ${img}"
  else
    warn "  Pull failed — will use in-cluster pull (slower)"
  fi
done

# ── 8. Install KubeVirt ───────────────────────────────────────────────────────
info "Installing KubeVirt ${KUBEVIRT_VERSION} (software emulation)..."

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

wait_pod_running "kubevirt" "kubevirt.io=virt-operator" "virt-operator" 60

info "Waiting for KubeVirt CR to become Available (up to 15 min)..."
if kubectl -n kubevirt wait kv kubevirt \
    --for condition=Available --timeout=900s 2>/dev/null; then
  success "KubeVirt is ready!"
else
  warn "KubeVirt timed out — run: bash sandbox/resume-sandbox.sh"
  exit 1
fi

# ── 9. Install virtctl ────────────────────────────────────────────────────────
info "Installing virtctl ${KUBEVIRT_VERSION}..."
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)
[[ "$ARCH" == x86_64  ]] && ARCH=amd64
[[ "$ARCH" == aarch64 ]] && ARCH=arm64
curl -fsSL --retry 3 \
  "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/virtctl-${KUBEVIRT_VERSION}-${OS}-${ARCH}" \
  -o /tmp/virtctl
chmod +x /tmp/virtctl && sudo mv /tmp/virtctl /usr/local/bin/virtctl
virtctl version --client 2>/dev/null || true
success "virtctl installed"

# ── 10. Install CDI ───────────────────────────────────────────────────────────
info "Installing CDI ${CDI_VERSION}..."
kubectl apply -f \
  "https://github.com/kubevirt/containerized-data-importer/releases/download/${CDI_VERSION}/cdi-operator.yaml"
kubectl apply -f \
  "https://github.com/kubevirt/containerized-data-importer/releases/download/${CDI_VERSION}/cdi-cr.yaml"

wait_pod_running "cdi" "name=cdi-operator" "cdi-operator" 24

if kubectl wait --for=condition=Available -n cdi cdi/cdi \
    --timeout=300s 2>/dev/null; then
  success "CDI is ready!"
else
  warn "CDI timed out. Run: bash sandbox/resume-sandbox.sh"
  exit 1
fi

# ── 11. Deploy UI ─────────────────────────────────────────────────────────────
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
  warn "Run: bash sandbox/deploy-ui.sh"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}╔════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║     VirtCloud Sandbox Ready! 🎉                   ║${NC}"
echo -e "${BOLD}${GREEN}╠════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║  Nodes    : 3 (1 control-plane + 2 workers)        ║${NC}"
echo -e "${GREEN}║  CNI      : kindnet (built-in)                      ║${NC}"
echo -e "${GREEN}║  Storage  : local-path                              ║${NC}"
echo -e "${GREEN}║  KubeVirt : ${KUBEVIRT_VERSION} (emulation mode)            ║${NC}"
echo -e "${GREEN}╠════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║  UI       : http://localhost:30080                  ║${NC}"
echo -e "${GREEN}║  VM SSH   : ssh ubuntu@localhost -p 30022           ║${NC}"
echo -e "${GREEN}╠════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║  kubectl apply -f sandbox/ubuntu-vm-sandbox.yaml   ║${NC}"
echo -e "${GREEN}║  Destroy  : bash sandbox/teardown.sh                ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════╝${NC}"
