#!/usr/bin/env bash
# =============================================================================
# VirtCloud — KubeVirt Installation Script
# Run on  : CONTROL PLANE node
# =============================================================================
set -euo pipefail

KUBEVIRT_VERSION="${KUBEVIRT_VERSION:-v1.2.0}"
CDI_VERSION="${CDI_VERSION:-v1.58.1}"       # Containerized Data Importer

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }

export KUBECONFIG=/etc/kubernetes/admin.conf

# ── 1. Check for hardware virtualization ─────────────────────────────────────
if grep -qE '(vmx|svm)' /proc/cpuinfo; then
  info "Hardware virtualization detected (KVM)"
  USE_EMULATION=false
else
  warn "No hardware virtualization — enabling software emulation (slower)"
  USE_EMULATION=true
fi

# ── 2. Install KubeVirt operator ──────────────────────────────────────────────
info "Installing KubeVirt operator ${KUBEVIRT_VERSION}..."
kubectl apply -f "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-operator.yaml"

# ── 3. KubeVirt CR ────────────────────────────────────────────────────────────
info "Deploying KubeVirt custom resource..."
cat <<EOF | kubectl apply -f -
apiVersion: kubevirt.io/v1
kind: KubeVirt
metadata:
  name: kubevirt
  namespace: kubevirt
spec:
  certificateRotateStrategy: {}
  configuration:
    developerConfiguration:
      useEmulation: ${USE_EMULATION}
    permittedHostDevices: {}
    cpuRequest: "100m"
    networkConfiguration:
      networkInterface: "masquerade"
    smbios:
      manufacturer: VirtCloud
      product: VirtCloud-VM
  customizeComponents: {}
  imagePullPolicy: IfNotPresent
  workloadUpdateStrategy:
    workloadUpdateMethods:
    - LiveMigrate
EOF

# ── 4. Wait for KubeVirt to be ready ──────────────────────────────────────────
info "Waiting for KubeVirt to be ready (this may take 3-5 minutes)..."
kubectl -n kubevirt wait kv kubevirt \
  --for condition=Available \
  --timeout=600s

# ── 5. Install virtctl ────────────────────────────────────────────────────────
info "Installing virtctl CLI tool..."
ARCH=$(uname -m)
[[ "$ARCH" == "x86_64" ]] && ARCH="amd64"
[[ "$ARCH" == "aarch64" ]] && ARCH="arm64"

curl -fsSL "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/virtctl-${KUBEVIRT_VERSION}-linux-${ARCH}" \
  -o /usr/local/bin/virtctl
chmod +x /usr/local/bin/virtctl
success "virtctl installed at /usr/local/bin/virtctl"

# ── 6. Install CDI (Containerized Data Importer) ──────────────────────────────
info "Installing CDI ${CDI_VERSION} for VM disk image management..."
kubectl apply -f "https://github.com/kubevirt/containerized-data-importer/releases/download/${CDI_VERSION}/cdi-operator.yaml"
kubectl apply -f "https://github.com/kubevirt/containerized-data-importer/releases/download/${CDI_VERSION}/cdi-cr.yaml"

info "Waiting for CDI to be ready..."
kubectl wait --for=condition=Available \
  -n cdi cdi/cdi \
  --timeout=300s

# ── 7. CDI Upload Proxy ────────────────────────────────────────────────────────
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

success "====================================================="
success " KubeVirt ${KUBEVIRT_VERSION} installed successfully!"
success "====================================================="
kubectl -n kubevirt get all
echo ""
info "CDI upload proxy available at NodePort 31001"
info "Create VMs with: kubectl apply -f manifests/vms/"
