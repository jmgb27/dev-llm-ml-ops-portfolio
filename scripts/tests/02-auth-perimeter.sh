#!/usr/bin/env bash
# Perimeter auth — validates LiteLLM rejects anonymous and invalid API keys.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

log "=== Auth perimeter test ==="
check_port_forward

payload=$(chat_payload "This should not succeed without auth")
url="${LITELLM_BASE_URL}/v1/chat/completions"

assert_http_code "No Authorization header → 401" "401" "$url" \
  -X POST -H "Content-Type: application/json" -d "$payload"

invalid_code=$(curl -sS -o /dev/null -w '%{http_code}' \
  --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" \
  -X POST \
  -H "Authorization: Bearer sk-invalid-key" \
  -H "Content-Type: application/json" \
  -d "$payload" \
  "$url" 2>/dev/null || echo "000")

TESTS_RUN=$((TESTS_RUN + 1))
if [[ "$invalid_code" == "401" || "$invalid_code" == "400" ]]; then
  pass "Invalid API key rejected (HTTP ${invalid_code})"
else
  fail "Invalid API key rejected — expected 401 or 400, got '${invalid_code}'"
fi

assert_http_code "Valid API key → 200" "200" "$url" \
  -X POST \
  -H "Authorization: Bearer ${LITELLM_API_KEY}" \
  -H "Content-Type: application/json" \
  -d "$(chat_payload "Auth test ok")"

print_summary
