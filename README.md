# Edge-Native LLM API Gateway — Homelab Portfolio

A homelab portfolio project that implements a local LLM API gateway on a heterogeneous edge K3s cluster. It applies **enterprise-style** patterns—GitOps, service mesh, queueing, observability—on constrained Proxmox hardware. This is a **demo and learning stack**, not a production-grade or highly available commercial deployment.

This project demonstrates hardware-aware workload scheduling, GitOps deployment practices, advanced sidecarless service mesh networking, and local Generative AI infrastructure management. It leverages **Proxmox VE** for virtualization and **K3s** for container orchestration, dynamically routing inference workloads across nodes with vastly different CPU architectures.

## 🧠 The Architectural Challenge: The AVX2 Constraint

Modern Large Language Model runtimes (like `llama.cpp` or Ollama) require the **AVX2 CPU instruction set** to perform performant tensor math.

- **The Worker Nodes (Intel i5-8500T)** support AVX2 and are capable of running quantized LLMs efficiently.
- **The Master Node (Intel Xeon E5-2650L v2)** is a high-core, high-memory Ivy Bridge processor that **lacks AVX2**. Scheduling an LLM container on this node results in a fatal `SIGILL` (Illegal Instruction) crash.

**The Solution:** A heterogeneous Kubernetes cluster utilizing strict `nodeAffinity` rules. The Xeon node is leveraged for its high I/O and thread count to run the GitOps Controller, API Gateway, Redis Queue, and Control Plane, while the i5 nodes are dedicated exclusively to AVX2-accelerated tensor calculations.

---

## System Architecture

### Sidecarless Service Mesh (Istio Ambient Mode) & L7 Routing

Traditional service meshes inject Envoy proxy "sidecars" into every application pod, which would cannibalize the vital CPU threads and memory bandwidth required by the LLM on the edge worker nodes. To solve this, this architecture utilizes **Istio Ambient Mesh**:

1. **L4 Zero-Trust Overlay (`ztunnel`):** A highly efficient, Rust-based DaemonSet runs on every node, securing pod-to-pod traffic via mTLS without modifying the application pods.
2. **L7 Gateway API Routing (`Waypoint Proxy`):** To intelligently distribute HTTP traffic based on active token generation loads, a Layer 7 Waypoint proxy is deployed. By utilizing `nodeSelector`, the Waypoint proxy is forced to run on the **Xeon Master Node**, offloading all L7 routing compute away from the i5 inference nodes.
3. **The External Queue:** LiteLLM backed by **Redis** holds incoming HTTP spikes and spoon-feeds them through the mesh to the worker nodes to prevent OOM (Out of Memory) crashes.
4. **The Internal Queue:** The C++ `llama-server` engine utilizes **Continuous Batching** to process multiple prompts in parallel within the same memory context.

### LiteLLM + Istio: Why Both?

Both can load-balance HTTP traffic, but they operate at different layers and make decisions with different context. This project uses them as a **two-tier system**, not as duplicates.

|                     | **LiteLLM** (AI gateway)                                              | **Istio Ambient** (service mesh)                                              |
| :------------------ | :-------------------------------------------------------------------- | :---------------------------------------------------------------------------- |
| **Role**            | Application policy & queueing                                         | Network delivery & pod health                                                 |
| **Balances by**     | Model, tokens (RPM/TPM), API keys, spend caps                         | Pod health, connections, latency (`least_request`)                            |
| **Queue**           | Redis — holds bursts before they hit inference                        | Stateless — routes live connections to healthy endpoints                      |
| **On node failure** | Keeps calling the `llama-cpp` Service; does not track individual pods | Detects dead pods and re-routes to surviving i5 workers over mTLS (`ztunnel`) |

**Flow:** Client → LiteLLM (auth, rate limits, Redis queue) → `llama-cpp` Service → Istio Waypoint (pod-level routing) → llama.cpp on AVX2 workers.

LiteLLM points at a single Kubernetes Service endpoint; Istio handles which replica receives each request and fails over when a worker node dies.

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

