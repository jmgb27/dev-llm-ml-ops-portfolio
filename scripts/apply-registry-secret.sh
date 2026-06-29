#!/usr/bin/env bash
# Apply private registry pull credentials without storing them in Git.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBECONFIG_FILE="${ROOT}/ansible/kubeconfig/k3s.yaml"
NS="${K8S_NAMESPACE:-llm-gateway}"
SECRET_NAME="registry-credentials"

if [[ -f "${ROOT}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${ROOT}/.env"
  set +a
fi

REGISTRY="${REGISTRY:-}"
USERNAME="${REGISTRY_USERNAME:-}"
PASSWORD="${REGISTRY_PASSWORD:-}"

if [[ -z "${REGISTRY}" || -z "${USERNAME}" || -z "${PASSWORD}" ]]; then
  cat >&2 <<EOF
REGISTRY, REGISTRY_USERNAME, and REGISTRY_PASSWORD are required.

Add to ${ROOT}/.env (gitignored):

  REGISTRY=your-registry.example.com
  REGISTRY_USERNAME=your-user
  REGISTRY_PASSWORD=your-token

Or export them for this shell and re-run:

  $0

EOF
  exit 1
fi

export KUBECONFIG="${KUBECONFIG_FILE}"

kubectl create secret docker-registry "${SECRET_NAME}" \
  --namespace="${NS}" \
  --docker-server="${REGISTRY}" \
  --docker-username="${USERNAME}" \
  --docker-password="${PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Secret ${SECRET_NAME} applied in namespace ${NS}."
echo "Restart chat-ui if it was already running:"
echo "  kubectl -n ${NS} rollout restart deployment/chat-ui"
