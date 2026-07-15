#!/usr/bin/env python3
"""logs.jsonl의 과거 CFS 실측 로그를 Loki로 한 번 주입한다."""
import json
import time
import urllib.error
import urllib.request

LOKI = "http://loki:3100"


def ready():
    try:
        with urllib.request.urlopen(LOKI + "/ready", timeout=2) as response:
            return response.status == 200
    except Exception:
        return False


for _ in range(90):
    if ready():
        break
    time.sleep(2)
else:
    raise SystemExit("loki not ready after wait")
time.sleep(3)

by_container = {}
with open("/logs.jsonl", encoding="utf-8") as source:
    for raw in source:
        if raw.strip():
            row = json.loads(raw)
            by_container.setdefault(row.get("container", "app"), []).append(
                (int(row["ts"]), row["line"])
            )

pushed = 0
for container, rows in by_container.items():
    rows.sort(key=lambda row: row[0])
    values = [[str(timestamp), line] for timestamp, line in rows]
    for offset in range(0, len(values), 500):
        batch = values[offset:offset + 500]
        payload = {"streams": [{"stream": {"job": "cfs-throttling", "container": container}, "values": batch}]}
        request = urllib.request.Request(
            LOKI + "/loki/api/v1/push",
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            urllib.request.urlopen(request, timeout=30)
            pushed += len(batch)
        except urllib.error.HTTPError as error:
            print("push error", error.code, error.read()[:400].decode(errors="replace"))
            raise
print(f"pushed {pushed} log lines to Loki (streams: {list(by_container.keys())})")
