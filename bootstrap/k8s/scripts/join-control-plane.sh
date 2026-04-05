#!/bin/bash
set -euo pipefail

NODE_IP="${1:?Usage: join-control-plane.sh <node-ip> <hostname>}"
HOSTNAME="${2:?Usage: join-control-plane.sh <node-ip> <hostname>}"

SSH="ssh -i ~/.ssh/aos_k8s stanley@${NODE_IP}"

case $HOSTNAME in
  AOS02) ADVERTISE_IP=192.168.32.12 ;;
  AOS03) ADVERTISE_IP=192.168.32.13 ;;
  *) echo "Unknown hostname: $HOSTNAME"; exit 1 ;;
esac

echo "==> Step 1: Copy kube-vip manifest from AOS01 to ${HOSTNAME}"
KVMANIFEST=$(ssh -i ~/.ssh/aos_k8s stanley@192.168.32.11 \
  "sudo cat /etc/kubernetes/manifests/kube-vip.yaml")

$SSH "sudo bash -s" << REMOTE
mkdir -p /etc/kubernetes/manifests
cat > /etc/kubernetes/manifests/kube-vip.yaml << 'KVEOF'
${KVMANIFEST}
KVEOF
echo "kube-vip manifest placed"
REMOTE

echo "==> Step 2: Join cluster as control plane"
# Read join command parts from saved file
JOIN_TOKEN=$(grep "kubeadm join" ~/journal/k8s/join-command.txt | head -1 | awk '{print $5}' | tr -d '\\')
DISCOVERY_HASH=$(grep "discovery-token-ca-cert-hash" ~/journal/k8s/join-command.txt | head -1 | awk '{print $2}')
CERT_KEY=$(grep "certificate-key" ~/journal/k8s/join-command.txt | head -1 | awk '{print $3}')

$SSH "sudo bash -s" << REMOTE
set -euo pipefail
kubeadm join 192.168.32.10:6443 \
  --token ${JOIN_TOKEN} \
  --discovery-token-ca-cert-hash ${DISCOVERY_HASH} \
  --control-plane \
  --certificate-key ${CERT_KEY} \
  --apiserver-advertise-address ${ADVERTISE_IP} 2>&1 | tee /tmp/kubeadm-join.log
REMOTE

echo "==> Step 3: Configure kubectl for stanley"
$SSH "bash -s" << 'REMOTE'
mkdir -p ~/.kube
sudo cp /etc/kubernetes/admin.conf ~/.kube/config
sudo chown $(id -u):$(id -g) ~/.kube/config
echo "kubectl configured"
REMOTE

echo "==> Step 4: Remove control-plane taint from ${HOSTNAME}"
$SSH "kubectl taint nodes $(echo ${HOSTNAME} | tr '[:upper:]' '[:lower:]') node-role.kubernetes.io/control-plane:NoSchedule-"

echo "==> ${HOSTNAME} joined cluster successfully"
