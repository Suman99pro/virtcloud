#!/usr/bin/env bash
# =============================================================================
# VirtCloud — KubeVirt + CDI Installation
# Run on  : CONTROL PLANE node
# =============================================================================
set -euo pipefail

KUBEVIRT_VERSION="${KUBEVIRT_VERSION:-v1.2.0}"
CDI_VERSION="${CDI_VERSION:-v1.58.1}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }

export KUBECONFIG=/etc/kubernetes/admin.conf

# ── Check KVM ─────────────────────────────────────────────────────────────────
if grep -qE '(vmx|svm)' /proc/cpuinfo; then
  info "Hardware virtualization (KVM) detected"
  USE_EMULATION=false
else
  warn "No KVM detected — enabling software emulation (slower but functional)"
  USE_EMULATION=true
fi

# ── Install KubeVirt operator ──────────────────────────────────────────────────
info "Installing KubeVirt operator ${KUBEVIRT_VERSION}..."
kubectl apply -f "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-operator.yaml"

# ── KubeVirt CR ───────────────────────────────────────────────────────────────
info "Deploying KubeVirt CR..."
cat <<EOF | kubectl apply -f -
apiVersion: kubevirt.io/v1
kind: KubeVirt
metadata:
  name: kubevirt
  namespace: kubevirt
spec:
  configuration:
    developerConfiguration:
      useEmulation: ${USE_EMULATION}
      featureGates:
        - LiveMigration
    cpuRequest: "100m"
    networkConfiguration:
      networkInterface: "masquerade"
  imagePullPolicy: IfNotPresent
  workloadUpdateStrategy:
    workloadUpdateMethods:
    - LiveMigrate
EOF

# ── Wait ──────────────────────────────────────────────────────────────────────
info "Waiting for KubeVirt to be ready (3–5 minutes)..."
kubectl -n kubevirt wait kv kubevirt \
  --for condition=Available \
  --timeout=600s

# ── Install virtctl ───────────────────────────────────────────────────────────
info "Installing virtctl..."
ARCH=$(uname -m)
[[ "$ARCH" == "x86_64" ]]  && ARCH="amd64"
[[ "$ARCH" == "aarch64" ]] && ARCH="arm64"
curl -fsSL "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/virtctl-${KUBEVIRT_VERSION}-linux-${ARCH}" \
  -o /usr/local/bin/virtctl
chmod +x /usr/local/bin/virtctl
success "virtctl installed at /usr/local/bin/virtctl"

# ── Install CDI ───────────────────────────────────────────────────────────────
info "Installing CDI ${CDI_VERSION} (Containerized Data Importer)..."
kubectl apply -f "https://github.com/kubevirt/containerized-data-importer/releases/download/${CDI_VERSION}/cdi-operator.yaml"
kubectl apply -f "https://github.com/kubevirt/containerized-data-importer/releases/download/${CDI_VERSION}/cdi-cr.yaml"
kubectl wait --for=condition=Available -n cdi cdi/cdi --timeout=300s

# CDI upload proxy NodePort
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: cdi-uploadproxy-nodeport
  namespace: cdi
spec:
  type: NodePort
  selector:
    cdi.kubevirt.io: cdi-uploadproxy
  ports:
  - port: 443
    targetPort: 8443
    nodePort: 31001
    protocol: TCP
EOF

success "================================================="
success " KubeVirt ${KUBEVIRT_VERSION} installed!"
success "================================================="
kubectl -n kubevirt get all
echo ""
info "Create VMs: kubectl apply -f manifests/vms/ubuntu-vm.yaml"
