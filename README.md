# Edge-Native LLM API Gateway — Homelab Portfolio

A homelab portfolio project that implements a local LLM API gateway on a heterogeneous edge K3s cluster. It applies **enterprise-style** patterns—GitOps, service mesh, queueing, observability—on constrained Proxmox hardware. This is a **demo and learning stack**, not a production-grade or highly available commercial deployment.

The stack spans **Proxmox → Terraform → Ansible → K3s → ArgoCD**, with hardware-aware scheduling that routes inference across nodes with different CPU capabilities.

---

## 🧠 The Architectural Challenge: The AVX2 Constraint

Modern LLM runtimes (`llama.cpp`, Ollama) require **AVX2** for performant tensor math.

- **Worker nodes (Intel i5-8500T)** — AVX2-capable; run quantized LLMs.
- **Master node (Intel Xeon E5-2650L v2)** — high core count but **no AVX2**; scheduling an LLM here causes `SIGILL`.

**Solution:** strict `nodeAffinity` — the Xeon runs the control plane, API gateway, Redis, and GitOps; i5 workers run inference only.

---

## System Architecture

### Sidecarless Service Mesh (Istio Ambient) & L7 Routing

Sidecar meshes would consume CPU and memory on inference nodes. This stack uses **Istio Ambient**:

1. **`ztunnel`** — L4 mTLS on every node without sidecar injection.
2. **Waypoint proxy** — L7 routing via Gateway API; pinned to the **Xeon master** so i5 workers stay free for inference.
3. **External queue** — LiteLLM + **Redis** absorbs HTTP spikes before they hit workers.
4. **Internal queue** — `llama-server` continuous batching within each pod.

### LiteLLM + Istio: Why Both?

|                     | **LiteLLM** (AI gateway)                                              | **Istio Ambient** (service mesh)                                              |
| :------------------ | :-------------------------------------------------------------------- | :---------------------------------------------------------------------------- |
| **Role**            | Application policy & queueing                                         | Network delivery & pod health                                                 |
| **Balances by**     | Model, tokens (RPM/TPM), API keys, spend caps                         | Pod health, connections, latency (`least_request`)                            |
| **Queue**           | Redis — holds bursts before they hit inference                        | Stateless — routes live connections to healthy endpoints                      |
| **On node failure** | Keeps calling the `llama-cpp` Service; does not track individual pods | Detects dead pods and re-routes to surviving i5 workers over mTLS (`ztunnel`) |

**Flow:** Client → LiteLLM (auth, rate limits, Redis queue) → `llama-cpp` Service → Istio Waypoint → llama.cpp on AVX2 workers.

### Security & Edge Ingress

- **Cloudflare Tunnel** — outbound `cloudflared`; no open inbound ports on the home router.
- **LiteLLM auth** — anonymous access disabled; Bearer tokens required; Virtual Keys for scoped budgets.
- **Rate limits** — `rpm` / `tpm` in `litellm_config.yaml` return `429` before traffic reaches inference.

### Homelab Coexistence

The cluster shares Proxmox with other services (Plex, Home Assistant, etc.):

- Worker pods capped at **4 vCPUs** with `-t 4` threads to avoid CFS throttling.
- Fixed RAM on worker VMs (no ballooning) so model weights stay in physical memory.
- Dedicated `llm-gateway` namespace with **ResourceQuotas**.

### Software Stack

- **IaC:** Terraform (Proxmox VMs) + Ansible (K3s bootstrap)
- **GitOps / CI:** ArgoCD + GitHub Actions
- **Mesh:** Istio Ambient + Gateway API
- **Inference:** `llama.cpp` on AVX2 workers
- **Gateway:** LiteLLM + Redis
- **Ingress:** Cloudflare Tunnel
- **UI:** Edge LLM Demo ([`chat-ui/`](chat-ui/README.md))
- **Observability:** Prometheus + Grafana

---

## Known Limitations

Enterprise patterns are applied where they fit; these gaps are intentional for a single-site homelab:

