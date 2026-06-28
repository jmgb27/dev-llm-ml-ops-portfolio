#!/usr/bin/env bash
# Build chat-ui for linux/amd64, import into K3s master, and apply the manifest.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBECONFIG_FILE="${ROOT}/ansible/kubeconfig/k3s.yaml"
MASTER_IP="${K3S_MASTER_IP:-192.168.100.71}"
MASTER_USER="${K3S_MASTER_USER:-ubuntu}"
IMAGE="chat-ui:latest"
TAR="/tmp/chat-ui-amd64.tar"

echo "==> Building ${IMAGE} for linux/amd64 ..."
docker build --platform linux/amd64 -t "${IMAGE}" "${ROOT}/chat-ui"

echo "==> Saving image to ${TAR} ..."
docker save "${IMAGE}" -o "${TAR}"

echo "==> Copying to ${MASTER_USER}@${MASTER_IP} ..."
scp "${TAR}" "${MASTER_USER}@${MASTER_IP}:/tmp/chat-ui-amd64.tar"

echo "==> Importing into K3s containerd ..."
ssh "${MASTER_USER}@${MASTER_IP}" \
  "sudo k3s ctr -n k8s.io images rm docker.io/library/${IMAGE} 2>/dev/null || true; \
   sudo k3s ctr -n k8s.io images import /tmp/chat-ui-amd64.tar; \
   sudo k3s crictl images | grep chat-ui"

echo "==> Applying Kubernetes manifest ..."
export KUBECONFIG="${KUBECONFIG_FILE}"
kubectl apply -f "${ROOT}/k8s/webui/chat-ui-deploy.yaml"
kubectl -n llm-gateway rollout restart deployment/chat-ui
kubectl -n llm-gateway rollout status deployment/chat-ui --timeout=120s

echo
echo "Chat UI deployed. Port-forward:"
echo "  export KUBECONFIG=${KUBECONFIG_FILE}"
echo "  kubectl -n llm-gateway port-forward svc/chat-ui 8000:8000"
echo "  open http://localhost:8000"
