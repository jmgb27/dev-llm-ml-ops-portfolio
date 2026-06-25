# Kubernetes manifests — LLM API Gateway

Production manifests for the heterogeneous K3s cluster. Mirrors the local [docker-compose.yml](../docker-compose.yml) stack with hardware-aware scheduling and Istio Ambient mesh L7 routing.

## What runs where

| Pod                | Replicas | Node                        | Service port                        |
| ------------------ | -------- | --------------------------- | ----------------------------------- |
| `llama-cpp`        | 2        | `cpu-feature=avx2` workers  | `8080` (internal)                   |
| `litellm`          | 1        | master (`cpu-feature=base`) | `4000`                              |
| `redis`            | 1        | master                      | `6379`                              |
| `prometheus`       | 1        | master                      | `9090`                              |
| `grafana`          | 1        | master                      | `3000`                              |
| `waypoint` (Istio) | 1        | master                      | mesh L7 proxy                       |
| `cloudflared`      | 2        | master                      | _(disabled until tunnel token set)_ |

Default cluster IPs (from Terraform):

| Node            | IP               |
| --------------- | ---------------- |
| `k3s-master`    | `192.168.100.71` |
| `k3s-worker-01` | `192.168.100.72` |
| `k3s-worker-02` | `192.168.100.73` |

All Services are **ClusterIP** — not reachable on node IPs without port-forward, NodePort, or Cloudflare Tunnel.

## Layout

```text
k8s/
├── kustomization.yaml          # Root — synced by ArgoCD (or kubectl apply -k k8s for manual bootstrap)
├── base/                       # Namespace (Istio ambient label) + ResourceQuota
├── inference/                  # llama.cpp on AVX2 workers
├── gateway/                    # Redis, LiteLLM, Cloudflare Tunnel
├── mesh/                       # Istio Waypoint + HTTPRoute + DestinationRule
├── observability/              # Prometheus + Grafana
├── argocd/                     # GitOps Application (apply once, not in kustomization)
└── smoke-test/                 # Minimal single-worker test (optional)
```

## Traffic flow

```text
Client (port-forward or Cloudflare)
        │
        ▼
   LiteLLM :4000                 ← API gateway: auth, Redis queue, rate limits
   (master, ClusterIP)
        │
        ▼
   llama-cpp Service :8080
        │
        ▼
   Istio Waypoint                ← L7 load balance (LEAST_REQUEST)
   (master)
        │
   ┌────┴────┐
   ▼         ▼
worker-01  worker-02             ← llama.cpp inference (-t 4, --parallel 4)
```

**LiteLLM** is the external API. **Istio** load-balances inference traffic between worker pods — it does not replace port-forward for dev access.

## Prerequisites

1. **K3s cluster** — `bootstrap-k3s.yml` + `label-nodes.yml` ([ansible/README.md](../ansible/README.md)).
2. **GGUF model** on the Ansible control machine at `models/Llama-3.2-1B-Instruct-Q4_K_M.gguf` (deploy playbook copies to workers), or set `llm_skip_model_copy: true` if already on workers at `/var/lib/llm-models/`.

**Automated deploy** (models, Gateway API, Istio, CNI fix, then ArgoCD sync):

```bash
./scripts/cluster.sh deploy
./scripts/cluster.sh argocd
# or: cd ansible && ansible-playbook deploy-llm-stack.yml && ansible-playbook deploy-argocd.yml
```

Manual prerequisites below if not using the playbook:

3. **Gateway API CRDs** (required for Istio Waypoint):

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml
```

4. **Istio Ambient** — K3s requires `global.platform=k3s`:

```bash
curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.24.2 sh -
cd istio-1.24.2
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml   # or ~/.kube/config from laptop
./bin/istioctl install -y --set profile=ambient --set values.global.platform=k3s

