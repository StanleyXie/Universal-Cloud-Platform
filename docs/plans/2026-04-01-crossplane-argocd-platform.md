# Crossplane + ArgoCD Platform Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

> **Decision (2026-04-03):** Gitea removed. GitHub is the permanent source of truth.
> Tasks 3 (Gitea Helm values) and 10 (Git migration to Gitea) are void — do not implement them.

**Goal:** Bootstrap ArgoCD on the cluster, then use a GitHub App-of-Apps repo to install local-path-provisioner, Crossplane, and all cloud providers via GitOps sync waves.

**Architecture:** ArgoCD is the only thing installed by script. Everything else is declared in a `platform` Git repo hosted on GitHub (permanent), synced by ArgoCD App-of-Apps with sync waves controlling install order.

**Tech Stack:** ArgoCD (Helm), Crossplane (Helm), local-path-provisioner, Upbound providers (AWS, GCP, Azure, Cloudflare, Terraform)

---

### Task 1: Create platform Git repo structure

**Files:**
- Create: `~/platform/` (new standalone git repo)
- Create: `~/platform/apps/root.yaml`
- Create: `~/platform/apps/local-path-provisioner.yaml`
- Create: `~/platform/apps/gitea.yaml`
- Create: `~/platform/apps/crossplane.yaml`
- Create: `~/platform/apps/crossplane-providers.yaml`

**Step 1: Initialize repo**

```bash
mkdir -p ~/platform
cd ~/platform
git init
git checkout -b main
```

**Step 2: Create root App-of-Apps**

Create `~/platform/apps/root.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/GITHUB_USER/platform
    targetRevision: HEAD
    path: apps
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

**Step 3: Create local-path-provisioner Application**

Create `~/platform/apps/local-path-provisioner.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: local-path-provisioner
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  project: default
  source:
    repoURL: https://github.com/GITHUB_USER/platform
    targetRevision: HEAD
    path: local-path-provisioner
  destination:
    server: https://kubernetes.default.svc
    namespace: local-path-storage
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

**Step 4: Create Gitea Application**

Create `~/platform/apps/gitea.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: gitea
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  project: default
  source:
    repoURL: https://dl.gitea.com/charts/
    chart: gitea
    targetRevision: "10.*"
    helm:
      valueFiles:
        - $values/gitea/values.yaml
  sources:
    - repoURL: https://dl.gitea.com/charts/
      chart: gitea
      targetRevision: "10.*"
      helm:
        valueFiles:
          - $values/gitea/values.yaml
    - repoURL: https://github.com/GITHUB_USER/platform
      targetRevision: HEAD
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: gitea
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

**Step 5: Create Crossplane Application**

Create `~/platform/apps/crossplane.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: crossplane
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  project: default
  source:
    repoURL: https://charts.crossplane.io/stable
    chart: crossplane
    targetRevision: "1.*"
    helm:
      valueFiles:
        - $values/crossplane/values.yaml
  sources:
    - repoURL: https://charts.crossplane.io/stable
      chart: crossplane
      targetRevision: "1.*"
      helm:
        valueFiles:
          - $values/crossplane/values.yaml
    - repoURL: https://github.com/GITHUB_USER/platform
      targetRevision: HEAD
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: crossplane-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

**Step 6: Create Crossplane providers Application**

Create `~/platform/apps/crossplane-providers.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: crossplane-providers
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "3"
spec:
  project: default
  source:
    repoURL: https://github.com/GITHUB_USER/platform
    targetRevision: HEAD
    path: crossplane-providers
  destination:
    server: https://kubernetes.default.svc
    namespace: crossplane-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

**Step 7: Verify files exist**

```bash
ls ~/platform/apps/
```

Expected: `root.yaml  local-path-provisioner.yaml  gitea.yaml  crossplane.yaml  crossplane-providers.yaml`

---

### Task 2: Create local-path-provisioner manifest

**Files:**
- Create: `~/platform/local-path-provisioner/install.yaml`

**Step 1: Download manifest**

```bash
mkdir -p ~/platform/local-path-provisioner
curl -fsSL https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.31/deploy/local-path-storage.yaml \
  -o ~/platform/local-path-provisioner/install.yaml
