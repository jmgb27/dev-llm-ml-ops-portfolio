# 🌐 Edge-Native LLM API Gateway: Heterogeneous Kubernetes Cluster

An enterprise-grade, highly available Local LLM API Gateway deployed on a heterogeneous Edge computing cluster.

This project demonstrates hardware-aware workload scheduling, GitOps deployment practices, advanced sidecarless service mesh networking, and local Generative AI infrastructure management. It leverages **Proxmox VE** for virtualization and **K3s** for container orchestration, dynamically routing inference workloads across nodes with vastly different CPU architectures.

## 🧠 The Architectural Challenge: The AVX2 Constraint

Modern Large Language Model runtimes (like `llama.cpp` or Ollama) require the **AVX2 CPU instruction set** to perform performant tensor math.

- **The Worker Nodes (Intel i5-8500T)** support AVX2 and are capable of running quantized LLMs efficiently.
- **The Master Node (Intel Xeon E5-2650L v2)** is a high-core, high-memory Ivy Bridge processor that **lacks AVX2**. Scheduling an LLM container on this node results in a fatal `SIGILL` (Illegal Instruction) crash.

**The Solution:** A heterogeneous Kubernetes cluster utilizing strict `nodeAffinity` rules. The Xeon node is leveraged for its high I/O and thread count to run the GitOps Controller, API Gateway, Redis Queue, and Control Plane, while the i5 nodes are dedicated exclusively to AVX2-accelerated tensor calculations.

---

## 🏗️ Enterprise System Architecture

### Sidecarless Service Mesh (Istio Ambient Mode) & L7 Routing

Traditional service meshes inject Envoy proxy "sidecars" into every application pod, which would cannibalize the vital CPU threads and memory bandwidth required by the LLM on the edge worker nodes. To solve this, this architecture utilizes **Istio Ambient Mesh**:

1. **L4 Zero-Trust Overlay (`ztunnel`):** A highly efficient, Rust-based DaemonSet runs on every node, securing pod-to-pod traffic via mTLS without modifying the application pods.
2. **L7 Gateway API Routing (`Waypoint Proxy`):** To intelligently distribute HTTP traffic based on active token generation loads, a Layer 7 Waypoint proxy is deployed. By utilizing `nodeSelector`, the Waypoint proxy is forced to run on the **Xeon Master Node**, offloading all L7 routing compute away from the i5 inference nodes.
3. **The External Queue:** LiteLLM backed by **Redis** holds incoming HTTP spikes and spoon-feeds them through the mesh to the worker nodes to prevent OOM (Out of Memory) crashes.
4. **The Internal Queue:** The C++ `llama-server` engine utilizes **Continuous Batching** to process multiple prompts in parallel within the same memory context.

### 🔐 Multi-Layer Security & Cloudflare Tunnel Edge Integration

Exposing local LLM compute nodes requires rigorous data plane and access controls to mitigate compute-hijacking and denial-of-service threats:

- **Zero-Port Public Ingress (Cloudflare Tunnel):** Public traffic reaches the cluster via an outbound `cloudflared` connection established from within the cluster. This obfuscates home network routing paths, completely eliminates the need for open inbound router ports, and grants native edge protection.
- **FinOps-Enforced Key Management (LiteLLM Authentication):** Anonymous access is systematically disabled via a cluster-wide LiteLLM `master_key` definition. All incoming inferencing traffic must present a valid Bearer token. Downstream tokens are issued as scoped Virtual Keys bound to specific user contexts, matching strict daily budget and usage rate caps to limit API spending.
- **Edge Ingress Protection:** Rate-limiting policies configured directly on the central gateway act as a buffer against client script failures, ensuring malicious request streams drop with immediate `429 Too Many Requests` responses before ever reaching internal resources.

### 🏠 Shared Homelab Coexistence & "Noisy Neighbor" Mitigation

