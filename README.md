# Universal Cloud Platform

[![Architecture Showcase](https://img.shields.io/badge/Architecture-Showcase-blueviolet?style=for-the-badge)](https://stanleyxie.github.io/Universal-Cloud-Platform/)

A self-hosted GitOps platform for managing homelab infrastructure and cloud resources declaratively. This project implements a full-stack GitOps workflow: infrastructure as code, policy as code, multi-cloud provisioning, and automated security scanning.

## 🚀 Architecture Showcase

The live architecture diagram and system overview can be found here:
**[https://stanleyxie.github.io/Universal-Cloud-Platform/](https://stanleyxie.github.io/Universal-Cloud-Platform/)**

For more details of architecture, please refer to [Architecture Overview](docs/plans/2026-04-05-architecture-overview.md).

---

## 🏗️ System Overview

- **Cluster**: AOS Homelab (3-node HA)
- **Kubernetes**: v1.35.3
- **GitOps**: ArgoCD (App-of-Apps pattern, Sync Waves 0–3)
- **Networking**: Cilium v1.19.2 (eBPF, L2 ARP, Gateway API)
- **Policy**: Kyverno 3.7.1 (Pod Security Standards, Custom Policies)
- **Cloud Management**: Crossplane (AWS, GCP, Azure, Terraform)
- **Storage**: local-path-provisioner

## 🛠️ Tech Stack & Tools

| Layer | Component | Description |
|-------|-----------|-------------|
| **CI/CD** | GitHub Actions | Gitleaks, yamllint, kubeconform, ShellCheck, ArgoCD Diff |
| **GitOps** | ArgoCD | Automated reconciliation and sync waves |
| **Networking**| Cilium | eBPF-based CNI with Gateway API support |
| **Security** | Kyverno | Admission control and policy enforcement |
| **IaC** | Crossplane | Multi-cloud resource management via Kubernetes |
| **Search** | SearXNG | Self-hosted privacy-focused search engine |

## 📂 Repository Structure

- `apps/` — ArgoCD App-of-Apps manifests
- `docs/` — Architecture documentation and project plans
- `gateway-api/` — Gateway CRDs, L2 pools, and HTTPRoutes
- `kyverno-policies/` — Pod Security Standards and custom admission policies
- `crossplane-providers/` — Cloud provider configurations
- `bootstrap/` — Day-0 cluster initialization scripts
- `scripts/` — Operational helper scripts

## 🚦 Deployment Pipeline

This repository follows a "Wave-based" deployment strategy:
- **Wave 0**: Bootstrap (ArgoCD, Cilium, Storage)
- **Wave 1**: Policy & Networking (Kyverno, Gateway API)
- **Wave 2**: Cloud Management (Crossplane)
- **Wave 3**: Services (SearXNG, Observability)

