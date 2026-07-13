# 자기조사 샌드박스 — 점점 나빠지는 결제 지연 (PG 타임아웃 램프)

얼린 **10시간 관측 스냅샷**을 학생이 직접 조회하며 가설을 세우고 판단하는 실습용 로컬 스택입니다.
데이터는 익명화된 실측 스냅샷이며(라이브 서버에 연결하지 않습니다), 명령어 한 줄로 뜹니다.

## 실행

```bash
docker compose up
```

- 처음 실행 시 이미지를 내려받고, Prometheus에 지표를 백필하고, Loki에 로그를 주입합니다(자동, 수십 초).
- 뜨면 브라우저에서 **http://localhost:3000** (Grafana, 로그인 없이 열림) → 왼쪽 **Explore**.
  - **Prometheus** 데이터소스: PromQL로 지표 조회
  - **Loki** 데이터소스: LogQL로 로그 조회
- **데이터 창: 2026-07-10 11:00 ~ 21:00 (KST)** — Grafana 오른쪽 위 시간 범위를 이 구간으로 맞추세요(그 밖 구간은 비어 있습니다). 발화 구간은 **15:00 ~ 18:00 KST**입니다.

## 조회를 시작할 신호 (출발점일 뿐, 조합은 직접)

- checkout-api p95 지연: `histogram_quantile(0.95, sum by (le)(rate(http_request_duration_seconds_bucket{service="checkout-api"}[5m])))`
- checkout-api 5xx율: `sum(rate(http_requests_total{service="checkout-api",status=~"5.."}[5m]))`
- checkout-api 요청량: `sum(rate(http_requests_total{service="checkout-api"}[5m]))`
- 하류(payment-service)도 같은 지표가 있습니다: `service="payment-service"`로 바꿔 대조해 보세요.
- 로그: `{namespace="app"}` — 정상 `order_created`(INFO)에 결제 실패 이벤트가 섞입니다. `{namespace="app"} | json | level="ERROR"`로 걸러 보세요.

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
