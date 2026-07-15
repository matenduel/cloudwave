# CFS CPU Throttling Lab — "평균은 여유로운데 왜 느려지는가"

앱의 평균 CPU는 quota 대비 약 40~60%로 보이지만, 30초마다 동시에 몰리는 CPU burst가 컨테이너의 CFS quota를 짧게 소진합니다. 그 순간 실행 가능한 요청도 scheduler에서 제외(throttle)되어 p99가 급등합니다. 처리 코드는 느려지지 않았는데 **CPU scheduling wait**가 지연을 만듭니다.

## 실행

```bash
chmod +x scripts/run-scenario.sh
./scripts/run-scenario.sh
```

`app`에는 실제 `cpus: "0.50"` Docker cgroup limit이 걸립니다. 스크립트는 1 RPS × 20 ms CPU baseline과 30초마다 30 VU × 250 ms CPU 동시 burst를 5분 30초 동안 실행합니다. 종료 후에도 스택은 남아 있어 관측할 수 있습니다.

## 포트

| 서비스 | 주소 |
|---|---|
| App | `http://localhost:18081/work?cpu_ms=20` |
| cAdvisor | `http://localhost:18082/metrics` |
| Prometheus | `http://localhost:19091` |
| Loki | `http://localhost:13101` |
| Grafana | `http://localhost:13001` |

## PromQL 출발점

`container` label은 Docker Desktop cAdvisor 버전에 따라 다를 수 있으므로, 먼저 다음에서 app series label을 확인합니다.

```promql
container_cpu_usage_seconds_total{container_label_com_docker_compose_service="app"}
```

quota 대비 5분 평균 CPU(%). `0.50`은 compose의 실제 quota(core)입니다.

```promql
100 * sum(rate(container_cpu_usage_seconds_total{container_label_com_docker_compose_service="app"}[5m])) / 0.50
```

앱 p99 지연:

```promql
histogram_quantile(0.99, sum by (le) (rate(http_request_duration_seconds_bucket[30s])))
```

CFS throttle 누적 시간의 순간 증가량과 period 수:

```promql
increase(container_cpu_cfs_throttled_seconds_total{container_label_com_docker_compose_service="app"}[30s])
```

```promql
increase(container_cpu_cfs_periods_total{container_label_com_docker_compose_service="app"}[30s])
```

메모리 사용량도 cAdvisor에서 함께 수집합니다.

```promql
container_memory_usage_bytes{container_label_com_docker_compose_service="app"}
```

## Loki 확인

Grafana Explore에서 Loki를 선택합니다.

```logql
{container="app"} | json
```

각 요청의 `duration_ms`, `cpu_work_ms`가 있어 p50/p99를 직접 계산하거나 burst 시각의 사용자 영향을 확인할 수 있습니다.

## 종료

```bash
docker compose down -v
```
