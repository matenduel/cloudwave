#!/usr/bin/env python3
"""Load frozen streams once, retaining timestamp order required by Loki."""
import json, time, urllib.error, urllib.request
LOKI="http://loki:3100"
def ready():
    try:
        with urllib.request.urlopen(LOKI+"/ready",timeout=2) as r: return r.status==200
    except Exception: return False
for _ in range(90):
    if ready(): break
    time.sleep(2)
else: raise SystemExit("loki not ready after 90 attempts")
time.sleep(3)
streams={}
for raw in open("/logs.jsonl"):
    if raw.strip():
        row=json.loads(raw); streams.setdefault(row.get("container","app"),[]).append((int(row["ts"]),row["line"]))
count=0
for container,rows in streams.items():
    rows.sort(key=lambda row:row[0])
    for i in range(0,len(rows),500):
        values=[[str(ts),line] for ts,line in rows[i:i+500]]
        body={"streams":[{"stream":{"job":"pg-replica-lag","container":container},"values":values}]}
        request=urllib.request.Request(LOKI+"/loki/api/v1/push",data=json.dumps(body).encode(),headers={"Content-Type":"application/json"},method="POST")
        with urllib.request.urlopen(request,timeout=30): pass
        count+=len(values)
print(f"pushed {count} log lines to Loki: {sorted(streams)}")
