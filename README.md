# 🌐 Edge-Native LLM API Gateway: Heterogeneous Kubernetes Cluster

An enterprise-grade, highly available Local LLM API Gateway deployed on a heterogeneous Edge computing cluster.

This project demonstrates hardware-aware workload scheduling, GitOps deployment practices, Layer 7 load balancing, and local Generative AI infrastructure management. It leverages **Proxmox VE** for virtualization and **K3s** for container orchestration, dynamically routing inference workloads across nodes with vastly different CPU architectures.

## 🧠 The Architectural Challenge: The AVX2 Constraint

Modern Large Language Model runtimes (like `llama.cpp` or Ollama) require the **AVX2 CPU instruction set** to perform performant tensor math.

* **The Worker Nodes (Intel i5-8500T)** support AVX2 and are capable of running quantized LLMs efficiently.
* **The Master Node (Intel Xeon E5-2650L v2)** is a high-core, high-memory Ivy Bridge processor that **lacks AVX2**. Scheduling an LLM container on this node results in a fatal `SIGILL` (Illegal Instruction) crash.

**The Solution:** A heterogeneous Kubernetes cluster utilizing strict `nodeAffinity` rules. The Xeon node is leveraged for its high I/O and thread count to run the GitOps Controller, API Gateway, Redis Queue, and Control Plane, while the i5 nodes are dedicated exclusively to AVX2-accelerated tensor calculations.

---

## 🏗️ Enterprise System Architecture

### Two-Tier Queuing & L7 Load Balancing

LLM inference cannot be load-balanced like a standard stateless web app. Blind round-robin routing will overload active nodes and crash the cluster. This architecture uses enterprise patterns to solve concurrency:

1. **The External Queue:** LiteLLM backed by **Redis** holds incoming HTTP spikes and spoon-feeds them to the worker nodes to prevent OOM (Out of Memory) crashes.
2. **Layer 7 Routing:** **Nginx Ingress Controller** utilizes the `least_conn` algorithm to intelligently route prompts to the i5 node currently processing the fewest active tokens.
3. **The Internal Queue:** The C++ `llama-server` engine utilizes **Continuous Batching** to process multiple prompts in parallel within the same memory context.

### 🏠 Shared Homelab Coexistence & "Noisy Neighbor" Mitigation

Because this cluster shares physical hardware with other homelab services (e.g., Plex, Home Assistant, backups) on Proxmox, the system is architected to protect host stability and prevent resource starvation:

* **Strict CPU Alignment & Throttling Prevention:** To ensure the LLM worker containers do not lock up the entire i5 host CPU, worker pods are strictly limited to **4 vCPUs** (`resources.limits.cpu: "4"`). Crucially, the internal engine is configured to spawn exactly 4 threads (`-t 4`) to match this allocation. This prevents the Linux CFS scheduler from aggressively throttling the container and protects other services running on the same Proxmox host.
* **Proxmox VM Ballooning & Memory Guardrails:** The i5 worker VMs utilize strict, non-ballooning RAM allocations in Proxmox to lock down 16GB of their physical 32GB RAM for Kubernetes workloads. This guarantees the LLM's model weights (approx. 2-4GB) reside purely in physical RAM, completely avoiding the disk-swapping latency that would occur if other homelab containers triggered ballooning.
* **Namespace Isolation:** The entire GenAI stack is isolated within a dedicated `llm-gateway` Kubernetes namespace, configured with strict `ResourceQuotas` to ensure a memory leak or runtime runaway cannot destabilize the system control plane.

### The Software Stack

* **CI/CD Pipeline:** GitHub Actions (CI) + ArgoCD (GitOps CD)
* **Infrastructure as Code:** Terraform (Proxmox VM Provisioning) + Ansible (K3s Bootstrapping & OS Configuration)
* **Orchestration:** K3s (Lightweight Kubernetes)
* **L7 Ingress Controller:** Nginx Ingress
* **Model Runtime:** `llama.cpp` (Server mode natively compiled in C++)
* **API Gateway & Queuing:** LiteLLM + Redis
* **Observability:** Prometheus + Grafana

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
│   ├── ingress/
│   │   └── nginx-ingress.yaml    # L7 Routing config (least_conn annotation)
│   ├── gateway/
│   │   ├── litellm-config.yaml   # API Gateway routing & Redis queue configuration
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

* Proxmox VE installed with a configured Ubuntu/Debian Cloud-Init image template.
* SSH access configured between your local machine and the Proxmox hosts.
* Terraform and Ansible installed on your local control machine.

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

*From this point forward, the cluster state is strictly declarative. Any changes pushed to the `k8s/` directory in GitHub will be automatically detected and synchronized by ArgoCD.*

---

## 📊 Observability & Chaos Testing

This infrastructure is designed to be resilient to heavy AI workloads. Access the **Grafana Dashboard** via `http://<xeon-node-ip>:3000` to monitor:

* LLM Token Generation Speed (Tokens/sec)
* L7 Ingress Load Distribution
* Redis Queue Length & Cache Hit Ratio

### Simulated Enterprise Failure Scenarios

To demonstrate the resilience of this architecture, the following chaos tests have been validated:

1. **GitOps Drift Reconciliation:** Manually deleting an active `llama-server` pod or altering a ConfigMap directly via `kubectl` results in ArgoCD instantly detecting the drift and healing the cluster back to the Git-defined state in seconds.
2. **Stateful Load Spike (L7 Routing Test):** Sending a burst of 50 concurrent prompts correctly triggers the LiteLLM/Redis queue on the Xeon node. Nginx Ingress routes active prompts evenly based on `least_conn` rather than round-robin, ensuring an i5 node processing a massive context window is not overwhelmed with a second request until the internal continuous batching queue clears.
3. **Worker Node Failure:** Shutting down `k3s-worker-01` in Proxmox instantly triggers endpoint removal. The API Gateway routes 100% of traffic to `k3s-worker-02` with zero 502 Bad Gateway errors exposed to the user.
4. **Hardware Constraint Validation:** Temporarily removing the `nodeSelector` constraint results in the Kubernetes scheduler attempting to place a pod on the Xeon master, immediately resulting in a `CrashLoopBackOff (SIGILL)`, proving the necessity of the hardware-aware scheduling design.

---

I built this project to demonstrate end-to-end MLOps and DevOps capabilities, spanning from hypervisor provisioning to API gateway queuing and GitOps orchestration.