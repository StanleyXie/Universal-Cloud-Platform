#!/bin/bash
set -euo pipefail

SSH="ssh -i ~/.ssh/aos_k8s stanley@192.168.32.11"

echo "==> Step 1: Deploy kube-vip static pod"
$SSH "sudo bash -s" << 'REMOTE'
set -euo pipefail
KVVERSION=$(curl -sL https://api.github.com/repos/kube-vip/kube-vip/releases/latest \
  | grep '"tag_name"' | cut -d'"' -f4)
echo "kube-vip version: $KVVERSION"

mkdir -p /etc/kubernetes/manifests

ctr image pull ghcr.io/kube-vip/kube-vip:${KVVERSION}

ctr run --rm --net-host ghcr.io/kube-vip/kube-vip:${KVVERSION} vip \
  /kube-vip manifest pod \
    --interface enp3s0 \
    --address 192.168.32.10 \
    --controlplane \
    --arp \
    --leaderElection \
  | tee /etc/kubernetes/manifests/kube-vip.yaml

echo "kube-vip manifest written"
REMOTE

echo "==> Step 2: kubeadm init"
$SSH "sudo bash -s" << 'REMOTE'
set -euo pipefail
# Temporarily assign VIP to loopback so kubeadm can POST to the controlPlaneEndpoint
# during upload-config phase (kube-vip isn't running yet at that point)
ip addr add 192.168.32.10/32 dev lo 2>/dev/null || true
trap 'ip addr del 192.168.32.10/32 dev lo 2>/dev/null || true' EXIT

cat > /tmp/kubeadm-config.yaml << 'EOF'
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v1.35.0
controlPlaneEndpoint: "192.168.32.10:6443"
networking:
  podSubnet: "10.10.0.0/16"
  serviceSubnet: "10.96.0.0/12"
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: "192.168.32.11"
  bindPort: 6443
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
failSwapOn: false
memorySwap:
  swapBehavior: LimitedSwap
cgroupDriver: systemd
EOF

kubeadm init --config /tmp/kubeadm-config.yaml --upload-certs 2>&1 | tee /tmp/kubeadm-init.log
echo "kubeadm init complete"
REMOTE

echo "==> Step 3: Configure kubectl for stanley"
$SSH "bash -s" << 'REMOTE'
mkdir -p ~/.kube
sudo cp /etc/kubernetes/admin.conf ~/.kube/config
sudo chown $(id -u):$(id -g) ~/.kube/config
echo "kubectl configured"
REMOTE

echo "==> Step 4: Remove control-plane taint from AOS01"
$SSH "kubectl taint nodes aos01 node-role.kubernetes.io/control-plane:NoSchedule-"

echo "==> Step 5: Install Helm"
$SSH "bash -s" << 'REMOTE'
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
REMOTE

echo "==> Step 6: Install Cilium"
$SSH "bash -s" << 'REMOTE'
helm repo add cilium https://helm.cilium.io/
helm repo update
helm install cilium cilium/cilium \
  --namespace kube-system \
  --set ipam.mode=kubernetes \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=192.168.32.10 \
  --set k8sServicePort=6443
echo "Cilium installed"
REMOTE

echo "==> Step 7: Save join commands"
mkdir -p ~/journal/k8s
$SSH "sudo grep -A2 'kubeadm join' /tmp/kubeadm-init.log | head -20" \
  > ~/journal/k8s/join-command.txt
echo "Join commands saved to ~/journal/k8s/join-command.txt"
cat ~/journal/k8s/join-command.txt

echo "==> AOS01 control plane initialized"
