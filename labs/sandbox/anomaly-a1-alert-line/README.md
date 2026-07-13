# 자기조사 샌드박스 — 새벽 접속량 저하, 경보선 긋기

얼린 **7일 관측 스냅샷**을 학생이 직접 조회하며 경보선을 설계·판단하는 실습용 로컬 스택입니다.
데이터는 익명화된 실측 스냅샷이며(라이브 서버에 연결하지 않습니다), 명령어 한 줄로 뜹니다.
7일을 통째로 실어 두어, 저하가 있던 새벽과 정상 새벽들을 같은 화면에서 대조할 수 있습니다.

## 실행

```bash
docker compose up
```

- 처음 실행 시 이미지를 내려받고, Prometheus에 지표를 백필하고, Loki에 로그를 주입합니다(자동, 수십 초).
- 뜨면 브라우저에서 **http://localhost:3000** (Grafana, 로그인 없이 열림) → 왼쪽 **Explore**.
- **데이터 창: 2026-07-06 09:00 ~ 07-13 09:00 (KST), 7일** — Grafana 시간 범위를 이 구간으로 맞추세요. 저하 구간은 **07-09 23:00 ~ 07-10 06:00 KST**(심야 코어 01:00~05:00), 정상 대비는 직전 비저하일(07-08)의 같은 심야입니다.

## 조회를 시작할 신호 (출발점일 뿐, 조합은 직접)

- 요청량: `sum(rate(http_requests_total{service="checkout-api"}[5m]))`
- 상태 코드별: `sum by (status)(rate(http_requests_total{service="checkout-api"}[5m]))` — 5xx가 늘었는지 확인
- 서비스 살아 있는지: `up{job="checkout-api"}`
- 로그: `{namespace="app"}` — 정상 `order_created`(INFO)만 있고 오류는 없습니다(요청량 자체가 줄어든 상황).

## 정지

```bash
docker compose down        # 컨테이너 정지
docker compose down -v      # 주입 데이터(볼륨)까지 삭제 후 초기화
```

## 구성

| 서비스 | 역할 |
| --- | --- |
| `prometheus-init` | `prometheus/metrics_openmetrics.txt`를 TSDB 블록으로 1회 백필 |
| `prometheus` | 백필된 스냅샷 조회(:9090) |
| `loki` | 로그 저장(:3100), 과거 타임스탬프 주입 허용 |
| `loki-loader` | `loki/logs.jsonl`을 Loki에 1회 주입 후 종료 |
| `grafana` | :3000, Prometheus·Loki 데이터소스 미리 연결, 익명 접근 |
