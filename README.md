# GitOps VM Disaster Recovery

Automated VM replication and failover across two OpenShift clusters using:
- **VolumeSync** (rsync-tls) — disk replication every 30 minutes
- **Skupper** (Red Hat Service Interconnect) — cross-cluster network without VPN/Submariner
- **ArgoCD** on hub cluster — GitOps push to both source and DR clusters
- **Ansible AAP + EDA** — auto-generates VM manifests, watches for VM lifecycle events

## Architecture

```
GitHub (this repo)
       │ poll (30s)
       ▼
ArgoCD on snomgm ──push──► c103 (on-prem)  → VMs running, PVCs managed
                  ──push──► cloud cluster   → VMs halted (DR standby)

AAP on sno16
  EDA rulebook ──watch──► c103 vmtocloud namespace
  ├── VM create/update → "VM DR - Reconcile VMs" job → commit manifests to Git
  ├── VM delete        → "VM DR - Garbage Collect" job → remove manifests from Git
  └── Manual failover  → "VM DR - Activate Failover" job → flip power patch → ArgoCD syncs

VolumeSync (every 30 min):  c103 PVC ──rsync-tls over Skupper──► cloud PVC
```

## Prerequisites

- `oc` CLI and `argocd` CLI available on bastion
- `git` configured with access to this repo
- ArgoCD running on snomgm (`openshift-gitops` namespace)
- AAP running on sno16 with EDA enabled

## Configuration

Copy and fill in `config.env.example`:
```bash
cp config.env.example config.env
# Edit config.env with your cluster values
```

`config.env` is gitignored — never commit it. Sensitive values (passwords, tokens) are passed as environment variables or stored in AAP vault, never in files.

---

## Section 1: Fresh Install (from scratch)

### Step 1 — Infrastructure (VolumeSync + Skupper + Reconciler)

```bash
export CLOUD_PASS=<cloud-cluster-admin-password>
bash scripts/01-install-infra.sh
```

When prompted, run the Skupper link script manually (it generates a one-time token):
```bash
export CLOUD_PASS=<password>
bash /root/demo/cloudreplication/08-skupper-link-and-volsync-connect.sh \
  --cloud-api $CLOUD_API \
  --cloud-user $CLOUD_USER \
  --onprem-kc $ONPREM_KC \
  --namespace vmtocloud
```

### Step 2 — GitOps layer (ArgoCD)

```bash
export CLOUD_PASS=<cloud-cluster-admin-password>
export ARGOCD_PASS=<argocd-admin-password-on-snomgm>
export SNOMGM_KC=/path/to/kubeconfig-snomgm
bash scripts/02-setup-gitops.sh
```

### Step 3 — AAP Job Templates (configure manually in AAP UI)

Create the following in AAP at `https://aap-platform-ansible-automation-platform.apps.sno16.anillocal.com/`:

| Job Template Name | Playbook | Extra vars |
|---|---|---|
| VM DR - Reconcile VMs | `ansible/reconcile_vms.yml` | see below |
| VM DR - Garbage Collect | `ansible/garbage_collector.yml` | see below |
| VM DR - Activate Failover | `ansible/activate_failover.yml` | survey: `action`, `vm_name` |

**Required AAP credentials:**
- `c103-kubeconfig` — Machine credential: kubeconfig file for c103
- `github-token` — Custom credential: `GIT_TOKEN` env var with GitHub PAT (repo write)
- `cloud-cluster-creds` — Custom credential: `CLOUD_PASS` env var

**Required AAP variables** (set in job template or as extra vars):
```yaml
NAMESPACE: vmtocloud
GIT_REPO: https://github.com/ansonmez/gitops-vm-dr.git
GIT_BRANCH: main
ONPREM_SC: democratic-csi-nfs
```

### Step 4 — EDA Rulebook Activation

In AAP EDA, create a Rulebook Activation pointing to `ansible/vm-dr-eda.yaml`.
Connect it to the c103 cluster API using an EDA credential with the c103 kubeconfig.

### Step 5 — Create your first VM

Label the VM to opt into DR:
```bash
oc label vm <vm-name> -n vmtocloud dr.enabled=true --kubeconfig /root/kubeconfig-c103
```

EDA will detect the label and trigger `VM DR - Reconcile VMs` automatically.
Or run it manually in AAP.

Within ~2 minutes the VM manifest will appear in Git and ArgoCD will sync a halted copy to the cloud cluster.

