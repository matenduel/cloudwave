# 강사용 메모 — platform-hop-latency (학생에게 노출 금지)

이 파일은 케이스가 심어 둔 정답 구조와 채점 관점을 담습니다. 학생에게는 `README.md` 만
보여 주세요. 이 파일은 학생 실습 경로에 등장하지 않습니다.

## 심어 둔 구조

- 느린 갈래는 세 쌍입니다: `order-api → payment-api`, `search-api → ranking-api`,
  `profile-api → auth-api`. 각 갈래에서 호출하는 쪽 CLIENT Span 은 길고(150~190ms)
  그 안 목적지 SERVER Span 은 짧습니다(35~40ms). 그 여백(~110~150ms)이 계측되지
  않은 경계 시간(사이드카·network 후보)입니다.
- 이 느린 홉들의 목적지 SERVER 는 모두 **`ap-northeast-2c`** 로 수렴합니다.
- 정상 대조 트레이스는 여백이 작고(~15ms) 목적지가 다른 AZ(2a/2b)입니다.
  `ap-northeast-2c` 에도 정상 트래픽이 조금 섞여 있어, 학생은 AZ 하나만으로 결론 내지
  않고 각 홉의 여백까지 함께 봐야 합니다.
- **시간 정합**: 느린 홉은 최근 ~18분(지표 p95 상승 구간) 안에만 나타나고, 정상 트래픽은
  전체(~33분)에 흩뿌려집니다. Metric 의 상승 시점과 Trace 의 느린 홉 등장 시점이 맞물립니다.
- 지표는 order/search/profile-api 의 p95 만 최근에 상승하고 처리량(rps)은 평평합니다
  (배포·트래픽 증가가 아니라는 방증). cart/user/payment-api p95 는 정상입니다.

## 확인용 TraceQL (검증)

- `{ resource.service.name = "order-api" }` → order-api 트레이스 반환.
- `{ span:kind = server && resource.cloud.availability_zone = "ap-northeast-2c" }`
  → 느린 홉의 목적지 SERVER 가 이 AZ 로 몰려 가장 많이 반환(정상 AZ 2a/2b 는 적게).
- `{ resource.service.name = "order-api" && trace:duration > 300ms }` → 느린 order-api 하나 열기.

## 채점 관점

교재 본문 `content/docs/20-observability/105-signals.md` 의 `[연습] 앱은 안 건드렸는데…`
절 안 "이 문제의 채점" callout 참조. 핵심은 결론이 아니라 근거(직접 조회로 뒷받침·다수
표본·상관vs인과·반증·확정불가 밝히기)입니다. "특정 앱 하나가 느리다"로 단정하면 다시
보게 하고, "앱이 아니라 목적지 노드·AZ 의 공유 계층"까지 좁히면서 그것이 아직 가설임을
밝히면 통과입니다.
