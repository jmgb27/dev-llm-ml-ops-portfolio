#!/usr/bin/env bash
# Smoke test — health check and single chat completion via port-forwarded LiteLLM.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

log "=== Smoke test ==="
check_port_forward

assert_http_code "Health endpoint returns 200" "200" \
  "${LITELLM_BASE_URL}/health/liveliness"

log "Sending chat completion ..."
response=$(chat_completion "Reply with exactly: smoke test ok")
TESTS_RUN=$((TESTS_RUN + 1))

if echo "$response" | grep -q '"content"'; then
  content=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin)['choices'][0]['message']['content'])" 2>/dev/null || echo "$response")
  pass "Chat completion returned content: ${content:0:80}"
else
  fail "Chat completion missing choices — response: ${response:0:200}"
fi

print_summary
