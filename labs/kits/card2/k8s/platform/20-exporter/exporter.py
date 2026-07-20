#!/usr/bin/env python3
"""Dependency-free OpenMetrics live replay exporter for Card 2."""

from __future__ import annotations

import json
import math
import os
import re
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


SERIES_RE = re.compile(r"^([a-zA-Z_:][a-zA-Z0-9_:]*)(?:\{(.*)\})?$")
LABEL_SET_RE = re.compile(
    r'\s*[a-zA-Z_][a-zA-Z0-9_]*="(?:\\.|[^"\\])*"'
    r'(?:\s*,\s*[a-zA-Z_][a-zA-Z0-9_]*="(?:\\.|[^"\\])*")*\s*'
)
STARTED_MONOTONIC = time.monotonic()


def escape_label(value: object) -> str:
    return str(value).replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


def escape_help(value: object) -> str:
    return str(value).replace("\\", "\\\\").replace("\n", "\\n")


def series_parts(expression: str) -> tuple[str, str]:
    match = SERIES_RE.fullmatch(expression)
    if not match:
        raise ValueError(f"invalid metric expression: {expression}")
    labels = match.group(2) or ""
    if labels and not LABEL_SET_RE.fullmatch(labels):
        raise ValueError(f"invalid label selector: {expression}")
    return match.group(1), labels.strip()


def load_inputs() -> tuple[dict, dict[str, str]]:
    data_path = Path(os.environ.get("REPLAY_DATA", "/data/card2_live_replay.json"))
    meta_path = Path(os.environ.get("METRIC_META", "/data/card2_metric_meta.json"))
    data = json.loads(data_path.read_text(encoding="utf-8"))
    meta = json.loads(meta_path.read_text(encoding="utf-8"))
    descriptions = {item["name"]: item["desc"] for item in meta["metrics"]}

    if not isinstance(data.get("step"), (int, float)) or data["step"] <= 0:
        raise ValueError("step must be a positive number")
    if not isinstance(data.get("labels"), dict) or not data["labels"]:
        raise ValueError("labels must be a non-empty object")
    lengths = set()
    family_types: dict[str, str] = {}
    for name, spec in data.get("metrics", {}).items():
        family, _ = series_parts(name)
        if spec.get("type") not in {"gauge", "counter"}:
            raise ValueError(f"unsupported metric type for {name}: {spec.get('type')}")
        previous_type = family_types.setdefault(family, spec["type"])
        if previous_type != spec["type"]:
            raise ValueError(f"metric family {family} has conflicting types")
        values = spec.get("values")
        if not isinstance(values, list) or not values:
            raise ValueError(f"values must be a non-empty list for {name}")
        if any(not isinstance(value, (int, float)) or not math.isfinite(value) for value in values):
            raise ValueError(f"all values must be finite numbers for {name}")
        lengths.add(len(values))
    if len(lengths) != 1:
        raise ValueError("all metric arrays must have the same length")
    return data, descriptions


DATA, DESCRIPTIONS = load_inputs()
MODE = os.environ.get("REPLAY_MODE", "hold").lower()
if MODE not in {"hold", "loop"}:
    raise ValueError("REPLAY_MODE must be hold or loop")


def replay_position(elapsed: float, count: int, step: float) -> tuple[int, int]:
    last_index = count - 1
    if MODE == "hold":
        return min(int(elapsed // step), last_index), 0
    period = max(step * last_index, step)
    cycle = int(elapsed // period)
    within_cycle = elapsed - cycle * period
    return min(int(within_cycle // step), last_index), cycle


def render_metrics() -> bytes:
    elapsed = max(0.0, time.monotonic() - STARTED_MONOTONIC)
    common_labels = ",".join(
        f'{key}="{escape_label(value)}"' for key, value in sorted(DATA["labels"].items())
    )
    count = len(next(iter(DATA["metrics"].values()))["values"])
    index, cycle = replay_position(elapsed, count, float(DATA["step"]))
    lines: list[str] = []
    emitted_families: set[str] = set()
    for expression, spec in DATA["metrics"].items():
        name, selector_labels = series_parts(expression)
        metric_type = spec["type"]
        value = float(spec["values"][index])
        if MODE == "loop" and metric_type == "counter":
            first = float(spec["values"][0])
            last = float(spec["values"][-1])
            value += cycle * max(last - first, 0.0)
        if name not in emitted_families:
            lines.append(f"# HELP {name} {escape_help(DESCRIPTIONS.get(expression, name))}")
            lines.append(f"# TYPE {name} {metric_type}")
            emitted_families.add(name)
        labels = ",".join(part for part in (selector_labels, common_labels) if part)
        lines.append(f"{name}{{{labels}}} {value:g}")
    lines.extend(
        (
            "# HELP card2_replay_elapsed_seconds Seconds elapsed since this exporter process started.",
            "# TYPE card2_replay_elapsed_seconds gauge",
            f"card2_replay_elapsed_seconds {elapsed:.3f}",
            "# HELP card2_replay_index Current zero-based replay data index.",
            "# TYPE card2_replay_index gauge",
            f"card2_replay_index {index}",
            "# EOF",
        )
    )
    return ("\n".join(lines) + "\n").encode("utf-8")


class Handler(BaseHTTPRequestHandler):
    server_version = "card2-live-replay/1.0"

    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/metrics":
            payload = render_metrics()
            self.send_response(200)
            self.send_header("Content-Type", "application/openmetrics-text; version=1.0.0; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if self.path == "/healthz":
            payload = b"ok\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        self.send_error(404)

    def log_message(self, format_string: str, *args: object) -> None:
        print(f"{self.address_string()} - {format_string % args}", flush=True)


def main() -> None:
    host = os.environ.get("LISTEN_HOST", "0.0.0.0")
    port = int(os.environ.get("LISTEN_PORT", "8080"))
    server = ThreadingHTTPServer((host, port), Handler)
    print(
        f"card2 live replay listening on {host}:{port}; mode={MODE}; "
        f"step={DATA['step']}s metrics={len(DATA['metrics'])}",
        flush=True,
    )
    server.serve_forever()


if __name__ == "__main__":
    main()
