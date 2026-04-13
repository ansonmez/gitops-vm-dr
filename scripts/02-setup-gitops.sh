#!/usr/bin/env bash
# FRESH INSTALL — Step 2: GitOps layer (ArgoCD cluster registration + ApplicationSets)
# Run AFTER 01-install-infra.sh and after Skupper link is established.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${SCRIPT_DIR}/../config.env"

if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: config.env not found. Copy config.env.example to config.env and fill in values."
  exit 1
fi
source "$CONFIG"

: "${CLOUD_PASS:?CLOUD_PASS env var is required}"
: "${ARGOCD_PASS:?ARGOCD_PASS env var is required (ArgoCD admin password on snomgm)}"

ARGOCD_DIR="${SCRIPT_DIR}/../argocd"
SNOMGM_KC="${SNOMGM_KC:-/root/kubeconfig-snomgm}"

echo "=== VM DR GitOps Setup ==="
echo "    ArgoCD server : $ARGOCD_SERVER"
echo "    c103 cluster  : $ONPREM_KC"
echo "    Cloud cluster : $CLOUD_API"
echo ""

# ── Login to ArgoCD on snomgm ─────────────────────────────────────────────────
echo "--- Logging into ArgoCD ---"
argocd login "$ARGOCD_SERVER" \
  --username admin \
  --password "$ARGOCD_PASS" \
  --insecure \
  --grpc-web

# ── Register c103 ─────────────────────────────────────────────────────────────
echo "--- Registering c103 in ArgoCD ---"
C103_CONTEXT=$(KUBECONFIG="$ONPREM_KC" oc config current-context)
KUBECONFIG="$ONPREM_KC" argocd cluster add "$C103_CONTEXT" \
  --name c103 \
  --server "$ARGOCD_SERVER" \
  --insecure \
  --grpc-web \
  --yes || echo "  c103 may already be registered"

# ── Register cloud cluster ────────────────────────────────────────────────────
echo "--- Registering cloud cluster in ArgoCD ---"
CLOUD_KC="/tmp/cloud-kubeconfig-gitops"
export KUBECONFIG="$CLOUD_KC"
oc login "$CLOUD_API" -u "$CLOUD_USER" -p "$CLOUD_PASS" \
  --insecure-skip-tls-verify 2>&1 | grep -E "Login|error" || true

CLOUD_CONTEXT=$(oc config current-context)
KUBECONFIG="$CLOUD_KC" argocd cluster add "$CLOUD_CONTEXT" \
  --name cloud \
  --server "$ARGOCD_SERVER" \
  --insecure \
  --grpc-web \
  --yes || echo "  cloud cluster may already be registered"

# ── Apply AppProject and ApplicationSets on snomgm ───────────────────────────
echo "--- Applying AppProject and ApplicationSets ---"
oc --kubeconfig="$SNOMGM_KC" apply -f "$ARGOCD_DIR/appproject-vm-dr.yaml"
oc --kubeconfig="$SNOMGM_KC" apply -f "$ARGOCD_DIR/applicationset-c103.yaml"
oc --kubeconfig="$SNOMGM_KC" apply -f "$ARGOCD_DIR/applicationset-cloud.yaml"

echo ""
echo "=== GitOps setup complete ==="
echo "ArgoCD will now watch: https://github.com/ansonmez/gitops-vm-dr.git"
echo ""
echo "Next steps:"
echo "  1. Run 'VM DR - Reconcile VMs' AAP job to populate initial VM manifests"
echo "  2. Watch ArgoCD UI: VMs should appear Synced on c103 and halted on cloud"
echo "  3. Create VMs with label dr.enabled=true — EDA will auto-reconcile"
