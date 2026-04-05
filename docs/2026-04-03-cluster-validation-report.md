# Cluster Validation Report

**Date:** 2026-04-03
**Cluster:** AOS (aos01–03, kubeadm, Kubernetes v1.35.3)

---

## Summary

| Area | Status |
|------|--------|
| Nodes | Healthy |
| Control plane | Healthy (minor restart history on aos01) |
| CNI (Cilium) | Healthy |
| etcd | Healthy |
| ArgoCD | All 8 apps Synced + Healthy |
| Crossplane | 4 providers Installed + Healthy |
| Kyverno | Controllers running, policies active |
| **Kyverno pods in wrong namespace** | **Issue — see below** |
| **Failed pods in `default`** | **Issue — see below** |
| **Kyverno policy violations on system workloads** | **Expected / known** |
| **No resource limits on ArgoCD/Crossplane** | **Warning** |

---

## Nodes

```
aos01  Ready  control-plane  8 CPU  32 GB  4% CPU  10% MEM
aos02  Ready  control-plane  8 CPU  32 GB  4% CPU   6% MEM
aos03  Ready  control-plane  8 CPU  32 GB  4% CPU   8% MEM
```

- All nodes Ready, no pressure conditions (Memory/Disk/PID)
- Cluster is 3-node control-plane only — **no dedicated worker nodes**
- All nodes at ≤10% memory utilization; plenty of headroom

**Note:** No taints on control-plane nodes. This is intentional for a homelab all-in-one setup but means all workloads schedule on control-plane nodes.

---

## Control Plane

All components running on all three nodes. aos01 shows 2 restarts each on:
- `kube-apiserver`, `kube-controller-manager`, `kube-scheduler`, `etcd`, `kube-vip`, `cilium`

These appear to be from the initial cluster setup ~39h ago and have been stable since (last restart ~23h ago). No ongoing crash loops.

**etcd:** All 3 members ready and stable on aos02/aos03. aos01 shows 2 historical restarts but currently healthy.

---

## Issue 1 — Kyverno Pods Running in `default` Namespace

**Severity: High**

Kyverno's main controllers are running in the `default` namespace instead of the `kyverno` namespace:

```
default/kyverno-admission-controller-7fbd99dd4-z6hcw    Running
default/kyverno-background-controller-778bffc669-qjj5p  Running
default/kyverno-cleanup-controller-685d477d7d-4fq66     Running
default/kyverno-reports-controller-6c666d96-x47kl       Running
```

This is caused by a Helm release state mismatch — Kyverno was first installed targeting `default` before the namespace was properly configured. The ArgoCD Application points to `namespace: kyverno` but the Helm release left the original deployment objects in `default`.

**Impact:**
- Triggers the `disallow-default-namespace` Enforce policy on these pods
- Metrics probes fail (`kyverno-svc-metrics.default:8000` is unreachable from `default`)
- ServiceAccount RBAC is misaligned (SA lives in `kyverno`, pods run in `default`)
- The `kyverno-rm-mutatingwhconfig` and `kyverno-rm-validatingwhconfig` jobs fail due to RBAC mismatch

**Fix:**
```bash
# Delete stale resources from default namespace — ArgoCD will recreate in kyverno
kubectl delete deployment -n default \
  kyverno-admission-controller \
  kyverno-background-controller \
  kyverno-cleanup-controller \
  kyverno-reports-controller 2>/dev/null

# Then force sync to recreate in correct namespace
kubectl -n argocd patch app kyverno --type merge \
  -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"HEAD","syncStrategy":{"apply":{}}}}}'
```

---

## Issue 2 — Failed Pods Accumulating in `default` Namespace

**Severity: Medium**

11 failed pods are stuck in `default` from Kyverno's Helm install jobs and liveness probes:

```
kyverno-admission-controller-metrics   Error
kyverno-cleanup-controller-liveness    Error
kyverno-cleanup-controller-metrics     Error
kyverno-cleanup-controller-readiness   Error
kyverno-reports-controller-metrics     Error
kyverno-rm-mutatingwhconfig-*          Error  (3 instances)
kyverno-rm-validatingwhconfig-*        Error  (3 instances)
```

Root causes:
- **Metrics pods**: trying to reach `kyverno-svc-metrics.default:8000` — service doesn't exist in `default`
- **rm-webhook jobs**: `ServiceAccount kyverno-admission-controller` in `default` lacks RBAC to list `MutatingWebhookConfigurations`

These are stale one-shot pods/jobs from repeated Helm installs. They won't self-clean.

