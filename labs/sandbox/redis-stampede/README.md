# Redis Cache Stampede / Thundering Herd 실습 킷

이 실습은 관측상 backend(DB) 지연이 급증하지만, 실제 원인은 backend 자체가 아니라 Redis 캐시 키의 동시 만료(PXAT)인 상황을 재현한다.

backend는 5개 FIFO 워커와 요청당 약 20ms의 고정 실행시간만 가진다. 요청 폭증 시 지연은 전부 워커 큐 대기에서 발생한다.

## 실행

```bash
docker compose up --build -d
```

서비스:

- App: http://localhost:8080/data?key=hot-1
- Prometheus: http://localhost:9090
- Grafana: http://localhost:3000
- Loki: http://localhost:3100
- Redis exporter: http://localhost:9121/metrics

Grafana는 익명 Viewer 접근이 활성화되어 있다. 대시보드는 의도적으로 제공하지 않는다.

## 부하 실험

```bash
docker compose run --rm k6
```

k6는 한 번의 실행에서 다음 순서를 수행한다.

1. 25초간 hot key 중심의 `constant-arrival-rate` baseline.
2. PXAT 만료 30초 전, incident와 같은 `40 VU × 12 key` burst를 캐시가 살아있는 상태에서 수행하는 control.
3. `setup()`이 받은 `expires_at_ms` PXAT 시각에 `Date.now()` barrier로 모든 VU를 동기화하여 동일 burst를 발사하는 stampede.

기본 설정에서 cache warm 후 약 70초에 incident가 발생한다. control burst는 그 30초 전인 약 40초에 발생한다.

## 핵심 검증

Prometheus에서 다음을 비교한다.

표면상 DB가 느려 보이는 지표:

```promql
histogram_quantile(
  0.95,
  sum by (le) (
    rate(db_query_duration_seconds_bucket[10s])
  )
)
```

실제 backend 실행시간. incident 중에도 약 20ms 근처여야 한다.

```promql
histogram_quantile(
  0.95,
  sum by (le) (
    rate(db_query_execution_duration_seconds_bucket[10s])
  )
)
```

backend FIFO 큐 적체:

```promql
db_worker_queue_depth
```

Redis hit ratio. incident 순간 급락해야 한다.

```promql
sum(rate(redis_keyspace_hits_total[10s]))
/
(
  sum(rate(redis_keyspace_hits_total[10s]))
  +
  sum(rate(redis_keyspace_misses_total[10s]))
)
```

동시 만료 증거:

```promql
increase(redis_expired_keys_total[10s])
```

애플리케이션 관점 miss:

```promql
sum(rate(app_cache_requests_total{outcome="miss"}[10s]))
```

## Loki 확인

Grafana Explore에서 Loki datasource를 선택하고 다음처럼 조회한다.

```logql
{job="app"} | json
```

```logql
{job="backend"} | json
```

backend 로그의 `queue_wait_ms`와 `total_duration_ms`는 stampede에서 증가하지만 `execution_duration_ms`는 약 20ms로 유지된다.

## 기대되는 해석

control burst는 incident와 동일한 요청 규모지만 캐시 hit이므로 backend 지연을 유발하지 않는다. PXAT 동시 만료 순간에만 Redis miss와 expired key가 증가하고, 같은 시각 backend FIFO queue wait 및 `db_query_duration_seconds`가 급증한다.

따라서 “DB 지연 증가”는 원인이 아니라 cache stampede가 만든 결과이며, `db_query_execution_duration_seconds`가 backend 자체의 무결성을 증명한다.

## 종료

```bash
docker compose down -v
```
```
tokens used
14,623
