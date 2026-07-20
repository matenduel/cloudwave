# 카드 1 · 결제/커머스 서비스 (온라인 커머스)

## 상황

당신은 한 회사의 **결제/커머스 서비스** 운영자입니다.

이 서비스는 사용자가 상품을 탐색하고 장바구니를 거쳐 **결제(체크아웃)**까지 진행하는 온라인 커머스입니다. 평소 트래픽은 **점심·저녁의 이중 피크**를 그리고, 가끔 **타임세일 같은 이벤트**로 주문이 짧게 급증합니다. 결제는 카드 검증 등 **무거운 처리**를 거치기 때문에, 결제 워크로드에는 쿠버네티스 **CPU limit**이 걸려 있습니다. 같은 클러스터에는 정적 웹·카탈로그 등 **여러 서비스**가 함께 돌아갑니다.

Grafana에 최근 **3일치 지표(과거)**와 **현재 진행 중인 상황(최근 구간)**이 함께 올라와 있습니다.

## 당신의 역할에서 생각해 보세요

정답을 바로 찾으려 하기 전에, **이 도메인과 당신의 역할(결제/커머스 서비스 운영자)**을 떠올려 보세요. 이런 서비스를 운영하는 사람은 평소 **무엇이 잘 돌아가는지, 무엇이 어긋나면 문제가 되는지**를 어떤 기준으로 지켜볼까요? 그 기준을 먼저 스스로 세우고, 그 관점으로 아래 지표를 읽으세요. 가장 크게 튄 값 하나를 답으로 고르는 대신, **무엇이 이 서비스의 평소이고 지금 그와 어떻게 다른지**를 근거로 판단합니다.

## 제공 지표 (각 지표의 의미)

| 지표 | 단위 | 의미 |
|---|---|---|
| `http_requests_total{route="/static"}` | req/s | 정적 자산 경로의 초당 HTTP 요청 수 |
| `http_requests_total{route="/api/catalog"}` | req/s | 상품 탐색 API 경로의 초당 HTTP 요청 수 |
| `http_requests_total{route="/checkout"}` | req/s | 체크아웃 경로의 초당 HTTP 요청 수 |
| `http_requests_total{route="/checkout",status="5xx"}` | req/s | 체크아웃 경로에서 관측된 초당 HTTP 5xx 응답 수 |
| `payment_transactions_total{result="success"}` | tx/s | 초당 성공 결제 거래 수 |
| `payment_transactions_total{result="fail"}` | tx/s | 초당 실패 결제 거래 수 |
| `commerce_payment_failure_ratio_1m` | ratio | 최근 1분 결제 시도 중 실패 거래의 비율 |
| `commerce_checkout_conversion_ratio_5m` | ratio | 최근 5분 체크아웃 시도 대비 성공 결제 비율 |
| `container_cpu_usage_seconds_total{namespace="demo",container="loadapp"}` | cores | 결제 검증 컨테이너가 사용한 CPU의 초당 코어 사용량 |
| `container_cpu_cfs_throttled_ratio_5m{container="loadapp"}` | ratio | 완전 공정 스케줄러(CFS)가 컨테이너 실행을 스로틀한 주기 비율(최근 5분) |
| `commerce_payment_pending_requests` | requests | 결제 admission 과정에서 대기 중인 요청 수 |
| `http_request_duration_seconds{route="/checkout",stat="p95"}` | s | 체크아웃 HTTP 요청 지속시간의 p95(초) |
| `kube_hpa_status_current_replicas{hpa="payment"}` | pods | 결제 HPA가 보고한 현재 레플리카 수 |
| `kube_hpa_status_current_replicas{hpa="web"}` | pods | 정적 웹 HPA가 보고한 현재 레플리카 수 |
| `kube_pod_container_status_restarts_total{container="loadapp"}` | count | 결제 컨테이너의 누적 재시작 횟수 |
| `kube_deployment_status_replicas_updated{deployment="payment"}` | pods | 결제 디플로이먼트에서 최신 리비전으로 갱신된 레플리카 수 |
| `commerce_cdn_cache_hit_ratio_5m` | ratio | 캐시 가능한 정적 요청 중 최근 5분 CDN 캐시 적중 비율 |
| `commerce_fraud_reject_ratio_5m` | ratio | 최근 5분 fraud 평가 중 거절된 비율 |
| `commerce_inventory_sync_items_total` | items/s | WMS 또는 ERP에서 동기화된 재고 항목의 초당 처리량 |
| `commerce_sale_inventory_available_units` | units | 타임세일 대상 상품군에서 현재 판매 가능한 재고 단위 수 |
| `commerce_settlement_pending_transactions` | transactions | 아직 정산 배치에서 처리되지 않은 결제 거래 수 |

## 과제

관측 데이터만으로 판단하고, 근거와 함께 정리하세요.

1. **지금 이상(정상과 다른 상황)이 있습니까?** 있다면 가장 유력한 원인은 무엇입니까?
2. 그 판단의 **근거가 되는 지표**는 무엇이고, 반대로 그 판단을 **반증할 수 있는 관찰**은 무엇입니까?
3. **이상처럼 보이지만 정상이거나 무해한 신호(오탐 후보)**가 있다면 무엇이고, 왜 그렇게 보십니까?

> 판단의 임계값이나 정답은 하나로 정해져 있지 않습니다. 채점은 숫자 하나가 아니라 **재현 가능한 근거와 반증**을 봅니다.
