#!/usr/bin/env bash
# Show DR replication status: VolumeSync lag, ArgoCD sync state, VM power state on both clusters.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${SCRIPT_DIR}/../config.env"
[[ -f "$CONFIG" ]] && source "$CONFIG"

: "${CLOUD_PASS:?CLOUD_PASS env var is required}"

CLOUD_KC="/tmp/cloud-kubeconfig-status"
export KUBECONFIG="$CLOUD_KC"
oc login "$CLOUD_API" -u "$CLOUD_USER" -p "$CLOUD_PASS" \
  --insecure-skip-tls-verify 2>&1 | grep -E "Login|error" || true

echo "=== VM DR Status ==="
echo ""

echo "── VolumeSync ReplicationSources (on-prem c103) ──"
oc --kubeconfig="$ONPREM_KC" get replicationsource -n "$NAMESPACE" \
  -o custom-columns=\
"NAME:.metadata.name,\
LAST-SYNC:.status.lastSyncTime,\
DURATION:.status.lastSyncDuration,\
NEXT:.status.nextSyncTime" 2>/dev/null || echo "  (none)"

echo ""
echo "── VolumeSync ReplicationDestinations (cloud) ──"
oc --kubeconfig="$CLOUD_KC" get replicationdestination -n "$NAMESPACE" \
  -o custom-columns=\
"NAME:.metadata.name,\
LAST-SYNC:.status.lastSyncTime" 2>/dev/null || echo "  (none)"

echo ""
echo "── VMs on on-prem c103 ──"
oc --kubeconfig="$ONPREM_KC" get vm -n "$NAMESPACE" \
  -o custom-columns="NAME:.metadata.name,RUNNING:.spec.running,STATUS:.status.printableStatus" \
  2>/dev/null || echo "  (none)"

echo ""
echo "── VMs on cloud ──"
oc --kubeconfig="$CLOUD_KC" get vm -n "$NAMESPACE" \
  -o custom-columns="NAME:.metadata.name,RUNNING:.spec.running,STATUS:.status.printableStatus" \
  2>/dev/null || echo "  (none)"

echo ""
echo "── PVCs on cloud (VolumeSync destinations) ──"
oc --kubeconfig="$CLOUD_KC" get pvc -n "$NAMESPACE" 2>/dev/null || echo "  (none)"

echo ""
echo "── ArgoCD Application status ──"
argocd app list --server "$ARGOCD_SERVER" --insecure --grpc-web 2>/dev/null \
  | grep vm-dr || echo "  (argocd not configured or no vm-dr apps)"
