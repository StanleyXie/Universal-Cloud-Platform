# Kyverno Policy Apps Sync Issues

**Date:** 2026-04-02
**Apps affected:** `kyverno-policies`, `kyverno-custom-policies`
**Status:** Resolved

---

## Issue 1: YAML Indentation Bug in ArgoCD Application Manifests

### Symptom

Root ArgoCD app failed with:

```
ComparisonError: Failed to load target state: failed to generate manifest for source 1 of 1:
rpc error: code = Unknown desc = Manifest generation error (cached):
failed to unmarshal "kyverno-custom-policies.yaml":
error converting YAML to JSON: yaml: line 20: did not find expected key
```

### Root Cause

`RespectIgnoreDifferences=true` was placed as a list item under `spec.syncPolicy.automated` instead of `spec.syncPolicy.syncOptions`:

```yaml
# WRONG
syncPolicy:
  automated:
    prune: true
    selfHeal: true
    - RespectIgnoreDifferences=true   # invalid — automated takes key/value, not a list
  syncOptions:
    - ServerSideApply=true
```

### Fix

Move the entry to `syncOptions`:

```yaml
# CORRECT
syncPolicy:
  automated:
    prune: true
    selfHeal: true
  syncOptions:
    - ServerSideApply=true
    - RespectIgnoreDifferences=true
```

---

## Issue 2: Kyverno Admission Webhook Timeout on ClusterPolicy Apply

### Symptom

After the YAML fix, ArgoCD sync still failed:

```
error when patching "/dev/shm/...": Internal error occurred:
failed calling webhook "validate-policy.kyverno.svc":
failed to call webhook: Post "https://kyverno-svc.kyverno.svc:443/policyvalidate?timeout=10s":
context deadline exceeded
```

### Root Cause

Kyverno's `validate-policy.kyverno.svc` webhook is configured with `failurePolicy: Fail`. When the admission controller is overloaded or stuck, it stops responding to webhook calls within the timeout, causing all `ClusterPolicy` CREATE/UPDATE operations to hard-fail.

The controller was stuck in an error loop caused by the `require-crossplane-labels` custom policy, which targets wildcard resource kinds (`*.aws.upbound.io/*`, `*.gcp.upbound.io/*`, `*.azure.upbound.io/*`). The Crossplane managed resource CRDs for these groups don't exist yet — only the provider-family CRDs are installed. Kyverno's policycache-controller repeatedly logged:

```
failed to fetch resource group versions  error="resource not found"  kind=*.aws.upbound.io
failed to process request  error="resource not found; resource not found; resource not found"  obj=require-crossplane-labels
```

### Fix

Restart the Kyverno admission controller to clear the stuck state:

```bash
kubectl rollout restart deployment/kyverno-admission-controller -n kyverno
kubectl rollout status deployment/kyverno-admission-controller -n kyverno --timeout=60s
```

Then re-trigger the ArgoCD sync once the rollout completes.

### Long-term note

The `require-crossplane-labels` error loop will resolve itself once actual Crossplane managed resource providers (e.g. `provider-aws-s3`, `provider-gcp-storage`) are installed and their CRDs are registered. Until then, the policycache errors are non-fatal — they only become a problem if they pile up enough to degrade the admission controller's responsiveness.

---

## Issue 3: ClusterPolicy Perpetual OutOfSync (ignoreDifferences)

### Symptom

Even after the webhook issue was resolved, `ClusterPolicy` resources remained `OutOfSync`. Kyverno's admission controller mutates ClusterPolicy objects after creation — injecting defaults, ready conditions, and status fields — so the live state always diverges from the Helm-rendered desired state.

### Fix

Add `ignoreDifferences` with `RespectIgnoreDifferences=true` to both policy apps:

```yaml
# apps/kyverno-policies.yaml and apps/kyverno-custom-policies.yaml
syncPolicy:
  automated:
    prune: true
    selfHeal: true
  syncOptions:
    - ServerSideApply=true
    - RespectIgnoreDifferences=true
ignoreDifferences:
  - group: kyverno.io
    kind: ClusterPolicy
    jqPathExpressions:
      - .spec
      - .status
```

`RespectIgnoreDifferences=true` prevents ArgoCD from patching the ignored fields even when a sync is triggered by other resources in the app.

---

## Final State

```
NAME                      SYNC     HEALTH
kyverno                   Synced   Healthy
kyverno-policies          Synced   Healthy
kyverno-custom-policies   Synced   Healthy
```

All 8 platform apps Synced + Healthy.
