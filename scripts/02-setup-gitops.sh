#!/usr/bin/env bash
# FRESH INSTALL — Step 2: GitOps layer
# Registers c103 and cloud cluster in ArgoCD using oc only (no argocd CLI).
# Applies AppProject and ApplicationSets to snomgm's openshift-gitops namespace.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${SCRIPT_DIR}/../config.env"

if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: config.env not found. Copy config.env.example to config.env and fill in values."
  exit 1
fi
source "$CONFIG"

: "${CLOUD_PASS:?CLOUD_PASS env var is required}"

ARGOCD_DIR="${SCRIPT_DIR}/../argocd"
SNOMGM_KC="${SNOMGM_KC:-/root/kubeconfig-snomgm}"
CLOUD_KC="/tmp/cloud-kubeconfig-gitops"
ARGOCD_NS="openshift-gitops"

echo "=== VM DR GitOps Setup (oc only) ==="
echo "    snomgm kubeconfig : $SNOMGM_KC"
echo "    c103 kubeconfig   : $ONPREM_KC"
echo "    Cloud API         : $CLOUD_API"
echo ""

# ── Login to cloud cluster ────────────────────────────────────────────────────
export KUBECONFIG="$CLOUD_KC"
oc login "$CLOUD_API" -u "$CLOUD_USER" -p "$CLOUD_PASS" \
  --insecure-skip-tls-verify 2>&1 | grep -E "Login|error" || true

# ── Create ArgoCD service accounts on both clusters for ArgoCD to use ─────────
echo "--- Creating ArgoCD service account on c103 ---"
KUBECONFIG="$ONPREM_KC" oc create sa argocd-manager \
  -n kube-system 2>/dev/null || echo "  (already exists)"
KUBECONFIG="$ONPREM_KC" oc create clusterrolebinding argocd-manager \
  --clusterrole=cluster-admin \
  --serviceaccount=kube-system:argocd-manager 2>/dev/null || echo "  (already exists)"

echo "--- Creating ArgoCD service account on cloud cluster ---"
KUBECONFIG="$CLOUD_KC" oc create sa argocd-manager \
  -n kube-system 2>/dev/null || echo "  (already exists)"
KUBECONFIG="$CLOUD_KC" oc create clusterrolebinding argocd-manager \
  --clusterrole=cluster-admin \
  --serviceaccount=kube-system:argocd-manager 2>/dev/null || echo "  (already exists)"

# ── Get tokens ────────────────────────────────────────────────────────────────
echo "--- Getting service account tokens ---"

# c103 token
C103_TOKEN=$(KUBECONFIG="$ONPREM_KC" oc create token argocd-manager \
  -n kube-system --duration=8760h 2>/dev/null)

# c103 CA cert
C103_CA=$(KUBECONFIG="$ONPREM_KC" oc get cm kube-root-ca.crt \
  -n kube-system -o jsonpath='{.data.ca\.crt}' | base64 -w0)

# c103 server URL
C103_SERVER=$(KUBECONFIG="$ONPREM_KC" oc whoami --show-server)

# Cloud token
CLOUD_TOKEN=$(KUBECONFIG="$CLOUD_KC" oc create token argocd-manager \
  -n kube-system --duration=8760h 2>/dev/null)

# Cloud CA cert
CLOUD_CA=$(KUBECONFIG="$CLOUD_KC" oc get cm kube-root-ca.crt \
  -n kube-system -o jsonpath='{.data.ca\.crt}' | base64 -w0)

# ── Create ArgoCD cluster Secrets on snomgm ───────────────────────────────────
echo "--- Registering c103 in ArgoCD (via Secret) ---"
KUBECONFIG="$SNOMGM_KC" oc apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cluster-c103
  namespace: ${ARGOCD_NS}
  labels:
    argocd.argoproj.io/secret-type: cluster
type: Opaque
stringData:
  name: c103
  server: "${C103_SERVER}"
  config: |
    {
      "bearerToken": "${C103_TOKEN}",
      "tlsClientConfig": {
        "insecure": false,
        "caData": "${C103_CA}"
      }
    }
EOF

echo "--- Registering cloud cluster in ArgoCD (via Secret) ---"
KUBECONFIG="$SNOMGM_KC" oc apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cluster-cloud
  namespace: ${ARGOCD_NS}
  labels:
    argocd.argoproj.io/secret-type: cluster
type: Opaque
stringData:
  name: cloud
  server: "${CLOUD_API}"
  config: |
    {
      "bearerToken": "${CLOUD_TOKEN}",
      "tlsClientConfig": {
        "insecure": true
      }
    }
EOF

# ── Apply AppProject and ApplicationSets ──────────────────────────────────────
echo "--- Applying AppProject ---"
KUBECONFIG="$SNOMGM_KC" oc apply -f "$ARGOCD_DIR/appproject-vm-dr.yaml"

echo "--- Applying ApplicationSets ---"
KUBECONFIG="$SNOMGM_KC" oc apply -f "$ARGOCD_DIR/applicationset-c103.yaml"
KUBECONFIG="$SNOMGM_KC" oc apply -f "$ARGOCD_DIR/applicationset-cloud.yaml"

echo ""
echo "=== GitOps setup complete ==="
echo ""
echo "Clusters registered in ArgoCD:"
KUBECONFIG="$SNOMGM_KC" oc get secret -n "$ARGOCD_NS" \
  -l argocd.argoproj.io/secret-type=cluster \
  -o custom-columns="NAME:.metadata.name,SERVER:.data.server" 2>/dev/null || true
echo ""
echo "Next steps:"
echo "  1. Run 'VM DR - Reconcile VMs' AAP job to populate initial VM manifests"
echo "  2. Watch ArgoCD UI: VMs should appear Synced on c103 and halted on cloud"
