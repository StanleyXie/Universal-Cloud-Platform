# Kubernetes HA Cluster Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Deploy a 3-node Kubernetes v1.35 HA cluster on AOS01/AOS02/AOS03 using kubeadm, kube-vip, and Cilium CNI.

**Architecture:** All 3 NUC nodes run as control-plane+worker with stacked etcd. kube-vip provides a floating VIP (192.168.32.10) in ARP mode. Scripts are created on the Mac and executed remotely via SSH.

**Tech Stack:** kubeadm v1.35, containerd, kube-vip (ARP), Cilium (eBPF), Helm 3

---

## Prerequisites

- SSH access to all 3 nodes: `ssh stanley@192.168.32.11/12/13`
- Password: `<PASSWORD>` (or use `ssh-copy-id` first)
- All nodes have internet access via enp3s0 or enp2s0

---

### Task 1: Set up SSH key auth to all nodes

**Files:**
- No files created

**Step 1: Copy SSH key to all 3 nodes**

```bash
ssh-keygen -t ed25519 -f ~/.ssh/aos_k8s -N "" 2>/dev/null || true
ssh-copy-id -i ~/.ssh/aos_k8s.pub stanley@192.168.32.11
ssh-copy-id -i ~/.ssh/aos_k8s.pub stanley@192.168.32.12
ssh-copy-id -i ~/.ssh/aos_k8s.pub stanley@192.168.32.13
```

**Step 2: Verify passwordless access**

```bash
ssh -i ~/.ssh/aos_k8s stanley@192.168.32.11 hostname
ssh -i ~/.ssh/aos_k8s stanley@192.168.32.12 hostname
ssh -i ~/.ssh/aos_k8s stanley@192.168.32.13 hostname
```

Expected: `AOS01`, `AOS02`, `AOS03`

---

### Task 2: Create prep-node.sh

**Files:**
- Create: `k8s/scripts/prep-node.sh`

**Step 1: Create scripts directory**

```bash
mkdir -p ~/journal/k8s/scripts
```

**Step 2: Write prep-node.sh**

Create `~/journal/k8s/scripts/prep-node.sh`:

```bash
#!/bin/bash
set -euo pipefail

NODE_IP="${1:?Usage: prep-node.sh <node-ip>}"
SSH="ssh -i ~/.ssh/aos_k8s stanley@${NODE_IP}"

echo "==> Preparing node ${NODE_IP}"

# 1. Remount lv-docker as /var/lib/containerd
$SSH "sudo bash -s" << 'REMOTE'
set -euo pipefail

# Rename mount point in fstab
sed -i 's|/var/lib/docker|/var/lib/containerd|g' /etc/fstab

# Move mount
if mountpoint -q /var/lib/docker; then
  umount /var/lib/docker
fi
mkdir -p /var/lib/containerd
mount /var/lib/containerd
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
apt-get install -y ca-certificates curl gnupg

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | tee /etc/apt/sources.list.d/docker.list

apt-get update
apt-get install -y containerd.io

# Configure containerd
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
apt-get install -y apt-transport-https

curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.35/deb/Release.key \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v1.35/deb/ /' \
  | tee /etc/apt/sources.list.d/kubernetes.list

apt-get update
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
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
```

**Step 3: Make executable**

```bash
chmod +x ~/journal/k8s/scripts/prep-node.sh
```

---

### Task 3: Run prep-node.sh on all 3 nodes

**Step 1: Run on AOS01**

```bash
~/journal/k8s/scripts/prep-node.sh 192.168.32.11
```

Expected: ends with `Node 192.168.32.11 prepared successfully`

**Step 2: Run on AOS02**

```bash
~/journal/k8s/scripts/prep-node.sh 192.168.32.12
```

Expected: ends with `Node 192.168.32.12 prepared successfully`

**Step 3: Run on AOS03**

```bash
~/journal/k8s/scripts/prep-node.sh 192.168.32.13
```

Expected: ends with `Node 192.168.32.13 prepared successfully`

**Step 4: Verify containerd running on all nodes**

```bash
for ip in 192.168.32.11 192.168.32.12 192.168.32.13; do
  echo -n "$ip: "
  ssh -i ~/.ssh/aos_k8s stanley@$ip "sudo systemctl is-active containerd"
done
```

