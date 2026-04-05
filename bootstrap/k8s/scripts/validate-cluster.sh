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
$SSH "kubectl exec -n kube-system etcd-aos01 -- etcdctl endpoint health \
  --cluster \
  --cacert /etc/kubernetes/pki/etcd/ca.crt \
  --cert   /etc/kubernetes/pki/etcd/peer.crt \
  --key    /etc/kubernetes/pki/etcd/peer.key"

echo ""
echo "--- Swap status on all nodes ---"
for ip in 192.168.32.11 192.168.32.12 192.168.32.13; do
  echo -n "$ip swap: "
  ssh -i ~/.ssh/aos_k8s stanley@$ip "free -h | grep Swap"
done

echo ""
echo "=== Validation complete ==="
