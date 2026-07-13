#!/usr/bin/env python3
"""학습용 합성 트레이스를 Tempo에 1회 주입한다. compose가 자동 실행.

- 실제 서비스 메시가 아니라, "여러 서비스가 동시에 조금씩 느려진" 상황을 재현하려고
  손으로 구성한 합성(synthetic) 트레이스다. OTLP JSON을 직접 만들어
  http://tempo:4318/v1/traces 로 POST 한다(SDK 대신 직접 JSON이라 timestamp·
  parent·attribute 를 완전히 제어한다).
- 타임스탬프는 주입 시각 기준 최근 ~30분에 흩뿌린다. 학생이 언제 띄우든
  Grafana 기본 "최근 1시간" 범위에서 조회된다.

트레이스 골격(느린 갈래):
  root SERVER (order-api POST /orders)
    └ CLIENT (order-api → payment-api, 시작 +offset)
        └ SERVER (payment-api, resource 에 k8s.node.name·cloud.availability_zone)
            └ INTERNAL (payment-api business)
  CLIENT 막대 길이 − 그 안 SERVER 막대 길이 = 사이드카·network 여백.
"""
import json
import os
import random
import time
import urllib.error
import urllib.request

TEMPO = "http://tempo:4318/v1/traces"
READY = "http://tempo:3200/ready"

random.seed(20260714)  # 재현성: 같은 데이터가 뜨도록 고정 시드

NANOS = 1_000_000_000
MS = 1_000_000


def hexid(nbytes):
    return os.urandom(nbytes).hex()


def sattr(key, value):
    return {"key": key, "value": {"stringValue": value}}


def resource_spans(service_name, node=None, az=None, spans=None):
    attrs = [sattr("service.name", service_name)]
    if node is not None:
        attrs.append(sattr("k8s.node.name", node))
    if az is not None:
        attrs.append(sattr("cloud.availability_zone", az))
    return {
        "resource": {"attributes": attrs},
        "scopeSpans": [{"scope": {"name": "synthetic-mesh-demo"}, "spans": spans or []}],
    }


def span(trace_id, span_id, name, kind, start_ns, dur_ms, parent=None, attrs=None):
    s = {
        "traceId": trace_id,
        "spanId": span_id,
        "name": name,
        "kind": kind,  # 1=INTERNAL 2=SERVER 3=CLIENT
        "startTimeUnixNano": str(int(start_ns)),
        "endTimeUnixNano": str(int(start_ns + dur_ms * MS)),
        "status": {},
    }
    if parent is not None:
        s["parentSpanId"] = parent
    if attrs:
        s["attributes"] = attrs
    return s


KIND_SERVER = 2
KIND_CLIENT = 3
KIND_INTERNAL = 1


def build_hop_trace(t0_ns, src, src_route, dst, dst_route, dst_node, dst_az,
                    root_ms, client_ms, client_start_ms, dst_ms, biz_ms):
    """소스 SERVER → CLIENT → 목적지 SERVER → business 4-span 트레이스.

    client_ms − dst_ms = 사이드카·network 여백. 목적지 SERVER resource 에만
    node·az 를 붙인다(소스 쪽 resource 는 service.name 만).
    """
    tid = hexid(16)
    root_id = hexid(8)
    client_id = hexid(8)
    dst_id = hexid(8)
    biz_id = hexid(8)

    # 목적지 SERVER 를 CLIENT 막대 가운데에 놓는다(앞뒤 여백 균등).
    gap = client_ms - dst_ms
    dst_start_ms = client_start_ms + gap / 2.0
    biz_start_ms = dst_start_ms + (dst_ms - biz_ms) / 2.0

    src_spans = [
        span(tid, root_id, f"{src_route}", KIND_SERVER, t0_ns, root_ms,
             attrs=[sattr("http.request.method", src_route.split()[0])]),
        span(tid, client_id, f"{src} → {dst}", KIND_CLIENT,
             t0_ns + client_start_ms * MS, client_ms, parent=root_id,
             attrs=[sattr("peer.service", dst)]),
    ]
    dst_spans = [
        span(tid, dst_id, f"{dst_route}", KIND_SERVER,
             t0_ns + dst_start_ms * MS, dst_ms, parent=client_id,
             attrs=[sattr("http.request.method", dst_route.split()[0]),
                    sattr("http.response.status_code", "200")]),
        span(tid, biz_id, "business", KIND_INTERNAL,
             t0_ns + biz_start_ms * MS, biz_ms, parent=dst_id),
    ]
    return [
        resource_spans(src, spans=src_spans),
        resource_spans(dst, node=dst_node, az=dst_az, spans=dst_spans),
    ]


def build_single_trace(t0_ns, src, src_route, root_ms):
    """다운스트림 없는 단일 SERVER 트레이스(노이즈)."""
    tid = hexid(16)
    root_id = hexid(8)
    biz_id = hexid(8)
    spans = [
        span(tid, root_id, f"{src_route}", KIND_SERVER, t0_ns, root_ms,
             attrs=[sattr("http.response.status_code", "200")]),
        span(tid, biz_id, "business", KIND_INTERNAL,
             t0_ns + (root_ms * 0.15) * MS, root_ms * 0.7, parent=root_id),
    ]
    return [resource_spans(src, spans=spans)]


