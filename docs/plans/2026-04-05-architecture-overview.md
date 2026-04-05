# Universal Cloud Platform — Architecture Overview

**Last updated:** 2026-04-05 (CI all green)  
**Cluster:** AOS01 / AOS02 / AOS03 · Kubernetes v1.35.3 · 3-node HA  
**Repo:** `https://github.com/StanleyXie/Universal-Cloud-Platform`

---

## 1. Platform Overview

```mermaid
flowchart TB
    classDef src     fill:#dbeafe,stroke:#2563eb,color:#1e3a5f,font-weight:bold
    classDef ci      fill:#fef9c3,stroke:#ca8a04,color:#713f12
    classDef argo    fill:#d1fae5,stroke:#059669,color:#064e3b,font-weight:bold
    classDef net     fill:#e0f2fe,stroke:#0284c7,color:#0c4a6e
    classDef pol     fill:#fdf4ff,stroke:#a21caf,color:#4a044e
    classDef cld     fill:#ede9fe,stroke:#7c3aed,color:#2e1065
    classDef stor    fill:#f1f5f9,stroke:#475569,color:#0f172a
    classDef svc     fill:#fff1f2,stroke:#e11d48,color:#881337
    classDef disabled fill:#f8fafc,stroke:#94a3b8,color:#94a3b8,stroke-dasharray:5 5

    DEV(["👤 Developer"]):::src

    subgraph GITHUB["GitHub — Source of Truth"]
        REPO[("Universal-Cloud-Platform\nStanleyXie/...")]:::src
        CIBOX["GitHub Actions CI\nGitleaks · yamllint\nkubeconform · Kyverno CLI · ShellCheck"]:::ci
    end

    subgraph CLUSTER["AOS Homelab Cluster   ·   Kubernetes v1.35.3   ·   VIP 192.168.32.10"]

        ARGOCD["ArgoCD 9.4.17\nApp-of-Apps · waves 0 → 3"]:::argo

        subgraph NET_BOX["Networking"]
            CIL["Cilium v1.19.2\nCNI · eBPF · kube-proxy replacement\nGateway API controller · L2 ARP"]:::net
            GW[/"platform-gateway\n192.168.32.100 : 80"/]:::net
        end

        subgraph POL_BOX["Policy"]
            KYV["Kyverno 3.7.1\n15 ClusterPolicies · 3 replicas\nBaseline PSS + Custom Rules"]:::pol
        end

        subgraph CLD_BOX["Cloud Management"]
            XP["Crossplane"]:::cld
            PROV["AWS   ·   GCP   ·   Azure   ·   Terraform"]:::cld
            CF(["Cloudflare  ⚠ disabled"]):::disabled
        end

        subgraph STOR_BOX["Storage"]
            LPP[("local-path-provisioner\ndefault StorageClass")]:::stor
        end

        subgraph SVC_BOX["Services"]
            SRX["SearXNG\ncommon-svc · search.aos.local"]:::svc
        end
    end

    DEV          -- "git push"                    --> REPO
    REPO         -- "on push / PR"                --> CIBOX
    REPO         -- "GitOps pull  (3 min)"        --> ARGOCD

    ARGOCD       -- "wave 0"                      --> CIL
    ARGOCD       -- "wave 0"                      --> LPP
    ARGOCD       -- "wave 1"                      --> GW
    ARGOCD       -- "wave 1"                      --> KYV
    ARGOCD       -- "wave 2"                      --> XP
    ARGOCD       -- "wave 3"                      --> SRX

    CIL          -->                                 GW
    XP           -->                                 PROV
    XP           -. "pending release" .->            CF
    GW           -- "HTTPRoute"                   --> SRX
    KYV          -. "admission control"  .->         SRX
    KYV          -. "admission control"  .->         PROV
```

---

## 2. Cluster Nodes

| Node | Role | IP |
|------|------|----|
| aos01 | control-plane | 192.168.32.11 |
| aos02 | control-plane | 192.168.32.12 |
| aos03 | control-plane + worker | 192.168.32.13 |
| — | kube-vip VIP | 192.168.32.10 |

- **CNI:** Cilium v1.19.2 · eBPF dataplane · kube-proxy replacement
- **HA:** kubeadm stacked etcd · kube-vip L2 control-plane VIP
- **Storage:** local-path-provisioner · `local-path` default StorageClass

---

## 3. GitOps — Sync Wave Deployment Order

