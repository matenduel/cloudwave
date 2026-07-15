# cfs-throttling-baked — 자기조사 샌드박스 (얼린 실측 스냅샷)

CFS CPU throttling 사건의 **실측 관측 데이터**를 얼려서 담은 baked 샌드박스입니다.
라이브 재현 킷(`../cfs-throttling/`)을 Docker Desktop Linux VM에서 실제로 실행해 캡처한 Prometheus 지표와 Loki 요청 로그를 재생합니다. 합성 데이터가 아니며 매번 같은 결과로 조회됩니다.

## 실행 (한 줄)

```bash
docker compose up
```

- Grafana `http://localhost:3000` (익명) → Explore에서 PromQL/LogQL 직접 조회. 정지: `docker compose down -v`

## 데이터 창

- **사건 시각: 2026-07-15 02:00:00~02:06:20 KST** (30초마다 burst). Grafana 범위를 **2026-07-15 01:59:50 ~ 02:06:30**으로 맞추세요.
- Prometheus 지표는 `up` 직후 조회됩니다. Loki 로그는 주입 후 store flush에 약 1~2분 걸립니다.

## 들어있는 신호 (출발점 — 무엇을 조합할지는 스스로)

- **사용자 영향**: `http_request_duration_seconds`의 p99는 baseline 약 20ms에서 burst마다 약 **19.8초**까지 튑니다. `{container="app"} | json` 로그에는 요청별 `duration_ms`, `cpu_work_ms`가 있습니다.
- **오진 유도 표면**: CPU quota(`0.50 core`) 대비 5분 평균 사용률은 **약 46%**로 여유 있게 보입니다. 따라서 평균만 보면 CPU를 후보에서 뺄 만합니다.
- **진짜 원인**: `container_cpu_cfs_throttled_seconds_total{container="app"}`가 p99 급등과 동시 증가합니다. 30초 증가량은 최대 **약 58초**이고, `container_cpu_cfs_periods_total`도 함께 증가합니다. 이는 처리 로직의 느린 실행이 아니라 quota가 소진된 뒤 scheduler에서 제외된 시간입니다.
- 보조 신호: `container_memory_usage_bytes{container="app"}`는 안정적이라 메모리 압박/GC라는 설명과 맞지 않습니다.

## PromQL / LogQL 출발점

```promql
histogram_quantile(0.99, sum by (le) (rate(http_request_duration_seconds_bucket[30s])))
```

```promql
100 * sum(rate(container_cpu_usage_seconds_total{container="app"}[5m])) / 0.50
```

```promql
increase(container_cpu_cfs_throttled_seconds_total{container="app"}[30s])
```

```promql
increase(container_cpu_cfs_periods_total{container="app"}[30s])
```

```logql
{container="app"} | json
```

## 원본

라이브 재현 킷: `../cfs-throttling/` (이 스냅샷은 해당 킷의 0.50 CPU limit·1 RPS baseline·30초마다 30 VU × 250ms CPU burst 실행을 캡처한 것).
