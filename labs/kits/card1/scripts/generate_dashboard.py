#!/usr/bin/env python3
"""Generate the Card 1 student Grafana dashboards from metric metadata."""

from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
META_PATH = ROOT / "data" / "card1_metric_meta.json"
OUTPUTS = (
    ROOT / "grafana" / "dashboards" / "card1-student.json",
    ROOT / "k8s" / "platform" / "40-grafana" / "card1-student.json",
)
INTEGRATED_OUTPUT = ROOT / "k8s" / "overlays" / "integrated" / "platform" / "card1-student.json"
STANDALONE_DATASOURCE = {"type": "prometheus", "uid": "card1-prometheus"}
BAKED_DATASOURCE = {"type": "prometheus", "uid": "card1-baked"}
LIVE_DATASOURCE = {"type": "prometheus", "uid": "${card1_live_ds}"}
MIXED_DATASOURCE = {"type": "datasource", "uid": "-- Mixed --"}

GROUPS = (
    (
        "트래픽과 결제 처리량",
        (
            'http_requests_total{route="/static"}',
            'http_requests_total{route="/api/catalog"}',
            'http_requests_total{route="/checkout"}',
            'http_requests_total{route="/checkout",status="5xx"}',
            'payment_transactions_total{result="success"}',
            'payment_transactions_total{result="fail"}',
        ),
    ),
    (
        "결제 품질과 병목",
        (
            "commerce_payment_failure_ratio_1m",
            "commerce_checkout_conversion_ratio_5m",
            'container_cpu_usage_seconds_total{namespace="demo",container="loadapp"}',
            'container_cpu_cfs_throttled_ratio_5m{container="loadapp"}',
            "commerce_payment_pending_requests",
            'http_request_duration_seconds{route="/checkout",stat="p95"}',
        ),
    ),
    (
        "스케일링과 배포 상태",
        (
            'kube_hpa_status_current_replicas{hpa="payment"}',
            'kube_hpa_status_current_replicas{hpa="web"}',
            'kube_pod_container_status_restarts_total{container="loadapp"}',
            'kube_deployment_status_replicas_updated{deployment="payment"}',
        ),
    ),
    (
        "커머스 보조 신호",
        (
            "commerce_cdn_cache_hit_ratio_5m",
            "commerce_fraud_reject_ratio_5m",
            "commerce_inventory_sync_items_total",
            "commerce_sale_inventory_available_units",
            "commerce_settlement_pending_transactions",
        ),
    ),
)

UNITS = {
    "req/s": "reqps",
    "tx/s": "ops",
    "ratio": "percentunit",
    "cores": "cores",
    "requests": "short",
    "s": "s",
    "pods": "short",
    "count": "short",
    "items/s": "ops",
    "units": "short",
    "transactions": "short",
}


def scenario_expression(expression: str) -> str:
    labels = 'cluster="commerce-01",job="commerce-platform"'
    if expression.endswith("}"):
        return f"{expression[:-1]},{labels}}}"
    return f"{expression}{{{labels}}}"


def target(expr: str, legend: str, ref_id: str, datasource: dict) -> dict:
    return {
        "datasource": datasource,
        "editorMode": "code",
        "expr": expr,
        "legendFormat": legend,
        "range": True,
        "refId": ref_id,
    }


