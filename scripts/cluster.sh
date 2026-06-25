#!/usr/bin/env bash
# Cluster lifecycle — pause workloads, stop/start K3s, or check status.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANSIBLE_DIR="${ROOT}/ansible"
NS="${K8S_NAMESPACE:-llm-gateway}"
ARGOCD_NS="${ARGOCD_NAMESPACE:-argocd}"
ARGOCD_APP="${ARGOCD_APPLICATION:-llm-gateway}"
KUBECONFIG_FILE="${ANSIBLE_DIR}/kubeconfig/k3s.yaml"

usage() {
  cat <<EOF
Usage: $(basename "$0") <command>

Commands:
  status       Show nodes and llm-gateway pods
  deploy       Ansible prerequisites (models, Gateway API, Istio, CNI fix, kubeconfig)
  argocd       Install ArgoCD and sync llm-gateway app from Git
  port-forward Forward litellm (4000) or grafana (3000) — uses ansible/kubeconfig/k3s.yaml
  pause        Disable ArgoCD auto-sync and scale llm-gateway to 0
  resume       Re-enable ArgoCD auto-sync (restores workloads from Git)
  stop         Stop K3s via Ansible (workers → master)
  start        Start K3s via Ansible (master → workers)

Bootstrap order:
  ./scripts/cluster.sh deploy
  ./scripts/cluster.sh argocd

Uses ${KUBECONFIG_FILE} when present (refresh: ansible-playbook deploy-llm-stack.yml --tags kubeconfig)
EOF
}

use_kubeconfig() {
  if [[ -f "$KUBECONFIG_FILE" ]]; then
    export KUBECONFIG="$KUBECONFIG_FILE"
  fi
}

require_kubectl() {
  use_kubeconfig
  command -v kubectl >/dev/null 2>&1 || { echo "kubectl not found" >&2; exit 1; }
  if ! kubectl get nodes >/dev/null 2>&1; then
    cat >&2 <<EOF
Cannot reach cluster (TLS or stale kubeconfig).

  export KUBECONFIG=${KUBECONFIG_FILE}
  cd ansible && ansible-playbook deploy-llm-stack.yml --tags kubeconfig

EOF
    exit 1
  fi
}

argocd_app_exists() {
  kubectl get application "$ARGOCD_APP" -n "$ARGOCD_NS" >/dev/null 2>&1
}

run_ansible_playbook() {
  export ANSIBLE_CONFIG="${ANSIBLE_DIR}/ansible.cfg"
  ansible-playbook -i "${ANSIBLE_DIR}/inventory.ini" "$@"
}

cmd_deploy() {
  shift || true
  echo "Deploying cluster prerequisites via Ansible ..."
  run_ansible_playbook "${ANSIBLE_DIR}/deploy-llm-stack.yml" "$@"
  echo
  echo "Next: hand the app to ArgoCD:"
  echo "  ./scripts/cluster.sh argocd"
}

cmd_argocd() {
  shift || true
  echo "Installing ArgoCD and registering llm-gateway Application ..."
  run_ansible_playbook "${ANSIBLE_DIR}/deploy-argocd.yml" "$@"
  echo
  echo "ArgoCD owns llm-gateway. Port-forward LiteLLM:"
  echo "  export KUBECONFIG=${ANSIBLE_DIR}/kubeconfig/k3s.yaml"
  echo "  kubectl -n ${NS} port-forward svc/litellm 4000:4000"
}

cmd_port_forward() {
  shift || true
  local target="${1:-litellm}"
  require_kubectl
  case "$target" in
    litellm|llm)
      echo "Forwarding LiteLLM → http://localhost:4000 (KUBECONFIG=${KUBECONFIG:-$KUBECONFIG_FILE})"
      kubectl -n "$NS" port-forward svc/litellm 4000:4000
      ;;
    grafana)
      echo "Forwarding Grafana → http://localhost:3000 (KUBECONFIG=${KUBECONFIG:-$KUBECONFIG_FILE})"
      kubectl -n "$NS" port-forward svc/grafana 3000:3000
      ;;
    *)
      echo "Unknown port-forward target: $target (use litellm or grafana)" >&2
      exit 1
      ;;
  esac
}

cmd_status() {
  require_kubectl
  echo "=== Nodes ==="
  kubectl get nodes -o wide
  echo
  echo "=== ${NS} pods ==="
  kubectl -n "$NS" get pods -o wide 2>/dev/null || echo "(namespace empty or missing)"
  echo
  echo "=== ArgoCD ==="
  kubectl get application -n "$ARGOCD_NS" 2>/dev/null || echo "(ArgoCD not installed)"
  echo
  echo "=== Istio ==="
  kubectl get pods -n istio-system --no-headers 2>/dev/null | awk '{print $2, $3}' | sort | uniq -c || true
}

cmd_pause() {
  require_kubectl
  if argocd_app_exists; then
    echo "Disabling ArgoCD auto-sync on ${ARGOCD_APP} ..."
    kubectl -n "$ARGOCD_NS" patch application "$ARGOCD_APP" --type=merge \
      -p '{"spec":{"syncPolicy":{"automated":null}}}'
  else
    echo "ArgoCD Application not found — scaling deployments only."
  fi
  echo "Scaling ${NS} deployments to 0 ..."
  kubectl -n "$NS" scale deployment --all --replicas=0 2>/dev/null || true
  kubectl -n "$NS" get pods 2>/dev/null || true
  echo "Done. K3s and Istio still running; run: $0 resume"
}

cmd_resume() {
  require_kubectl
  if argocd_app_exists; then
    echo "Re-enabling ArgoCD auto-sync on ${ARGOCD_APP} ..."
    kubectl -n "$ARGOCD_NS" patch application "$ARGOCD_APP" --type=merge \
      -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
    echo "Waiting for ArgoCD to restore workloads (model load may take ~2 min) ..."
    kubectl -n "$NS" rollout status deployment/llama-cpp --timeout=600s || true
    kubectl -n "$NS" rollout status deployment/litellm --timeout=300s || true
  else
    echo "ArgoCD Application not found. Run: $0 argocd" >&2
    exit 1
  fi
  kubectl -n "$NS" get pods -o wide
  echo
  echo "Port-forwards (run in separate terminals):"
  echo "  kubectl -n ${NS} port-forward svc/litellm 4000:4000"
  echo "  kubectl -n ${NS} port-forward svc/grafana 3000:3000"
}

cmd_stop() {
  echo "Stopping K3s cluster via Ansible ..."
  run_ansible_playbook "${ANSIBLE_DIR}/stop-k3s.yml"
  echo "Cluster stopped."
}

cmd_start() {
  echo "Starting K3s cluster via Ansible ..."
  run_ansible_playbook "${ANSIBLE_DIR}/start-k3s.yml"
  echo "Cluster started. Run: $0 resume  (if workloads were paused)"
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    status) cmd_status ;;
    deploy) cmd_deploy "$@" ;;
    argocd) cmd_argocd "$@" ;;
    port-forward|pf) cmd_port_forward "$@" ;;
    pause)  cmd_pause ;;
    resume) cmd_resume ;;
    stop)   cmd_stop ;;
    start)  cmd_start ;;
    -h|--help|help|"") usage ;;
    *) echo "Unknown command: $cmd" >&2; usage; exit 1 ;;
  esac
}

main "$@"