---

## Section 2: Replace Cloud Cluster

When the cloud cluster is decommissioned and replaced:

1. Update `config.env` with the new cluster's API URL and credentials
2. Run:
```bash
export CLOUD_PASS=<new-cluster-password>
export ARGOCD_PASS=<argocd-password>
bash scripts/replace-cloud-cluster.sh
```
3. Follow the Skupper link prompt (manual token exchange)
4. Trigger a reconciler run to recreate VolumeSync objects on the new cluster

The on-prem side (c103 VMs, VolumeSync sources, Skupper on-prem site) is **not touched**.

---

## Section 3: Daily Operations

### Create a VM (auto-replicated)
```bash
# Apply VM manifest with dr.enabled=true label
oc apply -f my-vm.yaml --kubeconfig /root/kubeconfig-c103
oc label vm <vm-name> -n vmtocloud dr.enabled=true --kubeconfig /root/kubeconfig-c103
# EDA triggers reconcile → manifest in Git → ArgoCD creates halted VM on cloud
```

### Check DR status
```bash
export CLOUD_PASS=<password>
bash scripts/check-dr-status.sh
```

### Trigger failover
```bash
# Via AAP: run "VM DR - Activate Failover" with action=failover
# Or manually edit vms/overlays/cloud/vmtocloud/components/failover-control/kustomization.yaml:
#   change: patches/power-off.yaml → patches/power-on.yaml
# Then: git commit -m "failover: activate" && git push
# ArgoCD syncs within 30s → VM starts on cloud
```

### Trigger failback
```bash
# Via AAP: run "VM DR - Activate Failover" with action=failback
# This sets cloud VMs back to halted; on-prem VMs were never stopped by failover
```

### Delete a VM (auto-cleanup)
```bash
oc delete vm <vm-name> -n vmtocloud --kubeconfig /root/kubeconfig-c103
# EDA triggers garbage collect → manifests removed from Git → ArgoCD prunes cloud VM
# VolumeSync reconciler CronJob cleans up ReplicationSource/Destination automatically
```

---

## Section 4: Failover Flow (end-to-end, ~1-2 min)

```
1. VolumeSync replicates disk c103→cloud every 30 min (RPO: 30 min)
2. ArgoCD keeps VM object halted on cloud continuously (RTO: ~30s after trigger)
3. Operator runs AAP "VM DR - Activate Failover" (or edits Git directly)
4. failover-control kustomization flips power-off → power-on
5. git push → ArgoCD detects change within 30s
6. ArgoCD patches VirtualMachine.spec.running = true on cloud
7. KubeVirt starts VM using VolumeSync-replicated PVC (already writable)
8. VM is running on cloud cluster
```

No storage promotion step is needed — VolumeSync `copyMethod: Direct` keeps the destination PVC always writable on the cloud cluster.

---

## Section 5: Future — Failback Storage (TODO)

> **Not implemented yet.** This section is a placeholder for future work.

Currently VolumeSync replicates one-way: c103 → cloud. During failover the VM runs on cloud and writes to the cloud PVC. If you want to failback (move the VM back to c103) with the latest data:

1. **Stop VM on cloud** (failback action in `activate_failover.yml` does this)
2. **Reverse replication direction**: set up a new VolumeSync ReplicationSource on cloud pointing back to c103
3. **Wait for sync to complete**
4. **Delete cloud ReplicationSource** and restart VM on c103

This requires changes to `reconcile.sh` and a new `activate_failback_storage.yml` playbook. The current architecture does not block this — VolumeSync supports bidirectional replication.

---

## Repo Structure

```
gitops-vm-dr/
  config.env.example          # copy to config.env (gitignored)
  vms/
    base/vmtocloud/           # VM + PVC manifests (auto-generated by AAP)
    overlays/
      c103/vmtocloud/         # source overlay (VM + PVC, running)
      cloud/vmtocloud/        # DR overlay (VM only, halted by default)
        components/
          failover-control/   # edit kustomization.yaml to trigger failover
  argocd/
    appproject-vm-dr.yaml
    applicationset-c103.yaml
    applicationset-cloud.yaml
  ansible/
    reconcile_vms.yml
    garbage_collector.yml
    activate_failover.yml
    vm-dr-eda.yaml
    tasks/
    templates/
  scripts/
    01-install-infra.sh
    02-setup-gitops.sh
    replace-cloud-cluster.sh
    check-dr-status.sh
```
