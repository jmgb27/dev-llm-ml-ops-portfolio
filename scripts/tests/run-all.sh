#!/usr/bin/env bash
# Run API tests against port-forwarded LiteLLM (safe suite + optional chaos).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RUN_CHAOS=false
for arg in "$@"; do
  case "$arg" in
    --chaos) RUN_CHAOS=true ;;
    -h|--help)
      cat <<EOF
Usage: $(basename "$0") [--chaos]

Runs enterprise/resilience tests against the LiteLLM gateway.

Prerequisites:
  kubectl -n llm-gateway port-forward svc/litellm 4000:4000

Environment:
  LITELLM_BASE_URL   default http://localhost:4000
  LITELLM_API_KEY    default sk-1234
  LITELLM_MODEL      default llama3

Safe tests (always, in order):
  01-smoke.sh           Health + chat completion
  02-auth-perimeter.sh  Reject missing/invalid token
  04-load-spike.sh      50 concurrent → queue, no 502 (runs before rate limit)
  03-rate-limit.sh      Burst → 429

Chaos tests (--chaos, requires kubectl):
  chaos/05-worker-failover.sh      Continuous traffic, then delete worker pod
  chaos/06-hardware-constraint.sh  SIGILL test (CONFIRM_CHAOS=yes)
  chaos/07-pod-kill-recovery.sh    Deployment self-healing
EOF
      exit 0
      ;;
  esac
done

echo "=============================================="
echo " LLM Gateway test suite"
echo " Target: ${LITELLM_BASE_URL:-http://localhost:4000}"
echo "=============================================="
echo

failed=0
run_test() {
  local script="$1"
  echo "----------------------------------------------"
  if bash "$script"; then
    echo
  else
    failed=$((failed + 1))
    echo
  fi
}

for script in \
  "${SCRIPT_DIR}/01-smoke.sh" \
  "${SCRIPT_DIR}/02-auth-perimeter.sh" \
  "${SCRIPT_DIR}/04-load-spike.sh" \
  "${SCRIPT_DIR}/03-rate-limit.sh"; do
  [[ -f "$script" ]] || continue
  run_test "$script"
done

if [[ "$RUN_CHAOS" == true ]]; then
  echo "=============================================="
  echo " Chaos / enterprise failure scenarios"
  echo "=============================================="
  for script in "${SCRIPT_DIR}"/chaos/*.sh; do
    [[ -f "$script" ]] || continue
    run_test "$script"
  done
else
  echo "Tip: run cluster chaos tests with: $0 --chaos"
fi

echo "=============================================="
if [[ "$failed" -gt 0 ]]; then
  echo "SUITE FAILED ($failed script(s))"
  exit 1
fi
echo "SUITE PASSED"
exit 0