Expected: `active` for all 3

---

### Task 4: Create init-control-plane.sh

**Files:**
- Create: `k8s/scripts/init-control-plane.sh`

Create `~/journal/k8s/scripts/init-control-plane.sh`:

```bash
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

kubeadm init --config /tmp/kubeadm-config.yaml --upload-certs | tee /tmp/kubeadm-init.log
echo "kubeadm init complete"
REMOTE

echo "==> Step 3: Configure kubectl for stanley"
$SSH "bash -s" << 'REMOTE'
mkdir -p ~/.kube
sudo cp /etc/kubernetes/admin.conf ~/.kube/config
sudo chown $(id -u):$(id -g) ~/.kube/config
REMOTE

echo "==> Step 4: Remove control-plane taint from AOS01"
$SSH "kubectl taint nodes AOS01 node-role.kubernetes.io/control-plane:NoSchedule-"

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
REMOTE

echo "==> Step 7: Save join command"
$SSH "sudo cat /tmp/kubeadm-init.log" | grep -A2 "kubeadm join" > ~/journal/k8s/join-command.txt
echo "Join command saved to ~/journal/k8s/join-command.txt"

echo "==> AOS01 control plane initialized"
```

```bash
chmod +x ~/journal/k8s/scripts/init-control-plane.sh
```

---

### Task 5: Create join-control-plane.sh

**Files:**
- Create: `k8s/scripts/join-control-plane.sh`

Create `~/journal/k8s/scripts/join-control-plane.sh`:

```bash
#!/bin/bash
set -euo pipefail

NODE_IP="${1:?Usage: join-control-plane.sh <node-ip> <hostname>}"
HOSTNAME="${2:?Usage: join-control-plane.sh <node-ip> <hostname>}"
JOIN_CMD="${3:?Usage: join-control-plane.sh <node-ip> <hostname> '<full join command>'}"

SSH="ssh -i ~/.ssh/aos_k8s stanley@${NODE_IP}"

# Node IP mapping
case $HOSTNAME in
  AOS02) ADVERTISE_IP=192.168.32.12 ;;
  AOS03) ADVERTISE_IP=192.168.32.13 ;;
  *) echo "Unknown hostname: $HOSTNAME"; exit 1 ;;
esac

echo "==> Step 1: Deploy kube-vip static pod on ${HOSTNAME}"
# Copy kube-vip manifest from AOS01
KVMANIFEST=$(ssh -i ~/.ssh/aos_k8s stanley@192.168.32.11 "sudo cat /etc/kubernetes/manifests/kube-vip.yaml")
$SSH "sudo bash -s" << REMOTE
mkdir -p /etc/kubernetes/manifests
cat > /etc/kubernetes/manifests/kube-vip.yaml << 'EOF'
${KVMANIFEST}
EOF
echo "kube-vip manifest placed"
REMOTE

echo "==> Step 2: Join cluster as control plane"
$SSH "sudo bash -s" << REMOTE
set -euo pipefail
# Patch join command with this node's advertise address
${JOIN_CMD} --apiserver-advertise-address ${ADVERTISE_IP} | tee /tmp/kubeadm-join.log
REMOTE

echo "==> Step 3: Configure kubectl for stanley"
$SSH "bash -s" << 'REMOTE'
mkdir -p ~/.kube
sudo cp /etc/kubernetes/admin.conf ~/.kube/config
sudo chown $(id -u):$(id -g) ~/.kube/config
REMOTE

echo "==> Step 4: Remove control-plane taint from ${HOSTNAME}"
$SSH "kubectl taint nodes ${HOSTNAME} node-role.kubernetes.io/control-plane:NoSchedule-"

echo "==> ${HOSTNAME} joined cluster successfully"
```

```bash
chmod +x ~/journal/k8s/scripts/join-control-plane.sh
```

---

### Task 6: Create validate-cluster.sh

**Files:**
- Create: `k8s/scripts/validate-cluster.sh`

Create `~/journal/k8s/scripts/validate-cluster.sh`:

