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
| `fix-istio-k3s-cni.yml` | After Istio ambient install | Symlink `istio-cni` into K3s CNI path; restart ztunnel |

### Istio on K3s

After installing Istio with `--set values.global.platform=k3s`, always run:

```bash
ansible-playbook fix-istio-k3s-cni.yml
```

Without this, new pods (including `ztunnel`) fail with `failed to find plugin "istio-cni" in path [/var/lib/rancher/k3s/data/cni]`.

## What comes next

Ansible stops at a healthy K3s cluster. To deploy the LLM stack:

1. Copy GGUF models to workers (`/var/lib/llm-models/`) — see [k8s/README.md](../k8s/README.md)
2. Install Gateway API CRDs + Istio Ambient
3. `kubectl apply -k k8s` from the repo root

## Configuration

`group_vars/all.yml`:

```yaml
k3s_version: ""   # pin e.g. v1.32.2+k3s1, or empty for latest
```

## Inventory

Regenerate after Terraform changes:

```bash
cd ../terraform
terraform output -raw ansible_inventory_ini > ../ansible/inventory.ini
```
