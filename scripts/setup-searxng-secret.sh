#!/usr/bin/env bash
# Creates the searxng-secret in the common-svc namespace.
# The chart injects the value as SEARXNG_SECRET env var for the secret_key.
# Run once before ArgoCD deploys SearXNG, or to rotate the key.
set -euo pipefail

NAMESPACE="common-svc"
SECRET_NAME="searxng-secret"
SECRET_KEY=$(openssl rand -hex 32)

echo "Generating SearXNG secret key..."

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic "$SECRET_NAME" \
  --namespace "$NAMESPACE" \
  --from-literal=searxng-secret="$SECRET_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Secret '${SECRET_NAME}' created in namespace '${NAMESPACE}'."
echo "ArgoCD will now be able to deploy SearXNG successfully."
