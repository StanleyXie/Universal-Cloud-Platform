# Kubernetes HA Cluster Design

**Date:** 2026-04-01
**Nodes:** 3x Intel NUC — AOS01, AOS02, AOS03
**Distribution:** kubeadm + Kubernetes v1.35

---

## Cluster Architecture

```
                    ┌─────────────────────────────┐
                    │  VIP: 192.168.32.10:6443     │  ← kube-vip (ARP mode)
                    └──────────────┬──────────────┘
               ┌───────────────────┼───────────────────┐
               ▼                   ▼                   ▼
       192.168.32.11        192.168.32.12        192.168.32.13
          AOS01                 AOS02                AOS03
    control-plane+worker  control-plane+worker  control-plane+worker
       etcd (stacked)        etcd (stacked)       etcd (stacked)
```

| Setting | Value |
|---|---|
| VIP | 192.168.32.10 |
| Cluster interface | enp3s0 (static IPs) |
| Pod CIDR | 10.10.0.0/16 |
| Service CIDR | 10.96.0.0/12 (kubeadm default) |
| CNI | Cilium (eBPF, kubeProxyReplacement=true) |
| Container runtime | containerd |
| kube-vip mode | ARP (layer 2) |

---

## Node Preparation (all 3 nodes) — `prep-node.sh`

1. **Keep swap enabled** (K8s 1.35, cgroup v2 required)
   - Retain existing 2GB `/swap.img`
   - kubelet `KubeletConfiguration`:
     ```yaml
     failSwapOn: false
     memorySwap:
       swapBehavior: LimitedSwap
     ```

2. **Repurpose storage LV**
   - Unmount `/var/lib/docker`
   - Remount as `/var/lib/containerd` in `/etc/fstab`

3. **Kernel modules** → `/etc/modules-load.d/k8s.conf`
   - `overlay`
   - `br_netfilter`

4. **sysctl** → `/etc/sysctl.d/k8s.conf`
   - `net.ipv4.ip_forward = 1`
   - `net.bridge.bridge-nf-call-iptables = 1`
   - `net.bridge.bridge-nf-call-ip6tables = 1`

5. **Install containerd** (Docker apt repo)
   - `SystemdCgroup = true`
   - Data root: `/var/lib/containerd`

6. **Install kubeadm + kubelet + kubectl v1.35**
   - `apt-mark hold` to pin versions

7. **`/etc/hosts` entries**
   ```
   192.168.32.10  k8s-api
   192.168.32.11  AOS01
   192.168.32.12  AOS02
   192.168.32.13  AOS03
   ```

---

## Cluster Bootstrap — `init-control-plane.sh` (AOS01 only)

1. Deploy kube-vip static pod at `/etc/kubernetes/manifests/kube-vip.yaml`
   - VIP: `192.168.32.10`, interface: `enp3s0`, mode: ARP
2. `kubeadm init --control-plane-endpoint 192.168.32.10:6443 --upload-certs --pod-network-cidr 10.10.0.0/16 --apiserver-advertise-address 192.168.32.11`
3. Configure `~/.kube/config` for stanley
4. Remove control-plane taint from AOS01
5. Install Cilium via Helm (`kubeProxyReplacement=true`, `k8sServiceHost=192.168.32.10`)
6. Save join command output

---

## Join Remaining Nodes — `join-control-plane.sh` (AOS02, AOS03)

1. Deploy kube-vip static pod (same manifest as AOS01)
2. `kubeadm join 192.168.32.10:6443 --control-plane --certificate-key <key> --apiserver-advertise-address <node-ip>`
3. Configure `~/.kube/config`
4. Remove control-plane taint

**Note:** Certificate key from `--upload-certs` expires in 2 hours.

---

## Validation — `validate-cluster.sh` (AOS01)

1. `kubectl get nodes -o wide` → 3 nodes Ready
2. `kubectl get pods -n kube-system` → all Running
3. Pod network connectivity test (busybox ping)
4. etcd cluster health check via `etcdctl`

---

## Scripts Summary

| Script | Runs on |
|---|---|
| `prep-node.sh` | All 3 nodes |
| `init-control-plane.sh` | AOS01 only |
| `join-control-plane.sh` | AOS02, AOS03 |
| `validate-cluster.sh` | AOS01 |

---

## Future Work

- Crossplane installation (separate plan)
