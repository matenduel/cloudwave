#!/usr/bin/env python3
"""얼린 로그 스냅샷(/logs/*.jsonl.gz)을 Loki에 1회 주입한다. compose가 자동 실행.
각 줄: {"ts": <nanoseconds>, "line": "...", "labels": {...}}
파일 안은 시간 오름차순이므로(캡처 시 보장) 스트림별 오름차순도 자동 보장된다.
스트리밍 방식: 라벨셋별 버퍼가 배치 크기에 차는 대로 밀어 넣어 메모리를 제한한다."""
import glob
import gzip
import json
import time
import urllib.error
import urllib.request

LOKI = "http://loki:3100"
BATCH = 1000


def ready():
    try:
        with urllib.request.urlopen(LOKI + "/ready", timeout=2) as r:
            return r.status == 200
    except Exception:
        return False


for _ in range(120):
    if ready():
        break
    time.sleep(2)
else:
    raise SystemExit("loki not ready after wait")
time.sleep(3)  # 링/스키마 정착 여유

total = 0


def push(labelset, values):
    global total
    payload = {"streams": [{"stream": labelset, "values": values}]}
    req = urllib.request.Request(LOKI + "/loki/api/v1/push",
                                 data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"}, method="POST")
    for attempt in range(5):
        try:
            urllib.request.urlopen(req, timeout=60)
            total += len(values)
            return
        except urllib.error.HTTPError as e:
            body = e.read()[:400].decode(errors="replace")
            if attempt == 4 or (e.code < 500 and e.code != 429):
                print("push error", e.code, body)
                raise
            time.sleep(2)  # 429(속도 제한)·5xx는 재시도
        except Exception:
            if attempt == 4:
                raise
            time.sleep(2)


files = sorted(glob.glob("/logs/*.jsonl.gz"))
streams = {}  # labelkey -> (labels, [[ts,line],...])
for path in files:
    print("loading", path, flush=True)
    with gzip.open(path, "rt") as f:
        for raw in f:
            raw = raw.strip()
            if not raw:
                continue
            o = json.loads(raw)
            labels = o["labels"]
            key = tuple(sorted(labels.items()))
            if key not in streams:
                streams[key] = (labels, [])
            buf = streams[key][1]
            buf.append([str(o["ts"]), o["line"]])
            if len(buf) >= BATCH:
                push(labels, buf)
                buf.clear()
                if total % 100000 < BATCH:
                    print(f"  pushed {total} lines...", flush=True)
# 잔여 버퍼 flush
for labels, buf in streams.values():
    if buf:
        push(labels, buf)
print(f"pushed {total} log lines to Loki across {len(streams)} stream(s)")
