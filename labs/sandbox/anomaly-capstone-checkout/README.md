# 자기조사 샌드박스 — 캡스톤: 결제 플로우 다서비스 스냅샷

실제 클러스터에서 캡처해 얼린 **약 3.6일치 다서비스 관측 스냅샷**을 학생이 직접 조회하며
이상 여부를 판단하는 실습용 로컬 스택입니다. 라이브 서버에 연결하지 않으며, 명령어 한 줄로 뜹니다.

대상 시스템은 주문·결제 플로우입니다:
`checkout-api`(주문 접수) → `payment-service`(결제 처리) → `external-pg`(외부 결제 게이트웨이),
그리고 배치 처리를 하는 `order-worker`, 트래픽을 만드는 `cloudwave-loadgen`이 함께 돕니다.

## 실행

```bash
docker compose up
```

- 처음 실행 시 이미지를 내려받고, Prometheus에 지표를 백필하고(압축 해제 임시로 약 1.1GB 디스크 사용, 완료 후 정리), Loki에 로그를 주입합니다(자동, 수 분).
- `loki-loader ... pushed ... log lines` / `prometheus-init ... INIT_DONE` 로그가 완료 신호입니다. 로그 주입 완료 후 1~2분 뒤부터 전 구간 조회가 안정됩니다.
- 뜨면 브라우저에서 **http://localhost:3000** (Grafana, 로그인 없이 열림) → 왼쪽 **Explore**.
- **데이터 창: 2026-07-09 10:00 ~ 2026-07-13 00:00 (KST)** — Grafana 시간 범위를 이 구간으로 맞추세요.

## 조회를 시작할 신호 (출발점일 뿐, 조합은 직접)

- 요청량: `sum(rate(http_requests_total{service="checkout-api"}[5m]))`
- 상태 코드별: `sum by (status)(rate(http_requests_total{service="checkout-api"}[5m]))`
- 지연 분포: `histogram_quantile(0.95, sum by (le)(rate(http_request_duration_seconds_bucket{service="payment-service"}[5m])))`
- 타깃 상태: `up{namespace="app"}`
- 컨테이너 자원: `container_memory_working_set_bytes{namespace="app"}` 등 `container_*`
- 로그: `{namespace="app"}` — 서비스별로는 `{namespace="app", service="checkout-api"}` 처럼 좁히기

무엇이 언제 이상이었는지는 스스로 조회해 판단합니다. 지표·로그를 오가며 근거를 쌓으세요.

## 정지

```bash
docker compose down        # 컨테이너 정지
docker compose down -v     # 백필 데이터(볼륨)까지 삭제 후 초기화
```

## 구성

| 서비스 | 역할 |
| --- | --- |
| `prometheus-init` | `prometheus/metrics_openmetrics.txt.gz`를 TSDB 블록으로 1회 백필 |
| `prometheus` | 백필된 스냅샷 조회(:9090) |
| `loki` | 로그 저장(:3100), 과거 타임스탬프 주입 허용 |
| `loki-loader` | `loki/logs/*.jsonl.gz`를 Loki에 1회 주입 후 종료 |
| `grafana` | :3000, Prometheus·Loki 데이터소스 미리 연결, 익명 접근 |

지표는 애플리케이션 노출 지표(전 시리즈)와 컨테이너 자원 지표(핵심 12종)를,
로그는 앱·트래픽 생성기 네임스페이스 전 구간을 원문 그대로 담았습니다.
