#!/usr/bin/env bash
# =============================================================================
# VirtCloud Sandbox — Resume Script
# Run this after bootstrap.sh exits with a KubeVirt/CDI timeout.
# All cluster infra is already in place — this just waits and finishes.
# Usage: bash sandbox/resume-sandbox.sh
# =============================================================================
set -uo pipefail

KUBEVIRT_VERSION="${KUBEVIRT_VERSION:-v1.2.0}"
CDI_VERSION="${CDI_VERSION:-v1.58.1}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
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
    [[ "$STATUS" == "Running" ]] && { success "${desc} Running"; return 0; }
    info "  ${desc}: ${STATUS:-Pending} (${i}/${max}) — retrying in 10s..."
    sleep 10
  done
  warn "${desc} did not reach Running. Check: kubectl get pods -n ${ns}"
  return 1
}

# ── Fix StorageClass if needed ────────────────────────────────────────────────
info "Checking StorageClass defaults..."
kubectl patch storageclass standard \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' \
  2>/dev/null || true
kubectl patch storageclass local-path \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' \
  2>/dev/null || true
kubectl get storageclass

# ── Wait for KubeVirt ─────────────────────────────────────────────────────────
info "Checking KubeVirt pod status..."
kubectl -n kubevirt get pods 2>/dev/null || true

# If virt-operator is missing, reinstall KubeVirt operator
if ! kubectl -n kubevirt get pods -l kubevirt.io=virt-operator 2>/dev/null | grep -q virt-operator; then
  warn "virt-operator not found — reinstalling KubeVirt operator..."
  kubectl apply -f \
    "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-operator.yaml"
fi

# If KubeVirt CR is missing, recreate it
if ! kubectl -n kubevirt get kv kubevirt &>/dev/null; then
  warn "KubeVirt CR not found — recreating..."
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
fi

wait_pod_running "kubevirt" "kubevirt.io=virt-operator" "virt-operator" 60

info "Waiting for KubeVirt CR to become Available (up to 15 min)..."
if kubectl -n kubevirt wait kv kubevirt \
    --for condition=Available --timeout=900s 2>/dev/null; then
  success "KubeVirt is ready!"
else
  warn "Still timing out. Check image pull progress:"
  warn "  kubectl -n kubevirt get pods"
  warn "  kubectl -n kubevirt describe pod -l kubevirt.io=virt-operator | tail -20"
  warn "Try pre-pulling images to speed things up:"
  warn "  docker pull quay.io/kubevirt/virt-operator:${KUBEVIRT_VERSION}"
  warn "  kind load docker-image quay.io/kubevirt/virt-operator:${KUBEVIRT_VERSION} --name virtcloud-sandbox"
  die "KubeVirt not ready. Re-run this script once pods are Running."
fi

# ── Install virtctl ───────────────────────────────────────────────────────────
if ! command -v virtctl &>/dev/null; then
  info "Installing virtctl ${KUBEVIRT_VERSION}..."
  OS=$(uname -s | tr '[:upper:]' '[:lower:]')
  ARCH=$(uname -m); [[ "$ARCH" == x86_64 ]] && ARCH=amd64; [[ "$ARCH" == aarch64 ]] && ARCH=arm64
  curl -fsSL --retry 3 \
    "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/virtctl-${KUBEVIRT_VERSION}-${OS}-${ARCH}" \
    -o /tmp/virtctl
  chmod +x /tmp/virtctl && sudo mv /tmp/virtctl /usr/local/bin/virtctl
  success "virtctl installed"
else
  success "virtctl already installed"
fi

# ── Wait for CDI ──────────────────────────────────────────────────────────────
info "Checking CDI..."

if ! kubectl -n cdi get cdi cdi &>/dev/null; then
  warn "CDI CR not found — reinstalling CDI..."
  kubectl apply -f \
    "https://github.com/kubevirt/containerized-data-importer/releases/download/${CDI_VERSION}/cdi-operator.yaml"
  kubectl apply -f \
    "https://github.com/kubevirt/containerized-data-importer/releases/download/${CDI_VERSION}/cdi-cr.yaml"
fi

wait_pod_running "cdi" "name=cdi-operator" "cdi-operator" 24

if kubectl wait --for=condition=Available -n cdi cdi/cdi \
    --timeout=300s 2>/dev/null; then
  success "CDI is ready!"
else
  warn "CDI timed out. Check: kubectl -n cdi get pods"
  die "CDI not ready. Re-run this script once pods are Running."
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
  warn "Run: bash sandbox/deploy-ui.sh"
fi

echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║     VirtCloud Sandbox Ready! 🎉                   ║${NC}"
echo -e "${GREEN}╠════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║  UI     : http://localhost:30080                   ║${NC}"
echo -e "${GREEN}║  VM SSH : ssh ubuntu@localhost -p 30022            ║${NC}"
echo -e "${GREEN}╠════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║  kubectl apply -f sandbox/ubuntu-vm-sandbox.yaml  ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════╝${NC}"
