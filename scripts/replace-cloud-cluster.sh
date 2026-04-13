#!/usr/bin/env bash
# CLUSTER REPLACE — Run when the cloud cluster is replaced with a new one.
# Updates ArgoCD registration and re-establishes VolumeSync+Skupper for the new cluster.
# On-prem side (c103) is NOT touched.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${SCRIPT_DIR}/../config.env"

if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: config.env not found. Update config.env with new cluster values first."
  exit 1
fi
source "$CONFIG"

: "${CLOUD_PASS:?CLOUD_PASS env var is required}"
: "${ARGOCD_PASS:?ARGOCD_PASS env var is required}"

INFRA_DIR="${INFRA_DIR:-/root/demo/cloudreplication}"
SNOMGM_KC="${SNOMGM_KC:-/root/kubeconfig-snomgm}"
CLOUD_KC="/tmp/cloud-kubeconfig-replace"

echo "=== Replace Cloud Cluster ==="
echo "    New cloud API : $CLOUD_API"
echo ""
echo "This will:"
echo "  1. Remove old 'cloud' cluster from ArgoCD"
echo "  2. Register new cloud cluster in ArgoCD"
echo "  3. Re-install VolumeSync on new cloud cluster"
echo "  4. Re-install Skupper on new cloud cluster"
echo "  5. Re-establish Skupper link (requires manual token step)"
echo "  6. Re-run reconciler to recreate VolumeSync objects on new cluster"
echo ""
read -rp "Continue? (yes/no): " CONFIRM
[[ "$CONFIRM" == "yes" ]] || { echo "Aborted."; exit 0; }

# ── Login to new cloud cluster ────────────────────────────────────────────────
export KUBECONFIG="$CLOUD_KC"
oc login "$CLOUD_API" -u "$CLOUD_USER" -p "$CLOUD_PASS" \
  --insecure-skip-tls-verify 2>&1 | grep -E "Login|error" || true

# ── Update ArgoCD cluster registration ───────────────────────────────────────
echo "--- Updating ArgoCD cluster registration ---"
argocd login "$ARGOCD_SERVER" \
  --username admin \
  --password "$ARGOCD_PASS" \
  --insecure \
  --grpc-web

argocd cluster rm cloud --yes 2>/dev/null || echo "  Old cloud cluster not found in ArgoCD"

CLOUD_CONTEXT=$(oc config current-context)
KUBECONFIG="$CLOUD_KC" argocd cluster add "$CLOUD_CONTEXT" \
  --name cloud \
  --server "$ARGOCD_SERVER" \
  --insecure \
  --grpc-web \
  --yes

# ── Re-apply namespace on new cloud cluster ───────────────────────────────────
echo "--- Namespace ---"
oc --kubeconfig="$CLOUD_KC" apply -f "$INFRA_DIR/01-namespace-both.yaml"

# ── Re-install VolumeSync on new cloud cluster ────────────────────────────────
echo "--- VolumeSync ---"
oc --kubeconfig="$CLOUD_KC" apply -f "$INFRA_DIR/02-volsync-sub-cloud.yaml"
echo -n "Waiting for VolumeSync CSV"
for i in $(seq 1 40); do
  PHASE=$(oc --kubeconfig="$CLOUD_KC" get csv -n openshift-operators \
    -o jsonpath='{.items[?(@.spec.displayName=="VolSync")].status.phase}' 2>/dev/null || true)
  [[ "$PHASE" == "Succeeded" ]] && { echo " done"; break; }
  echo -n "."; sleep 5
done

# ── Re-install Skupper on new cloud cluster ───────────────────────────────────
echo "--- Skupper ---"
oc --kubeconfig="$CLOUD_KC" apply -f "$INFRA_DIR/04-skupper-sub-cloud.yaml"
sleep 20
oc --kubeconfig="$CLOUD_KC" apply -f "$INFRA_DIR/06-skupper-site-cloud.yaml"

echo ""
echo "--- Manual step required: Re-establish Skupper link ---"
echo "Run: bash $INFRA_DIR/08-skupper-link-and-volsync-connect.sh \\"
echo "  --cloud-api $CLOUD_API \\"
echo "  --cloud-user $CLOUD_USER \\"
echo "  --onprem-kc $ONPREM_KC \\"
echo "  --namespace $NAMESPACE"
echo ""
echo "After Skupper link is up, trigger reconciler to recreate VolumeSync objects:"
echo "  oc --kubeconfig=$ONPREM_KC create job --from=cronjob/vm-replication-reconciler \\"
echo "    manual-rerun-\$(date +%s) -n $NAMESPACE"
echo ""
echo "=== Cloud cluster replacement complete ==="
