# 카드 2 · 푸시 알림 메시징 플랫폼 (푸시 기반 커머스/앱)

## 상황

당신은 한 회사의 **푸시 알림 메시징 플랫폼** 운영자입니다.

이 플랫폼은 커머스/앱 사용자에게 **마케팅 푸시 알림**을 보내는 서비스입니다. **푸시 캠페인**이 시작되면 대상 메시지가 **브로커(Kafka)**로 들어가고, **consumer**가 메시지를 가져가 사용자 단말로 **전송(delivery)**합니다. 평소에는 캠페인으로 생긴 작업이 이 흐름을 따라 처리되고, 전달 결과가 집계됩니다. 같은 클러스터에는 여러 서비스가 함께 돌아갑니다.

Grafana에 최근 **3일치 지표(과거)**와 **현재 진행 중인 상황(최근 구간)**이 함께 올라와 있습니다.

## 당신의 역할에서 생각해 보세요

정답을 바로 찾으려 하기 전에, **이 도메인과 당신의 역할(푸시 알림 메시징 플랫폼 운영자)**을 떠올려 보세요. 이런 플랫폼을 운영하는 사람은 평소 **무엇이 잘 돌아가는지, 무엇이 어긋나면 문제가 되는지**를 어떤 기준으로 지켜볼까요? 그 기준을 먼저 스스로 세우고, 그 관점으로 아래 지표를 읽으세요. 가장 크게 튄 값 하나를 답으로 고르는 대신, **무엇이 이 플랫폼의 평소이고 지금 그와 어떻게 다른지**를 근거로 판단합니다.

## 제공 지표 (각 지표의 의미)

| 지표 | 단위 | 의미 |
|---|---|---|
| `push_notifications_sent_total` | msg/s | 푸시 알림 발송 counter에 rate를 적용한 초당 발송량 |
| `kafka_server_BrokerTopicMetrics_MessagesInPerSec` | msg/s | 푸시 토픽으로 유입되는 Kafka 메시지의 초당 비율 |
| `kafka_consumergroup_lag` | messages | delivery consumer group이 아직 처리하지 못한 메시지 수 |
| `campaign_backlog_messages` | messages | broker admission 전 남아 있는 캠페인 대상 메시지 수 |
| `http_requests_total` | req/s | 앱 HTTP 요청 counter에 rate를 적용한 초당 요청량 |
| `http_request_duration_seconds` | s | 앱 HTTP 요청 지속시간의 합성 p95(초) |
| `notification_delivery_success_ratio` | ratio | 최근 5분 eligible terminal callback 중 성공 비율(0~1) |
| `kube_hpa_status_current_replicas` | pods | delivery consumer HPA의 현재 replica 수 |
| `kafka_consumergroup_members` | consumers | delivery consumer group에 현재 속한 consumer(member) 수 |
| `kube_pod_container_status_restarts_total` | count | delivery consumer 파드 컨테이너의 누적 재시작 횟수 |
| `kube_deployment_status_replicas_updated` | pods | 최신 리비전으로 업데이트된 delivery consumer replica 수 |
| `daily_active_users` | users | calendar-day 기준 당일 누적 활성 사용자 수 |
| `unsubscribe_total` | count | 푸시 수신 해지의 누적 건수 |

## 과제

관측 데이터만으로 판단하고, 근거와 함께 정리하세요.

1. **지금 이상(정상과 다른 상황)이 있습니까?** 있다면 가장 유력한 원인은 무엇입니까?
2. 그 판단의 **근거가 되는 지표**는 무엇이고, 반대로 그 판단을 **반증할 수 있는 관찰**은 무엇입니까?
3. **이상처럼 보이지만 정상이거나 무해한 신호(오탐 후보)**가 있다면 무엇이고, 왜 그렇게 보십니까?

> 판단의 임계값이나 정답은 하나로 정해져 있지 않습니다. 채점은 숫자 하나가 아니라 **재현 가능한 근거와 반증**을 봅니다.
