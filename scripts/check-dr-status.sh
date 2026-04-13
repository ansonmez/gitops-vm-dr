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
echo "── ArgoCD Application status (on snomgm) ──"
SNOMGM_KC="${SNOMGM_KC:-/root/kubeconfig-snomgm}"
KUBECONFIG="$SNOMGM_KC" oc get applications -n openshift-gitops \
  -l "app.kubernetes.io/managed-by=openshift-gitops" \
  -o custom-columns="NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status" \
  2>/dev/null | grep -E "vm-dr|NAME" || \
KUBECONFIG="$SNOMGM_KC" oc get applications -n openshift-gitops \
  -o custom-columns="NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status" \
  2>/dev/null | grep -E "vm-dr|NAME" || echo "  (no vm-dr applications found)"
