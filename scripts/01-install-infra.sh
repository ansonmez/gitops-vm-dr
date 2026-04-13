#!/usr/bin/env bash
# FRESH INSTALL — Step 1: Infrastructure (VolumeSync + Skupper + Reconciler CronJob)
# Applies /root/demo/cloudreplication files 01-11 to set up the replication layer.
# Run this BEFORE 02-setup-gitops.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${SCRIPT_DIR}/../config.env"

if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: config.env not found. Copy config.env.example to config.env and fill in values."
  exit 1
fi
# shellcheck source=/dev/null
source "$CONFIG"

# CLOUD_PASS must be set as env var — never in config.env
: "${CLOUD_PASS:?CLOUD_PASS env var is required}"

INFRA_DIR="${INFRA_DIR:-/root/demo/cloudreplication}"
CLOUD_KC="/tmp/cloud-kubeconfig-setup"

echo "=== VM DR Infrastructure Install ==="
echo "    On-prem kubeconfig : $ONPREM_KC"
echo "    Cloud API          : $CLOUD_API"
echo "    Namespace          : $NAMESPACE"
echo ""

# Login to cloud cluster
export KUBECONFIG="$CLOUD_KC"
oc login "$CLOUD_API" -u "$CLOUD_USER" -p "$CLOUD_PASS" \
  --insecure-skip-tls-verify 2>&1 | grep -E "Login|error" || true

echo "--- 01: Namespace on both clusters ---"
oc --kubeconfig="$ONPREM_KC" apply -f "$INFRA_DIR/01-namespace-both.yaml"
oc --kubeconfig="$CLOUD_KC"  apply -f "$INFRA_DIR/01-namespace-both.yaml"

echo "--- 02-03: VolumeSync subscriptions ---"
oc --kubeconfig="$CLOUD_KC"  apply -f "$INFRA_DIR/02-volsync-sub-cloud.yaml"
oc --kubeconfig="$ONPREM_KC" apply -f "$INFRA_DIR/03-volsync-sub-onprem.yaml"

echo "--- 04-07: Skupper operator + sites ---"
oc --kubeconfig="$CLOUD_KC"  apply -f "$INFRA_DIR/04-skupper-sub-cloud.yaml"
oc --kubeconfig="$ONPREM_KC" apply -f "$INFRA_DIR/05-skupper-sub-onprem.yaml"
sleep 30  # wait for operator to be ready
oc --kubeconfig="$CLOUD_KC"  apply -f "$INFRA_DIR/06-skupper-site-cloud.yaml"
oc --kubeconfig="$ONPREM_KC" apply -f "$INFRA_DIR/07-skupper-site-onprem.yaml"

echo "--- 08: Skupper link + VolumeSync connect ---"
echo "NOTE: This step requires manual token exchange."
echo "Run: bash $INFRA_DIR/08-skupper-link-and-volsync-connect.sh \\"
echo "  --cloud-api $CLOUD_API \\"
echo "  --cloud-user $CLOUD_USER \\"
echo "  --onprem-kc $ONPREM_KC \\"
echo "  --namespace $NAMESPACE"
echo ""

echo "--- 09-11: Reconciler CronJob ---"
bash "$INFRA_DIR/10-apply-reconciler.sh" \
  --cloud-api   "$CLOUD_API" \
  --cloud-user  "$CLOUD_USER" \
  --cloud-pass  "$CLOUD_PASS" \
  --onprem-kc   "$ONPREM_KC" \
  --namespace   "$NAMESPACE"

echo ""
echo "=== Infrastructure install complete ==="
echo "Next: Run scripts/02-setup-gitops.sh to configure ArgoCD"
