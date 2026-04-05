#!/bin/bash
set -euo pipefail

# Bootstrap ArgoCD onto the AOS cluster and apply the root App-of-Apps.
#
# Usage:
#   ./bootstrap-argocd.sh <github-repo-url>
#
# Example:
#   ./bootstrap-argocd.sh https://github.com/StanleyXie/Universal-Cloud-Platform
#
# After this script completes, ArgoCD will:
#   1. Sync all applications defined in apps/
#   2. Pick up apps/argocd.yaml and begin managing itself (self-management)
#
# Requirements:
#   - kubeconfig with cluster-admin access configured locally
#   - Helm 3 installed locally
#   - The platform repo already pushed to GitHub

GITHUB_REPO="${1:?Usage: bootstrap-argocd.sh <github-repo-url>}"

ARGOCD_CHART_VERSION="9.4.17"   # Must match apps/argocd.yaml targetRevision
ARGOCD_NAMESPACE="argocd"

echo "==> Step 1: Add Helm repo"
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

echo "==> Step 2: Install ArgoCD (chart ${ARGOCD_CHART_VERSION})"
helm install argocd argo/argo-cd \
  --namespace "${ARGOCD_NAMESPACE}" \
  --create-namespace \
  --version "${ARGOCD_CHART_VERSION}" \
  --set server.service.type=NodePort \
  --set server.service.nodePortHttp=30880 \
  --set server.service.nodePortHttps=30843 \
  --wait \
  --timeout 5m
echo "ArgoCD installed"

echo "==> Step 3: Apply root App-of-Apps"
kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: ${ARGOCD_NAMESPACE}
spec:
  project: default
  source:
    repoURL: ${GITHUB_REPO}
    targetRevision: HEAD
    path: apps
  destination:
    server: https://kubernetes.default.svc
    namespace: ${ARGOCD_NAMESPACE}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF
echo "Root app applied"

echo ""
echo "==> Bootstrap complete!"
echo ""
echo "ArgoCD UI:        http://192.168.32.11:30880"
echo "Initial password:"
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d && echo
echo ""
echo "NOTE: ArgoCD will now self-sync. Within a few minutes it will discover"
echo "      apps/argocd.yaml and begin managing itself. Once that app is Synced,"
echo "      resource limits and other Helm values from argocd/values.yaml will"
echo "      be applied. Change the admin password via the UI after first login."
