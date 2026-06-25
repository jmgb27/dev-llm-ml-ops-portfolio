#!/usr/bin/env bash
# Background chat-completion probes for chaos / failover tests.
# Start traffic before injecting failure, mark the event, keep probing through recovery.
set -euo pipefail

: "${PROBE_INTERVAL_SEC:=1}"
: "${PROBE_WARMUP_SEC:=5}"
: "${PROBE_POST_CHAOS_SEC:=20}"
: "${PROBE_MESSAGE_PREFIX:=Chaos probe}"

# shellcheck disable=SC2034
PROBE_COUNT_200=0 PROBE_COUNT_429=0 PROBE_COUNT_502=0 PROBE_COUNT_OTHER=0 PROBE_TOTAL=0
# shellcheck disable=SC2034
PROBE_PRE_200=0 PROBE_PRE_502=0 PROBE_POST_200=0 PROBE_POST_502=0

_continuous_probe_worker() {
  local out_dir="$1"
  local label="$2"
  local seq=0
  local -a pids=()

  while [[ ! -f "${out_dir}/.stop" ]]; do
    seq=$((seq + 1))
    (
      local start_ms code
      start_ms=$(python3 -c "import time; print(int(time.time()*1000))")
      code=$(curl -sS -o /dev/null -w '%{http_code}' \
        --connect-timeout "${CURL_CONNECT_TIMEOUT}" \
        --max-time "${CURL_MAX_TIME}" \
        -X POST \
        -H "Authorization: Bearer ${LITELLM_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "$(chat_payload "${label} ${seq}")" \
        "${LITELLM_BASE_URL}/v1/chat/completions" 2>/dev/null || echo "000")
      printf '%s,%s\n' "$start_ms" "$code" > "${out_dir}/probe_${seq}"
    ) &
    pids+=("$!")
    sleep "$PROBE_INTERVAL_SEC"
  done

  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
}

continuous_probe_start() {
  local out_dir="$1"
  local label="${2:-$PROBE_MESSAGE_PREFIX}"
  mkdir -p "$out_dir"
  rm -f "${out_dir}/.stop"
  _continuous_probe_worker "$out_dir" "$label" &
  echo "$!" > "${out_dir}/.pid"
}

continuous_probe_stop() {
  local out_dir="$1"
  touch "${out_dir}/.stop"
  if [[ -f "${out_dir}/.pid" ]]; then
    wait "$(cat "${out_dir}/.pid")" 2>/dev/null || true
    rm -f "${out_dir}/.pid"
  fi
}

continuous_probe_mark_event() {
  local out_dir="$1"
  local event_name="$2"
  python3 -c "import time; print(int(time.time()*1000))" > "${out_dir}/event_${event_name}"
}

continuous_probe_summary() {
  local out_dir="$1"
  local event_name="${2:-}"

  PROBE_COUNT_200=0 PROBE_COUNT_429=0 PROBE_COUNT_502=0 PROBE_COUNT_OTHER=0 PROBE_TOTAL=0
  PROBE_PRE_200=0 PROBE_PRE_502=0 PROBE_POST_200=0 PROBE_POST_502=0

  local event_ts=""
  if [[ -n "$event_name" && -f "${out_dir}/event_${event_name}" ]]; then
    event_ts=$(cat "${out_dir}/event_${event_name}")
  fi

  local f
  for f in "${out_dir}"/probe_*; do
    [[ -f "$f" ]] || continue
    local line ts code
    line=$(cat "$f")
    ts="${line%%,*}"
    code="${line##*,}"
    PROBE_TOTAL=$((PROBE_TOTAL + 1))

    case "$code" in
      200) PROBE_COUNT_200=$((PROBE_COUNT_200 + 1)) ;;
      429) PROBE_COUNT_429=$((PROBE_COUNT_429 + 1)) ;;
      502) PROBE_COUNT_502=$((PROBE_COUNT_502 + 1)) ;;
      *) PROBE_COUNT_OTHER=$((PROBE_COUNT_OTHER + 1)) ;;
    esac

    if [[ -n "$event_ts" ]]; then
      if [[ "$ts" -lt "$event_ts" ]]; then
        case "$code" in
          200) PROBE_PRE_200=$((PROBE_PRE_200 + 1)) ;;
          502) PROBE_PRE_502=$((PROBE_PRE_502 + 1)) ;;
        esac
      else
        case "$code" in
          200) PROBE_POST_200=$((PROBE_POST_200 + 1)) ;;
          502) PROBE_POST_502=$((PROBE_POST_502 + 1)) ;;
        esac
      fi
    fi
  done
}

continuous_probe_log_summary() {
  local out_dir="$1"
  local event_name="${2:-}"
  continuous_probe_summary "$out_dir" "$event_name"

  if [[ -n "$event_name" && -f "${out_dir}/event_${event_name}" ]]; then
    log "Probes: total=${PROBE_TOTAL} 200=${PROBE_COUNT_200} 429=${PROBE_COUNT_429} 502=${PROBE_COUNT_502} other=${PROBE_COUNT_OTHER}"
    log "Before chaos: 200=${PROBE_PRE_200} 502=${PROBE_PRE_502} | During/after chaos: 200=${PROBE_POST_200} 502=${PROBE_POST_502}"
  else
    log "Probes: total=${PROBE_TOTAL} 200=${PROBE_COUNT_200} 429=${PROBE_COUNT_429} 502=${PROBE_COUNT_502} other=${PROBE_COUNT_OTHER}"
  fi
}
