import json, os, time, uuid
from datetime import datetime, timezone
from flask import Flask, Response, jsonify, request
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST
import psycopg

app = Flask(__name__)
checks = Counter("app_read_after_write_checks_total", "read-after-write checks", ["observed_node"])
mismatches = Counter("app_read_after_write_mismatch_total", "read-after-write mismatches", ["observed_node"])
http_duration = Histogram("app_http_request_duration_seconds", "HTTP endpoint duration", ["endpoint"])
LOG_PATH = os.environ["LOG_PATH"]
SETTLE = float(os.getenv("READ_AFTER_WRITE_SETTLE_MS", "40")) / 1000

def connect(dsn):
    for _ in range(60):
        try: return psycopg.connect(dsn, autocommit=True)
        except Exception: time.sleep(1)
    raise RuntimeError("database did not become ready")

primary = connect(os.environ["PRIMARY_DSN"])
replica = connect(os.environ["REPLICA_DSN"])
with primary.cursor() as c:
    c.execute("CREATE TABLE IF NOT EXISTS orders (order_id uuid PRIMARY KEY, version integer NOT NULL, payload text NOT NULL, created_at timestamptz NOT NULL DEFAULT now())")

def log(event):
    event["ts"] = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    with open(LOG_PATH, "a", buffering=1) as f: f.write(json.dumps(event, separators=(",", ":")) + "\n")

@app.post("/orders")
def create_order():
    start = time.monotonic(); order_id = str(uuid.uuid4())
    payload = (request.get_json(silent=True) or {}).get("payload", "x" * 262144)
    with primary.cursor() as c:
        c.execute("INSERT INTO orders(order_id, version, payload) VALUES (%s, 1, %s)", (order_id, payload))
    elapsed = (time.monotonic()-start)*1000
    http_duration.labels("write").observe(elapsed / 1000)
    log({"event":"write_committed","order_id":order_id,"version":1,"observed_node":"primary","duration_ms":round(elapsed,3)})
    return jsonify(order_id=order_id, version=1), 201

@app.get("/orders/<order_id>")
def read_order(order_id):
    start=time.monotonic(); expected=int(request.args.get("expected_version", "1")); raw=request.args.get("raw") == "1"
    if not raw and expected: time.sleep(SETTLE)
    with replica.cursor() as c:
        c.execute("SELECT version FROM orders WHERE order_id=%s", (order_id,)); row=c.fetchone()
    observed = row[0] if row else 0; mismatch = observed < expected; elapsed=(time.monotonic()-start)*1000
    http_duration.labels("read").observe(elapsed / 1000)
    if expected:
        checks.labels("replica").inc()
        if mismatch: mismatches.labels("replica").inc()
        log({"event":"read_after_write","order_id":order_id,"expected_version":expected,"observed_version":observed,"observed_node":"replica","match":not mismatch,"duration_ms":round(elapsed,3)})
    return jsonify(order_id=order_id, version=observed, match=not mismatch), (200 if row else 404)

@app.get("/healthz")
def health(): return "ok\n"
@app.get("/metrics")
def metrics(): return Response(generate_latest(), mimetype=CONTENT_TYPE_LATEST)

@app.after_request
def observe(response):
    return response

if __name__ == "__main__": app.run(host="0.0.0.0", port=8080, threaded=True)
