# Kafka Consumer Lag / Sink I/O Amplification Lab

Kafka producer는 항상 60 RPS로 정상 produce합니다. Consumer는 종료, pause, 재시작, rebalance 없이 poll과 heartbeat를 유지하지만, 처리 지연과 실제 파일 sink write 증폭 때문에 처리량이 낮아져 consumer group lag가 누적됩니다.

## 실행

```bash
chmod +x scripts/run-scenario.sh
./scripts/run-scenario.sh
```

직접 기동만 하려면 다음을 사용합니다.

```bash
docker compose up --build
```

시나리오 스크립트는 baseline 4분, fault 10분, recovery 5분을 실행합니다. 마지막에 자동 정리하지 않으므로 관측 후 수동으로 정리합니다.

```bash
docker compose down -v
```

## 포트

| 서비스 | 주소 |
|---|---|
| Kafka 외부 bootstrap | `localhost:9092` |
| Producer HTTP ingest | `http://localhost:18080/orders` |
| Producer metrics | `http://localhost:18000/metrics` |
| Consumer metrics 및 control | `http://localhost:18001/metrics`, `http://localhost:18001/control` |
| Kafka exporter | `http://localhost:9308/metrics` |
| Prometheus | `http://localhost:19090` |
| Loki | `http://localhost:13100` |
| Grafana | `http://localhost:13000` |

컨테이너 내부 Kafka bootstrap 주소는 모든 서비스에서 `kafka:29092`입니다.

## 수동 Fault 주입

```bash
curl -sS -X POST http://localhost:18001/control \
  -H 'content-type: application/json' \
  -d '{"extra_delay_ms":40,"writes_per_record":8,"sink_write_bytes":8192}'
```

복구:

```bash
curl -sS -X POST http://localhost:18001/control \
  -H 'content-type: application/json' \
  -d '{"extra_delay_ms":0,"writes_per_record":1,"sink_write_bytes":1024}'
```

## PromQL 검증 쿼리

표면 지표는 정상으로 유지되어야 합니다.

```promql
up
```

```promql
sum(rate(app_http_requests_total{status=~"5.."}[1m]))
```

```promql
rate(process_cpu_seconds_total[1m])
```

실제 이상 신호는 다음 쿼리에서 확인합니다.

```promql
sum(kafka_consumergroup_lag{consumergroup="orders-cg",topic="orders"})
```

```promql
sum(rate(consumer_sink_write_ops_total[30s]))
```

```promql
sum(rate(consumer_sink_write_bytes_total[30s]))
```

```promql
consumer_processing_delay_seconds
```

## 채택 기준

- 정상 baseline: consumer lag는 대체로 `< 100`
- Fault 구간: 최대 consumer lag는 `> 15000`
- 정상 sink write ops: 약 `60/s`
- Fault sink write ops: 약 `160~200/s`
- 정상 sink write bytes: 약 `60 KiB/s`
- Fault sink write bytes: 약 `1.3~1.6 MiB/s`
- `consumer_processing_delay_seconds`: 정상 `0`, fault `0.04`
- Producer HTTP 5xx와 delivery error는 정상적으로 `0`에 가깝고, consumer `up` 및 Kafka exporter `up`은 유지

## Rebalance 방지 근거

Consumer는 `max_poll_records=10`, `max.poll.interval.ms=600000`(10분)입니다. Fault의 최대 처리 시간은 레코드당 `40ms` 지연이며, 최대 poll batch의 지연 합계는 `10 × 40ms = 400ms`입니다. Sink write 8회와 flush 시간을 포함해도 10분의 극히 일부이므로 consumer는 처리 지연 중에도 `max.poll.interval.ms`를 초과하지 않아 rebalance가 발생하지 않습니다.