def rand_t0(now_ns, lo=120, hi=2000):
    offset_s = random.uniform(lo, hi)
    return now_ns - int(offset_s * NANOS)


def jitter(v, pct=0.08):
    return v * random.uniform(1 - pct, 1 + pct)


def main():
    now_ns = time.time_ns()
    resource_spans_all = []

    # (src, src_route, dst, dst_route) 조합별 목적지 라우트
    def add_hop(n, src, src_route, dst, dst_route, node, az, kind):
        for _ in range(n):
            # 느린 홉은 최근 ~18분(지표 p95 상승 구간) 안에만 나타나게 하고,
            # 정상 트래픽은 전체(~33분)에 흩뿌린다 → Metric 상승 시점과 Trace 가 시간상 정합.
            if kind == "slow":
                t0 = rand_t0(now_ns, 120, 1080)
            else:
                t0 = rand_t0(now_ns, 120, 2000)
            if kind == "slow":
                root = jitter({"order-api": 330, "search-api": 250, "profile-api": 230}.get(src, 300))
                client = jitter({"order-api": 190, "search-api": 160, "profile-api": 150}.get(src, 170))
                dst_ms = jitter({"order-api": 40, "search-api": 38, "profile-api": 35}.get(src, 40))
                biz = jitter({"order-api": 30, "search-api": 28, "profile-api": 25}.get(src, 28))
                client_start = jitter(40)
            else:  # normal: 여백 작음(사이드카·network 정상)
                dst_ms = jitter(38)
                client = dst_ms + jitter(15)   # 여백 ~15ms
                root = jitter(200)
                biz = jitter(28)
                client_start = jitter(35)
            resource_spans_all.extend(
                build_hop_trace(t0, src, src_route, dst, dst_route, node, az,
                                root, client, client_start, dst_ms, biz))

    def add_single(n, src, src_route):
        for _ in range(n):
            t0 = rand_t0(now_ns)
            resource_spans_all.extend(build_single_trace(t0, src, src_route, jitter(160)))

    # --- 느린 갈래: 목적지가 ap-northeast-2c 로 수렴 ---
    add_hop(6, "order-api", "POST /orders", "payment-api", "POST /authorize",
            "node-c-2", "ap-northeast-2c", "slow")
    add_hop(5, "search-api", "GET /search", "ranking-api", "GET /rank",
            "node-c-1", "ap-northeast-2c", "slow")
    add_hop(4, "profile-api", "GET /profile", "auth-api", "POST /verify",
            "node-c-3", "ap-northeast-2c", "slow")

    # --- 정상 대조: 여백 작고 목적지가 다른 AZ(2a/2b) ---
    add_hop(7, "order-api", "POST /orders", "payment-api", "POST /authorize",
            "node-a-1", "ap-northeast-2a", "normal")
    add_hop(3, "profile-api", "GET /profile", "auth-api", "POST /verify",
            "node-a-2", "ap-northeast-2a", "normal")
    add_hop(7, "search-api", "GET /search", "ranking-api", "GET /rank",
            "node-b-1", "ap-northeast-2b", "normal")
    add_hop(3, "cart-api", "POST /cart", "payment-api", "POST /authorize",
            "node-b-2", "ap-northeast-2b", "normal")
    # 2c 에도 정상 트래픽 일부(2c 가 100% 느린 게 아니게 — 학생이 여백으로 걸러야 함)
    add_hop(3, "order-api", "POST /orders", "payment-api", "POST /authorize",
            "node-c-4", "ap-northeast-2c", "normal")

    # --- 노이즈: 다운스트림 없는 단일 트레이스 ---
    add_single(4, "user-api", "GET /users")
    add_single(3, "profile-api", "GET /profile")
    add_single(2, "cart-api", "GET /cart")

    payload = {"resourceSpans": resource_spans_all}

    # Tempo 준비 대기
    for _ in range(90):
        try:
            with urllib.request.urlopen(READY, timeout=2) as r:
                if r.status == 200 and b"ready" in r.read().lower():
                    break
        except Exception:
            pass
        time.sleep(2)
    else:
        raise SystemExit("tempo not ready after wait")
    time.sleep(3)

    n_traces = sum(len(rs["scopeSpans"][0]["spans"]) for rs in resource_spans_all)
    body = json.dumps(payload).encode()
    req = urllib.request.Request(
        TEMPO, data=body,
        headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            print(f"injected OTLP: HTTP {resp.status}, "
                  f"{len(resource_spans_all)} resourceSpans, {n_traces} spans")
    except urllib.error.HTTPError as e:
        print("inject error", e.code, e.read()[:600].decode(errors="replace"))
        raise


if __name__ == "__main__":
    main()
