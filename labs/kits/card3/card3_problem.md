# 카드 3 · 배치 데이터 파이프라인 (데이터웨어하우스)

## 상황

당신은 한 회사의 **데이터 플랫폼(데이터웨어하우스, DW)** 운영자입니다.

이 플랫폼은 매일 **새벽에 대용량 배치(Spark)**가 돌아 데이터를 만들고, **아침에는 사람들이 BI·리포트 쿼리(Trino)**로 그 데이터를 사용합니다. 핵심 배치는 정해진 **마감 시각(06:00)**까지 끝나야 다음 작업과 아침 사용자가 최신 데이터를 쓸 수 있습니다. 같은 클러스터에는 여러 서비스가 함께 돌아갑니다.

Grafana에 최근 **3일치 지표(과거)**와 **현재 진행 중인 상황(최근 구간)**이 함께 올라와 있습니다.

## 당신의 역할에서 생각해 보세요

정답을 바로 찾으려 하기 전에, **이 도메인과 당신의 역할(데이터 플랫폼 운영자)**을 떠올려 보세요. 이런 플랫폼을 운영하는 사람은 평소 **무엇이 잘 돌아가는지, 무엇이 어긋나면 문제가 되는지**를 어떤 기준으로 지켜볼까요? 그 기준을 먼저 스스로 세우고, 그 관점으로 아래 지표를 읽으세요. 가장 크게 튄 값 하나를 답으로 고르는 대신, **무엇이 이 플랫폼의 평소이고 지금 그와 어떻게 다른지**를 근거로 판단합니다.

## 제공 지표 (각 지표의 의미)

| 지표 | 단위 | 의미 |
|---|---|---|
| `spark_executor_activeTasks` | tasks | Spark 익스큐터에서 현재 실행 중인 태스크 수(배치 작업량 대리) |
| `spark_stage_shuffleReadBytes_rate` | MB/s | Spark stage의 shuffle read 처리량(초당). shuffle 있는 stage에서만 큼 |
| `dw_scan_bytes_rate` | GB/s | 쿼리·배치가 스캔한 데이터량(초당). 큰 테이블 스캔 시 급증 |
| `container_memory_working_set_ratio` | ratio | 컨테이너 메모리 사용률(0~1) |
| `airflow_task_instance_running` | tasks | Airflow에서 현재 running 상태인 태스크 수(스케줄된 DAG 실행) |
| `trino_execution_running_queries` | queries | Trino(대화형 BI 쿼리 엔진)에서 실행 중인 쿼리 수 |
| `trino_execution_queued_queries` | queries | Trino에서 대기(큐) 중인 쿼리 수. 동시 용량 초과 시 증가 |
| `trino_query_wallTime_p95_seconds` | s | Trino 쿼리 응답시간 p95(초) |
| `cluster_autoscaler_nodes` | nodes | 오토스케일러가 띄운 워커 노드 수 |
| `dataset_freshness_lag_minutes` | min | 핵심 데이터셋의 신선도 지연(분). 마지막 성공 publish 이후 경과 시간이며, |
| `warehouse_storage_used_ratio` | ratio | 웨어하우스 스토리지 사용률(0~1) |
| `pipeline_retry_ratio_5m` | ratio | 파이프라인 태스크 재시도 비율(최근 5분). 태스크 실패 시 상승 |
| `kube_pod_container_status_restarts_total` | count | 파드 컨테이너의 누적 재시작 횟수 |
| `kube_deployment_status_replicas_updated` | pods | 디플로이먼트에서 최신 리비전으로 업데이트된 레플리카 수(배포 진행 지표) |

## 과제

관측 데이터만으로 판단하고, 근거와 함께 정리하세요.

1. **지금 이상(정상과 다른 상황)이 있습니까?** 있다면 가장 유력한 원인은 무엇입니까?
2. 그 판단의 **근거가 되는 지표**는 무엇이고, 반대로 그 판단을 **반증할 수 있는 관찰**은 무엇입니까?
3. **이상처럼 보이지만 정상이거나 무해한 신호(오탐 후보)**가 있다면 무엇이고, 왜 그렇게 보십니까?

> 판단의 임계값이나 정답은 하나로 정해져 있지 않습니다. 채점은 숫자 하나가 아니라 **재현 가능한 근거와 반증**을 봅니다.
