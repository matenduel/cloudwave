#!/usr/bin/env python3
"""얼린 로그 스냅샷(logs.jsonl)을 Loki에 1회 주입한다. compose가 자동 실행.
logs.jsonl 각 줄: {"ts": <nanoseconds>, "iso_kst": "...", "line": "...", "labels": {...}}
labels가 있으면 그 라벨셋별 스트림으로, 없으면 기본 스트림으로 주입한다."""
import json, time, urllib.request, urllib.error
from collections import defaultdict

LOKI = "http://loki:3100"


def ready():
    try:
        with urllib.request.urlopen(LOKI + "/ready", timeout=2) as r:
            return r.status == 200
    except Exception:
        return False


for _ in range(90):
    if ready():
        break
    time.sleep(2)
else:
    raise SystemExit("loki not ready after wait")
time.sleep(3)  # 링/스키마 정착 여유

streams = defaultdict(list)
with open("/logs.jsonl") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        o = json.loads(line)
        labels = o.get("labels") or {"job": "app", "container": "app"}
        key = tuple(sorted(labels.items()))
        streams[key].append((int(o["ts"]), o["line"]))

total = 0
B = 500
for key, rows in streams.items():
    rows.sort(key=lambda x: x[0])  # Loki는 스트림 내 타임스탬프 오름차순 요구
    labelset = dict(key)
    values = [[str(ts), ln] for ts, ln in rows]
    for i in range(0, len(values), B):
        payload = {"streams": [{"stream": labelset, "values": values[i:i + B]}]}
        req = urllib.request.Request(LOKI + "/loki/api/v1/push",
                                     data=json.dumps(payload).encode(),
                                     headers={"Content-Type": "application/json"}, method="POST")
        try:
            urllib.request.urlopen(req, timeout=30)
            total += len(values[i:i + B])
        except urllib.error.HTTPError as e:
            print("push error", e.code, e.read()[:400].decode(errors="replace"))
            raise
print(f"pushed {total} log lines to Loki across {len(streams)} stream(s)")
