#!/usr/bin/env bash
# Worker failover — delete one llama-cpp pod; API must stay up (Istio routes to survivor).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${TESTS_ROOT}/lib/common.sh"
# shellcheck source=../lib/continuous-probe.sh
source "${TESTS_ROOT}/lib/continuous-probe.sh"

: "${FAILOVER_WORKER_NODE:=k3s-worker-01}"

log "=== Worker failover chaos test ==="
check_port_forward || true
require_kubectl || exit 1

pods_before=$(kubectl -n "$K8S_NAMESPACE" get pods -l app=llama-cpp --no-headers 2>/dev/null | wc -l | tr -d ' ')
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "$pods_before" -ge 2 ]]; then
  pass "At least 2 llama-cpp replicas running ($pods_before)"
else
  fail "Need 2 llama-cpp replicas for failover test (found $pods_before)"
  print_summary
fi

victim=$(kubectl -n "$K8S_NAMESPACE" get pods -l app=llama-cpp \
  -o jsonpath="{range .items[?(@.spec.nodeName==\"${FAILOVER_WORKER_NODE}\")]}{.metadata.name}{\"\n\"}{end}" \
  | head -1)

if [[ -z "$victim" ]]; then
  victim=$(kubectl -n "$K8S_NAMESPACE" get pods -l app=llama-cpp -o jsonpath='{.items[0].metadata.name}')
  warn "No pod on ${FAILOVER_WORKER_NODE}; killing ${victim} instead"
fi

tmpdir=$(mktemp -d)
trap 'continuous_probe_stop "$tmpdir" 2>/dev/null || true; rm -rf "$tmpdir"' EXIT

log "Starting continuous traffic (${PROBE_WARMUP_SEC}s warmup before pod delete) ..."
continuous_probe_start "$tmpdir" "Failover probe"
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
  pass "No 502 exposed during worker pod failure"
else
  fail "${PROBE_COUNT_502} probes returned 502 (during/after chaos: ${PROBE_POST_502})"
fi

log "Waiting for llama-cpp deployment to recover ..."
kubectl -n "$K8S_NAMESPACE" rollout status deployment/llama-cpp --timeout=300s

TESTS_RUN=$((TESTS_RUN + 1))
ready=$(kubectl -n "$K8S_NAMESPACE" get pods -l app=llama-cpp --no-headers | awk '$2=="1/1" && $3=="Running"' | wc -l | tr -d ' ')
if [[ "$ready" -ge 2 ]]; then
  pass "Deployment recovered ($ready/2 pods ready)"
else
  fail "Deployment not fully recovered ($ready ready)"
fi

response=$(chat_completion "Failover recovery check")
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$response" | grep -q '"content"'; then
  pass "Chat completion works after recovery"
else
  fail "Post-recovery chat failed: ${response:0:200}"
fi

print_summary
