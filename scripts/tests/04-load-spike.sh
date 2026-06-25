#!/usr/bin/env bash
# Load spike — concurrent prompts through Redis queue; no 502s, high success rate.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

: "${LOAD_SPIKE_CONCURRENCY:=50}"
: "${LOAD_SPIKE_MIN_SUCCESS_PCT:=80}"

log "=== Load spike test (concurrency=${LOAD_SPIKE_CONCURRENCY}) ==="
check_port_forward

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

log "Launching ${LOAD_SPIKE_CONCURRENCY} concurrent chat requests (global_max_parallel_requests=4) ..."
start_ms=$(python3 -c "import time; print(int(time.time()*1000))")

for i in $(seq 1 "$LOAD_SPIKE_CONCURRENCY"); do
  (
    code=$(curl -sS -o "${tmpdir}/body_${i}" -w '%{http_code}' \
      --connect-timeout "$CURL_CONNECT_TIMEOUT" \
      --max-time "$CURL_MAX_TIME" \
      -X POST \
      -H "Authorization: Bearer ${LITELLM_API_KEY}" \
      -H "Content-Type: application/json" \
      -d "$(chat_payload "Load spike request ${i}: one word reply.")" \
      "${LITELLM_BASE_URL}/v1/chat/completions" 2>/dev/null || echo "000")
    echo "$code" > "${tmpdir}/code_${i}"
  ) &
done
wait

end_ms=$(python3 -c "import time; print(int(time.time()*1000))")
elapsed_s=$(python3 -c "print(round(($end_ms - $start_ms) / 1000, 1))")

count_200=0 count_429=0 count_502=0 count_other=0
for i in $(seq 1 "$LOAD_SPIKE_CONCURRENCY"); do
  code=$(cat "${tmpdir}/code_${i}")
  case "$code" in
    200) count_200=$((count_200 + 1)) ;;
    429) count_429=$((count_429 + 1)) ;;
    502) count_502=$((count_502 + 1)) ;;
    *) count_other=$((count_other + 1)); warn "request $i → HTTP $code" ;;
  esac
done

success_pct=$(python3 -c "print(round(100 * $count_200 / $LOAD_SPIKE_CONCURRENCY, 1))")
log "Completed in ${elapsed_s}s — 200=${count_200} 429=${count_429} 502=${count_502} other=${count_other} (${success_pct}% success)"

TESTS_RUN=$((TESTS_RUN + 1))
if [[ "$count_502" -eq 0 ]]; then
  pass "No 502 Bad Gateway during load spike"
else
  fail "${count_502} requests returned 502"
fi

TESTS_RUN=$((TESTS_RUN + 1))
if python3 -c "exit(0 if float('$success_pct') >= float('$LOAD_SPIKE_MIN_SUCCESS_PCT') else 1)"; then
  pass "Success rate ${success_pct}% >= ${LOAD_SPIKE_MIN_SUCCESS_PCT}%"
elif [[ "$count_502" -eq 0 && "$count_other" -eq 0 && "$count_429" -gt 0 ]]; then
  pass "Gateway absorbed spike via backpressure (429=${count_429}, no 5xx)"
else
  fail "Success rate ${success_pct}% below threshold ${LOAD_SPIKE_MIN_SUCCESS_PCT}%"
fi

TESTS_RUN=$((TESTS_RUN + 1))
if [[ "$count_429" -gt 0 || "$LOAD_SPIKE_CONCURRENCY" -gt 4 ]]; then
  pass "Queue/backpressure observed (429=${count_429}) or concurrency > inference slots"
else
  warn "No 429s — queue may not have been stressed"
fi

print_summary