def make_panel(metric: dict, panel_id: int, x: int, y: int, integrated: bool) -> dict:
    name = metric["name"]
    scenario_expr = scenario_expression(name)
    if integrated:
        targets = [
            target(scenario_expr, "과거 bake · commerce-01", "A", BAKED_DATASOURCE),
            target(scenario_expr, "라이브 replay · commerce-01", "B", LIVE_DATASOURCE),
        ]
        infrastructure_ref = "C"
        infrastructure_datasource = LIVE_DATASOURCE
        infrastructure_namespace = "demo"
        infrastructure_deployment_match = ""
        panel_datasource = MIXED_DATASOURCE
    else:
        targets = [target(scenario_expr, "시나리오 · commerce-01", "A", STANDALONE_DATASOURCE)]
        infrastructure_ref = "B"
        infrastructure_datasource = STANDALONE_DATASOURCE
        infrastructure_namespace = "commerce-lab"
        infrastructure_deployment_match = ',deployment=~"card1-.*"'
        panel_datasource = STANDALONE_DATASOURCE
    if name.startswith("kube_pod_container_status_restarts_total"):
        targets.append(
            target(
                'sum by (namespace, pod, container) '
                f'(kube_pod_container_status_restarts_total{{job="kube-state-metrics",namespace="{infrastructure_namespace}"}})',
                "실제 EKS · {{pod}}/{{container}}",
                infrastructure_ref,
                infrastructure_datasource,
            )
        )
    elif name.startswith("kube_deployment_status_replicas_updated"):
        targets.append(
            target(
                f'kube_deployment_status_replicas_updated{{job="kube-state-metrics",'
                f'namespace="{infrastructure_namespace}"{infrastructure_deployment_match}}}',
                "실제 EKS · {{deployment}}",
                infrastructure_ref,
                infrastructure_datasource,
            )
        )
    return {
        "id": panel_id,
        "type": "timeseries",
        "title": name,
        "description": f"단위: {metric['unit']}\n\n{metric['desc']}",
        "datasource": panel_datasource,
        "gridPos": {"h": 8, "w": 12, "x": x, "y": y},
        "fieldConfig": {
            "defaults": {
                "color": {"mode": "palette-classic"},
                "custom": {
                    "axisCenteredZero": False,
                    "axisColorMode": "text",
                    "axisLabel": metric["unit"],
                    "axisPlacement": "auto",
                    "drawStyle": "line",
                    "fillOpacity": 10,
                    "gradientMode": "none",
                    "hideFrom": {"legend": False, "tooltip": False, "viz": False},
                    "lineInterpolation": "linear",
                    "lineWidth": 1,
                    "pointSize": 3,
                    "scaleDistribution": {"type": "linear"},
                    "showPoints": "never",
                    "spanNulls": False,
                    "stacking": {"group": "A", "mode": "none"},
                    "thresholdsStyle": {"mode": "off"},
                },
                "mappings": [],
                "thresholds": {
                    "mode": "absolute",
                    "steps": [{"color": "green", "value": None}],
                },
                "unit": UNITS[metric["unit"]],
                "min": 0 if metric["unit"] == "ratio" else None,
                "max": 1 if metric["unit"] == "ratio" else None,
            },
            "overrides": [],
        },
        "options": {
            "legend": {"calcs": ["lastNotNull"], "displayMode": "list", "placement": "bottom", "showLegend": True},
            "tooltip": {"hideZeros": False, "mode": "multi", "sort": "none"},
        },
        "targets": targets,
    }


def make_dashboard(source: dict, integrated: bool) -> dict:
    metrics = {item["name"]: item for item in source["metrics"]}
    expected = [name for _, names in GROUPS for name in names]
    if len(metrics) != 21 or set(expected) != set(metrics):
        raise SystemExit("dashboard groups must contain each of the 21 metadata metrics exactly once")

    panels: list[dict] = []
    panel_id = 1
    y = 0
    for group_title, names in GROUPS:
        panels.append(
            {
                "id": panel_id,
                "type": "row",
                "title": group_title,
                "collapsed": False,
                "gridPos": {"h": 1, "w": 24, "x": 0, "y": y},
                "panels": [],
            }
        )
        panel_id += 1
        y += 1
        for offset, name in enumerate(names):
            x = 0 if offset % 2 == 0 else 12
            panel_y = y + (offset // 2) * 8
            panels.append(make_panel(metrics[name], panel_id, x, panel_y, integrated))
            panel_id += 1
        y += ((len(names) + 1) // 2) * 8

    templating = {"list": []}
    description = "카드1 결제·커머스 관측 실습 학생용 대시보드"
    if integrated:
        description += " (기존 kube-prometheus-stack 통합)"
        templating = {
            "list": [
                {
                    "current": {"selected": True, "text": "Prometheus", "value": "prometheus"},
                    "hide": 0,
                    "includeAll": False,
                    "label": "라이브 Prometheus",
                    "multi": False,
                    "name": "card1_live_ds",
                    "options": [],
                    "query": "prometheus",
                    "refresh": 1,
                    "regex": "",
                    "skipUrlSync": False,
                    "type": "datasource",
                }
            ]
        }
    return {
        "annotations": {"list": []},
        "description": description,
        "editable": False,
        "fiscalYearStartMonth": 0,
        "graphTooltip": 1,
        "id": None,
        "links": [],
        "liveNow": True,
        "panels": panels,
        "refresh": "10s",
        "schemaVersion": 41,
        "tags": ["card1", "commerce", "student"],
        "templating": templating,
        "time": {"from": "now-4d", "to": "now"},
        "timepicker": {"refresh_intervals": ["10s", "30s", "1m", "5m"]},
        "timezone": "browser",
        "title": "카드1 · 결제·커머스 이상 분석",
        "uid": "card1-commerce-student",
        "version": 1,
        "weekStart": "monday",
    }


def main() -> None:
    source = json.loads(META_PATH.read_text(encoding="utf-8"))
    payload = json.dumps(make_dashboard(source, integrated=False), ensure_ascii=False, indent=2) + "\n"
    for output in OUTPUTS:
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(payload, encoding="utf-8")
        print(output)
    integrated_payload = json.dumps(make_dashboard(source, integrated=True), ensure_ascii=False, indent=2) + "\n"
    INTEGRATED_OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    INTEGRATED_OUTPUT.write_text(integrated_payload, encoding="utf-8")
    print(INTEGRATED_OUTPUT)


if __name__ == "__main__":
    main()
