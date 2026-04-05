# Crossplane + ArgoCD Platform Design

**Date:** 2026-04-01
**Cluster:** 3-node HA Kubernetes v1.35 — AOS01/AOS02/AOS03

> **Decision (2026-04-03):** Gitea removed from plan. GitHub is the permanent source of truth.
> Rationale: added operational complexity with no meaningful benefit for a homelab cluster.

---

## Goal

Deploy a full GitOps platform on the existing cluster:
- **ArgoCD** as the GitOps engine (bootstrapped via script, manages everything else)
- **Crossplane** as the infrastructure control plane
- **Crossplane providers:** AWS, GCP, Azure, Cloudflare, Terraform
- **local-path-provisioner** for PVC support (persistent volumes)

---

## Architecture

```
Phase 1: Bootstrap (script from Mac)
  └── Install ArgoCD via Helm → argocd namespace

Phase 2: App-of-Apps (GitHub repo → ArgoCD)
  └── root Application
        ├── local-path-provisioner  (wave 0)
        ├── kyverno                 (wave 1)
        ├── crossplane              (wave 2)
        └── crossplane-providers    (wave 3)
              ├── provider-aws
              ├── provider-gcp
              ├── provider-azure
              ├── provider-cloudflare
              └── provider-terraform

GitHub remains the permanent single source of truth.
```

---

## Components

### ArgoCD
| Setting | Value |
|---|---|
| Helm chart | `argo/argo-cd` |
| Namespace | `argocd` |
| Version | latest stable |
| Install method | Bootstrap script (`bootstrap-argocd.sh`) |
| Root app | `kubectl apply -f root-app.yaml` pointing at GitHub `apps/` |

### local-path-provisioner
| Setting | Value |
|---|---|
| Source | `rancher/local-path-provisioner` manifest |
| StorageClass | `local-path` (default) |
| Data dir | `/opt/local-path-provisioner` on each node |
| sync wave | 0 |

### Crossplane
| Setting | Value |
|---|---|
| Helm chart | `crossplane-stable/crossplane` |
| Namespace | `crossplane-system` |
| Version | latest stable |
| sync wave | 2 |

### Crossplane Providers
| Provider | Package |
|---|---|
| AWS | `xpkg.upbound.io/upbound/provider-aws` |
| GCP | `xpkg.upbound.io/upbound/provider-gcp` |
| Azure | `xpkg.upbound.io/upbound/provider-azure` |
| Cloudflare | `xpkg.upbound.io/upbound/provider-cloudflare` |
| Terraform | `xpkg.upbound.io/upbound/provider-terraform` |

Providers are installed without `ProviderConfig` — credentials wired up in a separate plan.
sync wave: 3

---

## Repository Structure

```
platform/                              # GitHub repo (permanent source of truth)
├── apps/
│   ├── root.yaml                      # Root App-of-Apps
│   ├── local-path-provisioner.yaml    # ArgoCD Application
│   ├── kyverno.yaml                   # ArgoCD Application
│   ├── crossplane.yaml                # ArgoCD Application
│   └── crossplane-providers.yaml      # ArgoCD Application
├── local-path-provisioner/
│   └── install.yaml
├── kyverno/
│   └── values.yaml
├── crossplane/
│   └── values.yaml
└── crossplane-providers/
    ├── provider-aws.yaml
    ├── provider-gcp.yaml
    ├── provider-azure.yaml
    ├── provider-cloudflare.yaml
    └── provider-terraform.yaml
```

---

## Bootstrap Scripts

`~/journal/platform/scripts/bootstrap-argocd.sh`
1. `helm repo add argo https://argoproj.github.io/argo-helm`
2. `helm install argocd argo/argo-cd -n argocd --create-namespace`
3. Wait for ArgoCD to be ready
4. `kubectl apply -f root-app.yaml` (points ArgoCD at GitHub `apps/`)

---

## Future Work

- Wire ProviderConfig credentials (AWS, GCP, Azure, Cloudflare, Terraform) — separate plan
- Add Ingress controller for HTTPS access to ArgoCD UI
- Create Crossplane Compositions and XRDs
- Set up Crossplane + Terraform provider for existing Terraform module automation
- Add observability stack (kube-prometheus-stack + Loki)