```

**Step 2: Make it the default StorageClass**

Edit `~/platform/local-path-provisioner/install.yaml` — find the `StorageClass` object and add the annotation:

```yaml
metadata:
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
```

**Step 3: Verify**

```bash
grep "is-default-class" ~/platform/local-path-provisioner/install.yaml
```

Expected: `storageclass.kubernetes.io/is-default-class: "true"`

---

### Task 3: Create Gitea Helm values

**Files:**
- Create: `~/platform/gitea/values.yaml`

**Step 1: Write values**

Create `~/platform/gitea/values.yaml`:

```yaml
gitea:
  admin:
    username: stanley
    password: "changeme123!"
    email: stanley@local

service:
  http:
    type: NodePort
    port: 3000
    nodePort: 30300
  ssh:
    type: NodePort
    port: 22
    nodePort: 30022

persistence:
  enabled: true
  storageClass: local-path
  size: 10Gi

resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 512Mi

# Disable unnecessary features for homelab
redis-cluster:
  enabled: false
redis:
  enabled: true
postgresql:
  enabled: true
postgresql-ha:
  enabled: false
```

---

### Task 4: Create Crossplane Helm values

**Files:**
- Create: `~/platform/crossplane/values.yaml`

**Step 1: Write values**

Create `~/platform/crossplane/values.yaml`:

```yaml
replicas: 1

resourcesCrossplane:
  limits:
    cpu: 500m
    memory: 512Mi
  requests:
    cpu: 100m
    memory: 256Mi

resourcesRBACManager:
  limits:
    cpu: 100m
    memory: 128Mi
  requests:
    cpu: 50m
    memory: 64Mi
```

---

### Task 5: Create Crossplane provider manifests

**Files:**
- Create: `~/platform/crossplane-providers/provider-aws.yaml`
- Create: `~/platform/crossplane-providers/provider-gcp.yaml`
- Create: `~/platform/crossplane-providers/provider-azure.yaml`
- Create: `~/platform/crossplane-providers/provider-cloudflare.yaml`
- Create: `~/platform/crossplane-providers/provider-terraform.yaml`

**Step 1: Create providers directory**

```bash
mkdir -p ~/platform/crossplane-providers
```

**Step 2: Write provider-aws.yaml**

```yaml
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-family-aws
  namespace: crossplane-system
spec:
  package: xpkg.upbound.io/upbound/provider-family-aws:v1
  packagePullPolicy: IfNotPresent
  revisionActivationPolicy: Automatic
```

**Step 3: Write provider-gcp.yaml**

```yaml
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-family-gcp
  namespace: crossplane-system
spec:
  package: xpkg.upbound.io/upbound/provider-family-gcp:v1
  packagePullPolicy: IfNotPresent
  revisionActivationPolicy: Automatic
```

**Step 4: Write provider-azure.yaml**

```yaml
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-family-azure
  namespace: crossplane-system
spec:
  package: xpkg.upbound.io/upbound/provider-family-azure:v1
  packagePullPolicy: IfNotPresent
  revisionActivationPolicy: Automatic
```

**Step 5: Write provider-cloudflare.yaml**

```yaml
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-cloudflare
  namespace: crossplane-system
spec:
  package: xpkg.upbound.io/upbound/provider-cloudflare:v0
  packagePullPolicy: IfNotPresent
  revisionActivationPolicy: Automatic
```

**Step 6: Write provider-terraform.yaml**

```yaml
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-terraform
  namespace: crossplane-system
