#!/usr/bin/env bash
# Apply Cloudflare tunnel token without storing it in Git.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBECONFIG_FILE="${ROOT}/ansible/kubeconfig/k3s.yaml"
NS="${K8S_NAMESPACE:-llm-gateway}"
SECRET_NAME="cloudflared-credentials"

if [[ -f "${ROOT}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${ROOT}/.env"
  set +a
fi

TOKEN="${CLOUDFLARE_TUNNEL_TOKEN:-}"

if [[ -z "${TOKEN}" ]]; then
  cat >&2 <<EOF
CLOUDFLARE_TUNNEL_TOKEN is not set.

Add to ${ROOT}/.env (gitignored):

  CLOUDFLARE_TUNNEL_TOKEN=eyJ...

Or export it for this shell:

  export CLOUDFLARE_TUNNEL_TOKEN='eyJ...'
  $0

EOF
  exit 1
fi

export KUBECONFIG="${KUBECONFIG_FILE}"

kubectl create secret generic "${SECRET_NAME}" \
  --namespace="${NS}" \
  --from-literal=tunnel-token="${TOKEN}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Secret ${SECRET_NAME} applied in namespace ${NS}."
echo "Restart cloudflared if it was already running:"
echo "  kubectl -n ${NS} rollout restart deployment/cloudflared"