- **CI/CD:** GitHub Actions (validate, test, publish `chat-ui` to private registry) + ArgoCD GitOps CD
- **Infrastructure as Code:** Terraform (Proxmox VM Provisioning) + Ansible (K3s Bootstrapping & OS Configuration)
- **Orchestration:** K3s (Lightweight Kubernetes)
- **Public Ingress Edge:** Cloudflare Tunnel (`cloudflared`)
- **Service Mesh:** Istio (Ambient Mode) via Kubernetes Gateway API
- **Model Runtime:** `llama.cpp` (Server mode natively compiled in C++)
- **API Gateway & Queuing:** LiteLLM + Redis
- **Chat UI:** Edge LLM Demo — FastAPI proxy + streaming web frontend (portfolio showcase)
- **Observability:** Prometheus + Grafana

---

## 🛑 Enterprise Readiness Matrix & Production Gaps

While this architecture leverages enterprise-grade deployment, container orchestration, and networking paradigms, certain compromises were explicitly accepted due to physical hardware constraints and resource limits.

| Component / Layer          | What's Implemented (Enterprise Ready ✅)                                                                                         | Left Out / Production Gaps (To Be Addressed ⚠️)                                                                                                            |
| :------------------------- | :------------------------------------------------------------------------------------------------------------------------------- | :--------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Orchestration & GitOps** | Full Infrastructure-as-Code pipeline (Terraform/Ansible) with strict GitOps declarative reconciliation via ArgoCD.               | **No Distributed Cluster Storage:** Uses ephemeral pod paths and local paths rather than an enterprise SAN or Ceph cluster.                                |
| **Networking & Routing**   | Layer 7 traffic load balancing via Istio Ambient Mesh Waypoint Proxies utilizing advanced `least_request` token routing metrics. | **Public Single Domain Ingress:** Lacks globally distributed Multi-Region DNS failover across multiple distinct data centers.                              |
| **API Edge Security**      | Outbound reverse Cloudflare Tunnels (Zero open firewall ports) coupled with FinOps token limits and L7 Rate Limiting.            | **No Enterprise Identity Provider:** Auth relies on custom Virtual Keys rather than integration with Okta, Active Directory, or an OAuth SSO.              |
| **Secrets Management**     | Declarative manifest files pushed automatically to cluster namespaces via the ArgoCD engine loops.                               | **Hardcoded Plaintext Secrets:** Secrets are committed directly to the Git manifests. A true enterprise needs ExternalSecrets with Vault/AWS SM.           |
| **AI Data Governance**     | Dynamic Redis caching layer prevents redundant internal network requests and caches responses locally.                           | **No LLM Conversation Logging:** No central logging database (like PostgreSQL/ClickHouse) to archive user prompt logs or run PII masking audits.           |
| **AI Observability**       | Prometheus scraping of inference throughput metrics (tokens/sec, context length, engine memory usage) and dashboarding.          | **No LLM Tracing / Evaluation:** Lacks runtime tracing (e.g., Langfuse or OpenInference) to visualize latency steps or track semantic hallucination rates. |

---

## 📂 Repository Structure

