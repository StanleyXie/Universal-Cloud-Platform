# Universal Cloud Platform — Build Progress & Reference

**Last updated:** 2026-04-05 (CI workflow fixes)
**Status:** All components running and Synced
**Cluster:** AOS01/AOS02/AOS03 at 192.168.32.11–13 (3-node HA K8s, v1.35.3)
**Platform repo:** `~/platform` → `https://github.com/StanleyXie/Universal-Cloud-Platform`

---

## Architecture Overview

```
GitHub (StanleyXie/Universal-Cloud-Platform)  ← single source of truth
  └── ArgoCD root App-of-Apps
      ├── wave 0: argocd                  (self-managed, resource limits)
      ├── wave 0: cilium                  (CNI, Gateway API controller, L2 LB)
      ├── wave 1: kyverno                 (policy engine controller)
      ├── wave 1: gateway-api             (CRDs v1.2.1 + platform-gateway + L2 pool)
      ├── wave 1: kyverno-policies        (baseline pod security policies)
      ├── wave 1: kyverno-custom-policies (custom + exceptions)
      ├── wave 2: crossplane              (control plane)
      ├── wave 2: crossplane-providers    (AWS/GCP/Azure/Terraform)
      ├── wave 2: crossplane-providerconfigs
      ├── wave 3: local-path-provisioner  (default StorageClass)
      └── wave 3: searxng                 (common-svc, agentic search service)
CI:   .github/workflows/security.yml     (Gitleaks · yamllint · kubeconform · Kyverno apply · ShellCheck)
```

**Note:** Gitea was evaluated and removed — GitHub is the single source of truth.
ArgoCD manages itself via `apps/argocd.yaml` (self-management pattern).

---

## Current Component Status

| Component | Namespace | Status |
|-----------|-----------|--------|
| ArgoCD | argocd | Synced, Healthy — self-managed |
| Cilium v1.19.2 | kube-system | Synced, Healthy — CNI + Gateway API controller |
| Gateway API CRDs | cluster-scoped | v1.2.1 installed |
| platform-gateway | networking | Programmed — IP 192.168.32.100 |
| local-path-provisioner | local-path-storage | Synced, Healthy |
| Kyverno 3.7.1 | kyverno | Synced, Healthy — 3 admission replicas |
| kyverno-policies | kyverno | Synced, Healthy — baseline pod security |
| kyverno-custom-policies | kyverno | Synced, Healthy |
| Crossplane | crossplane-system | Synced, Healthy |
| provider-family-aws | crossplane-system | Installed, Healthy |
| provider-family-gcp | crossplane-system | Installed, Healthy |
| provider-family-azure | crossplane-system | Installed, Healthy |
| provider-terraform | crossplane-system | Installed, Healthy |
| provider-cloudflare | — | **Disabled** — unfixable CRD generation bugs in wildbitca fork |
| SearXNG | common-svc | Synced, Healthy — http://search.aos.local |

---

## Access

| Service | URL | Notes |
|---------|-----|-------|
| ArgoCD UI | `https://192.168.32.11:30843` | Username: `admin` |
| SearXNG | `http://search.aos.local` | Add `192.168.32.100 search.aos.local` to `/etc/hosts` |
| kubectl (local) | kubeconfig at `~/.kube/config` | Merged from remote cluster |
| Platform Gateway | `192.168.32.100:80` | Cilium L2 ARP, HTTPRoute-based routing |

SSH: `ssh -i ~/.ssh/id_rsa stanley@192.168.32.11`

---

## Platform Repo Structure

