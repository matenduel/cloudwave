#!/usr/bin/env sh
set -eu

KIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
VALIDATE_DIR=$(mktemp -d /private/tmp/card2-kit-static.XXXXXX)

cleanup() {
  rm -rf "$VALIDATE_DIR"
}
trap cleanup EXIT INT TERM

echo "[1/5] Python, replay, metadata, exporter, dashboard JSON"
PYTHONPYCACHEPREFIX="$VALIDATE_DIR/pycache" python3 -m py_compile \
  "$KIT_DIR/k8s/bake/normalize_openmetrics.py" \
  "$KIT_DIR/k8s/platform/20-exporter/exporter.py" \
  "$KIT_DIR/scripts/generate_dashboard.py"
python3 - "$KIT_DIR" <<'PY'
import gzip, json, os, runpy, sys
from pathlib import Path
root = Path(sys.argv[1])
replay = json.loads((root / "data/card2_live_replay.json").read_text())
meta = json.loads((root / "data/card2_metric_meta.json").read_text())
assert replay["labels"] == {"cluster": "push-01", "job": "push-platform"}
assert replay["step"] == 30
assert len(replay["metrics"]) == len(meta["metrics"]) == 13
assert list(replay["metrics"]) == [item["name"] for item in meta["metrics"]]
assert {len(spec["values"]) for spec in replay["metrics"].values()} == {121}
assert "kafka_consumergroup_members" in replay["metrics"]
for path, uid in (
    (root / "grafana/dashboards/card2-student.json", "card2-prometheus"),
    (root / "k8s/platform/40-grafana/card2-student.json", "card2-prometheus"),
    (root / "k8s/overlays/integrated/platform/card2-student.json", "-- Mixed --"),
):
    dashboard = json.loads(path.read_text())
    panels = [panel for panel in dashboard["panels"] if panel["type"] == "timeseries"]
    assert len(panels) == 13
    assert all(panel["datasource"]["uid"] == uid for panel in panels)
    assert [panel["title"] for panel in panels[:3]] == [
        "kafka_consumergroup_lag",
        "kafka_consumergroup_members",
        "kube_hpa_status_current_replicas",
    ]
env = os.environ.copy()
os.environ.update(REPLAY_DATA=str(root / "data/card2_live_replay.json"), METRIC_META=str(root / "data/card2_metric_meta.json"))
module = runpy.run_path(str(root / "k8s/platform/20-exporter/exporter.py"))
payload = module["render_metrics"]().decode()
assert 'push_notifications_sent_total{cluster="push-01",job="push-platform"}' in payload
assert payload.endswith("# EOF\n")
os.environ.clear(); os.environ.update(env)
for name in ("history", "full"):
    path = root / f"k8s/bake/data/card2_bake_{name}.openmetrics.gz"
    with gzip.open(path, "rt", encoding="utf-8") as handle:
        text = handle.read()
    assert text.endswith("# EOF\n")
    assert 'cluster="push-01",job="push-platform"' in text
    by_series = {}
    for line in text.splitlines():
        if not line or line.startswith("#"):
            continue
        series, _, timestamp = line.rsplit(maxsplit=2)
        by_series.setdefault(series, []).append(int(timestamp))
    expected_points = 865 if name == "history" else 985
    assert len(by_series) == 13
    assert {len(timestamps) for timestamps in by_series.values()} == {expected_points}
    assert all(
        all(left < right for left, right in zip(timestamps, timestamps[1:]))
        for timestamps in by_series.values()
    )
problem = (root / "card2_problem.md").read_text(encoding="utf-8")
table_rows = [line for line in problem.splitlines() if line.startswith("| `")]
assert len(table_rows) == 13
assert all(
    f"| `{item['name']}` | {item['unit']} | {item['desc']} |" in table_rows
    for item in meta["metrics"]
)
framing = problem.split("## 제공 지표", 1)[0]
for leaked in ("리밸런", "HPA", "스케일아웃", "롤링 배포", "저녁 피크", "자연 피크"):
    assert leaked not in framing, leaked
assert "## 진행 방식" not in problem and "## 진행방식" not in problem
readme = (root / "README.md").read_text(encoding="utf-8")
apply_commands = [
    line.strip()
    for line in readme.splitlines()
    if line.strip().startswith("kubectl apply")
]
assert apply_commands
assert all("--server-side" in line for line in apply_commands), apply_commands
assert all("--force-conflicts" in line for line in apply_commands), apply_commands
assert all(" -k " in line for line in apply_commands), apply_commands
print("replay/meta: 13 metrics, 121 points; dashboards: 13 time-series panels; problem: 13 exact rows; gzip monotonic; server-side apply: PASS")
PY

