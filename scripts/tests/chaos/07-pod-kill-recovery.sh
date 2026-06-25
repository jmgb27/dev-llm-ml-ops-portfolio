#!/usr/bin/env bash
# Pod kill recovery — delete a running llama-cpp pod; Deployment must recreate it.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${TESTS_ROOT}/lib/common.sh"
# shellcheck source=../lib/continuous-probe.sh
source "${TESTS_ROOT}/lib/continuous-probe.sh"

log "=== Pod kill recovery test ==="
check_port_forward || true
require_kubectl || exit 1

victim=$(kubectl -n "$K8S_NAMESPACE" get pods -l app=llama-cpp -o jsonpath='{.items[0].metadata.name}')

tmpdir=$(mktemp -d)
trap 'continuous_probe_stop "$tmpdir" 2>/dev/null || true; rm -rf "$tmpdir"' EXIT

log "Starting continuous traffic (${PROBE_WARMUP_SEC}s warmup before pod delete) ..."
continuous_probe_start "$tmpdir" "Recovery probe"
sleep "$PROBE_WARMUP_SEC"

log "Deleting pod ${victim} while probes continue ..."
continuous_probe_mark_event "$tmpdir" "pod_delete"
kubectl -n "$K8S_NAMESPACE" delete pod "$victim" --wait=false

log "Probing through recovery (${PROBE_POST_CHAOS_SEC}s) ..."
sleep "$PROBE_POST_CHAOS_SEC"
continuous_probe_stop "$tmpdir"
continuous_probe_log_summary "$tmpdir" "pod_delete"

TESTS_RUN=$((TESTS_RUN + 1))
if [[ "$PROBE_COUNT_502" -eq 0 ]]; then
  pass "No 502 exposed during pod kill"
else
  fail "${PROBE_COUNT_502} probes returned 502"
fi

kubectl -n "$K8S_NAMESPACE" rollout status deployment/llama-cpp --timeout=300s

ready=$(kubectl -n "$K8S_NAMESPACE" get pods -l app=llama-cpp --no-headers \
  | awk '$2=="1/1" && $3=="Running"' | wc -l | tr -d ' ')

TESTS_RUN=$((TESTS_RUN + 1))
if [[ "$ready" -ge 1 ]]; then
  pass "llama-cpp pods recreated ($ready running)"
else
  fail "No healthy llama-cpp pods after delete"
fi

if check_port_forward 2>/dev/null; then
  response=$(chat_completion "Pod recovery check")
  TESTS_RUN=$((TESTS_RUN + 1))
  if echo "$response" | grep -q '"content"'; then
    pass "Inference works after pod kill"
  else
    fail "Inference failed after pod kill"
  fi
fi

print_summary