```text
├── .github/
│   └── workflows/
│       └── ci.yaml               # Validate, pytest, kustomize, push chat-ui to registry
├── terraform/
│   ├── main.tf                   # Provisions VMs on Proxmox via BPG Provider
│   ├── variables.tf              # VM resource sizing and network IP mapping
│   ├── outputs.tf                # Generates Ansible inventory output
│   └── terraform.tfvars.example  # Copy to terraform.tfvars (not committed)
├── scripts/
│   ├── cluster.sh                # deploy, argocd, status, pause/resume, port-forward, stop/start
│   ├── create-proxmox-template.sh
│   ├── fix-proxmox-template-cicustom.sh
│   ├── apply-cloudflared-secret.sh
│   ├── apply-registry-secret.sh
│   ├── deploy-chat-ui.sh         # Manual registry push (CI is the standard path)
│   ├── README.md                 # Proxmox template bootstrap
│   └── tests/                    # API security, load, and chaos tests (see tests/README.md)
├── ansible/
│   ├── README.md                 # Playbooks, lifecycle, troubleshooting
│   ├── inventory.ini             # From terraform output (regenerate after apply)
│   ├── group_vars/all.yml        # K3s, Istio, ArgoCD, model paths
│   ├── bootstrap-k3s.yml         # K3s server + agents
│   ├── label-nodes.yml           # AVX2 detection → cpu-feature labels
│   ├── deploy-llm-stack.yml      # Models, Gateway API, Istio, CNI fix, kubeconfig
│   ├── deploy-argocd.yml         # ArgoCD install + llm-gateway Application
│   ├── fix-istio-k3s-cni.yml     # K3s Istio CNI symlink (also run from deploy)
│   ├── start-k3s.yml / stop-k3s.yml
│   └── kubeconfig/               # Fetched k3s.yaml (gitignored contents)
├── k8s/
│   ├── kustomization.yaml        # Root bundle — ArgoCD sync path (or kubectl apply -k k8s)
│   ├── README.md                 # K8s deploy, Cloudflare, dev testing (detailed)
│   ├── base/                     # Namespace (Istio ambient) + ResourceQuota
│   ├── argocd/
│   │   └── application.yaml.example  # Reference; live app rendered by Ansible (registry not in Git)
│   ├── mesh/                     # Istio Waypoint + HTTPRoute
│   ├── gateway/                  # Redis, LiteLLM, cloudflared (+ secret templates)
│   ├── inference/                # llama-cpp (2 replicas on AVX2 workers)
│   ├── observability/            # Prometheus, Grafana, dashboard ConfigMap
│   ├── webui/                    # chat-ui Deployment
│   └── smoke-test/               # Single-worker validation (optional)
├── observability/                # Prometheus/Grafana config for Docker Compose
├── chat-ui/                      # FastAPI proxy + streaming frontend (see chat-ui/README.md)
├── models/                       # GGUF weights (gitignored — place locally for deploy)
├── docker-compose.yml            # Local dev stack (no cluster required)
├── litellm_config.yaml           # LiteLLM config for Docker Compose
├── .env.example                  # Copy to .env for docker compose / tunnel token
└── README.md

```

---

## ✅ Current implementation status

What is **built and running** on the homelab cluster today:

| Layer                     | Status | Notes                                                                                    |
| ------------------------- | ------ | ---------------------------------------------------------------------------------------- |
| Proxmox VMs (Terraform)   | ✅     | 1 master + 2 workers on `192.168.100.0/24`                                               |
| K3s cluster (Ansible)     | ✅     | Pin in `group_vars/all.yml` or latest stable; nodes labeled `cpu-feature=avx2\|base`     |
| LLM stack (ArgoCD GitOps) | ✅     | LiteLLM, Redis, llama-cpp ×2, chat-ui, Prometheus, Grafana — synced from `k8s/`        |
| Istio Ambient mesh        | ✅     | ztunnel + Waypoint L7 routing to inference pods                                          |
| Docker Compose local dev  | ✅     | Same stack for laptop testing without a cluster (copy `.env.example` → `.env`)           |
| Chat UI (Edge LLM Demo)   | ✅     | CI publishes to private registry; ArgoCD syncs tag from `k8s/kustomization.yaml` |
| Cloudflare Tunnel         | ⏳     | `cloudflared` Deployment in Git; apply token with `scripts/apply-cloudflared-secret.sh`  |
| ArgoCD GitOps             | ✅     | Standard deploy path via `./scripts/cluster.sh argocd`                                   |

### Cluster topology (default IPs)

| Node            | IP               | Role          | Key workloads                                       |
| --------------- | ---------------- | ------------- | --------------------------------------------------- |
| `k3s-master`    | `192.168.100.71` | control-plane | LiteLLM, Redis, chat-ui, Grafana, Prometheus, Istio Waypoint, cloudflared |
| `k3s-worker-01` | `192.168.100.72` | inference     | llama-cpp pod                                       |
| `k3s-worker-02` | `192.168.100.73` | inference     | llama-cpp pod                                       |

GGUF models are stored on workers at `/var/lib/llm-models/` (hostPath volume).

