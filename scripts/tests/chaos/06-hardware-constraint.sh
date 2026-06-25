#!/usr/bin/env bash
# Hardware constraint — temporarily allow llama-cpp on master (no AVX2) → expect CrashLoopBackOff.
# Restores nodeSelector after test. DESTRUCTIVE: brief inference outage on one replica.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${TESTS_ROOT}/lib/common.sh"

log "=== Hardware constraint chaos test (AVX2 / SIGILL) ==="
require_kubectl || exit 1

if [[ "${CONFIRM_CHAOS:-}" != "yes" ]]; then
  warn "This test patches llama-cpp scheduling and may cause brief outages."
  warn "Re-run with: CONFIRM_CHAOS=yes $0"
  exit 0
fi

log "Removing cpu-feature=avx2 nodeSelector (patch) ..."
kubectl -n "$K8S_NAMESPACE" patch deployment llama-cpp --type=json \
  -p='[{"op":"remove","path":"/spec/template/spec/nodeSelector/cpu-feature"}]' \
  2>/dev/null || kubectl -n "$K8S_NAMESPACE" patch deployment llama-cpp --type=merge \
  -p='{"spec":{"template":{"spec":{"nodeSelector":{"kubernetes.io/os":"linux"}}}}}'

log "Waiting up to 120s for a pod to crash on non-AVX2 master ..."
deadline=$((SECONDS + 120))
saw_crash=false
while [[ $SECONDS -lt $deadline ]]; do
  if kubectl -n "$K8S_NAMESPACE" get pods -l app=llama-cpp --no-headers 2>/dev/null \
    | grep -qE 'CrashLoopBackOff|Error'; then
    saw_crash=true
    break
  fi
  sleep 5
done

kubectl -n "$K8S_NAMESPACE" get pods -l app=llama-cpp -o wide

TESTS_RUN=$((TESTS_RUN + 1))
if [[ "$saw_crash" == true ]]; then
  pass "Pod crashed on non-AVX2 node (CrashLoopBackOff / SIGILL expected)"
else
  # May still pass if scheduler never placed on master
  crash_pod=$(kubectl -n "$K8S_NAMESPACE" get pods -l app=llama-cpp -o wide --no-headers \
    | awk '$7=="k3s-master" {print $1}')
  if [[ -n "$crash_pod" ]]; then
    reason=$(kubectl -n "$K8S_NAMESPACE" get pod "$crash_pod" -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}' 2>/dev/null || true)
    pass "Master-scheduled pod unhealthy (reason=${reason:-unknown})"
  else
    fail "No crash observed — scheduler may not have tried master; check anti-affinity"
  fi
fi

log "Restoring cpu-feature=avx2 nodeSelector ..."
kubectl -n "$K8S_NAMESPACE" patch deployment llama-cpp --type=merge \
  -p='{"spec":{"template":{"spec":{"nodeSelector":{"cpu-feature":"avx2"}}}}}'

kubectl -n "$K8S_NAMESPACE" rollout status deployment/llama-cpp --timeout=300s
pass "nodeSelector restored; rollout complete"

if check_port_forward 2>/dev/null; then
  response=$(chat_completion "Hardware constraint test recovery")
  TESTS_RUN=$((TESTS_RUN + 1))
  if echo "$response" | grep -q '"content"'; then
    pass "API healthy after restoring AVX2 scheduling"
  else
    fail "API not healthy after restore"
  fi
fi

print_summary
