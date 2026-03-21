#!/usr/bin/env bash
# =============================================================================
# VirtCloud Sandbox — Deploy / Update UI Dashboard
# Run from the repo root: bash sandbox/deploy-ui.sh
# =============================================================================
set -euo pipefail

CYAN='\033[0;36m'; GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
die()     { echo -e "${RED}[ERR]${NC}  $*"; exit 1; }

UI_FILE="${1:-ui/virtcloud-ui.html}"

[[ -f "$UI_FILE" ]] || die "File not found: $UI_FILE\nMake sure ui/virtcloud-ui.html exists in your repo."

info "Loading ${UI_FILE} into Kubernetes ConfigMap..."
kubectl create namespace virtcloud-ui --dry-run=client -o yaml | kubectl apply -f -

kubectl create configmap virtcloud-ui-html \
  --from-file=index.html="${UI_FILE}" \
  --namespace virtcloud-ui \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f sandbox/virtcloud-ui-sandbox.yaml

info "Waiting for UI pod to be ready..."
kubectl rollout status deployment/virtcloud-ui -n virtcloud-ui --timeout=60s

success "VirtCloud UI is live at http://localhost:30080"
