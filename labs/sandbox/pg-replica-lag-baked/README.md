# pg-replica-lag-baked — 자기조사 샌드박스 (얼린 실측 스냅샷)

PostgreSQL primary commit과 hot-standby replica 읽기 가시성의 경계가 벌어진 **실제 실행 데이터**를 동결한 baked 샌드박스입니다. 원본 라이브 재현 킷은 `../pg-replica-lag/`이며, OpenMetrics 백필과 Loki JSONL 주입을 매번 같은 시간축으로 재현합니다.

## 실행 (한 줄)

```bash
docker compose up
```

- Grafana `http://localhost:13001` (익명 Viewer) → Explore에서 PromQL/LogQL을 직접 조회합니다.
- 중지·초기화: `docker compose down -v`

## 데이터 창

- **사건 창: 2026-07-14 10:00~10:07 KST.** Grafana 시간 범위를 **2026-07-14 09:59 ~ 10:08 KST**로 맞추세요. 이 밖에는 baked 데이터가 없습니다.
- replay pause는 **10:02:00 KST**, resume은 **10:04:00 KST**입니다. 이 실측의 primary WAL byte lag peak는 **1071.2 MiB**였고, mismatch ratio는 baseline 0%에서 pause 중 100%로 상승한 뒤 resume 후 0%로 돌아왔습니다.
- Prometheus 지표는 기동 직후 조회됩니다. Loki는 loader 주입 뒤 빠른 flush를 쓰지만, 로그가 비어 있으면 약 1~2분 뒤 다시 조회하세요.
- JSON 로그 내부의 `ts`도 이 앵커 시간축과 동일합니다.

## 출발점 — 먼저 표면, 그 뒤 판별

```promql
sum(rate(app_read_after_write_mismatch_total[30s])) / clamp_min(sum(rate(app_read_after_write_checks_total[30s])), 0.001)
```

```promql
histogram_quantile(0.99, sum by (le) (rate(app_http_request_duration_seconds_bucket{endpoint="read"}[30s])))
```

```logql
{container="app"} | json | match="false"
```

그 다음 primary 관점의 실제 WAL byte gap과, 풀 고갈 가설을 반증하는 두 지표를 같은 시각에 놓습니다.

```promql
pg_stat_replication_pg_wal_lsn_diff{db_role="primary"} / 1024 / 1024
```

```promql
sum by (db_role) (pg_stat_activity_count{application_name="order-app"})
```

```promql
sum by (db_role, mode) (pg_locks_count{mode=~"accessexclusivelock|exclusivelock"})
```

## 판단

primary 쓰기 성공은 replica 읽기 가시성을 보장하지 않습니다. replay가 멈춘 동안 mismatch의 `observed_node`는 replica이고 WAL byte lag는 증가하지만 activity·lock은 평탄합니다. replay를 재개해 lag가 소진되면 코드나 풀 크기를 바꾸지 않아도 mismatch가 함께 사라집니다. 따라서 “커넥션 풀을 늘리자”는 진단은 증거에 의해 기각됩니다.
