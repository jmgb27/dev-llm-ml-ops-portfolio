# Ansible — K3s cluster configuration

Configures the VMs provisioned by Terraform: base OS hardening, K3s install, worker join, and hardware-aware node labels.

## Prerequisites

- Terraform VMs running with SSH access (`ubuntu` user + your public key)
- `inventory.ini` populated (from `terraform output -raw ansible_inventory_ini`)
- Ansible on your control machine:

```bash
# macOS
brew install ansible

# or pip
pip install ansible
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

## Verify the cluster

On the master:

```bash
ssh ubuntu@192.168.100.71
sudo kubectl get nodes -o wide
sudo kubectl get nodes --show-labels | grep cpu-feature
```

Expected labels:

| Node | Label |
|------|-------|
| `k3s-master` | `cpu-feature=base` |
| `k3s-worker-01` | `cpu-feature=avx2` |
| `k3s-worker-02` | `cpu-feature=avx2` |

Copy kubeconfig to your laptop (optional):

```bash
scp ubuntu@192.168.100.71:/etc/rancher/k3s/k3s.yaml ~/.kube/config
# Edit server IP in the file if needed (replace 127.0.0.1 with 192.168.100.71)
```

## Playbooks

| Playbook | Purpose |
|----------|---------|
| `bootstrap-k3s.yml` | OS prep, qemu-guest-agent, K3s server + agents |
| `label-nodes.yml` | `lscpu` AVX2 detection → `cpu-feature` Kubernetes labels |

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