```
~/platform/
├── apps/                              # Root App-of-Apps — ArgoCD watches this dir
│   ├── argocd.yaml                    # wave 0 — ArgoCD self-management
│   ├── cilium.yaml                    # wave 0 — CNI + Gateway API
│   ├── kyverno.yaml                   # wave 1
│   ├── gateway-api.yaml               # wave 1 — CRDs + gateway + L2 pool
│   ├── kyverno-policies.yaml          # wave 1
│   ├── kyverno-custom-policies.yaml   # wave 1
│   ├── crossplane.yaml                # wave 2
│   ├── crossplane-providers.yaml      # wave 2
│   ├── crossplane-providerconfigs.yaml # wave 2
│   ├── local-path-provisioner.yaml    # wave 3
│   └── searxng.yaml                   # wave 3 — common-svc namespace
├── argocd/values.yaml
├── cilium/values.yaml                 # kubeProxyReplacement, gatewayAPI, l2announcements
├── gateway-api/
│   ├── kustomization.yaml             # pulls CRDs from kubernetes-sigs/gateway-api
│   ├── gateway.yaml                   # platform-gateway (Cilium, port 80)
│   ├── lb-ip-pool.yaml               # CiliumLoadBalancerIPPool 192.168.32.100-110
│   │                                  # + CiliumL2AnnouncementPolicy (^enp.*)
│   └── cilium-l2-rbac.yaml           # Supplemental RBAC — fixes Cilium 1.19.2 chart gap
├── kyverno/values.yaml
├── kyverno-policies/values.yaml
├── kyverno-custom-policies/
│   ├── disallow-default-namespace.yaml
│   ├── restrict-external-ips.yaml     # excludes networking namespace
│   ├── require-resource-limits.yaml
│   ├── require-crossplane-labels.yaml
│   ├── kube-system-exception.yaml     # PolicyException — kube-system/argocd/crossplane/local-path
│   └── gateway-external-ip-exception.yaml  # (unused, prefer exclude block in policy)
├── crossplane/values.yaml
├── crossplane-providers/
│   ├── runtime-config-default.yaml
│   ├── provider-aws.yaml
│   ├── provider-gcp.yaml
│   ├── provider-azure.yaml
│   ├── provider-cloudflare.yaml       # Disabled — see cloudflare-provider-cel-fix.md
│   ├── provider-terraform.yaml        # Uses DeploymentRuntimeConfig (ControllerConfig deprecated)
│   └── runtime-config-default.yaml   # Default DeploymentRuntimeConfig for all providers
├── crossplane-providerconfigs/
├── searxng/
│   ├── values.yaml                    # Chart: unknowniq/searxng 0.1.10
│   └── (httproute managed by chart)
├── scripts/
│   ├── setup-credentials.sh
│   └── setup-searxng-secret.sh        # Creates searxng-secret in common-svc (not in git)
├── bootstrap/
│   ├── bootstrap-argocd.sh            # Day-0: Helm install ArgoCD + apply root app
│   └── k8s/                           # Node setup scripts (kubeadm init/join)
├── test/
│   └── sample-pod.yaml                # Minimal Pod used by Kyverno CI policy checks
└── docs/
    ├── plans/                         # Architecture & progress docs
    └── issues/                        # Resolved issue write-ups
```

---

## Key Design Decisions & Lessons Learned

### Gateway API on bare metal with Cilium

Cilium v1.19 is the Gateway controller. Requires:
1. **Gateway API CRDs** installed before Cilium reconciles them (sync wave ordering)
2. **L2 announcements** for bare-metal LoadBalancer IPs — Cilium agent handles ARP, operator manages leases
3. **IP pool** (`CiliumLoadBalancerIPPool`) to assign IPs from the local subnet

**Known gap in Cilium 1.19.2 Helm chart:** The operator ClusterRole omits `ciliuml2announcementpolicies`. Without it, the operator can't watch L2 policies and never creates election leases → no ARP responses → IPs unreachable. Fix: `gateway-api/cilium-l2-rbac.yaml` adds a supplemental ClusterRole bound to `cilium-operator` ServiceAccount.

**Config drift detection:** The Cilium agent detects `enable-l2-announcements` mismatch at runtime (`actual=false, expected=true`). A rolling restart of the DaemonSet picks up the updated ConfigMap value.

**Adopting an existing Helm release into ArgoCD:** Resources created outside Helm must be annotated before `helm upgrade` will manage them:
```bash
kubectl annotate <resource> meta.helm.sh/release-name=cilium meta.helm.sh/release-namespace=kube-system --overwrite
kubectl label <resource> app.kubernetes.io/managed-by=Helm --overwrite
```

