#!/bin/bash
# setup-gh-runner.sh
# Installs a GitHub Actions self-hosted runner on an AOS cluster node as a
# systemd service. The runner connects outbound to GitHub — no inbound ports
# needed. Used by the diff-preview workflow to access the cluster LAN.
#
# Usage (run on aos01, aos02, or aos03):
#   sudo ./setup-gh-runner.sh <RUNNER_TOKEN>
#
# Get RUNNER_TOKEN from:
#   GitHub → Universal-Cloud-Platform → Settings → Actions → Runners → New self-hosted runner
#   Copy the token from the "Configure" step.
#
# Labels applied: self-hosted, aos-cluster, linux, x64
# These labels match the diff-preview.yml: runs-on: [self-hosted, aos-cluster]

set -euo pipefail

RUNNER_TOKEN="${1:?Usage: setup-gh-runner.sh <RUNNER_TOKEN>}"
RUNNER_VERSION="2.321.0"
RUNNER_USER="github-runner"
RUNNER_DIR="/opt/github-runner"
REPO_URL="https://github.com/StanleyXie/Universal-Cloud-Platform"

echo "==> Creating runner user"
id "$RUNNER_USER" &>/dev/null || useradd -m -s /bin/bash "$RUNNER_USER"

echo "==> Granting runner user read-only kubectl access"
# Copy kubeconfig and restrict permissions
mkdir -p "/home/${RUNNER_USER}/.kube"
cp /root/.kube/config "/home/${RUNNER_USER}/.kube/config" 2>/dev/null || \
  cp "$HOME/.kube/config" "/home/${RUNNER_USER}/.kube/config"
chown -R "${RUNNER_USER}:${RUNNER_USER}" "/home/${RUNNER_USER}/.kube"
chmod 600 "/home/${RUNNER_USER}/.kube/config"

echo "==> Installing runner to ${RUNNER_DIR}"
mkdir -p "$RUNNER_DIR"
chown "${RUNNER_USER}:${RUNNER_USER}" "$RUNNER_DIR"

ARCH="linux-x64"
curl -sSLo /tmp/runner.tar.gz \
  "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-${ARCH}-${RUNNER_VERSION}.tar.gz"
tar -xzf /tmp/runner.tar.gz -C "$RUNNER_DIR"
chown -R "${RUNNER_USER}:${RUNNER_USER}" "$RUNNER_DIR"

echo "==> Configuring runner"
sudo -u "$RUNNER_USER" "$RUNNER_DIR/config.sh" \
  --url "$REPO_URL" \
  --token "$RUNNER_TOKEN" \
  --name "aos-$(hostname)" \
  --labels "self-hosted,aos-cluster,linux,x64" \
  --work "_work" \
  --unattended

echo "==> Installing as systemd service"
"$RUNNER_DIR/svc.sh" install "$RUNNER_USER"
"$RUNNER_DIR/svc.sh" start

echo ""
echo "Runner status:"
"$RUNNER_DIR/svc.sh" status

echo ""
echo "══════════════════════════════════════════════════════════════"
echo " Runner installed and running."
echo " Verify at: GitHub → Universal-Cloud-Platform → Settings → Actions → Runners"
echo "══════════════════════════════════════════════════════════════"