---

## 🚀 Deployment guide (end-to-end)

Full details for the Kubernetes layer: [`k8s/README.md`](k8s/README.md).

### Step 0: Proxmox template

See [`scripts/README.md`](scripts/README.md). Copy `terraform/terraform.tfvars.example` → `terraform.tfvars`.

### Step 1: Terraform — provision VMs

```bash
cd terraform
terraform init
terraform apply

# Refresh Ansible inventory
terraform output -raw ansible_inventory_ini > ../ansible/inventory.ini
```

### Step 2: Ansible — K3s, labels, and cluster prerequisites

```bash
cd ../ansible
ansible k3s_cluster -m ping
ansible-playbook bootstrap-k3s.yml
ansible-playbook label-nodes.yml
ansible-playbook deploy-llm-stack.yml   # models, Gateway API, Istio, CNI fix, kubeconfig
```

Or from the repo root: `./scripts/cluster.sh deploy` (requires `models/Llama-3.2-1B-Instruct-Q4_K_M.gguf` on your laptop, or set `llm_skip_model_copy: true` in `group_vars/all.yml` when models are already on workers).

See [`ansible/README.md`](ansible/README.md) for playbook tags, pause/resume, and troubleshooting.

### Step 3: ArgoCD — sync the LLM gateway app

```bash
./scripts/cluster.sh argocd
# or: cd ansible && ansible-playbook deploy-argocd.yml
```

Verify:

```bash
export KUBECONFIG=ansible/kubeconfig/k3s.yaml
kubectl get nodes --show-labels | grep cpu-feature
kubectl -n argocd get application llm-gateway
kubectl -n llm-gateway get pods
```

### Step 3b: Registry pull secret (Kubernetes, one-time)

The cluster pulls `chat-ui` from your private registry (host not stored in Git). Apply pull credentials once:

```bash
# In repo root .env: REGISTRY, REGISTRY_USERNAME, REGISTRY_PASSWORD
./scripts/apply-registry-secret.sh
```

Also copy `ansible/group_vars/secrets.yml.example` → `secrets.yml` and set `container_registry` before `./scripts/cluster.sh argocd`.

CI pushes images on merge to `master` and commits the new tag to `k8s/kustomization.yaml`; ArgoCD rolls out the update. Manual push: `./scripts/deploy-chat-ui.sh`.

### Step 4: Copy model to inference workers

Handled by `deploy-llm-stack.yml`. To copy manually:

```bash
# From repo root
for host in 192.168.100.72 192.168.100.73; do
  ssh ubuntu@$host 'sudo mkdir -p /var/lib/llm-models && sudo chown ubuntu:ubuntu /var/lib/llm-models'
  scp models/Llama-3.2-1B-Instruct-Q4_K_M.gguf ubuntu@$host:/var/lib/llm-models/
done
```

### Step 5: Istio Ambient on K3s

Handled by `deploy-llm-stack.yml`. Manual install:

```bash
# On the master (or with KUBECONFIG pointing at the cluster)
curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.24.2 sh -
cd istio-1.24.2
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
./bin/istioctl install -y --set profile=ambient --set values.global.platform=k3s

# Gateway API CRDs (if not already installed)
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml

# Symlink istio-cni into K3s plugin directory (all nodes)
cd ../../ansible && ansible-playbook fix-istio-k3s-cni.yml
```

### Step 6: Manual app deploy (optional)

ArgoCD is the standard app owner. For a one-off manual apply without ArgoCD:

```bash
# From repo root — edit secrets in k8s/gateway/ and k8s/observability/ first if needed
kubectl apply -k k8s
kubectl -n llm-gateway get pods -w
```

