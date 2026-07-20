#!/usr/bin/env python3
"""Generate the Card 2 student Grafana dashboards from metric metadata."""

from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
META_PATH = ROOT / "data" / "card2_metric_meta.json"
OUTPUTS = (
    ROOT / "grafana" / "dashboards" / "card2-student.json",
    ROOT / "k8s" / "platform" / "40-grafana" / "card2-student.json",
)
INTEGRATED_OUTPUT = ROOT / "k8s" / "overlays" / "integrated" / "platform" / "card2-student.json"
STANDALONE_DATASOURCE = {"type": "prometheus", "uid": "card2-prometheus"}
BAKED_DATASOURCE = {"type": "prometheus", "uid": "card2-baked"}
LIVE_DATASOURCE = {"type": "prometheus", "uid": "${card2_live_ds}"}
MIXED_DATASOURCE = {"type": "datasource", "uid": "-- Mixed --"}

GROUPS = (
    (
        "Consumer 처리 상태",
        (
            "kafka_consumergroup_lag",
            "kafka_consumergroup_members",
            "kube_hpa_status_current_replicas",
        ),
    ),
    (
        "캠페인과 브로커 흐름",
        (
            "push_notifications_sent_total",
            "kafka_server_BrokerTopicMetrics_MessagesInPerSec",
            "campaign_backlog_messages",
        ),
    ),
    (
        "앱 유입과 전달 품질",
        (
            "http_requests_total",
            "http_request_duration_seconds",
            "notification_delivery_success_ratio",
        ),
    ),
    (
        "스케일링과 배포 상태",
        (
            "kube_pod_container_status_restarts_total",
            "kube_deployment_status_replicas_updated",
        ),
    ),
    (
        "사용자 반응",
        (
            "daily_active_users",
            "unsubscribe_total",
        ),
    ),
)

UNITS = {
    "msg/s": "ops",
    "messages": "short",
    "req/s": "reqps",
    "s": "s",
    "ratio": "percentunit",
    "pods": "short",
    "consumers": "short",
    "count": "short",
    "users": "short",
}


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
    scenario_expr = f'{name}{{cluster="push-01",job="push-platform"}}'
    if integrated:
        targets = [
            target(scenario_expr, "과거 bake · push-01", "A", BAKED_DATASOURCE),
            target(scenario_expr, "라이브 replay · push-01", "B", LIVE_DATASOURCE),
        ]
        infrastructure_ref = "C"
        infrastructure_datasource = LIVE_DATASOURCE
        infrastructure_namespace = "demo"
        infrastructure_deployment_match = ""
        panel_datasource = MIXED_DATASOURCE
    else:
        targets = [target(scenario_expr, "시나리오 · push-01", "A", STANDALONE_DATASOURCE)]
        infrastructure_ref = "B"
        infrastructure_datasource = STANDALONE_DATASOURCE
        infrastructure_namespace = "push-lab"
        infrastructure_deployment_match = ',deployment=~"card2-.*"'
        panel_datasource = STANDALONE_DATASOURCE
    if name == "kube_pod_container_status_restarts_total":
        targets.append(
            target(
                'sum by (namespace, pod, container) '
                f'(kube_pod_container_status_restarts_total{{job="kube-state-metrics",namespace="{infrastructure_namespace}"}})',
                "실제 EKS · {{pod}}/{{container}}",
                infrastructure_ref,
                infrastructure_datasource,
            )
        )
    elif name == "kube_deployment_status_replicas_updated":
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
    if len(metrics) != 13 or set(expected) != set(metrics):
        raise SystemExit("dashboard groups must contain each of the 13 metadata metrics exactly once")

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
    description = "카드2 푸시 알림 메시징 관측 실습 학생용 대시보드"
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
                    "name": "card2_live_ds",
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
        "tags": ["card2", "push", "student"],
        "templating": templating,
        "time": {"from": "now-4d", "to": "now"},
        "timepicker": {"refresh_intervals": ["10s", "30s", "1m", "5m"]},
        "timezone": "browser",
        "title": "카드2 · 푸시 알림 이상 분석",
        "uid": "card2-push-student",
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
