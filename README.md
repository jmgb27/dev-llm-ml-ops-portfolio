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