```mermaid
flowchart LR
    classDef root fill:#f8fafc,stroke:#475569,color:#0f172a,font-weight:bold
    classDef w0   fill:#d1fae5,stroke:#059669,color:#064e3b
    classDef w1   fill:#dbeafe,stroke:#2563eb,color:#1e3a5f
    classDef w2   fill:#fef3c7,stroke:#d97706,color:#78350f
    classDef w3   fill:#fce7f3,stroke:#db2777,color:#831843

    ROOT(["root App\ngithub: apps/"]):::root

    subgraph W0["Wave 0 — Infrastructure Bootstrap"]
        direction TB
        A0["ArgoCD 9.4.17\nself-managed"]:::w0
        B0["Cilium v1.19.2\nCNI · L2 · Gateway API"]:::w0
        C0["local-path-provisioner\ndefault StorageClass"]:::w0
    end

    subgraph W1["Wave 1 — Policy & Networking"]
        direction TB
        A1["Kyverno 3.7.1\nController"]:::w1
        B1["gateway-api\nCRDs + platform-gateway"]:::w1
        C1["kyverno-policies\nBaseline PSS"]:::w1
        D1["kyverno-custom-policies\nCustom rules + exceptions"]:::w1
    end

    subgraph W2["Wave 2 — Cloud Management"]
        direction TB
        A2["Crossplane"]:::w2
        B2["crossplane-providers\nAWS · GCP · Azure · Terraform"]:::w2
        C2["crossplane-providerconfigs\nCredential bindings"]:::w2
    end

    subgraph W3["Wave 3 — Services"]
        A3["SearXNG\nsearch.aos.local"]:::w3
    end

    ROOT --> W0 --> W1 --> W2 --> W3
```

All apps: `automated: {prune: true, selfHeal: true}` — except `argocd` which uses `prune: false`.  
Helm values sourced from the same repo via multi-source `ref:` pattern.

---

## 4. Networking — Traffic Flow

```mermaid
flowchart LR
    classDef client fill:#f0f9ff,stroke:#0284c7,color:#0c4a6e,font-weight:bold
    classDef l2     fill:#ecfdf5,stroke:#059669,color:#064e3b
    classDef gw     fill:#e0f2fe,stroke:#0284c7,color:#0c4a6e
    classDef svc    fill:#fdf4ff,stroke:#9333ea,color:#3b0764
    classDef pod    fill:#fff7ed,stroke:#ea580c,color:#7c2d12

    CLIENT(["🖥️ LAN Client"]):::client

    subgraph L2LAYER["Cilium L2 Announcement  (ARP)"]
        ARP["192.168.32.100\n← announced via ARP on enp*"]:::l2
    end

    subgraph NS_NET["namespace: networking"]
        GW[/"platform-gateway\n192.168.32.100 : 80\nGatewayClass: cilium"/]:::gw
    end

    subgraph NS_SVC["namespace: common-svc"]
        SVC(["searxng Service\nClusterIP : 8080"]):::svc
        POD["SearXNG Pod\nimage: 2026.4.3"]:::pod
        SVC --> POD
    end

    CLIENT  -- "GET http://search.aos.local"          --> ARP
    ARP     -->                                           GW
    GW      -- "HTTPRoute\nhost: search.aos.local / *" --> SVC
```

**L2 components:**

| Resource | Kind | Value |
|----------|------|-------|
| `platform-lb-pool` | `CiliumLoadBalancerIPPool` | 192.168.32.100 – .110 |
| `platform-l2-policy` | `CiliumL2AnnouncementPolicy` | interfaces `^enp.*` · LoadBalancer IPs |
| `cilium-operator-l2-announcements` | `ClusterRole` + `ClusterRoleBinding` | Supplemental RBAC — Cilium 1.19.2 chart omits `ciliuml2announcementpolicies` from operator ClusterRole |

---

## 5. Policy — Kyverno Admission Flow

```mermaid
flowchart LR
    classDef req      fill:#f0f9ff,stroke:#0284c7,color:#0c4a6e,font-weight:bold
    classDef engine   fill:#fdf4ff,stroke:#a21caf,color:#4a044e,font-weight:bold
    classDef baseline fill:#fef3c7,stroke:#d97706,color:#78350f
    classDef custom   fill:#dbeafe,stroke:#2563eb,color:#1e3a5f
    classDef exc      fill:#d1fae5,stroke:#059669,color:#064e3b
    classDef allow    fill:#dcfce7,stroke:#16a34a,color:#14532d,font-weight:bold
    classDef deny     fill:#fee2e2,stroke:#dc2626,color:#7f1d1d,font-weight:bold
    classDef report   fill:#f1f5f9,stroke:#475569,color:#0f172a

    REQ(["Admission Request\nPod · Deployment · Service"]):::req

    KYV(["Kyverno\nAdmission Controller\n3 replicas"]):::engine

    subgraph BASELINE["Baseline Pod Security  (Audit)"]
        direction TB
        B1["disallow-host-namespaces"]:::baseline
        B2["disallow-host-path"]:::baseline
        B3["disallow-privileged-containers"]:::baseline
        B4["disallow-capabilities"]:::baseline
        B5["restrict-seccomp"]:::baseline
    end

    subgraph CUSTOM["Custom Policies"]
        direction TB
        C1["disallow-default-namespace  Enforce"]:::custom
        C2["require-resource-limits  Audit"]:::custom
        C3["restrict-external-ips  Enforce"]:::custom
        C4["require-crossplane-labels  Audit"]:::custom
    end

    subgraph EXCEPT["PolicyExceptions  (always Allowed)"]
        direction TB
        E1["kube-system-exception\nkube-system · argocd · crossplane-system\nmonitoring · local-path-storage"]:::exc
        E2["gateway-external-ip-exception\nnetworking namespace"]:::exc
    end

    ALLOW(["✅ Allowed"]):::allow
    DENY(["❌ Denied"]):::deny
    RPT(["📋 PolicyReport\nAudit log"]):::report

    REQ        --> KYV
    KYV        --> BASELINE
    KYV        --> CUSTOM
    KYV        --> EXCEPT
    BASELINE   -- "Audit violation"  --> RPT
    CUSTOM     -- "Enforce violation"--> DENY
    CUSTOM     -- "Audit violation"  --> RPT
    EXCEPT     -->                      ALLOW
```

