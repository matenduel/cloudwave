#!/usr/bin/env python3
"""학습용 합성 메트릭을 OpenMetrics 텍스트로 생성한다(promtool 백필 입력).

- 주입 시각 기준 최근 ~35분, 분당 1샘플.
- order/search/profile-api 의 p95 가 최근 구간에서 함께 ~100ms 상승(그 외 정상).
- 요청 처리량(rps)은 세 서비스 모두 평평 → "배포도 트래픽 증가도 없었다"는
  전제를 학생이 지표로 직접 확인할 수 있게 한다.
메트릭은 보조 신호다. 원인 위치는 Trace 로 좁힌다.
"""
import random
import time

random.seed(20260714)

OUT = "/out/metrics.txt"
STEP = 60          # 1분 간격
POINTS = 36        # 최근 36분
RISE_AT = 20       # 최근 ~20분 전부터 상승(인덱스 = POINTS - RISE_AT 이후)

# service -> (baseline_p95_s, elevated_p95_s, rps)
SERVICES = {
    "order-api":   (0.21, 0.33, 42.0),
    "search-api":  (0.15, 0.25, 55.0),
    "profile-api": (0.12, 0.23, 38.0),
    "cart-api":    (0.18, 0.18, 24.0),   # 정상(비교군)
    "user-api":    (0.14, 0.14, 30.0),   # 정상(비교군)
    "payment-api": (0.05, 0.05, 90.0),   # 목적지 자체 앱 처리시간은 정상
}


def jitter(v, pct=0.04):
    return round(v * random.uniform(1 - pct, 1 + pct), 4)


def main():
    now = int(time.time())
    start = now - (POINTS - 1) * STEP
    ts = [start + i * STEP for i in range(POINTS)]
    rise_idx = POINTS - RISE_AT

    lines = []

    lines.append("# HELP http_server_request_duration_p95_seconds 서비스별 요청 처리 p95(초). 학습용 합성 데이터.")
    lines.append("# TYPE http_server_request_duration_p95_seconds gauge")
    for svc, (base, elev, _rps) in SERVICES.items():
        for i, t in enumerate(ts):
            val = elev if i >= rise_idx else base
            lines.append(
                f'http_server_request_duration_p95_seconds{{service="{svc}"}} {jitter(val)} {t}')

    lines.append("# HELP http_server_requests_per_second 서비스별 초당 요청 수. 학습용 합성 데이터.")
    lines.append("# TYPE http_server_requests_per_second gauge")
    for svc, (_base, _elev, rps) in SERVICES.items():
        for t in ts:
            lines.append(
                f'http_server_requests_per_second{{service="{svc}"}} {jitter(rps, 0.06)} {t}')

    lines.append("# EOF")

    with open(OUT, "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"wrote {OUT}: {len(SERVICES)} services x {POINTS} points, "
          f"window {ts[0]}..{ts[-1]} (rise at index {rise_idx})")


if __name__ == "__main__":
    main()