Because this cluster shares physical hardware with other homelab services (e.g., Plex, Home Assistant, backups) on Proxmox, the system is architected to protect host stability and prevent resource starvation:

- **Strict CPU Alignment & Throttling Prevention:** To ensure the LLM worker containers do not lock up the entire i5 host CPU, worker pods are strictly limited to **4 vCPUs** (`resources.limits.cpu: "4"`). Crucially, the internal engine is configured to spawn exactly 4 threads (`-t 4`) to match this allocation. This prevents the Linux CFS scheduler from aggressively throttling the container.
- **Proxmox VM Ballooning & Memory Guardrails:** The i5 worker VMs utilize strict, non-ballooning RAM allocations in Proxmox to lock down 16GB of their physical 32GB RAM for Kubernetes workloads. This guarantees the LLM's model weights (approx. 2-4GB) reside purely in physical RAM, completely avoiding disk-swapping latency.
- **Namespace Isolation:** The entire GenAI stack is isolated within a dedicated `llm-gateway` Kubernetes namespace, configured with strict `ResourceQuotas` to ensure a memory leak or runtime runaway cannot destabilize the system control plane.

### The Software Stack

- **CI/CD Pipeline:** GitHub Actions (CI) + ArgoCD (GitOps CD)
- **Infrastructure as Code:** Terraform (Proxmox VM Provisioning) + Ansible (K3s Bootstrapping & OS Configuration)
- **Orchestration:** K3s (Lightweight Kubernetes)
- **Public Ingress Edge:** Cloudflare Tunnel (`cloudflared`)
- **Service Mesh:** Istio (Ambient Mode) via Kubernetes Gateway API
- **Model Runtime:** `llama.cpp` (Server mode natively compiled in C++)
- **API Gateway & Queuing:** LiteLLM + Redis
- **Observability:** Prometheus + Grafana

---

## 📂 Repository Structure

```text
├── .github/
│   └── workflows/
│       └── ci.yaml               # CI: Builds inference/gateway Docker images & updates manifests
├── terraform/
│   ├── main.tf                   # Provisions K3s VMs on Proxmox via BPG Provider
│   ├── variables.tf              # VM resource sizing and network IP mapping
│   └── outputs.tf                # Generates dynamic Ansible inventory
├── ansible/
│   ├── inventory.ini             # Dynamic IPs mapped from Terraform outputs
│   ├── bootstrap-k3s.yml         # Installs K3s and configures cluster
│   └── label-nodes.yml           # Detects CPU features & applies K8s labels
├── k8s/
│   ├── argocd/
│   │   └── application.yaml      # CD: ArgoCD "App-of-Apps" GitOps root configuration
│   ├── mesh/
│   │   ├── waypoint.yaml         # Istio Waypoint Proxy (Gateway API) restricted to Xeon node
│   │   └── httproute.yaml        # L7 routing rules for LLM traffic
│   ├── gateway/
│   │   ├── cloudflared-deploy.yaml # Cloudflare Tunnel Daemon high-availability deployment
│   │   ├── litellm-config.yaml   # API Gateway routing, Token Authentication, & Redis queue configuration
│   │   ├── litellm-deploy.yaml   # LiteLLM deployment (tied to Xeon node)
│   │   └── redis-deploy.yaml     # Redis Semantic Cache & Stateful Queue
│   ├── inference/
│   │   ├── llama-cpp-deploy.yaml # Inference pods (Continuous batching args, tied to i5 nodes)
│   │   └── service.yaml          # Internal ClusterIP for inference pods
│   └── observability/
│       ├── prometheus.yaml       # Scrapes /metrics from LiteLLM and nodes
│       └── grafana.yaml          # Dashboards for token/sec, queue length, and latency
└── README.md
```
---

## 🚀 GitOps Deployment Guide

### Prerequisites

- Proxmox VE installed with a configured Ubuntu/Debian Cloud-Init image template.
- An active Cloudflare Account with an authorized domain attached to Cloudflare Zero Trust.
- SSH access configured between your local machine and the Proxmox hosts.
- Terraform and Ansible installed on your local control machine.