---

## 6. Cloud Management — Crossplane Providers

```mermaid
flowchart TB
    classDef ctrl     fill:#ede9fe,stroke:#7c3aed,color:#2e1065,font-weight:bold
    classDef active   fill:#d1fae5,stroke:#059669,color:#064e3b
    classDef config   fill:#f0fdf4,stroke:#16a34a,color:#14532d
    classDef disabled fill:#f8fafc,stroke:#94a3b8,color:#94a3b8,stroke-dasharray:5 5
    classDef cred     fill:#fef9c3,stroke:#ca8a04,color:#713f12

    XP(["Crossplane\ncrossplane-system · v1.x"]):::ctrl

    subgraph ACTIVE["Active Providers  (Installed · Healthy)"]
        direction LR
        AWS["provider-family-aws"]:::active
        GCP["provider-family-gcp"]:::active
        AZ["provider-family-azure"]:::active
        TF["provider-terraform"]:::active
    end

    subgraph CONFIGS["ProviderConfigs  (credential bindings)"]
        direction LR
        AC["ProviderConfig: default\nSecret: aws-creds"]:::config
        GC["ProviderConfig: default\nSecret: gcp-creds"]:::config
        AZC["ProviderConfig: default\nSecret: azure-creds"]:::config
    end

    CF(["provider-cloudflare\n⚠ no xpkg available\nmonitor crossplane-contrib/releases"]):::disabled

    NOTE["⚠ Credentials not yet provisioned\nRun: scripts/setup-credentials.sh"]:::cred

    XP  --> ACTIVE
    XP  -. "pending release" .-> CF
    AWS --> AC
    GCP --> GC
    AZ  --> AZC
    AC & GC & AZC --> NOTE
```

---

## 7. CI/CD — Security Workflow

```mermaid
flowchart TB
    classDef trigger fill:#dbeafe,stroke:#2563eb,color:#1e3a5f,font-weight:bold
    classDef job     fill:#f0fdf4,stroke:#16a34a,color:#14532d
    classDef pass    fill:#d1fae5,stroke:#059669,color:#064e3b,font-weight:bold
    classDef fail    fill:#fee2e2,stroke:#dc2626,color:#7f1d1d,font-weight:bold

    TRIGGER(["push / PR → main"]):::trigger

    subgraph JOBS["Parallel Jobs   (.github/workflows/security.yml)"]
        direction LR
        J1["secret-scan\nGitleaks\nfull git history"]:::job
        J2["yaml-lint\nyamllint\nall *.yaml / *.yml"]:::job
        J3["manifest-validate\nkubeconform\nk8s 1.35.0 schema"]:::job
        J4["kyverno-lint\nKyverno CLI\npolicy syntax"]:::job
        J5["shellcheck\nShellCheck\nscripts/"]:::job
        J6["argocd-app-lint\nkubeconform\napps/ + argocd/"]:::job
    end

    OK(["✅ All passed — merge allowed"]):::pass
    NOK(["❌ Failed — merge blocked"]):::fail

    TRIGGER --> JOBS
    JOBS    -- "all green" --> OK
    JOBS    -- "any red"   --> NOK
```

**Status: all 6 jobs passing.** Known issues resolved during initial setup:

| Symptom | Root Cause | Fix |
|---------|-----------|-----|
| kubeconform exit 123 | `/releases/latest` redirect not followed | Pinned to explicit `v0.7.0` URL |
| kubeconform `missing 'kind' key` | Helm `values.yaml` picked up by `find` | Excluded `values.yaml` from find |
| ClusterRole schema rejection | Invalid `spec: {}` on `cilium-l2-rbac.yaml` | Removed `spec: {}` |
| Kyverno CLI tar error | Binary extracted as `kyverno`, conflicted with `kyverno/` checkout dir | Extract to `/tmp/kyverno-cli/` |
| `kyverno lint` unknown command | `lint` subcommand removed in v1.17 | Use `kyverno apply --resource test/sample-pod.yaml` |
| yamllint `document-start` warnings | Missing `---` on K8s manifests (not required) | Disabled `document-start` rule |

---

## 8. Services

| Service | Namespace | Chart | Endpoint |
|---------|-----------|-------|----------|
| SearXNG | `common-svc` | unknowniq/searxng 0.1.10 | `http://search.aos.local` → 192.168.32.100:80 |

**Notes:**
- Secret key: `scripts/setup-searxng-secret.sh` → K8s Secret `searxng-secret`
- Valkey/Redis disabled; chart injects empty `valkey.url` causing crash → fixed with `extraConfig.valkey.url: "false"`
- HTTPRoute configured via chart-native `route:` block targeting `platform-gateway`

---

## 9. Repository Structure

```
Universal-Cloud-Platform/  (github.com/StanleyXie/Universal-Cloud-Platform)
│
├── .github/workflows/
│   └── security.yml               ← CI: Gitleaks · yamllint · kubeconform · Kyverno CLI · ShellCheck
│
├── apps/                          ← ArgoCD App-of-Apps (root watches this dir)
│   ├── argocd.yaml                  wave 0
│   ├── cilium.yaml                  wave 0
│   ├── local-path-provisioner.yaml  wave 0
│   ├── kyverno.yaml                 wave 1
│   ├── gateway-api.yaml             wave 1
│   ├── kyverno-policies.yaml        wave 1
│   ├── kyverno-custom-policies.yaml wave 1
│   ├── crossplane.yaml              wave 2
│   ├── crossplane-providers.yaml    wave 2
│   ├── crossplane-providerconfigs.yaml wave 2
│   ├── searxng.yaml                 wave 3
│   └── root.yaml                  ← self-referencing root app
│
├── argocd/                        ← ArgoCD Helm values
├── cilium/                        ← Cilium Helm values (CNI + Gateway API + L2)
├── crossplane/                    ← Crossplane Helm values
├── crossplane-providers/          ← Provider CRs (AWS/GCP/Azure/Terraform)
│   └── provider-terraform.yaml    ← uses DeploymentRuntimeConfig (ControllerConfig deprecated v1.16+)
├── crossplane-providerconfigs/    ← ProviderConfig CRs (credential bindings)
├── gateway-api/                   ← CRD kustomization + Gateway + L2 pool + RBAC fix
├── kyverno/                       ← Kyverno Helm values
├── kyverno-policies/              ← Upstream Baseline PSS Helm values
├── kyverno-custom-policies/       ← Custom ClusterPolicies + PolicyExceptions
├── local-path-provisioner/        ← StorageClass manifest
├── searxng/                       ← SearXNG Helm values
│
├── scripts/                       ← Cluster-level setup scripts
│   ├── setup-credentials.sh         cloud provider secrets
│   └── setup-searxng-secret.sh      SearXNG secret key generation
│
├── bootstrap/                     ← Day-0 scripts (run once)
│   ├── bootstrap-argocd.sh          Helm install ArgoCD + apply root app
│   └── k8s/                         Node setup scripts (kubeadm init/join)
│
├── test/
│   └── sample-pod.yaml            ← Minimal Pod for Kyverno CI policy checks
│
└── docs/
    ├── plans/                     ← Architecture & design docs
    └── issues/                    ← Resolved issue write-ups
```

---

## 10. Access

| Service | Address | Notes |
|---------|---------|-------|
| ArgoCD UI | `https://192.168.32.11:30843` | admin user |
| SearXNG | `http://search.aos.local` | add `192.168.32.100 search.aos.local` to `/etc/hosts` |
| Platform Gateway | `192.168.32.100:80` | Cilium L2 ARP, HTTPRoute routing |
| kubectl | `~/.kube/config` | merged from remote cluster |

SSH: `ssh stanley@192.168.32.11`

---

## 11. Pending / Roadmap

| Item | Priority | Notes |
|------|----------|-------|
| Observability | High | kube-prometheus-stack + Loki + Promtail · wave 4 |
| Cloud credentials | Medium | Run `scripts/setup-credentials.sh` |
| provider-cloudflare | Low | Monitor [crossplane-contrib/provider-upjet-cloudflare](https://github.com/crossplane-contrib/provider-upjet-cloudflare/releases) |
| TLS on gateway | Low | Add HTTPS listener + cert-manager for `*.aos.local` |
| ArgoCD SSO | Low | Replace admin password with OIDC |
