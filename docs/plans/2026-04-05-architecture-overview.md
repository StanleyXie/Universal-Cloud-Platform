# Universal Cloud Platform — Architecture Overview

**Last updated:** 2026-04-05  
**Cluster:** AOS01 / AOS02 / AOS03 · Kubernetes v1.35.3 · 3-node HA  
**Repo:** `https://github.com/StanleyXie/Universal-Cloud-Platform`

---

## 1. High-Level Architecture

```mermaid
graph TB
    subgraph Developer["Developer Workstation"]
        git["git push"]
    end

    subgraph GitHub["GitHub — Source of Truth"]
        repo["StanleyXie/Universal-Cloud-Platform\n(manifests + Helm values)"]
        actions["GitHub Actions\n· Gitleaks · yamllint\n· kubeconform · Kyverno CLI\n· ShellCheck"]
    end

    subgraph Cluster["AOS Homelab Cluster · 192.168.32.10 (VIP)"]
        direction TB

        subgraph ControlPlane["Control Plane Layer"]
            argocd["ArgoCD 9.4.17\napp-of-apps (root)"]
            kyverno["Kyverno 3.7.1\n3 admission replicas"]
        end

        subgraph Networking["Networking Layer"]
            cilium["Cilium v1.19.2\nCNI · kube-proxy replacement\nGateway API controller · L2 ARP"]
            gw["platform-gateway\n192.168.32.100:80\n(GatewayClass: cilium)"]
            pool["CiliumLoadBalancerIPPool\n192.168.32.100 – 110"]
        end

        subgraph Storage["Storage"]
            lpp["local-path-provisioner\ndefault StorageClass"]
        end

        subgraph CloudMgmt["Cloud Management (Crossplane)"]
            xp["Crossplane (latest 1.x)"]
            aws["provider-family-aws"]
            gcp["provider-family-gcp"]
            azure["provider-family-azure"]
            tf["provider-terraform"]
            cf["provider-cloudflare\n⚠ disabled"]
        end

        subgraph Services["Services (common-svc)"]
            searxng["SearXNG\nsearch.aos.local"]
        end
    end

    subgraph LAN["LAN Clients"]
        browser["Browser / curl\nhttp://search.aos.local"]
    end

    git -->|push| repo
    repo -->|CI on push/PR| actions
    repo -->|GitOps pull| argocd
    argocd -->|deploys & reconciles| ControlPlane
    argocd -->|deploys & reconciles| Networking
    argocd -->|deploys & reconciles| Storage
    argocd -->|deploys & reconciles| CloudMgmt
    argocd -->|deploys & reconciles| Services
    kyverno -->|admits / denies Pods| Services
    kyverno -->|admits / denies Pods| CloudMgmt
    cilium --> gw
    pool --> gw
    gw -->|HTTPRoute| searxng
    browser -->|ARP → 192.168.32.100| gw
```

---

## 2. Cluster Infrastructure

| Node | Role | IP | OS |
|------|------|----|----|
| aos01 | control-plane | 192.168.32.11 | Ubuntu (NUC) |
| aos02 | control-plane | 192.168.32.12 | Ubuntu (NUC) |
| aos03 | control-plane + worker | 192.168.32.13 | Ubuntu (NUC) |
| — | kube-vip VIP | 192.168.32.10 | — |

- **CNI:** Cilium v1.19.2 — kube-proxy replacement, eBPF dataplane
- **HA:** kubeadm stacked etcd, kube-vip L2 control-plane VIP
- **Storage:** local-path-provisioner (default StorageClass, `local-path`)

---

## 3. GitOps — ArgoCD App-of-Apps

```mermaid
flowchart TD
    root["root App\n(watches apps/)"]

    root --> w0a["wave 0\nargocd\n(self-managed)"]
    root --> w0b["wave 0\ncilium"]
    root --> w0c["wave 0\nlocal-path-provisioner"]

    root --> w1a["wave 1\nkyverno"]
    root --> w1b["wave 1\ngateway-api"]
    root --> w1c["wave 1\nkyverno-policies\n(baseline)"]
    root --> w1d["wave 1\nkyverno-custom-policies"]

    root --> w2a["wave 2\ncrossplane"]
    root --> w2b["wave 2\ncrossplane-providers"]
    root --> w2c["wave 2\ncrossplane-providerconfigs"]

    root --> w3a["wave 3\nsearxng"]

    style w0a fill:#d4edda,stroke:#28a745
    style w0b fill:#d4edda,stroke:#28a745
    style w0c fill:#d4edda,stroke:#28a745
    style w1a fill:#cce5ff,stroke:#004085
    style w1b fill:#cce5ff,stroke:#004085
    style w1c fill:#cce5ff,stroke:#004085
    style w1d fill:#cce5ff,stroke:#004085
    style w2a fill:#fff3cd,stroke:#856404
    style w2b fill:#fff3cd,stroke:#856404
    style w2c fill:#fff3cd,stroke:#856404
    style w3a fill:#f8d7da,stroke:#721c24
```

