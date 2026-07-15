#!/usr/bin/env python3
"""실행 중인 CFS lab의 Prometheus/Loki 원본을 baked 입력 파일로 동결한다."""
import datetime as dt
import json
import subprocess
import sys
import urllib.parse
import urllib.request
from pathlib import Path

PROMETHEUS = "http://localhost:19091/api/v1/query_range"
PROJECT = 'container_label_com_docker_compose_project="cfs-throttling"'
APP = PROJECT + ',container_label_com_docker_compose_service="app"'
TARGET = Path(__file__).resolve().parents[2] / "cfs-throttling-baked"

TYPES = {
    "http_request_duration_seconds_bucket": "histogram",
    "http_request_duration_seconds_sum": "histogram",
    "http_request_duration_seconds_count": "histogram",
    "http_requests_total": "counter",
    "container_cpu_cfs_throttled_seconds_total": "counter",
    "container_cpu_cfs_periods_total": "counter",
    "container_cpu_usage_seconds_total": "counter",
    "container_memory_usage_bytes": "gauge",
}

QUERIES = [
    ("http_request_duration_seconds_bucket", "http_request_duration_seconds_bucket"),
    ("http_request_duration_seconds_sum", "http_request_duration_seconds_sum"),
    ("http_request_duration_seconds_count", "http_request_duration_seconds_count"),
    ("http_requests_total", "http_requests_total"),
    ("container_cpu_cfs_throttled_seconds_total", f"container_cpu_cfs_throttled_seconds_total{{{APP}}}"),
    ("container_cpu_cfs_periods_total", f"container_cpu_cfs_periods_total{{{APP}}}"),
    ("container_cpu_usage_seconds_total", f"container_cpu_usage_seconds_total{{{APP},cpu=\"total\"}}"),
    ("container_memory_usage_bytes", f"container_memory_usage_bytes{{{APP}}}"),
]


def get_matrix(query, start, end):
    url = PROMETHEUS + "?" + urllib.parse.urlencode({"query": query, "start": start, "end": end, "step": "2s"})
    with urllib.request.urlopen(url, timeout=60) as response:
        body = json.load(response)
    if body.get("status") != "success":
        raise RuntimeError(body)
    return body["data"]["result"]


def labels(metric, name):
    # App histogram labels are already compact. cAdvisor's Docker Desktop labels
    # contain local paths and image digests, so retain only the truthful identity.
    if name.startswith("container_"):
        return {"container": "app"}
    return {key: value for key, value in metric.items() if key != "__name__"}


def render_labels(values):
    if not values:
        return ""
    def quote(value):
        return value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
    return "{" + ",".join(f'{key}="{quote(value)}"' for key, value in sorted(values.items())) + "}"


def as_openmetrics(start, end, anchor):
    output = []
    emitted_types = set()
    for name, query in QUERIES:
        if name not in emitted_types:
            output.append(f"# TYPE {name} {TYPES[name]}")
            emitted_types.add(name)
        for series in get_matrix(query, start, end):
            encoded_labels = render_labels(labels(series["metric"], name))
            for timestamp, value in series["values"]:
                shifted = int(anchor + float(timestamp) - start)
                output.append(f"{name}{encoded_labels} {value} {shifted}")
    output.append("# EOF")
    return "\n".join(output) + "\n"


def as_logs(start, end, anchor):
    raw = subprocess.check_output(
        ["docker", "run", "--rm", "-v", "cfs-throttling_app_logs:/logs:ro", "alpine:3.20", "cat", "/logs/app.jsonl"],
        text=True,
    )
    result = []
    for raw_line in raw.splitlines():
        event = json.loads(raw_line)
        raw_timestamp = event["ts"].replace("Z", "+00:00")
        # Python's stdlib accepts microseconds (six digits), while Go's
        # RFC3339Nano log timestamps can carry nine.
        if "." in raw_timestamp:
            head, tail = raw_timestamp.split(".", 1)
            fraction, separator, offset = tail.partition("+")
            if not separator:
                fraction, separator, offset = tail.partition("-")
            raw_timestamp = head + "." + fraction[:6].ljust(6, "0") + separator + offset
        moment = dt.datetime.fromisoformat(raw_timestamp).timestamp()
        if not start <= moment <= end:
            continue
        shifted = anchor + moment - start
        event["ts"] = dt.datetime.fromtimestamp(shifted, dt.timezone.utc).isoformat().replace("+00:00", "Z")
        result.append(json.dumps({"ts": int(shifted * 1_000_000_000), "container": "app", "line": json.dumps(event, separators=(",", ":"))}, separators=(",", ":")))
    return "\n".join(result) + "\n"


if __name__ == "__main__":
    # Usage: capture-baked.py <live-start-unix> <live-end-unix> <anchor-unix>.
    start, end, anchor = map(float, sys.argv[1:4])
    (TARGET / "prometheus" / "metrics_openmetrics.txt").write_text(as_openmetrics(start, end, anchor))
    (TARGET / "loki" / "logs.jsonl").write_text(as_logs(start, end, anchor))
