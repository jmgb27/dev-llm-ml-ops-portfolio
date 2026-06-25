#!/usr/bin/env bash
# Unit checks for continuous-probe helpers (no cluster or gateway required).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${TESTS_ROOT}/lib/common.sh"
# shellcheck source=../lib/continuous-probe.sh
source "${TESTS_ROOT}/lib/continuous-probe.sh"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

printf '%s,200\n' "1000" > "${tmpdir}/probe_1"
printf '%s,200\n' "2000" > "${tmpdir}/probe_2"
printf '%s,502\n' "3000" > "${tmpdir}/probe_3"
printf '%s,200\n' "4000" > "${tmpdir}/probe_4"
echo "2500" > "${tmpdir}/event_pod_delete"

continuous_probe_summary "$tmpdir" "pod_delete"

log "=== continuous-probe unit checks ==="

TESTS_RUN=$((TESTS_RUN + 1))
if [[ "$PROBE_TOTAL" -eq 4 && "$PROBE_COUNT_200" -eq 3 && "$PROBE_COUNT_502" -eq 1 ]]; then
  pass "Aggregate counts (total=4, 200=3, 502=1)"
else
  fail "Aggregate counts — got total=${PROBE_TOTAL} 200=${PROBE_COUNT_200} 502=${PROBE_COUNT_502}"
fi

TESTS_RUN=$((TESTS_RUN + 1))
if [[ "$PROBE_PRE_200" -eq 2 && "$PROBE_PRE_502" -eq 0 && "$PROBE_POST_200" -eq 1 && "$PROBE_POST_502" -eq 1 ]]; then
  pass "Pre/post chaos split (pre 200=2/502=0, post 200=1/502=1)"
else
  fail "Pre/post chaos split — pre 200=${PROBE_PRE_200} 502=${PROBE_PRE_502}, post 200=${PROBE_POST_200} 502=${PROBE_POST_502}"
fi

print_summary