**Fix:**
```bash
kubectl delete pods -n default --field-selector=status.phase=Failed
kubectl delete jobs -n default -l app.kubernetes.io/instance=kyverno
```

---

## Warning — No Resource Limits on ArgoCD and Crossplane Pods

**Severity: Low–Medium**

The following namespaces have containers without CPU/memory limits:

**ArgoCD** (7 containers): `application-controller`, `applicationset-controller`, `dex-server`, `notifications-controller`, `redis`, `repo-server`, `server`

**Crossplane providers** (4 containers): `provider-family-aws`, `provider-family-azure`, `provider-family-gcp`, `provider-terraform`

Without limits, these pods can consume unbounded resources under load and could starve other workloads. This also triggers the `require-resource-limits` Kyverno Audit policy.

**Fix:** Add resource requests/limits to ArgoCD values and Crossplane provider configs. Example for ArgoCD `values.yaml`:
```yaml
server:
  resources:
    requests: {cpu: 100m, memory: 128Mi}
    limits: {cpu: 500m, memory: 256Mi}
applicationSet:
  resources:
    requests: {cpu: 50m, memory: 64Mi}
    limits: {cpu: 200m, memory: 128Mi}
```

---

## Kyverno Policy Violations (Expected)

Kyverno's `kyverno-policies` baseline profile is generating Audit violations against system workloads that legitimately need privileged access. These are **expected and not actionable** — system components must use host namespaces, hostPath, and privileged mode:

| Workload | Violations |
|----------|-----------|
| `kube-proxy` | `disallow-host-namespaces`, `disallow-host-path`, `disallow-privileged-containers` |
| `kube-vip` | `disallow-host-namespaces`, `disallow-host-path`, `disallow-capabilities` |
| `kube-scheduler` | `disallow-host-namespaces`, `disallow-host-path`, `disallow-host-ports` |
| `local-path-provisioner` | `require-resource-limits` |

**Recommendation:** Add a `PolicyException` for `kube-system` workloads to suppress noise from these expected violations. This keeps policy reports clean so real violations are visible.

```yaml
apiVersion: kyverno.io/v2
kind: PolicyException
metadata:
  name: kube-system-exception
  namespace: kyverno
spec:
  exceptions:
    - policyName: disallow-host-namespaces
      ruleNames: ["host-namespaces", "autogen-host-namespaces"]
    - policyName: disallow-host-path
      ruleNames: ["host-path", "autogen-host-path"]
    - policyName: disallow-privileged-containers
      ruleNames: ["privileged-containers", "autogen-privileged-containers"]
    - policyName: disallow-capabilities
      ruleNames: ["adding-capabilities", "autogen-adding-capabilities"]
    - policyName: disallow-host-ports
      ruleNames: ["host-ports-none", "autogen-host-ports-none"]
  match:
    any:
      - resources:
          namespaces: ["kube-system"]
```

---

## `require-crossplane-labels` Error Loop

The `require-crossplane-labels` custom policy targets `*.aws.upbound.io/*`, `*.gcp.upbound.io/*`, `*.azure.upbound.io/*` — but only the provider-family CRDs are installed, not managed resource CRDs (e.g. `provider-aws-s3`). Kyverno logs a tight error loop:

```
failed to fetch resource group versions  error="resource not found"  kind=*.aws.upbound.io
```

This is non-fatal but noisy and can degrade admission controller responsiveness under load. It will resolve automatically once actual service providers are installed. No action needed now.

---

## Storage

- **StorageClass:** `local-path` (default, Rancher local-path-provisioner)
- **ReclaimPolicy:** `Delete` — PVs are deleted when PVCs are deleted; no data retention
- No PVs or PVCs currently in use

**Note:** `local-path` is node-local storage. Pods are not portable across nodes if they use PVCs. Acceptable for a homelab but worth noting for stateful workloads.

---

## Admission Webhooks

9 validating + 3 mutating webhooks active, all from Kyverno and Crossplane. No stale or orphaned webhooks.

---

## RBAC

No unexpected `cluster-admin` bindings. Only the standard kubeadm groups (`system:masters`, `kubeadm:cluster-admins`) have cluster-admin access.

---

## Prioritized Action List

| Priority | Action |
|----------|--------|
| 1 | Delete failed pods in `default` namespace |
| 2 | Delete stale Kyverno deployments from `default`, force ArgoCD resync to `kyverno` namespace |
| 3 | Add `PolicyException` for `kube-system` to clean up policy violation noise |
| 4 | Add resource limits to ArgoCD and Crossplane provider values |
| 5 | Install Crossplane managed resource providers when cloud access is configured |
