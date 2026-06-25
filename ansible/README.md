# Ansible — K3s cluster configuration

Configures the VMs provisioned by Terraform: base OS hardening, K3s install, worker join, hardware-aware node labels, and the K3s-specific Istio CNI fix.

Part of the full pipeline documented in the [root README](../README.md) and [k8s/README](../k8s/README.md).

## Prerequisites

- Terraform VMs running with SSH access (`ubuntu` user + your public key)
- `inventory.ini` populated (from `terraform output -raw ansible_inventory_ini`)
- Ansible on your control machine:

```bash
brew install ansible    # macOS
# or: pip install ansible
```

## Quick start

```bash
cd ansible

# 1. Verify SSH to all nodes
ansible k3s_cluster -m ping

# 2. Install K3s and join workers
ansible-playbook bootstrap-k3s.yml

# 3. Label nodes (avx2 on workers, base on master)
ansible-playbook label-nodes.yml

# 4. Cluster prerequisites (models, Gateway API, Istio, CNI fix)
ansible-playbook deploy-llm-stack.yml

# 5. Install ArgoCD and sync llm-gateway from Git
ansible-playbook deploy-argocd.yml
```

`deploy-llm-stack.yml` copies the GGUF model to workers, installs Gateway API + Istio Ambient, runs the K3s Istio CNI fix, and fetches kubeconfig to `ansible/kubeconfig/k3s.yaml`. **`deploy-argocd.yml`** installs ArgoCD and applies `k8s/argocd/application.yaml` so ArgoCD owns ongoing sync of `k8s/`.

From the repo root:

```bash
./scripts/cluster.sh deploy
./scripts/cluster.sh argocd
```

## Default cluster layout

| Node | IP | `cpu-feature` label |
|------|-----|---------------------|
| `k3s-master` | `192.168.100.71` | `base` |
| `k3s-worker-01` | `192.168.100.72` | `avx2` |
| `k3s-worker-02` | `192.168.100.73` | `avx2` |

IPs come from `terraform/terraform.tfvars` — regenerate inventory after changes.

## Verify the cluster

```bash
ssh ubuntu@192.168.100.71
sudo kubectl get nodes -o wide
sudo kubectl get nodes --show-labels | grep cpu-feature
```

### Kubeconfig on your laptop

```bash
mkdir -p ~/.kube
scp ubuntu@192.168.100.71:/etc/rancher/k3s/k3s.yaml ~/.kube/config
sed -i '' 's/127.0.0.1/192.168.100.71/' ~/.kube/config
kubectl get nodes
```

## Playbooks

| Playbook | When to run | Purpose |
|----------|-------------|---------|
| `bootstrap-k3s.yml` | After Terraform apply | OS prep, qemu-guest-agent, K3s server + agents |
| `label-nodes.yml` | After bootstrap | `lscpu` AVX2 detection → `cpu-feature` Kubernetes labels |
| `deploy-llm-stack.yml` | After label-nodes | Models → Gateway API → Istio → CNI fix → kubeconfig |
| `deploy-argocd.yml` | After deploy-llm-stack | Install ArgoCD → apply Application → wait for llm-gateway sync |
| `fix-istio-k3s-cni.yml` | Included by deploy (or manual after Istio) | Symlink `istio-cni` into K3s CNI path; restart ztunnel |
| `stop-k3s.yml` | Shut down cluster | Stop `k3s-agent` on workers, then `k3s` on master |
| `start-k3s.yml` | Boot cluster | Start master, wait for API, start workers |

### Cluster lifecycle

```bash
./scripts/cluster.sh deploy    # prerequisites only
./scripts/cluster.sh argocd    # GitOps app sync
./scripts/cluster.sh pause     # disable ArgoCD auto-sync, scale to 0
./scripts/cluster.sh resume    # re-enable auto-sync (ArgoCD restores from Git)
./scripts/cluster.sh stop      # ansible-playbook stop-k3s.yml
./scripts/cluster.sh start     # ansible-playbook start-k3s.yml
./scripts/cluster.sh status
```

