#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

compose() {
  docker compose "$@"
}

wait_for_prometheus() {
  local deadline=$(( $(date +%s) + 120 ))

  until curl -fsS http://localhost:19090/-/ready >/dev/null; do
    if (( $(date +%s) >= deadline )); then
      echo "Prometheus did not become ready within 120 seconds." >&2
      exit 1
    fi
    sleep 2
  done
}

wait_for_consumer_lag_series() {
  local deadline=$(( $(date +%s) + 60 ))
  local metrics

  while true; do
    metrics="$(curl -fsS http://localhost:9308/metrics 2>/dev/null || true)"
    if grep -q '^kafka_consumergroup_lag{' <<<"$metrics"; then
      return 0
    fi

    if (( $(date +%s) >= deadline )); then
      echo "kafka_consumergroup_lag did not appear within 60 seconds." >&2
      exit 1
    fi
    sleep 2
  done
}

post_control() {
  curl -fsS -X POST http://localhost:18001/control \
    -H 'content-type: application/json' \
    -d "$1" >/dev/null
}

compose up -d --build

wait_for_prometheus
wait_for_consumer_lag_series

T_START="$(date +%s)"
echo "T_START=${T_START}"

sleep 240

post_control '{"extra_delay_ms":40,"writes_per_record":8,"sink_write_bytes":8192}'
T_FAULT="$(date +%s)"
echo "T_FAULT=${T_FAULT}"

sleep 600

post_control '{"extra_delay_ms":0,"writes_per_record":1,"sink_write_bytes":1024}'
T_RECOVERY="$(date +%s)"
echo "T_RECOVERY=${T_RECOVERY}"

sleep 300

T_END="$(date +%s)"
echo "T_END=${T_END}"