### Step 1: Infrastructure Provisioning & Auto-Labeling

1. Use Terraform to provision your VMs on the Proxmox VE hypervisor securely:

```bash
cd terraform
terraform init
terraform apply -auto-approve

```

2. Run the Ansible bootstrap playbook. This installs K3s, joins the workers to the master, and runs a hardware detection script (`lscpu | grep avx2`) to dynamically label the Kubernetes nodes:

```bash
cd ../ansible
ansible-playbook -i inventory.ini bootstrap-k3s.yml

```

Verify the hardware labels were applied correctly via `kubectl`:

```bash
kubectl get nodes --show-labels | grep cpu-feature
# Expected Output:
# k3s-worker-01 ... cpu-feature=avx2
# k3s-worker-02 ... cpu-feature=avx2
# k3s-master    ... cpu-feature=base

```

### Step 2: Bootstrap ArgoCD (The GitOps Way)

Unlike traditional pipelines, we do not use `kubectl apply` for application manifests from the CI server. Instead, we install ArgoCD on the Xeon master node and point it to this repository.

```bash
# Install ArgoCD into the cluster
kubectl create namespace argocd
kubectl apply -n argocd -f [https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml](https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml)

# Apply the Root GitOps App
kubectl apply -f k8s/argocd/application.yaml

```

_From this point forward, the cluster state is strictly declarative. Any changes pushed to the `k8s/` directory in GitHub will be automatically detected and synchronized by ArgoCD, including the Istio Ambient mesh components and the Cloudflare Tunnel configuration._

---

## 📊 Observability & Chaos Testing

This infrastructure is designed to be resilient to heavy AI workloads. Access the **Grafana Dashboard** via `http://<xeon-node-ip>:3000` to monitor:

- LLM Token Generation Speed (Tokens/sec)
- Istio Waypoint Proxy Request Routing & Latency
- Redis Queue Length & Cache Hit Ratio

### Simulated Enterprise Failure Scenarios

To demonstrate the resilience of this architecture, the following chaos tests have been validated:

1. **GitOps Drift Reconciliation:** Manually deleting an active `llama-server` pod or altering a ConfigMap directly via `kubectl` results in ArgoCD instantly detecting the drift and healing the cluster back to the Git-defined state in seconds.
2. **Stateful Load Spike (Ambient Routing Test):** Sending a burst of 50 concurrent prompts correctly triggers the LiteLLM/Redis queue on the Xeon node. The Istio Waypoint proxy routes active prompts using advanced load balancing strategies ensuring an i5 node processing a massive context window is not overwhelmed with a second request until the internal continuous batching queue clears.
3. **Endpoint Security & Perimeter Audit:** Requests issued without a valid Bearer token are dropped at the cluster perimeter by LiteLLM with an immediate `401 Unauthorized` response. Attempting to spam or flood the authenticated endpoint triggers Nginx rate limits, causing upstream packets to be dropped with an immediate `429 Too Many Requests` error before reaching backend compute.
4. **Worker Node Failure:** Shutting down `k3s-worker-01` in Proxmox instantly triggers endpoint removal. The Istio mesh routes 100% of traffic to `k3s-worker-02` with zero 502 Bad Gateway errors exposed to the user.
5. **Hardware Constraint Validation:** Temporarily removing the `nodeSelector` constraint results in the Kubernetes scheduler attempting to place a pod on the Xeon master, immediately resulting in a `CrashLoopBackOff (SIGILL)`, proving the necessity of the hardware-aware scheduling design.

---

I built this project to demonstrate end-to-end MLOps and DevOps capabilities, spanning from hypervisor provisioning to API gateway queuing and GitOps orchestration. If you are interested in DevOps, Site Reliability, or MLOps Engineering roles, I'd love to chat!
