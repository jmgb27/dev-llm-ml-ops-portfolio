#!/usr/bin/env bash
# Build chat-ui, push to your private registry, and restart the Deployment.
# Prefer CI (.github/workflows/ci.yaml) for production — this script is for manual pushes.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBECONFIG_FILE="${ROOT}/ansible/kubeconfig/k3s.yaml"
IMAGE_NAME="${IMAGE_NAME:-chat-ui}"
TAG="${IMAGE_TAG:-latest}"

if [[ -f "${ROOT}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${ROOT}/.env"
  set +a
fi

REGISTRY="${REGISTRY:-}"
USERNAME="${REGISTRY_USERNAME:-}"
PASSWORD="${REGISTRY_PASSWORD:-}"
IMAGE="${REGISTRY}/${IMAGE_NAME}:${TAG}"

if [[ -z "${REGISTRY}" || -z "${USERNAME}" || -z "${PASSWORD}" ]]; then
  cat >&2 <<EOF
REGISTRY, REGISTRY_USERNAME, and REGISTRY_PASSWORD are required in ${ROOT}/.env

For GitOps deploys, merge to master and let CI push the image + bump k8s/kustomization.yaml.
EOF
  exit 1
fi

echo "==> Building ${IMAGE} for linux/amd64 ..."
docker build --platform linux/amd64 -t "${IMAGE}" "${ROOT}/chat-ui"

echo "==> Logging in to registry ..."
echo "${PASSWORD}" | docker login "${REGISTRY}" --username "${USERNAME}" --password-stdin

echo "==> Pushing ${IMAGE} ..."
docker push "${IMAGE}"

export KUBECONFIG="${KUBECONFIG_FILE}"
echo "==> Restarting chat-ui Deployment ..."
kubectl -n llm-gateway rollout restart deployment/chat-ui
kubectl -n llm-gateway rollout status deployment/chat-ui --timeout=120s

echo
echo "Chat UI updated. Port-forward:"
echo "  export KUBECONFIG=${KUBECONFIG_FILE}"
echo "  kubectl -n llm-gateway port-forward svc/chat-ui 8000:8000"
echo "  open http://localhost:8000"
