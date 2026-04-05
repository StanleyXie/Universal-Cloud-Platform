#!/bin/bash
set -euo pipefail

NODE_IP="${1:?Usage: prep-node.sh <node-ip>}"
SSH="ssh -i ~/.ssh/aos_k8s stanley@${NODE_IP}"

echo "==> Preparing node ${NODE_IP}"

# 1. Remount lv-docker as /var/lib/containerd
$SSH "sudo bash -s" << 'REMOTE'
set -euo pipefail
sed -i 's|/var/lib/docker|/var/lib/containerd|g' /etc/fstab
if mountpoint -q /var/lib/docker; then
  umount /var/lib/docker
fi
mkdir -p /var/lib/containerd
mountpoint -q /var/lib/containerd || mount /var/lib/containerd
echo "Storage remounted at /var/lib/containerd"
REMOTE

# 2. Kernel modules
$SSH "sudo bash -s" << 'REMOTE'
set -euo pipefail
cat > /etc/modules-load.d/k8s.conf << 'EOF'
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter
echo "Kernel modules loaded"
REMOTE

# 3. sysctl
$SSH "sudo bash -s" << 'REMOTE'
set -euo pipefail
cat > /etc/sysctl.d/k8s.conf << 'EOF'
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
sysctl --system
echo "sysctl applied"
REMOTE

# 4. Install containerd
$SSH "sudo bash -s" << 'REMOTE'
set -euo pipefail
DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gnupg

install -m 0755 -d /etc/apt/keyrings
if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --batch --no-tty --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
fi

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | tee /etc/apt/sources.list.d/docker.list

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y containerd.io

mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

systemctl restart containerd
systemctl enable containerd
echo "containerd installed and configured"
REMOTE

# 5. Install kubeadm, kubelet, kubectl v1.35
$SSH "sudo bash -s" << 'REMOTE'
set -euo pipefail
DEBIAN_FRONTEND=noninteractive apt-get install -y apt-transport-https

if [ ! -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg ]; then
  curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.35/deb/Release.key \
    | gpg --batch --no-tty --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
fi

echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.35/deb/ /' \
  | tee /etc/apt/sources.list.d/kubernetes.list

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
systemctl enable kubelet
echo "kubeadm/kubelet/kubectl installed"
REMOTE

# 6. /etc/hosts entries
$SSH "sudo bash -s" << 'REMOTE'
set -euo pipefail
grep -q "k8s-api" /etc/hosts || cat >> /etc/hosts << 'EOF'
192.168.32.10  k8s-api
192.168.32.11  AOS01
192.168.32.12  AOS02
192.168.32.13  AOS03
EOF
echo "/etc/hosts updated"
REMOTE

echo "==> Node ${NODE_IP} prepared successfully"
