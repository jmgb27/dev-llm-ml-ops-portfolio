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

# 4. Deploy LiteLLM stack (models, Istio, k8s manifests)
ansible-playbook deploy-llm-stack.yml
```

`deploy-llm-stack.yml` copies the GGUF model to workers, installs Gateway API + Istio Ambient, runs the K3s Istio CNI fix, applies `k8s/`, waits for `litellm` + `llama-cpp`, and fetches kubeconfig to `ansible/kubeconfig/k3s.yaml`. ArgoCD can take over manifest sync later (see [What comes next](#what-comes-next)).

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
| `deploy-llm-stack.yml` | After label-nodes | Models → Gateway API → Istio → CNI fix → `kubectl apply -k k8s` |
| `fix-istio-k3s-cni.yml` | Included by deploy (or manual after Istio) | Symlink `istio-cni` into K3s CNI path; restart ztunnel |
| `stop-k3s.yml` | Shut down cluster | Stop `k3s-agent` on workers, then `k3s` on master |
| `start-k3s.yml` | Boot cluster | Start master, wait for API, start workers |

### Cluster lifecycle

```bash
./scripts/cluster.sh pause    # scale llm-gateway to 0 — cluster still up
./scripts/cluster.sh resume   # kubectl apply -k k8s
./scripts/cluster.sh stop     # ansible-playbook stop-k3s.yml
./scripts/cluster.sh start    # ansible-playbook start-k3s.yml
./scripts/cluster.sh status
```

**Pause** is the usual overnight option (fast, no Ansible). **Stop/start** powers down K3s systemd units on all VMs.

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
ansible-playbook deploy-llm-stack.yml --tags stack       # sync and apply k8s manifests
ansible-playbook deploy-llm-stack.yml --tags kubeconfig  # fetch kubeconfig to ansible/kubeconfig/
```

Set `llm_skip_model_copy: true` in `group_vars/all.yml` when models are already on workers.

## What comes next

Ansible can deploy the full gateway stack with `deploy-llm-stack.yml`. For ongoing GitOps:

1. Install ArgoCD and apply `k8s/argocd/application.yaml` (manifest sync from Git)
2. Keep using Ansible for cluster bootstrap, models, and Istio (or migrate Istio to GitOps later)

Manual steps if not using `deploy-llm-stack.yml`:

1. Copy GGUF models to workers (`/var/lib/llm-models/`) — see [k8s/README.md](../k8s/README.md)
2. Install Gateway API CRDs + Istio Ambient
3. `kubectl apply -k k8s` from the repo root

## Configuration

`group_vars/all.yml`:

```yaml
k3s_version: ""   # pin e.g. v1.32.2+k3s1, or empty for latest

# deploy-llm-stack.yml
llm_model_filename: Llama-3.2-1B-Instruct-Q4_K_M.gguf
llm_skip_model_copy: false   # true when GGUF already on workers
istio_version: "1.24.2"
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
