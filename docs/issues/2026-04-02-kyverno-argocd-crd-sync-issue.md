# Kyverno ArgoCD CRD Sync Issue

**Date:** 2026-04-02
**Severity:** Medium — platform functional, Kyverno pods healthy, but ArgoCD showed OutOfSync
**Status:** Resolved

---

## Symptom

ArgoCD `kyverno` Application showed `OutOfSync, Healthy`. Every sync attempt failed with:

```
one or more objects failed to apply, reason: error when patching "/dev/shm/...":
CustomResourceDefinition.apiextensions.k8s.io "clusterpolicies.kyverno.io" is invalid:
metadata.annotations: Too long: may not be more than 262144 bytes
```

Kyverno pods were running correctly — the issue was purely in ArgoCD's ability to reconcile the CRD resources.

---

## Root Cause

### 1. ArgoCD falls back to client-side apply (CSA) for Helm CRDs

ArgoCD v3.3.6 with `ServerSideApply=true` uses server-side apply (SSA) for most resources, but falls back to **client-side apply (CSA)** when rendering Helm charts that embed CRDs in sub-charts (Kyverno's `crds` and `kyverno-api` sub-charts).

CSA stores the entire applied manifest in the `kubectl.kubernetes.io/last-applied-configuration` annotation. For large CRDs this annotation exceeds Kubernetes' 262,144-byte annotation size limit.

### 2. Kyverno 3.7.1 ships extremely large CRDs

The two largest CRDs — `clusterpolicies.kyverno.io` and `policies.kyverno.io` — are each **~1.4 MB** of OpenAPI validation schema. Their CSA annotation would be ~1.4 MB, far above the 262 KB limit.

| CRD | Schema size | Would-be annotation size |
|-----|-------------|--------------------------|
| `clusterpolicies.kyverno.io` | ~1.4 MB | Exceeds limit → sync fails |
| `policies.kyverno.io` | ~1.4 MB | Exceeds limit → sync fails |
| `mutatingpolicies.policies.kyverno.io` | ~240 KB | Under limit → sync succeeds but annotation bloat |
| `imagevalidatingpolicies.policies.kyverno.io` | ~235 KB | Under limit |

### 3. kube-apiserver normalizes CRD schemas, causing perpetual diffs

Even for the CRDs that don't exceed the limit, kube-apiserver normalizes `.spec.versions[*].schema.openAPIV3Schema` (adds `x-kubernetes-preserve-unknown-fields`, default values, etc.) after each apply. ArgoCD sees the live state diverge from the Helm-rendered desired state and triggers another sync, re-adding the annotation — an infinite loop.

### 4. `policies.kyverno.io` sub-chart CRDs define `labels: {}`

The `kyverno-api` sub-chart templates emit `labels: {}` and `annotations: {}`. After Kubernetes stores these objects, the empty maps are normalized away (field absent). ArgoCD saw `labels: {}` (desired) vs no labels field (live) as a persistent diff, even after schema normalization was resolved.

---

## Fix

### Step 1 — Strip oversized annotations from all Kyverno CRDs

```bash
for crd in $(kubectl get crd | grep kyverno | awk '{print $1}'); do
  kubectl annotate crd $crd kubectl.kubernetes.io/last-applied-configuration-
done
```

### Step 2 — Re-apply all Kyverno CRDs via server-side apply

This establishes clean SSA ownership under `argocd-controller` without ever touching the annotation:

```bash
helm template kyverno kyverno/kyverno --version 3.7.1 | \
  kubectl apply --server-side --field-manager=argocd-controller --force-conflicts -f -
```

### Step 3 — Configure `ignoreDifferences` in the ArgoCD Application

Tell ArgoCD to ignore `.spec`, `.metadata.annotations`, and `.metadata.labels` diffs on all CRDs. Combined with `RespectIgnoreDifferences=true`, ArgoCD will treat the CRDs as Synced and will **not attempt to re-apply them** via CSA during future syncs.

```yaml
# apps/kyverno.yaml (relevant section)
spec:
  syncPolicy:
    syncOptions:
      - ServerSideApply=true
      - RespectIgnoreDifferences=true
  ignoreDifferences:
    - group: apiextensions.k8s.io
      kind: CustomResourceDefinition
      jqPathExpressions:
        - .spec
        - .metadata.annotations
        - .metadata.labels
    - group: admissionregistration.k8s.io
      kind: MutatingWebhookConfiguration
      managedFieldsManagers:
        - kyverno
        - kyverno-admission-controller
    - group: admissionregistration.k8s.io
      kind: ValidatingWebhookConfiguration
      managedFieldsManagers:
        - kyverno
        - kyverno-admission-controller
```

**Why this works:**
- `jqPathExpressions` strips those fields from both desired and live state before ArgoCD computes the diff → CRDs appear Synced
- `RespectIgnoreDifferences=true` instructs ArgoCD not to patch the ignored fields even when a sync is triggered for other resources in the same app
- The CRDs remain correctly installed in the cluster; they just aren't re-managed by ArgoCD's diff loop

---

## Outcome

```
NAME                      SYNC     HEALTH
kyverno                   Synced   Healthy   ✓
```

Kyverno admission controller, background controller, cleanup controller, and reports controller all running with 0 restarts.

---

## Notes for Future Upgrades

When upgrading Kyverno (changing `targetRevision`), the CRDs will not be automatically applied by ArgoCD (since their diffs are ignored). Run the following before or after bumping the chart version:

```bash
helm template kyverno kyverno/kyverno --version <NEW_VERSION> | \
  kubectl apply --server-side --field-manager=argocd-controller --force-conflicts -f -
```

This applies the new CRD schemas via SSA without the annotation size problem.

---

## Related

- ArgoCD issue: CSA fallback for Helm sub-chart CRDs with `ServerSideApply=true`
- Kubernetes limit: `metadata.annotations` total size ≤ 262,144 bytes
- Kyverno chart: large CRDs are in `charts/crds` and `charts/kyverno-api` sub-charts
