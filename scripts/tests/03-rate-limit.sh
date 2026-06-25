#!/usr/bin/env bash
# Rate limit test — bursts past rpm (60/min) and expects 429 from LiteLLM perimeter.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

: "${RATE_LIMIT_BURST:=70}"

log "=== Rate limit test (burst=${RATE_LIMIT_BURST}, configured rpm=60) ==="
check_port_forward

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

payload=$(chat_payload "rate limit probe")

log "Firing ${RATE_LIMIT_BURST} parallel requests ..."
for i in $(seq 1 "$RATE_LIMIT_BURST"); do
  (
    code=$(curl -sS -o /dev/null -w '%{http_code}' \
      --connect-timeout "$CURL_CONNECT_TIMEOUT" \
      --max-time 30 \
      -X POST \
      -H "Authorization: Bearer ${LITELLM_API_KEY}" \
      -H "Content-Type: application/json" \
      -d "$payload" \
      "${LITELLM_BASE_URL}/v1/chat/completions" 2>/dev/null || echo "000")
    echo "$code" > "${tmpdir}/code_${i}"
  ) &
done
wait

count_200=0 count_429=0 count_other=0
for f in "${tmpdir}"/code_*; do
  code=$(cat "$f")
  case "$code" in
    200) count_200=$((count_200 + 1)) ;;
    429) count_429=$((count_429 + 1)) ;;
    *) count_other=$((count_other + 1)); warn "unexpected HTTP $code" ;;
  esac
done

log "Results: 200=${count_200} 429=${count_429} other=${count_other}"

TESTS_RUN=$((TESTS_RUN + 1))
if [[ "$count_429" -gt 0 ]]; then
  pass "Rate limiter returned 429 (${count_429} requests throttled)"
else
  fail "Expected at least one 429 — got 200=${count_200} other=${count_other}"
fi

TESTS_RUN=$((TESTS_RUN + 1))
if [[ "$count_200" -gt 0 ]]; then
  pass "Some requests succeeded before limit (${count_200} × 200)"
else
  warn "No 200 responses — limits may already be saturated; retry in 60s"
fi

print_summary
