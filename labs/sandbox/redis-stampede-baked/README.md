# redis-stampede-baked — 자기조사 샌드박스 (얼린 실측 스냅샷)

Redis cache stampede 사건의 **실측 관측 데이터**를 얼려서 담은 baked 샌드박스입니다.
라이브 재현 킷(`../redis-stampede/`)을 실제로 돌려 캡처한 Prometheus 지표 + Loki 로그를 주입합니다.
합성이 아니라 진짜 실행에서 나온 값이며, 매번 동일하게 재현됩니다.

## 실행 (한 줄)

```bash
docker compose up
```

- Prometheus(백필) · Loki(주입) · Grafana(익명)가 데이터 실린 채 뜹니다.
- Grafana `http://localhost:3000` → Explore에서 PromQL/LogQL 직접 조회.
- 정지: `docker compose down -v`

## 데이터 창

- **사건 시각: 2026-07-14 09:00~09:02 KST.** Grafana 우상단 시간 범위를 **2026-07-14 08:59 ~ 09:03** 으로 맞추세요(그 밖 구간엔 데이터 없음).
- 지표(Prometheus)는 `up` 직후 바로 조회됩니다.
- **로그(Loki)는 주입 후 store flush에 약 1~2분** 걸립니다. 로그가 안 보이면 잠시 뒤 다시 조회하세요.

## 들어있는 신호 (출발점 — 무엇을 조합할지는 스스로)

- **표면(가장 먼저 튀는 값)**: `db_query_duration_seconds`(백엔드 조회 지연, p95가 stampede에 ~1200ms로 급등). 겉보기엔 "DB가 느리다".
- **진짜 원인(파고들어야 보이는 값)**:
  - `db_query_execution_duration_seconds` — 백엔드 **순수 실행시간**. stampede 중에도 ~25ms로 **평탄**. 즉 DB 자체는 느려지지 않았음.
  - `db_worker_queue_depth` — 백엔드 워커 큐 적체(stampede에 급증). 지연은 실행이 아니라 **대기**에서 발생.
  - `redis_keyspace_hits_total` / `redis_keyspace_misses_total` — hit ratio가 **DB 지연 급등과 같은 시각에 급락**. `redis_expired_keys_total`에서 다수 키 **동시 만료** 확인.
- **로그**: `{container="app"}`(요청별 `cache_status` hit/miss·`duration_ms`), `{container="backend"}`(`execution_duration_ms`·`queue_wait_ms`). `| json` 으로 필드 조회.

## 이 문제의 반전

표면 지표(`db_query_duration`)만 보면 DB가 범인처럼 보입니다. 그러나 실행시간은 평탄하고(DB 무결), 지연은 워커 큐 대기에서 나오며, 그 원인은 캐시 키 **동시 만료 → 캐시 미스 쇄도(thundering herd)** 입니다. DB 지연 급등과 Redis hit ratio 급락이 **같은 타임스탬프에 동시에** 일어났다는 상관을 봐야 진짜 원인이 드러납니다.

## 원본

라이브 재현 킷: `../redis-stampede/` (이 스냅샷은 그 킷을 로컬에서 실제로 돌려 캡처한 것).
