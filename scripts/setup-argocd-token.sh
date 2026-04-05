#!/bin/bash
# setup-argocd-token.sh
# Creates a read-only ArgoCD service account and API token for use in
# the diff-preview GitHub Actions workflow.
#
# Usage:
#   ./setup-argocd-token.sh
#
# Output:
#   Prints the token — add it to GitHub as secret ARGOCD_AUTH_TOKEN
#   Also add ARGOCD_SERVER = "192.168.32.11:30843" to GitHub secrets
#
# Requirements:
#   - argocd CLI installed and logged in as admin
#   - kubectl access to the cluster

set -euo pipefail

ACCOUNT_NAME="ci-diff-preview"
ARGOCD_NS="argocd"

echo "==> Creating ArgoCD local user: ${ACCOUNT_NAME}"

# Patch the argocd-cm ConfigMap to add the service account
kubectl -n "$ARGOCD_NS" get configmap argocd-cm -o json | \
  python3 -c "
import sys, json
cm = json.load(sys.stdin)
accounts = cm['data'].get('accounts.${ACCOUNT_NAME}', '')
if 'apiKey' not in accounts:
    cm['data']['accounts.${ACCOUNT_NAME}'] = 'apiKey'
    print(json.dumps(cm))
else:
    print('already exists', file=sys.stderr)
    sys.exit(0)
" | kubectl apply -f - 2>/dev/null || echo "(account already configured)"

echo "==> Waiting for ArgoCD to pick up config change..."
sleep 5

echo "==> Setting RBAC policy: read-only on all apps"
kubectl -n "$ARGOCD_NS" get configmap argocd-rbac-cm -o json | \
  python3 -c "
import sys, json
cm = json.load(sys.stdin)
policy = cm['data'].get('policy.csv', '')
rule = 'p, role:ci-readonly, applications, get, */*, allow'
if rule not in policy:
    cm['data']['policy.csv'] = policy.rstrip() + '\n' + rule + '\n'
    binding = 'g, ${ACCOUNT_NAME}, role:ci-readonly'
    if binding not in cm['data']['policy.csv']:
        cm['data']['policy.csv'] += binding + '\n'
    print(json.dumps(cm))
else:
    print('policy already set', file=sys.stderr)
    sys.exit(0)
" | kubectl apply -f - 2>/dev/null || echo "(RBAC already configured)"

echo "==> Generating API token"
TOKEN=$(argocd account generate-token --account "$ACCOUNT_NAME")

echo ""
echo "══════════════════════════════════════════════════════════════"
echo " Add the following secrets to GitHub:"
echo " Repo: StanleyXie/Universal-Cloud-Platform"
echo " Settings → Secrets and variables → Actions → New repository secret"
echo ""
echo " ARGOCD_AUTH_TOKEN = ${TOKEN}"
echo " ARGOCD_SERVER     = 192.168.32.11:30843"
echo "══════════════════════════════════════════════════════════════"
echo ""
echo "Token is NOT stored locally. Copy it now."
