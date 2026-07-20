#!/usr/bin/env sh
set -eu

KIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
VALIDATE_DIR=$(mktemp -d /private/tmp/card3-kit-validate.XXXXXX)
EXPORTER_PID=""

cleanup() {
  if [ -n "$EXPORTER_PID" ]; then
    kill "$EXPORTER_PID" 2>/dev/null || true
    wait "$EXPORTER_PID" 2>/dev/null || true
  fi
  rm -rf "$VALIDATE_DIR"
}
trap cleanup EXIT INT TERM

echo "[1/6] Python syntax and dashboard structure"
PYTHONPYCACHEPREFIX="$VALIDATE_DIR/pycache" python3 -m py_compile \
  "$KIT_DIR/k8s/bake/normalize_openmetrics.py" \
  "$KIT_DIR/k8s/platform/20-exporter/exporter.py" \
  "$KIT_DIR/scripts/generate_dashboard.py"
python3 - "$KIT_DIR/k8s/platform/40-grafana/card3-student.json" <<'PY'
import json
import sys
dashboard = json.load(open(sys.argv[1], encoding="utf-8"))
timeseries = [panel for panel in dashboard["panels"] if panel["type"] == "timeseries"]
assert len(timeseries) == 14, len(timeseries)
assert all(panel["datasource"]["uid"] == "card3-prometheus" for panel in timeseries)
print("dashboard: 14 time-series panels, datasource UID card3-prometheus")
PY
python3 - "$KIT_DIR/k8s/overlays/integrated/platform/card3-student.json" <<'PY'
import json
import sys
dashboard = json.load(open(sys.argv[1], encoding="utf-8"))
timeseries = [panel for panel in dashboard["panels"] if panel["type"] == "timeseries"]
assert len(timeseries) == 14, len(timeseries)
assert all(panel["datasource"]["uid"] == "-- Mixed --" for panel in timeseries)
target_uids = {target["datasource"]["uid"] for panel in timeseries for target in panel["targets"]}
assert {"card3-baked", "${card3_live_ds}"} <= target_uids, target_uids
assert dashboard["templating"]["list"][0]["name"] == "card3_live_ds"
print("integrated dashboard: 14 Mixed panels, baked + selectable live datasources")
PY

echo "[2/6] Kustomize render (integrated, standalone, and static-full fallback)"
kubectl kustomize "$KIT_DIR/k8s/bake" > "$VALIDATE_DIR/bake.yaml"
kubectl kustomize "$KIT_DIR/k8s/platform" > "$VALIDATE_DIR/platform.yaml"
kubectl kustomize "$KIT_DIR/k8s/overlays/static-full/bake" > "$VALIDATE_DIR/fallback-bake.yaml"
kubectl kustomize "$KIT_DIR/k8s/overlays/static-full/platform" > "$VALIDATE_DIR/fallback-platform.yaml"
kubectl kustomize "$KIT_DIR/k8s/overlays/integrated" > "$VALIDATE_DIR/integrated.yaml"
ruby -ryaml -e '
  ARGV.each do |path|
    docs = YAML.load_stream(File.read(path)).compact
    abort("#{path}: empty YAML") if docs.empty?
    docs.each_with_index do |doc, index|
      abort("#{path}: document #{index + 1} lacks apiVersion/kind") unless doc["apiVersion"] && doc["kind"]
    end
  end
' "$KIT_DIR/k8s/namespace.yaml" "$KIT_DIR/k8s/storage.yaml" \
  "$VALIDATE_DIR/bake.yaml" "$VALIDATE_DIR/platform.yaml" \
  "$VALIDATE_DIR/fallback-bake.yaml" "$VALIDATE_DIR/fallback-platform.yaml" \
  "$VALIDATE_DIR/integrated.yaml"
echo "kustomize render + local YAML parse: PASS"

ruby -ryaml -rjson - "$VALIDATE_DIR/integrated.yaml" <<'RUBY'
docs = YAML.load_stream(File.read(ARGV.fetch(0))).compact
find_one = lambda do |kind, name|
  matches = docs.select { |doc| doc["kind"] == kind && doc.dig("metadata", "name") == name }
  abort("expected exactly one #{kind}/#{name}, got #{matches.length}") unless matches.length == 1
  matches.first
end

service = find_one.call("Service", "card3-live-replay")
monitor = find_one.call("ServiceMonitor", "card3-live-replay")
abort("ServiceMonitor missing release=monitoring") unless monitor.dig("metadata", "labels", "release") == "monitoring"
abort("ServiceMonitor selector mismatch") unless monitor.dig("spec", "selector", "matchLabels") == service.dig("metadata", "labels").slice("app.kubernetes.io/name")
endpoint = monitor.fetch("spec").fetch("endpoints").fetch(0)
abort("ServiceMonitor endpoint mismatch") unless endpoint.values_at("port", "path") == ["metrics", "/metrics"]

datasource = find_one.call("ConfigMap", "card3-baked-datasource")
dashboard = find_one.call("ConfigMap", "card3-student-dashboard")
abort("datasource sidecar label missing") unless datasource.dig("metadata", "labels", "grafana_datasource") == "1"
abort("dashboard sidecar label missing") unless dashboard.dig("metadata", "labels", "grafana_dashboard") == "1"
JSON.parse(dashboard.fetch("data").fetch("card3-student.json"))

