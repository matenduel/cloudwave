#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

docker compose up -d --build

deadline=$(( $(date +%s) + 180 ))
until curl -fsS http://localhost:19091/-/ready >/dev/null && \
      curl -fsS http://localhost:18081/healthz >/dev/null; do
  if (( $(date +%s) >= deadline )); then
    echo "app or Prometheus did not become ready within 180 seconds" >&2
    exit 1
  fi
  sleep 2
done

echo "Starting 5m30s baseline + 10 synchronized 30-VU CPU bursts."
docker compose --profile load run --rm k6
echo "Scenario completed. Keep the stack running to inspect Grafana."