All apps use `automated: {prune: true, selfHeal: true}` (except `argocd` which uses `prune: false`).  
Helm values are sourced from the same repo via the multi-source `ref:` pattern.

---

## 4. Networking — Gateway API & L2

```mermaid
flowchart LR
    client["LAN Client\nbrowser"] -->|"HTTP GET search.aos.local"| arp

    subgraph L2["Layer 2 — ARP"]
        arp["ARP broadcast\nsearch.aos.local → 192.168.32.100"]
    end

    arp --> gw

    subgraph networking["Namespace: networking"]
        gw["platform-gateway\nIP: 192.168.32.100:80\nGatewayClass: cilium"]
    end

    gw -->|"HTTPRoute\nhostname: search.aos.local\npath: /"| svc

    subgraph common-svc["Namespace: common-svc"]
        svc["searxng Service\nClusterIP:8080"]
        pod["SearXNG Pod"]
        svc --> pod
    end
```

**Key components:**

| Resource | Kind | Details |
|----------|------|---------|
| `platform-gateway` | `Gateway` | Namespace `networking`, GatewayClass `cilium`, port 80 HTTP, `allowedRoutes.namespaces: All` |
| `platform-lb-pool` | `CiliumLoadBalancerIPPool` | 192.168.32.100 – 192.168.32.110 |
| `platform-l2-policy` | `CiliumL2AnnouncementPolicy` | Interfaces `^enp.*`, LoadBalancer IPs only |
| `cilium-operator-l2-announcements` | `ClusterRole` + `ClusterRoleBinding` | Supplemental RBAC — Cilium 1.19.2 chart omits `ciliuml2announcementpolicies` from operator ClusterRole |

**Known fix applied:** Cilium 1.19.2 Helm chart does not grant the operator RBAC for `ciliuml2announcementpolicies`. Without it the L2 announcer silently does nothing. Fixed via `gateway-api/cilium-l2-rbac.yaml`.

---

## 5. Policy — Kyverno

```mermaid
flowchart TD
    req["Admission Request\n(Pod create/update)"]
    req --> kyverno["Kyverno Admission Controller\n3 replicas"]

    kyverno --> baseline["kyverno-policies\nPod Security Baseline\n· disallow-host-namespaces\n· disallow-host-path\n· disallow-privileged-containers\n· disallow-capabilities\n· disallow-host-ports\n· restrict-seccomp\n(all: Audit mode)"]

    kyverno --> custom["kyverno-custom-policies\n· disallow-default-namespace\n· require-resource-limits\n· restrict-external-ips\n· require-crossplane-labels"]

    kyverno --> exc["PolicyExceptions\n· kube-system-exception\n  (kube-system, local-path-storage,\n   argocd, crossplane-system, monitoring)\n· gateway-external-ip-exception\n  (networking namespace)"]

    baseline -->|"violates → Audit"| report["PolicyReport\ncluster-wide"]
    custom -->|"violates → Audit"| report
    exc -->|"exempt"| allow["Allowed"]
```

**ClusterPolicies (custom):**

| Policy | Mode | Purpose |
|--------|------|---------|
| `disallow-default-namespace` | Enforce | Blocks workloads in `default` namespace |
| `require-resource-limits` | Audit | All containers must declare CPU + memory limits |
| `restrict-external-ips` | Enforce | Services may not specify `.spec.externalIPs` (CVE-2020-8554 mitigation) |
| `require-crossplane-labels` | Audit | Crossplane managed resources must carry `crossplane.io/claim-name` label |

---

## 6. Cloud Management — Crossplane

```mermaid
flowchart LR
    xp["Crossplane\ncrossplane-system"]

    xp --> aws["provider-family-aws\nSecret: aws-creds"]
    xp --> gcp["provider-family-gcp\nSecret: gcp-creds"]
    xp --> azure["provider-family-azure\nSecret: azure-creds"]
    xp --> tf["provider-terraform\nSecret: tf-creds"]
    xp -. "disabled" .-> cf["provider-cloudflare\n⚠ No production xpkg exists\nMonitor: crossplane-contrib releases"]

    aws --> awspc["ProviderConfig: default\ncredentials source: Secret"]
    gcp --> gcppc["ProviderConfig: default\ncredentials source: Secret"]
    azure --> azurepc["ProviderConfig: default\ncredentials source: Secret"]
```