**Pause** disables ArgoCD `automated` sync before scaling to 0 so `selfHeal` does not fight manual scale-down. **Resume** re-enables sync instead of `kubectl apply -k`.

### Istio on K3s

`deploy-llm-stack.yml` installs Istio with `istioctl install --wait=false` (ztunnel cannot start until the K3s CNI symlink exists), then runs the CNI fix and waits for `ztunnel`. If a prior run failed on ztunnel, re-run:

```bash
ansible-playbook deploy-llm-stack.yml --tags istio
```

```bash
ansible-playbook fix-istio-k3s-cni.yml
```

Without the CNI symlink, new pods (including `ztunnel`) fail with `failed to find plugin "istio-cni" in path [/var/lib/rancher/k3s/data/cni]`.

### Deploy tags

```bash
ansible-playbook deploy-llm-stack.yml --tags models      # only copy GGUF to workers
ansible-playbook deploy-llm-stack.yml --tags istio       # Gateway API + Istio + CNI fix
ansible-playbook deploy-llm-stack.yml --tags kubeconfig  # fetch kubeconfig to ansible/kubeconfig/
ansible-playbook deploy-argocd.yml                       # full ArgoCD install + app sync
```

Set `llm_skip_model_copy: true` in `group_vars/all.yml` when models are already on workers.

## ArgoCD GitOps

ArgoCD is the **app owner** for everything under `k8s/` (kustomization). Ansible handles cluster prerequisites ArgoCD cannot install (models, Gateway API CRDs, Istio, K3s CNI fix).

1. Run `deploy-llm-stack.yml` first — `HTTPRoute`/`Gateway` need Gateway API + Istio present before the first sync.
2. Run `deploy-argocd.yml` (or `./scripts/cluster.sh argocd`).
3. Ensure `k8s/argocd/application.yaml` `repoURL` / `targetRevision` match your pushed Git remote (default: `master` on `jmgb27/devops_llmops_mlops_portfolio`). Private repos need ArgoCD repo credentials.

**Caveats:**

- `selfHeal: true` reverts manual edits to synced resources (including `litellm-secret.yaml` / `grafana-secret.yaml`) — change those in Git or move secrets out of the kustomization.
- `k8s/argocd/application.yaml` is **not** in `k8s/kustomization.yaml` so ArgoCD does not manage itself.

Manual bootstrap (without ArgoCD) is still possible with `kubectl apply -k k8s` after prerequisites, but pause/resume in `cluster.sh` expects ArgoCD.

## Configuration

`group_vars/all.yml`:

```yaml
k3s_version: ""   # pin e.g. v1.32.2+k3s1, or empty for latest

# deploy-llm-stack.yml
llm_model_filename: Llama-3.2-1B-Instruct-Q4_K_M.gguf
llm_skip_model_copy: false   # true when GGUF already on workers
istio_version: "1.24.2"

# deploy-argocd.yml
argocd_version: "v3.3.5"
```

## Inventory

Regenerate after Terraform changes:

```bash
cd ../terraform
terraform output -raw ansible_inventory_ini > ../ansible/inventory.ini
```

## Troubleshooting

### `REMOTE HOST IDENTIFICATION HAS CHANGED` after Terraform rebuild

Reprovisioned VMs get new SSH host keys. Remove stale entries, then re-run the playbook:

```bash
ssh-keygen -R 192.168.100.71
ssh-keygen -R 192.168.100.72
ssh-keygen -R 192.168.100.73
cd ansible && ansible k3s_cluster -m ping
```

Run playbooks from `ansible/` (loads `ansible.cfg`) or use `./scripts/cluster.sh deploy` from the repo root.

### `x509: certificate signed by unknown authority` (kubectl)

Your laptop kubeconfig is from an **old cluster** (e.g. after `terraform apply` rebuild). Refresh it:

```bash
cd ansible && ansible-playbook deploy-llm-stack.yml --tags kubeconfig
export KUBECONFIG="$(pwd)/kubeconfig/k3s.yaml"
kubectl get nodes
```