forbidden = /grafana|alertmanager|node-exporter|kube-state-metrics/i
duplicates = docs.select do |doc|
  %w[DaemonSet Deployment StatefulSet Service].include?(doc["kind"]) &&
    doc.dig("metadata", "name").to_s.match?(forbidden)
end
abort("integrated overlay deploys duplicate stack resources: #{duplicates.map { |doc| [doc["kind"], doc.dig("metadata", "name")] }}") unless duplicates.empty?
puts "integrated contract: ServiceMonitor/Service + sidecar labels + no duplicate stack workloads: PASS"
RUBY

if command -v kubeconform >/dev/null 2>&1; then
  kubeconform -strict -ignore-missing-schemas "$VALIDATE_DIR/integrated.yaml"
  echo "kubeconform integrated schema validation: PASS (CRD schemas ignored when unavailable)"
else
  echo "kubeconform integrated schema validation: SKIP (not installed)"
fi

echo "[3/6] Prometheus configuration"
docker run --rm --entrypoint /bin/promtool \
  -v "$KIT_DIR/k8s/platform/10-prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro" \
  prom/prometheus:v3.13.1 check config /etc/prometheus/prometheus.yml

echo "[4/6] Normalize history and create TSDB blocks"
mkdir -p "$VALIDATE_DIR/tsdb"
SOURCE_PATH="$KIT_DIR/k8s/bake/data/card3_bake_history.openmetrics.gz" \
OUTPUT_PATH="$VALIDATE_DIR/normalized.openmetrics" \
TSDB_PATH="$VALIDATE_DIR/tsdb" \
BAKE_LAG_STEPS=1 \
python3 "$KIT_DIR/k8s/bake/normalize_openmetrics.py"
docker run --rm --entrypoint /bin/promtool \
  -v "$VALIDATE_DIR:/validation" \
  prom/prometheus:v3.13.1 \
  tsdb create-blocks-from openmetrics /validation/normalized.openmetrics /validation/tsdb
BLOCK_COUNT=$(find "$VALIDATE_DIR/tsdb" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
test "$BLOCK_COUNT" -gt 0
echo "promtool blocks: $BLOCK_COUNT"

echo "[5/6] Exporter HTTP on localhost:18080"
REPLAY_DATA="$KIT_DIR/k8s/platform/20-exporter/card3_live_replay.json" \
METRIC_META="$KIT_DIR/k8s/platform/20-exporter/card3_metric_meta.json" \
LISTEN_HOST=127.0.0.1 LISTEN_PORT=18080 \
python3 "$KIT_DIR/k8s/platform/20-exporter/exporter.py" >"$VALIDATE_DIR/exporter.log" 2>&1 &
EXPORTER_PID=$!
attempt=0
until curl --fail --silent http://127.0.0.1:18080/healthz >"$VALIDATE_DIR/healthz"; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 20 ]; then
    cat "$VALIDATE_DIR/exporter.log"
    exit 1
  fi
  sleep 0.25
done
curl --fail --silent --show-error http://127.0.0.1:18080/metrics >"$VALIDATE_DIR/metrics"
grep -q '^spark_executor_activeTasks{cluster="dw-01",job="dw-platform"}' "$VALIDATE_DIR/metrics"
grep -q '^kube_pod_container_status_restarts_total{cluster="dw-01",job="dw-platform"}' "$VALIDATE_DIR/metrics"
grep -q '^# EOF$' "$VALIDATE_DIR/metrics"
TYPE_COUNT=$(grep -c '^# TYPE ' "$VALIDATE_DIR/metrics")
test "$TYPE_COUNT" -eq 16
echo "exporter curl: HTTP 200, 14 scenario metrics + 2 exporter self-metrics"

echo "[6/6] Exporter exposition parse"
set +e
docker run --rm -i --entrypoint /bin/promtool prom/prometheus:v3.13.1 check metrics \
  <"$VALIDATE_DIR/metrics" >"$VALIDATE_DIR/metric-lint" 2>&1
LINT_STATUS=$?
set -e
if [ "$LINT_STATUS" -eq 0 ]; then
  echo "promtool exposition parse/lint: PASS"
elif [ "$LINT_STATUS" -eq 3 ] \
  && [ "$(wc -l <"$VALIDATE_DIR/metric-lint" | tr -d ' ')" -eq 4 ] \
  && grep -q '^dataset_freshness_lag_minutes use base unit "seconds" instead of "minutes"$' "$VALIDATE_DIR/metric-lint" \
  && grep -q '^spark_executor_activeTasks metric names should be written in.*snake_case' "$VALIDATE_DIR/metric-lint" \
  && grep -q '^spark_stage_shuffleReadBytes_rate metric names should be written in.*snake_case' "$VALIDATE_DIR/metric-lint" \
  && grep -q '^trino_query_wallTime_p95_seconds metric names should be written in.*snake_case' "$VALIDATE_DIR/metric-lint"; then
  echo "promtool exposition parse: PASS; expected source-name lint warnings:"
  sed 's/^/  - /' "$VALIDATE_DIR/metric-lint"
else
  cat "$VALIDATE_DIR/metric-lint"
  exit "$LINT_STATUS"
fi

echo "CARD3_LOCAL_VALIDATION_PASS"
