#!/usr/bin/env bash
# Shared helpers for LLM gateway test scripts.
set -euo pipefail

: "${LITELLM_BASE_URL:=http://localhost:4000}"
: "${LITELLM_API_KEY:=sk-1234}"
: "${LITELLM_MODEL:=llama3}"
: "${K8S_NAMESPACE:=llm-gateway}"
: "${CURL_CONNECT_TIMEOUT:=5}"
: "${CURL_MAX_TIME:=180}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

log() { printf '%b\n' "${BLUE}[test]${NC} $*"; }
warn() { printf '%b\n' "${YELLOW}[warn]${NC} $*"; }
pass() { TESTS_PASSED=$((TESTS_PASSED + 1)); printf '%b\n' "${GREEN}[PASS]${NC} $*"; }
fail() { TESTS_FAILED=$((TESTS_FAILED + 1)); printf '%b\n' "${RED}[FAIL]${NC} $*" >&2; }
skip() { printf '%b\n' "${YELLOW}[SKIP]${NC} $*"; }

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ "$expected" == "$actual" ]]; then
    pass "$desc (got: $actual)"
    return 0
  fi
  fail "$desc — expected '$expected', got '$actual'"
  return 1
}

assert_http_code() {
  local desc="$1" expected="$2" url="$3"
  shift 3
  local code
  code=$(curl -sS -o /dev/null -w '%{http_code}' \
    --connect-timeout "$CURL_CONNECT_TIMEOUT" \
    --max-time "$CURL_MAX_TIME" \
  "$@" "$url" || echo "000")
  assert_eq "$desc" "$expected" "$code"
}

chat_payload() {
  local message="${1:-Say hello in one sentence.}"
  printf '{"model":"%s","messages":[{"role":"user","content":"%s"}]}' \
    "$LITELLM_MODEL" "$message"
}

chat_completion() {
  local message="${1:-Say hello in one sentence.}"
  curl -sS \
    --connect-timeout "$CURL_CONNECT_TIMEOUT" \
    --max-time "$CURL_MAX_TIME" \
    -H "Authorization: Bearer ${LITELLM_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "$(chat_payload "$message")" \
    "${LITELLM_BASE_URL}/v1/chat/completions"
}

check_port_forward() {
  log "Checking LiteLLM at ${LITELLM_BASE_URL} ..."
  local code
  code=$(curl -sS -o /dev/null -w '%{http_code}' \
    --connect-timeout "$CURL_CONNECT_TIMEOUT" \
    --max-time 10 \
    "${LITELLM_BASE_URL}/health/liveliness" 2>/dev/null || echo "000")

  if [[ "$code" == "200" || "$code" == "401" ]]; then
    log "Gateway reachable (HTTP $code)"
    return 0
  fi

  fail "Gateway not reachable at ${LITELLM_BASE_URL} (HTTP $code)"
  cat >&2 <<EOF

Start port-forward in another terminal:
  kubectl -n ${K8S_NAMESPACE} port-forward svc/litellm 4000:4000

Or for Docker Compose:
  docker compose up -d
  export LITELLM_BASE_URL=http://localhost:4000

EOF
  return 1
}

require_kubectl() {
  if ! command -v kubectl >/dev/null 2>&1; then
    fail "kubectl not found — required for this test"
    return 1
  fi
  if ! kubectl get ns "$K8S_NAMESPACE" >/dev/null 2>&1; then
    fail "Cannot reach cluster or namespace '${K8S_NAMESPACE}' — check ~/.kube/config"
    return 1
  fi
  return 0
}

print_summary() {
  echo
  log "Results: ${TESTS_PASSED}/${TESTS_RUN} passed, ${TESTS_FAILED} failed"
  if [[ "$TESTS_FAILED" -gt 0 ]]; then
    exit 1
  fi
}

script_dir() {
  cd "$(dirname "${BASH_SOURCE[1]}")" && pwd
}
