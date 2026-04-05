#!/usr/bin/env bash
# Creates the searxng-secret in the common-svc namespace.
# Contains a complete settings.yml with a generated secret_key.
# Run once before ArgoCD deploys SearXNG, or to rotate the key.
set -euo pipefail

NAMESPACE="common-svc"
SECRET_NAME="searxng-secret"
SECRET_KEY=$(openssl rand -hex 32)

echo "Generating SearXNG secret key..."

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic "$SECRET_NAME" \
  --namespace "$NAMESPACE" \
  --from-literal=settings.yml="$(cat <<EOF
use_default_settings: true

server:
  secret_key: "${SECRET_KEY}"
  limiter: false
  image_proxy: false

search:
  safe_search: 0
  autocomplete: ""

ui:
  default_theme: simple
  default_language: "en"
  query_in_title: false
EOF
)" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Secret '${SECRET_NAME}' created in namespace '${NAMESPACE}'."
echo "ArgoCD will now be able to deploy SearXNG successfully."