echo "[2/5] kubectl kustomize static render"
kubectl kustomize "$KIT_DIR/k8s/overlays/integrated" > "$VALIDATE_DIR/integrated.yaml"
kubectl kustomize "$KIT_DIR/k8s/bake" > "$VALIDATE_DIR/fallback-bake.yaml"
kubectl kustomize "$KIT_DIR/k8s/platform" > "$VALIDATE_DIR/fallback-platform.yaml"
kubectl kustomize "$KIT_DIR/k8s/overlays/static-full/bake" > "$VALIDATE_DIR/static-full-bake.yaml"
kubectl kustomize "$KIT_DIR/k8s/overlays/static-full/platform" > "$VALIDATE_DIR/static-full-platform.yaml"
echo "integrated overlay render: PASS"
echo "standalone fallback bake/platform render: PASS"
echo "static-full fallback bake/platform render: PASS"

echo "[3/5] Local YAML parse"
ruby -ryaml -e '
  ARGV.each do |path|
    docs = YAML.load_stream(File.read(path)).compact
    abort("#{path}: empty YAML") if docs.empty?
    docs.each_with_index do |doc, index|
      abort("#{path}: document #{index + 1} lacks apiVersion/kind") unless doc["apiVersion"] && doc["kind"]
    end
  end
' "$KIT_DIR/k8s/namespace.yaml" "$KIT_DIR/k8s/storage.yaml" "$VALIDATE_DIR"/*.yaml
echo "all rendered YAML documents: PASS"

echo "[4/5] Integrated sidecar/ServiceMonitor contract and duplicate scan"
ruby -ryaml -rjson - "$VALIDATE_DIR/integrated.yaml" <<'RUBY'
docs = YAML.load_stream(File.read(ARGV.fetch(0))).compact
find_one = lambda do |kind, name|
  matches = docs.select { |doc| doc["kind"] == kind && doc.dig("metadata", "name") == name }
  abort("expected one #{kind}/#{name}, got #{matches.length}") unless matches.length == 1
  matches.first
end
service = find_one.call("Service", "card2-live-replay")
monitor = find_one.call("ServiceMonitor", "card2-live-replay")
abort("release label") unless monitor.dig("metadata", "labels", "release") == "monitoring"
abort("selector") unless monitor.dig("spec", "selector", "matchLabels", "app.kubernetes.io/name") == service.dig("metadata", "labels", "app.kubernetes.io/name")
endpoint = monitor.dig("spec", "endpoints", 0)
abort("endpoint") unless endpoint.values_at("port", "path") == ["metrics", "/metrics"] && endpoint["honorLabels"] == true
datasource = find_one.call("ConfigMap", "card2-baked-datasource")
dashboard = find_one.call("ConfigMap", "card2-student-dashboard")
abort("datasource label") unless datasource.dig("metadata", "labels", "grafana_datasource") == "1"
abort("dashboard label") unless dashboard.dig("metadata", "labels", "grafana_dashboard") == "1"
JSON.parse(dashboard.dig("data", "card2-student.json"))
forbidden = /grafana|alertmanager|node-exporter|kube-state-metrics/i
duplicates = docs.select { |doc| %w[DaemonSet Deployment StatefulSet Service].include?(doc["kind"]) && doc.dig("metadata", "name").to_s.match?(forbidden) }
abort("duplicate stack resources: #{duplicates.map { |doc| [doc["kind"], doc.dig("metadata", "name")] }}") unless duplicates.empty?
puts "ServiceMonitor release=monitoring; datasource/dashboard labels=1; duplicate stack workloads=0: PASS"
RUBY
if grep -Ein '^  name: .*(grafana|alertmanager|node-exporter|kube-state-metrics)' "$VALIDATE_DIR/integrated.yaml"; then
  echo "integrated overlay duplicate component grep: FAIL"
  exit 1
else
  echo "integrated overlay duplicate component grep: PASS (no matching resource names)"
fi

echo "[5/5] kubeconform"
if command -v kubeconform >/dev/null 2>&1; then
  kubeconform -strict -ignore-missing-schemas "$VALIDATE_DIR"/*.yaml
  echo "kubeconform schema validation: PASS (missing CRD schemas ignored)"
else
  echo "kubeconform schema validation: SKIP (not installed)"
fi

echo "CARD2_STATIC_VALIDATION_PASS"