cd ../ansible && ansible-playbook fix-istio-k3s-cni.yml
```

The `fix-istio-k3s-cni.yml` playbook symlinks `istio-cni` into `/var/lib/rancher/k3s/data/cni/` on every node. Without it, `ztunnel` pods fail with `failed to find plugin "istio-cni"`.

5. **Secrets** — edit before apply (defaults match `.env.example` for local dev):
    - `gateway/litellm-secret.yaml` — `master-key` (`sk-1234`)
    - `observability/grafana-secret.yaml` — admin credentials
    - `gateway/cloudflared-secret.yaml` — tunnel token _(only when enabling cloudflared)_

## Deploy

**Standard path:** ArgoCD syncs `k8s/` after `./scripts/cluster.sh argocd`. Validate locally:

```bash
kubectl kustomize k8s          # validate manifests
kubectl -n llm-gateway get pods -w   # llama-cpp ~2 min/pod to load model
```

Manual bootstrap (without ArgoCD) after prerequisites:

```bash
kubectl apply -k k8s
```

Cloudflare Tunnel is commented out in `kustomization.yaml` until a token is configured.

### ArgoCD (app owner)

```bash
./scripts/cluster.sh argocd
# or: cd ansible && ansible-playbook deploy-argocd.yml
```

ArgoCD installs from a pinned manifest (`argocd_version` in `ansible/group_vars/all.yml`) and applies `k8s/argocd/application.yaml`. The Application manifest is **not** part of `kustomization.yaml`.

**Requirements:** `repoURL` and `targetRevision` in `application.yaml` must match your pushed Git remote. The cluster must reach GitHub (or configure private-repo credentials in ArgoCD).

**Caveats:**

- `automated.selfHeal: true` reverts manual `kubectl edit` on synced resources — change secrets in Git (`litellm-secret.yaml`, `grafana-secret.yaml`) or move them out of the kustomization.
- First sync needs Gateway API CRDs and Istio already installed (`deploy-llm-stack.yml`).
- `./scripts/cluster.sh pause` disables auto-sync before scaling to 0; `resume` re-enables sync.

## Development testing

### Kubeconfig (one time, on your laptop)

```bash
mkdir -p ~/.kube
scp ubuntu@192.168.100.71:/etc/rancher/k3s/k3s.yaml ~/.kube/config
sed -i '' 's/127.0.0.1/192.168.100.71/' ~/.kube/config
kubectl get nodes
```

### Port-forward (standard dev workflow)

```bash
kubectl -n llm-gateway port-forward svc/litellm 4000:4000
```

```bash
curl -s http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer sk-1234" \
  -H "Content-Type: application/json" \
  -d '{"model":"llama3","messages":[{"role":"user","content":"Hello from K3s"}]}' | jq .
```

### Automated tests

```bash
./scripts/tests/run-all.sh          # auth, rate limits, load spike
./scripts/tests/run-all.sh --chaos    # worker failover, pod recovery, AVX2
```

Full catalog: [`scripts/tests/README.md`](../scripts/tests/README.md).

### Useful commands

```bash
kubectl -n llm-gateway get pods -o wide
kubectl -n llm-gateway get svc
kubectl -n llm-gateway logs deploy/litellm --tail=50
kubectl -n llm-gateway logs deploy/llama-cpp --tail=50
kubectl -n llm-gateway get gateway waypoint
kubectl get pods -n istio-system
```

## K3s / hardware notes

Learned from deploying on 4-vCPU worker VMs:

| Setting                      | Value                          | Reason                                                                                   |
| ---------------------------- | ------------------------------ | ---------------------------------------------------------------------------------------- |
| `llama-cpp` CPU **requests** | `3000m`                        | Workers have 4 allocatable CPUs; 4000m request blocks scheduling alongside Istio/Traefik |
| `llama-cpp` CPU **limits**   | `4`                            | Matches `-t 4` llama.cpp threads                                                         |
| Rolling update `maxSurge`    | `0`                            | Prevents a third pending pod during deploys on tight CPU                                 |
| Waypoint `nodeSelector`      | `k3s-master`                   | Keeps L7 proxy off inference nodes                                                       |
| Model storage                | hostPath `/var/lib/llm-models` | No shared cluster storage yet                                                            |

## Cloudflare Tunnel (production ingress)

When ready, set `tunnel-token` in `gateway/cloudflared-secret.yaml`, uncomment in `kustomization.yaml`, and re-apply. In Zero Trust, point the public hostname at `http://litellm.llm-gateway.svc.cluster.local:4000`.

## Smoke test

For validating a single worker before the full stack: [smoke-test/llama-cpp-worker.yaml](smoke-test/llama-cpp-worker.yaml).
