#!/usr/bin/env python3
"""Capture a passed live run, shift it to a fixed past KST anchor, and verify gates."""
import datetime as dt, json, subprocess, sys, urllib.parse, urllib.request
from pathlib import Path

PROM="http://localhost:19090/api/v1/query_range"
TARGET=Path(__file__).resolve().parents[2] / "pg-replica-lag-baked"
PROJECT='container_label_com_docker_compose_project="pg-replica-lag"'
QUERIES=[
 ("app_read_after_write_checks_total", "app_read_after_write_checks_total"),
 ("app_read_after_write_mismatch_total", "app_read_after_write_mismatch_total"),
 ("app_http_request_duration_seconds_bucket", "app_http_request_duration_seconds_bucket"),
 ("app_http_request_duration_seconds_sum", "app_http_request_duration_seconds_sum"),
 ("app_http_request_duration_seconds_count", "app_http_request_duration_seconds_count"),
 ("pg_stat_replication_pg_wal_lsn_diff", "pg_stat_replication_pg_wal_lsn_diff{db_role=\"primary\"}"),
 ("pg_stat_activity_count", "pg_stat_activity_count"),
 ("pg_locks_count", "pg_locks_count"),
]
TYPES={n:("counter" if n.endswith(("_total","_sum","_count")) else "histogram" if n.endswith("_bucket") else "gauge") for n,_ in QUERIES}
def matrix(q,start,end):
 u=PROM+"?"+urllib.parse.urlencode({"query":q,"start":start,"end":end,"step":"5s"})
 with urllib.request.urlopen(u,timeout=60) as r: body=json.load(r)
 if body["status"]!="success": raise RuntimeError(body)
 return body["data"]["result"]
def render(labels):
 return "{"+",".join(f'{k}="{v.replace(chr(34), chr(92)+chr(34))}"' for k,v in sorted(labels.items()))+"}" if labels else ""
def openmetrics(start,end,anchor):
 out=[]
 for name,q in QUERIES:
  out.append(f"# TYPE {name} {TYPES[name]}")
  for s in matrix(q,start,end):
   labels={k:v for k,v in s["metric"].items() if k not in ("__name__","instance","job")}
   # promtool's OpenMetrics importer takes a timestamp in seconds (as do the
   # established baked kits), not the Prometheus HTTP API's milliseconds.
   for ts,val in s["values"]: out.append(f"{name}{render(labels)} {val} {int(anchor+float(ts)-start)}")
 out.append("# EOF"); return "\n".join(out)+"\n"
def parse_time(value):
 return dt.datetime.fromisoformat(value.replace("Z","+00:00")).timestamp()
def logs(start,end,anchor):
 raw=subprocess.check_output(["docker","run","--rm","-v","pg-replica-lag_app_logs:/logs:ro","alpine:3.20","sh","-c","cat /logs/*.jsonl"],text=True)
 rows=[]
 for line in raw.splitlines():
  e=json.loads(line); moment=parse_time(e["ts"])
  if start <= moment <= end:
   shifted=anchor+moment-start; e["ts"]=dt.datetime.fromtimestamp(shifted,dt.timezone.utc).isoformat().replace("+00:00","Z")
   container="replica-controller" if e.get("event"," ").startswith(("replay_","controller_")) else "app"
   rows.append({"ts":int(shifted*1e9),"container":container,"line":json.dumps(e,separators=(",",":"))})
 rows.sort(key=lambda x:(x["container"],x["ts"])); return "\n".join(json.dumps(x,separators=(",",":")) for x in rows)+"\n"
def value(q,at):
 u="http://localhost:19090/api/v1/query?"+urllib.parse.urlencode({"query":q,"time":at})
 with urllib.request.urlopen(u) as r: return json.load(r)["data"]["result"]
def samples(query, start, end):
 return [(float(ts),float(v)) for series in matrix(query,start,end) for ts,v in series["values"]]
def counter_delta(query, start, end):
 points=sorted(samples(query,start,end))
 return max(0,points[-1][1]-points[0][1]) if len(points)>1 else 0
def gate(start,end):
 # The controller's fixed seven-minute schedule is intentionally part of the
 # kit contract. Check its three phases on raw, not post-processed, series.
 pause_start, pause_end=start+120,start+240
 wal=max(v for _,v in samples('pg_stat_replication_pg_wal_lsn_diff{db_role="primary"}',start,end))
 if wal < 20*1024*1024: raise RuntimeError(f"WAL lag {wal/1048576:.1f} MiB < 20 MiB")
 checks='app_read_after_write_checks_total{observed_node="replica"}'
 mismatch='app_read_after_write_mismatch_total{observed_node="replica"}'
 baseline=counter_delta(mismatch,start+20,pause_start-10)/max(1,counter_delta(checks,start+20,pause_start-10))
 incident=counter_delta(mismatch,pause_start+10,pause_end-10)/max(1,counter_delta(checks,pause_start+10,pause_end-10))
 recovery=counter_delta(mismatch,pause_end+30,min(end,pause_end+120))/max(1,counter_delta(checks,pause_end+30,min(end,pause_end+120)))
 if incident < .5 or (baseline > .001 and incident < baseline*10) or recovery > .1:
  raise RuntimeError(f"mismatch ratios baseline={baseline:.3f}, incident={incident:.3f}, recovery={recovery:.3f}")
 activity=samples('pg_stat_activity_count{application_name="order-app"}',pause_start+10,pause_end-10)
 if not activity or max(v for _,v in activity)-min(v for _,v in activity)>1:
  raise RuntimeError("order-app pg_stat_activity_count was not flat")
 locks=samples('pg_locks_count{mode=~"accessexclusivelock|exclusivelock"}',pause_start+10,pause_end-10)
 if not locks or max(v for _,v in locks)>0:
  raise RuntimeError("high-impact pg_locks_count was not flat at zero")
 print(f"gates: WAL {wal/1048576:.1f} MiB, mismatch {baseline:.1%}->{incident:.1%}->{recovery:.1%}, app activity flat, locks zero")
 return wal
if __name__=="__main__":
 start,end,anchor=map(float,sys.argv[1:4])
 # All gates run before any baked artifact is written.
 paused_peak=gate(start,end)
 TARGET.joinpath("prometheus/metrics_openmetrics.txt").write_text(openmetrics(start,end,anchor))
 TARGET.joinpath("loki/logs.jsonl").write_text(logs(start,end,anchor))
 print(f"captured WAL lag peak {paused_peak/1048576:.1f} MiB")