spec:
  package: xpkg.upbound.io/upbound/provider-terraform:v0
  packagePullPolicy: IfNotPresent
  revisionActivationPolicy: Automatic
  controllerConfigRef:
    name: provider-terraform-config
---
apiVersion: pkg.crossplane.io/v1alpha1
kind: ControllerConfig
metadata:
  name: provider-terraform-config
  namespace: crossplane-system
spec:
  serviceAccountName: provider-terraform
  args:
    - --enable-management-policies
```

**Step 7: Verify all files**

```bash
ls ~/platform/crossplane-providers/
```

Expected: `provider-aws.yaml  provider-azure.yaml  provider-cloudflare.yaml  provider-gcp.yaml  provider-terraform.yaml`

---

### Task 6: Create bootstrap script

**Files:**
- Create: `~/journal/platform/scripts/bootstrap-argocd.sh`

**Step 1: Create directory**

```bash
mkdir -p ~/journal/platform/scripts
```

**Step 2: Write script**

Create `~/journal/platform/scripts/bootstrap-argocd.sh`:

```bash
#!/bin/bash
set -euo pipefail

GITHUB_REPO="${1:?Usage: bootstrap-argocd.sh <github-repo-url>}"
SSH="ssh -i ~/.ssh/aos_k8s stanley@192.168.32.11"

echo "==> Step 1: Install ArgoCD"
$SSH "bash -s" << 'REMOTE'
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm install argocd argo/argo-cd \
  --namespace argocd \
  --create-namespace \
  --set server.service.type=NodePort \
  --set server.service.nodePortHttp=30880 \
  --set server.service.nodePortHttps=30843 \
  --wait \
  --timeout 5m
echo "ArgoCD installed"
REMOTE

echo "==> Step 2: Apply root App-of-Apps"
GITHUB_REPO_URL="${GITHUB_REPO}"
$SSH "bash -s" << REMOTE
kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
spec:
  project: default
  source:
    repoURL: ${GITHUB_REPO_URL}
    targetRevision: HEAD
    path: apps
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF
echo "Root app applied"
REMOTE

echo ""
echo "==> Bootstrap complete!"
echo ""
echo "ArgoCD UI:      http://192.168.32.11:30880"
echo "Initial password:"
$SSH "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d && echo"
```

**Step 3: Make executable**

```bash
chmod +x ~/journal/platform/scripts/bootstrap-argocd.sh
```

---

### Task 7: Push platform repo to GitHub

**Step 1: Create GitHub repo**

Go to GitHub and create a new public repo named `platform` under your account.

**Step 2: Replace GITHUB_USER placeholder in all files**

```bash
cd ~/platform
GITHUB_USER="<your-github-username>"
find . -name "*.yaml" -exec sed -i '' "s/GITHUB_USER/${GITHUB_USER}/g" {} \;
```

**Step 3: Initial commit and push**

```bash
cd ~/platform
git add .
git commit -m "feat: initial platform App-of-Apps structure"
git remote add origin https://github.com/${GITHUB_USER}/platform.git
git push -u origin main
```

**Step 4: Verify on GitHub**

Open `https://github.com/<your-username>/platform` and confirm all files are present.

---

### Task 8: Bootstrap ArgoCD

**Step 1: Run bootstrap script**

```bash
~/journal/platform/scripts/bootstrap-argocd.sh https://github.com/<your-username>/platform
```

Expected: ends with `Bootstrap complete!` and prints the initial ArgoCD password.

**Step 2: Verify ArgoCD pods are running**

```bash
ssh -i ~/.ssh/aos_k8s stanley@192.168.32.11 "kubectl get pods -n argocd"
```

Expected: all pods `Running` or `Ready`.

**Step 3: Check ArgoCD UI is accessible**

```bash
curl -sk http://192.168.32.11:30880 | grep -i "argo"
```

Expected: HTML containing ArgoCD page content.

---

### Task 9: Verify full platform sync

**Step 1: Watch sync progress (allow up to 10 min for all waves)**