### Kyverno PolicyException — `exclude` vs `PolicyException`

Kyverno 3.7 `PolicyException` (v2 API) has unreliable matching for ClusterPolicies when using `namespaces` in the match block — the exception may not fire at admission even when the resource matches. Prefer an `exclude` block directly in the ClusterPolicy for reliable behaviour.

### SearXNG deployment notes

- **Chart:** `unknowniq/searxng` at `https://unknowniq.github.io/helm-charts/` — has native `route:` support for Gateway API HTTPRoute
- **Secret key:** stored as k8s Secret `searxng-secret` in `common-svc`, created by `scripts/setup-searxng-secret.sh` (not in git)
- **Valkey:** Chart always injects `valkey.url` even when `valkey.enabled=false`. Must set `extraConfig.valkey.url: ""` to prevent startup crash (empty string is falsy in Python; `"false"` is not)
- **HTTPRoute** is managed by the chart via `route.enabled: true` — no standalone HTTPRoute manifest needed

### Kyverno CRDs — annotation size limit (262 KB)

**Problem:** ArgoCD falls back to CSA for Helm sub-chart CRDs. Kyverno 3.7.1 CRDs are ~1.4 MB — far above the 262 KB annotation limit.

**Fix (three steps):**
1. Strip the annotation from all Kyverno CRDs:
   ```bash
   for crd in $(kubectl get crd | grep kyverno | awk '{print $1}'); do
     kubectl annotate crd $crd kubectl.kubernetes.io/last-applied-configuration-
   done
   ```
2. Re-apply all Kyverno CRDs via SSA:
   ```bash
   helm template kyverno kyverno/kyverno --version 3.7.1 | \
     kubectl apply --server-side --field-manager=argocd-controller --force-conflicts -f -
   ```
3. Add `ignoreDifferences` to the ArgoCD Application for CRDs.

### Kyverno ClusterPolicy — perpetual OutOfSync

Kyverno mutates ClusterPolicy objects after creation. Fix:
```yaml
ignoreDifferences:
  - group: kyverno.io
    kind: ClusterPolicy
    jqPathExpressions: [.spec, .status]
```

### Crossplane: ServerSideApply required

Crossplane CRDs exceed the CSA annotation size limit. All Crossplane ArgoCD apps must have `ServerSideApply=true` in `syncOptions`.

### ArgoCD multi-source for Helm value files

```yaml
sources:
  - repoURL: https://charts.crossplane.io/stable
    chart: crossplane
    targetRevision: "1.*"
    helm:
      valueFiles:
        - $values/crossplane/values.yaml
  - repoURL: https://github.com/StanleyXie/Universal-Cloud-Platform
    targetRevision: HEAD
    ref: values
```

### Crossplane provider-terraform — ControllerConfig deprecated

`ControllerConfig` (`pkg.crossplane.io/v1alpha1`) is deprecated in Crossplane v1.16+. The `provider-terraform.yaml` now uses a dedicated `DeploymentRuntimeConfig` named `terraform` that passes `--enable-management-policies` as a container arg. The old `ControllerConfig` + `controllerConfigRef` pattern is removed.

### GitHub Actions CI — all jobs green

`.github/workflows/security.yml` runs 6 parallel jobs on push/PR to `main`. Known issues resolved:

| Issue | Fix |
|-------|-----|
| kubeconform exit 123 on `/releases/latest` redirect | Pinned to `v0.7.0` with explicit versioned URL |
| kubeconform failing on Helm `values.yaml` (missing `kind`) | Excluded `values.yaml` from `find` |
| ClusterRole `cilium-l2-rbac.yaml` rejected (`spec` not allowed) | Removed invalid `spec: {}` field |
| Kyverno CLI tar conflict with checked-out `kyverno/` dir | Extract to `/tmp/kyverno-cli/` |
| `kyverno lint` / `kyverno policy lint` removed in v1.17 | Use `kyverno apply --resource test/sample-pod.yaml` |
| yamllint `document-start` flagging K8s manifests | Disabled `document-start` rule |

### Crossplane Cloudflare provider — disabled