```bash
#!/bin/bash
set -euo pipefail

SSH="ssh -i ~/.ssh/aos_k8s stanley@192.168.32.11"

echo "=== Kubernetes Cluster Validation ==="

echo ""
echo "--- Nodes ---"
$SSH "kubectl get nodes -o wide"

echo ""
echo "--- kube-system pods ---"
$SSH "kubectl get pods -n kube-system -o wide"

echo ""
echo "--- Cilium status ---"
$SSH "kubectl -n kube-system exec ds/cilium -- cilium status --brief" 2>/dev/null || \
  echo "(cilium CLI not available in pod, check pod status above)"

echo ""
echo "--- Pod network connectivity ---"
$SSH "kubectl run nettest --image=busybox:1.36 --rm -it --restart=Never \
  -- ping -c3 10.96.0.1" 2>/dev/null || echo "Note: run this manually if TTY not available"

echo ""
echo "--- etcd cluster health ---"
$SSH "sudo bash -s" << 'REMOTE'
kubectl exec -n kube-system etcd-AOS01 -- etcdctl endpoint health \
  --cluster \
  --cacert /etc/kubernetes/pki/etcd/ca.crt \
  --cert   /etc/kubernetes/pki/etcd/peer.crt \
  --key    /etc/kubernetes/pki/etcd/peer.key
REMOTE

echo ""
echo "--- Swap status on all nodes ---"
for ip in 192.168.32.11 192.168.32.12 192.168.32.13; do
  echo -n "$ip swap: "
  ssh -i ~/.ssh/aos_k8s stanley@$ip "free -h | grep Swap"
done

echo ""
echo "=== Validation complete ==="
```

```bash
chmod +x ~/journal/k8s/scripts/validate-cluster.sh
```

---

### Task 7: Initialize the cluster on AOS01

**Step 1: Run init script**

```bash
~/journal/k8s/scripts/init-control-plane.sh
```

Expected: ends with `AOS01 control plane initialized`

**Step 2: Verify join-command.txt was saved**

```bash
cat ~/journal/k8s/join-command.txt
```

Expected: contains `kubeadm join 192.168.32.10:6443 --token ... --control-plane --certificate-key ...`

**Step 3: Check AOS01 node is Ready**

```bash
ssh -i ~/.ssh/aos_k8s stanley@192.168.32.11 "kubectl get nodes"
```

Expected: `AOS01   Ready   control-plane   ...`

---

### Task 8: Join AOS02 and AOS03

> **Important:** Certificate key expires 2 hours after `kubeadm init`. Complete both joins before that, or re-run `kubeadm init phase upload-certs --upload-certs` on AOS01 to get a fresh key.

**Step 1: Extract join command from saved file**

```bash
cat ~/journal/k8s/join-command.txt
# Copy the full "kubeadm join ... --control-plane --certificate-key ..." line
```

**Step 2: Join AOS02**

```bash
~/journal/k8s/scripts/join-control-plane.sh \
  192.168.32.12 \
  AOS02 \
  "kubeadm join 192.168.32.10:6443 --token <TOKEN> --discovery-token-ca-cert-hash sha256:<HASH> --control-plane --certificate-key <CERT_KEY>"
```

Expected: ends with `AOS02 joined cluster successfully`

**Step 3: Join AOS03**

```bash
~/journal/k8s/scripts/join-control-plane.sh \
  192.168.32.13 \
  AOS03 \
  "kubeadm join 192.168.32.10:6443 --token <TOKEN> --discovery-token-ca-cert-hash sha256:<HASH> --control-plane --certificate-key <CERT_KEY>"
```

Expected: ends with `AOS03 joined cluster successfully`

---

### Task 9: Validate the cluster

**Step 1: Run validation script**

```bash
~/journal/k8s/scripts/validate-cluster.sh
```

Expected:
- 3 nodes with status `Ready`
- All kube-system pods `Running`
- etcd: `3 members, 3 healthy`
- Swap present on all nodes

**Step 2: Verify kube-vip VIP is reachable**

```bash
curl -k https://192.168.32.10:6443/healthz
```

Expected: `ok`

**Step 3: Check all nodes are schedulable (no taint)**

```bash
ssh -i ~/.ssh/aos_k8s stanley@192.168.32.11 \
  "kubectl describe nodes | grep -E 'Name:|Taints:'"
```

Expected: `Taints: <none>` for all 3 nodes