Cloudflare Tunnel: `cloudflared-deploy.yaml` is already in `kustomization.yaml`. Store the token in `.env` and run `./scripts/apply-cloudflared-secret.sh` (see [`k8s/README.md`](k8s/README.md#cloudflare-tunnel-public-ingress)). **Never commit the tunnel token.**

**ArgoCD caveats:** `selfHeal: true` reverts manual edits to synced manifests — change secrets in Git (`litellm-secret.yaml`, `grafana-secret.yaml`). Use `./scripts/cluster.sh pause` / `resume` / `stop` / `start` instead of ad-hoc scaling when ArgoCD is installed.

---

## 🔄 CI/CD pipeline

| Stage | Tool | What happens |
| ----- | ---- | ------------ |
| **CI** | GitHub Actions (`.github/workflows/ci.yaml`) | On every PR and push: `terraform fmt`/`validate`, `kubectl kustomize k8s`, `pytest` in `chat-ui/`, Docker build |
| **Publish** | GitHub Actions (merge to `master` only) | Push `<REGISTRY>/chat-ui:<sha>` + `:latest`, commit tag bump to `k8s/kustomization.yaml` |
| **CD** | ArgoCD | Syncs `k8s/` → cluster rollout |

### GitHub repository secrets

Configure in **Settings → Secrets and variables → Actions**:

| Name | Type | Purpose |
| ---- | ---- | ------- |
| `REGISTRY` | Variable | Private registry hostname (not committed to Git) |
| `REGISTRY_USERNAME` | Secret | Registry login |
| `REGISTRY_PASSWORD` | Secret | Registry token or password |

The publish job uses `[skip ci]` on the manifest commit to avoid an infinite loop.

### Cluster one-time setup

```bash
./scripts/apply-registry-secret.sh   # imagePullSecret (REGISTRY* in .env)
```

Registry host for ArgoCD lives in `ansible/group_vars/secrets.yml` (gitignored). If the registry uses a private CA, configure K3s `registries.yaml` on each node (see [K3s private registry docs](https://docs.k3s.io/installation/private-registry)).

---

## 🧪 Development & testing

Two supported paths:

| Environment        | When to use                                  | How to call the API                                                                          |
| ------------------ | -------------------------------------------- | -------------------------------------------------------------------------------------------- |
| **Docker Compose** | Fastest local iteration, no cluster          | `cp .env.example .env && docker compose up` → Chat UI at `http://localhost:8000` (API at `:4000`) |
| **K3s cluster**    | Production-like path with Istio + scheduling | `./scripts/cluster.sh port-forward` or `kubectl port-forward` (see below)                  |

Services in Kubernetes are **ClusterIP** — they are not exposed on the master node IP (`192.168.100.71:4000`) by default. Istio load-balances **between llama-cpp worker pods** inside the cluster; it is not the external API entry point. **LiteLLM** is what clients call.

### One-time: kubeconfig on your laptop

`deploy-llm-stack.yml` fetches kubeconfig to `ansible/kubeconfig/k3s.yaml`. Either use that path or copy from the master:

```bash
mkdir -p ~/.kube
scp ubuntu@192.168.100.71:/etc/rancher/k3s/k3s.yaml ~/.kube/config
sed -i '' 's/127.0.0.1/192.168.100.71/' ~/.kube/config   # macOS
kubectl get nodes
```

`./scripts/cluster.sh status` uses `ansible/kubeconfig/k3s.yaml` when present.

### Dev API test (port-forward)

```bash
# Terminal 1 — keep running (uses ansible/kubeconfig/k3s.yaml when present)
./scripts/cluster.sh port-forward litellm
# or: kubectl -n llm-gateway port-forward svc/litellm 4000:4000

# Terminal 2
curl -s http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer sk-1234" \
  -H "Content-Type: application/json" \
  -d '{"model":"llama3","messages":[{"role":"user","content":"Hello"}]}' | jq .
```

Grafana: `kubectl -n llm-gateway port-forward svc/grafana 3000:3000` → `http://localhost:3000` (default `admin` / `admin`).

### Edge LLM Demo (Chat UI)

**Docker Compose:** after `docker compose up`, open **http://localhost:8000**.

**Kubernetes:**

```bash
./scripts/cluster.sh port-forward chat-ui
# or: kubectl -n llm-gateway port-forward svc/chat-ui 8000:8000
```

The chat UI proxies to LiteLLM internally — the API key is not exposed to the browser. See [`chat-ui/README.md`](chat-ui/README.md) for build and test instructions.

> **Disclaimer:** The chat UI is for **demo and portfolio purposes only**. It runs **Llama 3.2 1B** on edge homelab nodes with a **limited context window** (resource constraints on AVX2 workers). The 1B model **may be inaccurate** at times — it is not intended for production workloads.

### Inspect running workloads

```bash
kubectl -n llm-gateway get pods -o wide          # which node each pod runs on
kubectl -n llm-gateway get svc                   # internal ClusterIP services
kubectl get pods -n istio-system                 # ztunnel, istio-cni, istiod
```

---

## 📊 Observability & chaos testing

### Local Docker Compose Stack

With `docker compose up`, Prometheus scrapes LiteLLM (`:4000/metrics`), llama.cpp (`:8080/metrics`), and Redis. Grafana is pre-provisioned with an **LLM API Gateway** dashboard:

| Service       | URL                     |
| :------------ | :---------------------- |
| Edge LLM Demo | `http://localhost:8000` |
| Grafana       | `http://localhost:3000` |
| Prometheus    | `http://localhost:9090` |
| LiteLLM       | `http://localhost:4000` |

Default Grafana login: `admin` / `admin` (override via `GRAFANA_ADMIN_PASSWORD` in `.env`).

Gateway rate limits are enforced in `litellm_config.yaml` (`rpm` / `tpm` with `enforce_model_rate_limits`). Exceeding limits returns `429 Too Many Requests` before traffic reaches the inference worker.

### Production Cluster

Access Grafana and Prometheus via port-forward from a machine with kubeconfig (same pattern as LiteLLM):

```bash
kubectl -n llm-gateway port-forward svc/grafana 3000:3000
kubectl -n llm-gateway port-forward svc/prometheus 9090:9090
```

Monitor token generation speed, Redis metrics, and LiteLLM gateway stats in the pre-provisioned **LLM API Gateway** Grafana dashboard.

### Simulated Enterprise Failure Scenarios

Automated scripts live in [`scripts/tests/`](scripts/tests/README.md). Run against a port-forwarded gateway:

```bash
# Terminal 1
kubectl -n llm-gateway port-forward svc/litellm 4000:4000

# Terminal 2
./scripts/tests/run-all.sh          # API security + load tests
./scripts/tests/run-all.sh --chaos  # + worker failover, pod recovery, AVX2
```

To demonstrate the resilience of this architecture, the following chaos tests have been validated:

1. **GitOps Drift Reconciliation:** Manually deleting an active `llama-server` pod or altering a ConfigMap directly via `kubectl` results in ArgoCD instantly detecting the drift and healing the cluster back to the Git-defined state in seconds.
2. **Stateful Load Spike (Ambient Routing Test):** Sending a burst of 50 concurrent prompts correctly triggers the LiteLLM/Redis queue on the Xeon node. The Istio Waypoint proxy routes active prompts using advanced load balancing strategies ensuring an i5 node processing a massive context window is not overwhelmed with a second request until the internal continuous batching queue clears.
3. **Endpoint Security & Perimeter Audit:** Requests issued without a valid Bearer token are dropped at the cluster perimeter by LiteLLM with an immediate `401 Unauthorized` response. Attempting to spam or flood the authenticated endpoint triggers LiteLLM rate limits (`rpm` / `tpm` in `litellm_config.yaml`), returning `429 Too Many Requests` before traffic reaches inference workers.
4. **Worker Node Failure:** Shutting down `k3s-worker-01` in Proxmox instantly triggers endpoint removal. The Istio mesh routes 100% of traffic to `k3s-worker-02` with zero 502 Bad Gateway errors exposed to the user.
5. **Hardware Constraint Validation:** Temporarily removing the `nodeSelector` constraint results in the Kubernetes scheduler attempting to place a pod on the Xeon master, immediately resulting in a `CrashLoopBackOff (SIGILL)`, proving the necessity of the hardware-aware scheduling design.

---

I built this project to demonstrate end-to-end MLOps and DevOps capabilities, spanning from hypervisor provisioning to API gateway queuing and GitOps orchestration.
