#!/usr/bin/env python3
"""학습용 최소 로그를 Loki 에 1회 주입한다. compose가 자동 실행.

이 케이스의 전제는 "Log 는 비어 있다(에러가 없다)"이다. 그래서 로그는
느린 요청조차 200 으로 정상 종료한 접근 로그 몇 줄만 둔다 — 학생이
Log 를 뒤져도 원인 줄이 없다는 걸 직접 확인하도록. 타임스탬프는 주입
시각 기준 최근 ~30분에 분산한다.
"""
import json
import random
import time
import urllib.error
import urllib.request

LOKI = "http://loki:3100"
random.seed(20260714)

# (service, 접근 로그 라인 템플릿, 지연 ms 범위)
ROUTES = [
    ("order-api", 'POST /orders 200 {ms}ms trace_sampled=true'),
    ("search-api", 'GET /search 200 {ms}ms trace_sampled=true'),
    ("profile-api", 'GET /profile 200 {ms}ms trace_sampled=true'),
    ("cart-api", 'POST /cart 200 {ms}ms'),
    ("user-api", 'GET /users 200 {ms}ms'),
]
LAT = {"order-api": (300, 360), "search-api": (230, 270), "profile-api": (210, 250),
       "cart-api": (60, 120), "user-api": (40, 90)}


def ready():
    try:
        with urllib.request.urlopen(LOKI + "/ready", timeout=2) as r:
            return r.status == 200
    except Exception:
        return False


def main():
    for _ in range(90):
        if ready():
            break
        time.sleep(2)
    else:
        raise SystemExit("loki not ready after wait")
    time.sleep(3)

    now_ns = time.time_ns()
    # 서비스별 스트림 구성
    streams = {}
    for svc, tmpl in ROUTES:
        rows = []
        lo, hi = LAT[svc]
        for _ in range(6):
            off_s = random.uniform(60, 1800)
            ts = now_ns - int(off_s * 1_000_000_000)
            ms = random.randint(lo, hi)
            rows.append((ts, tmpl.format(ms=ms)))
        rows.sort(key=lambda x: x[0])
        streams[svc] = [[str(ts), ln] for ts, ln in rows]

    pushed = 0
    for svc, values in streams.items():
        payload = {"streams": [{"stream": {"service": svc, "job": "mesh-demo"},
                                "values": values}]}
        req = urllib.request.Request(
            LOKI + "/loki/api/v1/push",
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"}, method="POST")
        try:
            urllib.request.urlopen(req, timeout=30)
            pushed += len(values)
        except urllib.error.HTTPError as e:
            print("push error", e.code, e.read()[:400].decode(errors="replace"))
            raise
    print(f"pushed {pushed} log lines to Loki (job=mesh-demo, 200 only, no errors)")


if __name__ == "__main__":
    main()