- **No shared cluster storage** — models on hostPath; no Ceph/NFS.
- **Secrets in Git** — no Vault / ExternalSecrets integration yet.
- **No SSO** — LiteLLM Virtual Keys instead of Okta/AD.
- **Single region** — one Cloudflare hostname, no multi-site failover.
- **No LLM tracing** — Prometheus/Grafana only; no Langfuse-style prompt logging or eval pipeline.

---

## Quick Start

### Local (no cluster)

```bash
cp .env.example .env
docker compose up
```

Open **http://localhost:8000** (Chat UI). API at `:4000`, Grafana at `:3000`.

### Cluster (Proxmox homelab)

One-time: Proxmox template ([`scripts/README.md`](scripts/README.md)), then `terraform apply`, then:

```bash
./scripts/cluster.sh deploy    # K3s, Istio, models, kubeconfig
./scripts/cluster.sh argocd    # ArgoCD + llm-gateway sync
```

Requires `models/Llama-3.2-1B-Instruct-Q4_K_M.gguf` locally (or `llm_skip_model_copy: true` in `ansible/group_vars/all.yml`).

One-time cluster secrets (from repo root `.env`):

```bash
./scripts/apply-registry-secret.sh      # REGISTRY, REGISTRY_USERNAME, REGISTRY_PASSWORD
./scripts/apply-cloudflared-secret.sh   # CLOUDFLARE_TUNNEL_TOKEN (optional public ingress)
```

Also copy `ansible/group_vars/secrets.yml.example` → `secrets.yml` before `./scripts/cluster.sh argocd`.

| Environment        | When to use                         | Access |
| ------------------ | ----------------------------------- | ------ |
| **Docker Compose** | Fast iteration, no cluster          | `http://localhost:8000` |
| **K3s cluster**    | Production-like Istio + scheduling  | `./scripts/cluster.sh port-forward` — see [`k8s/README.md`](k8s/README.md) |

---

## Documentation Map

```text
terraform/     Proxmox VM provisioning (copy terraform.tfvars.example → terraform.tfvars)
ansible/       K3s bootstrap, node labels, Istio, ArgoCD install
k8s/           Manifests synced by ArgoCD — deploy, dev testing, Cloudflare
chat-ui/       Edge LLM Demo — build, test, disclaimer
scripts/       cluster.sh, secrets helpers, Proxmox template, chaos tests
.github/       CI validate + publish chat-ui to private registry
```

| Topic | Where to read |
| ----- | ------------- |
| Full cluster deploy & playbooks | [`ansible/README.md`](ansible/README.md) |
| K8s manifests, port-forward, tunnel | [`k8s/README.md`](k8s/README.md) |
| Chat UI development | [`chat-ui/README.md`](chat-ui/README.md) |
| Proxmox golden image | [`scripts/README.md`](scripts/README.md) |
| API security, load & chaos tests | [`scripts/tests/README.md`](scripts/tests/README.md) |

Resilience scenarios (GitOps drift healing, worker failover, AVX2 scheduling proof) are automated in [`scripts/tests/`](scripts/tests/README.md).

---

## CI/CD

| Stage | Tool | What happens |
| ----- | ---- | ------------ |
| **CI** | GitHub Actions | `terraform fmt`/`validate`, `kubectl kustomize k8s`, `pytest`, Docker build |
| **Publish** | GitHub Actions (merge to `master`) | Push `chat-ui:<sha>` to private registry; bump tag in `k8s/kustomization.yaml` |
| **CD** | ArgoCD | Syncs `k8s/` → cluster rollout |

GitHub Actions needs `REGISTRY` (variable), `REGISTRY_USERNAME`, and `REGISTRY_PASSWORD` (secrets). The publish job uses `[skip ci]` on the manifest commit to avoid loops.

---

I built this project to demonstrate end-to-end MLOps and DevOps capabilities, spanning from hypervisor provisioning to API gateway queuing and GitOps orchestration.
