#!/usr/bin/env bash
# =============================================================================
# VirtCloud Sandbox — Teardown
# Destroys the KinD cluster and cleans up local storage
# Usage: bash sandbox/teardown.sh
# =============================================================================
set -uo pipefail

YELLOW='\033[1;33m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
CLUSTER_NAME="virtcloud-sandbox"

echo -e "${YELLOW}This will destroy cluster '${CLUSTER_NAME}' and all VMs inside it.${NC}"
read -rp "Continue? [y/N] " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

echo -e "${CYAN}[INFO]${NC}  Deleting KinD cluster..."
kind delete cluster --name "${CLUSTER_NAME}" 2>/dev/null || true

echo -e "${CYAN}[INFO]${NC}  Cleaning up local storage directories..."
rm -rf /tmp/virtcloud-sandbox/

echo -e "${GREEN}[OK]${NC}    Sandbox destroyed cleanly."
echo -e "${GREEN}[OK]${NC}    Run 'bash sandbox/bootstrap.sh' to start fresh."