All providers use `DeploymentRuntimeConfig: default` for resource limits.  
Credentials are stored as Kubernetes Secrets (created by `platform/scripts/setup-credentials.sh` — **not yet configured**).

**provider-cloudflare status:** Disabled. The `wildbitca/provider-upjet-cloudflare` fork has unfixable CRD generation defects. The official `crossplane-contrib/provider-upjet-cloudflare` has no published xpkg release yet. Monitor [releases](https://github.com/crossplane-contrib/provider-upjet-cloudflare/releases).

---

## 7. Services

| Service | Namespace | Helm Chart | Exposed At |
|---------|-----------|------------|------------|
| SearXNG | `common-svc` | unknowniq/searxng 0.1.10 | `http://search.aos.local` → 192.168.32.100:80 |

**SearXNG notes:**
- Secret key managed via `platform/scripts/setup-searxng-secret.sh` (random generation, stored in `searxng-secret`)
- Valkey/Redis disabled; chart injects empty `valkey.url` causing crash — fixed with `extraConfig.valkey.url: "false"` in values
- HTTPRoute configured via chart-native `route:` block targeting `platform-gateway`

---

## 8. CI/CD — GitHub Actions Security Workflow

File: `.github/workflows/security.yml`

```mermaid
flowchart LR
    push["push / PR\nto main"] --> jobs

    subgraph jobs["Parallel Jobs"]
        gl["secret-scan\nGitleaks\n(full git history)"]
        yl["yaml-lint\nyamllint"]
        mv["manifest-validate\nkubeconform\nK8s 1.35.0 schema"]
        kl["kyverno-lint\nKyverno CLI\npolicy lint"]
        sc["shellcheck\nScripts in scripts/"]
        al["argocd-app-lint\nkubeconform\nArgoCD app manifests"]
    end
```

---

## 9. Project Repository Structure

```
universal-cloud-platform/           ← project root (local only, not a git repo)
├── .gitignore                      ← excludes DS_Store, join-command.txt, secrets
├── platform/                       ← git repo → github.com/StanleyXie/Universal-Cloud-Platform
│   ├── .github/workflows/
│   │   └── security.yml            ← CI security scanning
│   ├── apps/                       ← ArgoCD Application manifests (app-of-apps)
│   ├── argocd/                     ← ArgoCD Helm values
│   ├── cilium/                     ← Cilium Helm values
│   ├── crossplane/                 ← Crossplane Helm values
│   ├── crossplane-providers/       ← Provider CRs (AWS/GCP/Azure/Terraform)
│   ├── crossplane-providerconfigs/ ← ProviderConfig CRs
│   ├── gateway-api/                ← CRD kustomization + Gateway + L2 pool + RBAC fix
│   ├── kyverno/                    ← Kyverno Helm values
│   ├── kyverno-policies/           ← Upstream baseline policy Helm values
│   ├── kyverno-custom-policies/    ← Custom ClusterPolicies + PolicyExceptions
│   ├── local-path-provisioner/     ← StorageClass manifest
│   ├── scripts/                    ← setup-searxng-secret.sh, setup-credentials.sh
│   └── searxng/                    ← SearXNG Helm values
├── docs/
│   ├── plans/                      ← Architecture & progress docs
│   └── issues/                     ← Resolved issue notes
├── provider-upjet-cloudflare/      ← git repo (fork, paused)
└── scripts/
    ├── bootstrap-argocd.sh         ← Day-0 ArgoCD install + root app apply
    └── k8s/                        ← Cluster setup scripts
        └── join-command.txt        ← ⚠ gitignored — contains bootstrap token
```

---

## 10. Pending / Roadmap

| Item | Priority | Notes |
|------|----------|-------|
| Observability stack | High | kube-prometheus-stack + Loki + Promtail, wave 4 |
| Cloud credentials | Medium | Run `scripts/setup-credentials.sh` to populate provider secrets |
| provider-cloudflare | Low | Monitor crossplane-contrib/provider-upjet-cloudflare for first release |
| TLS on platform-gateway | Low | Add HTTPS listener + cert-manager for `*.aos.local` |
| ArgoCD OIDC / SSO | Low | Replace admin password auth |