```bash
ssh -i ~/.ssh/aos_k8s stanley@192.168.32.11 "watch kubectl get applications -n argocd"
```

Expected order of appearance and sync:
1. `root` → Synced
2. `local-path-provisioner` → Synced
3. `gitea` → Synced
4. `crossplane` → Synced
5. `crossplane-providers` → Synced

**Step 2: Verify StorageClass**

```bash
ssh -i ~/.ssh/aos_k8s stanley@192.168.32.11 "kubectl get storageclass"
```

Expected: `local-path (default)` present.

**Step 3: Verify Gitea**

```bash
curl -s http://192.168.32.11:30300
```

Expected: Gitea HTML page.

**Step 4: Verify Crossplane**

```bash
ssh -i ~/.ssh/aos_k8s stanley@192.168.32.11 "kubectl get pods -n crossplane-system"
```

Expected: `crossplane-*` and `crossplane-rbac-manager-*` pods `Running`.

**Step 5: Verify providers are installing**

```bash
ssh -i ~/.ssh/aos_k8s stanley@192.168.32.11 "kubectl get providers -n crossplane-system"
```

Expected: all 5 providers listed (may show `Installing` initially, then `Healthy`).

---

### Task 10: Migrate Git source to Gitea

**Step 1: Log in to Gitea and create repo**

```bash
# Create repo via Gitea API
curl -X POST http://192.168.32.11:30300/api/v1/user/repos \
  -H "Content-Type: application/json" \
  -u stanley:changeme123! \
  -d '{"name":"platform","private":false,"description":"Platform GitOps repo","default_branch":"main"}'
```

Expected: JSON response with `"full_name":"stanley/platform"`.

**Step 2: Push platform repo to Gitea**

```bash
cd ~/platform
git remote add gitea http://stanley:changeme123!@192.168.32.11:30300/stanley/platform.git
git push gitea main
```

**Step 3: Update ArgoCD Application sources to use Gitea**

On each Application yaml in `~/platform/apps/`, replace:
```
repoURL: https://github.com/<user>/platform
```
with:
```
repoURL: http://gitea.gitea.svc:3000/stanley/platform.git
```

Do this for all 5 Application files:

```bash
cd ~/platform
find apps/ -name "*.yaml" -exec sed -i '' \
  's|https://github.com/.*/platform|http://gitea.gitea.svc:3000/stanley/platform.git|g' {} \;
```

Also update the `root` Application (which ArgoCD already has applied) — patch it directly:

```bash
ssh -i ~/.ssh/aos_k8s stanley@192.168.32.11 "kubectl patch application root -n argocd \
  --type=json \
  -p='[{\"op\":\"replace\",\"path\":\"/spec/source/repoURL\",\"value\":\"http://gitea.gitea.svc:3000/stanley/platform.git\"}]'"
```

**Step 4: Commit and push updated apps to Gitea**

```bash
cd ~/platform
git add apps/
git commit -m "feat: migrate ArgoCD sources to in-cluster Gitea"
git push gitea main
```

**Step 5: Verify ArgoCD re-syncs from Gitea**

```bash
ssh -i ~/.ssh/aos_k8s stanley@192.168.32.11 "kubectl get applications -n argocd"
```

Expected: all applications show `Synced` with source now pointing to Gitea.

**Step 6: Verify all providers healthy**

```bash
ssh -i ~/.ssh/aos_k8s stanley@192.168.32.11 "kubectl get providers"
```

Expected: all 5 providers `INSTALLED=True  HEALTHY=True`.

---

## Notes

- Provider credentials (`ProviderConfig`) are **not** set up in this plan — covered in a future plan
- ArgoCD admin password should be changed after first login: Settings → Accounts → admin → Update Password
- Gitea admin password (`changeme123!`) should be changed after first login
- GitHub repo can be kept as a backup mirror: `git push github main` from `~/platform` at any time
