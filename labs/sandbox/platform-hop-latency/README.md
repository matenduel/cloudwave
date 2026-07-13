# 자기조사 샌드박스 — 플랫폼 홉 지연 (여러 서비스가 동시에 느려짐)

**학습용 합성 데이터**로 만든 상황입니다. 애플리케이션 배포가 없었는데 기능상 서로 무관한
여러 서비스의 p95 가 같은 시각에 함께 올랐습니다. 원인이 어느 앱 안에 있는지, 아니면
서비스들이 공유하는 인프라 계층에 있는지, 학생이 **직접 Tempo·Prometheus 를 조회해**
찾고 판단하는 열린 문제용 스택입니다.

> 트레이스·메트릭·로그는 실측이 아니라 합성입니다(라이브 서버에 연결하지 않습니다).
> 다만 학생은 **진짜 Tempo 에 진짜 TraceQL 로** 조회하므로 자기조사 훈련 효과는 같습니다.

## 실행

```bash
docker compose up
```

- 처음 실행 시 이미지를 내려받고, Tempo 에 합성 트레이스를 주입하고, Prometheus 에 지표를
  백필하고, Loki 에 로그를 주입합니다(자동, 수십 초).
- 뜨면 브라우저에서 **http://localhost:3000** (Grafana, 로그인 없이 열림) → 왼쪽 **Explore**.
  - **Tempo** 데이터소스: TraceQL 로 트레이스 조회(주력 신호)
  - **Prometheus** 데이터소스: PromQL 로 지표 조회
  - **Loki** 데이터소스: LogQL 로 로그 조회
- **데이터 창: 실행 시각 기준 최근 약 35분.** Grafana 시간 범위는 기본값(최근 1시간)
  그대로 두면 됩니다.

## 조회를 시작할 신호 (출발점일 뿐, 조합은 직접)

- 트레이스(Tempo, 주력)
  - 느린 요청 하나 열기: `{ resource.service.name = "order-api" && trace:duration > 300ms }`
  - Span 종류: `span:kind`(server / client / internal)
  - 목적지가 어느 노드·AZ 였는지: `resource.k8s.node.name`, `resource.cloud.availability_zone`
  - CLIENT Span 길이와 그 안 SERVER Span 길이의 차이(여백)를 Waterfall 에서 읽으세요.
- 지표(Prometheus, 보조)
  - 서비스별 p95: `http_server_request_duration_p95_seconds{service="order-api"}`
  - 서비스별 처리량: `http_server_requests_per_second{service="order-api"}`
- 로그(Loki, 보조): `{job="mesh-demo"}` — 느린 요청도 200 으로 끝나 에러 줄이 없습니다.

## 정지

```bash
docker compose down          # 컨테이너 정지
docker compose down -v       # 주입 데이터(볼륨)까지 삭제 후 초기화
```

## 구성

| 서비스 | 역할 |
| --- | --- |
| `tempo` | 트레이스 저장·조회(:3200), OTLP receiver(:4318 http · :4317 grpc), local storage |
| `trace-injector` | 합성 트레이스를 OTLP JSON 으로 직접 구성해 Tempo 에 1회 주입 후 종료 |
| `metrics-gen` | 최근 ~35분 합성 지표를 OpenMetrics 텍스트로 생성(볼륨 공유) |
| `prometheus-init` | 생성된 OpenMetrics 를 TSDB 블록으로 1회 백필 |
| `prometheus` | 백필된 스냅샷 조회(:9090) |
| `loki` | 로그 저장(:3100), 과거 타임스탬프 주입 허용 |
| `loki-loader` | 최소 로그(200 만)를 Loki 에 1회 주입 후 종료 |
| `grafana` | :3000, Tempo·Prometheus·Loki 데이터소스 미리 연결, 익명 접근, 대시보드 없음 |

데이터를 다시 뿌리려면 `docker compose down -v && docker compose up` 하면 됩니다
(타임스탬프가 그 시각 기준으로 다시 최근 ~35분에 맞춰집니다).

> 이 케이스가 심어 둔 구조(정답)와 채점 관점은 학생용이 아니라 강사용 문서
> `INSTRUCTOR-NOTES.md` 에 따로 두었습니다. 학생에게는 이 README 만 보여 주세요.