`wildbitca/provider-upjet-cloudflare` has multiple CRD generation defects beyond the original CEL bug: missing `Snippet` CRD, kind/plural naming mismatches. Not fixable by manual patching without full Upjet code regeneration. Disabled pending `crossplane-contrib/provider-upjet-cloudflare` official release. See `2026-04-03-cloudflare-provider-cel-fix.md` for full analysis.

---

## Eval Script

```bash
bash ~/journal/scripts/eval-platform.sh --report
```

Covers 5 modules: Baremetal & Bootstrap, Platform, DevOps/CI·CD, Security, Metrics & Observability.

---

## Open Issues / Remaining Work

### 1. Cloudflare provider — unfixable in wildbitca fork
Monitor `crossplane-contrib/provider-upjet-cloudflare` for an official release.

### 2. Cloud credentials not yet configured
AWS, GCP, Azure ProviderConfigs reference secrets that don't exist yet. Run `platform/scripts/setup-credentials.sh` when ready.

### 3. Observability stack not deployed
No kube-prometheus-stack or Loki. `monitoring` namespace missing. Add to `platform/apps/` when needed.

### 4. No cluster backup
No Velero or etcd snapshot automation.

---

## How to Resume

```bash
# Check all ArgoCD apps
kubectl get applications -n argocd

# Run platform eval
bash ~/journal/scripts/eval-platform.sh --report

# Push a change
cd ~/platform && git add . && git commit -m "..." && git push

# Force ArgoCD refresh
kubectl -n argocd annotate app <app-name> argocd.argoproj.io/refresh=hard --overwrite

# Add new service (HTTPRoute pattern)
# 1. Create apps/<service>.yaml (wave 3, namespace: common-svc)
# 2. Create <service>/values.yaml with route.enabled=true pointing at platform-gateway
# 3. Add hostname to /etc/hosts: 192.168.32.100 <hostname>
```

---

## Tasks Completed

- [x] Platform Git repo structure
- [x] local-path-provisioner (default StorageClass)
- [x] Crossplane + all provider family manifests
- [x] ArgoCD bootstrap + self-management
- [x] Full platform sync verified
- [x] Removed Gitea — GitHub as single source of truth
- [x] metrics-server installed
- [x] Kyverno policy-as-code layer (controller + baseline + custom policies)
- [x] Fixed Kyverno CRD annotation size issue
- [x] Fixed ClusterPolicy perpetual OutOfSync
- [x] PolicyException for kube-system/argocd/crossplane-system/local-path-storage
- [x] Platform eval script (5 modules)
- [x] GitHub repo security hardening (branch protection, workflow permissions, Dependabot)
- [x] Cilium brought under ArgoCD management
- [x] Gateway API CRDs v1.2.1 installed
- [x] Cilium GatewayClass + platform-gateway at 192.168.32.100
- [x] Cilium L2 announcements — bare metal LoadBalancer IPs via ARP
- [x] Fixed Cilium 1.19.2 L2 RBAC gap (cilium-l2-rbac.yaml)
- [x] SearXNG deployed in common-svc via Gateway API HTTPRoute
- [x] http://search.aos.local accessible on port 80
- [x] Project consolidated under universal-cloud-platform/ (docs, bootstrap, platform)
- [x] Architecture overview doc with Mermaid diagrams (docs/plans/2026-04-05-architecture-overview.md)
- [x] GitHub Actions security workflow — all 6 jobs passing (Gitleaks, yamllint, kubeconform, Kyverno apply, ShellCheck, ArgoCD lint)
- [x] Migrated provider-terraform from deprecated ControllerConfig to DeploymentRuntimeConfig
- [x] Fixed ClusterRole cilium-l2-rbac.yaml (removed invalid spec: {} field)

## Remaining / Follow-up

- [ ] Configure cloud credentials (AWS, GCP, Azure)
- [ ] Install Crossplane service providers (e.g. provider-aws-s3)
- [ ] Re-enable Cloudflare provider when official release ships
- [ ] Observability stack (kube-prometheus-stack + Loki)
- [ ] Set up etcd backup / Velero
