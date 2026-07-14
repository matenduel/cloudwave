import json
import logging
import os
import threading
import time
from dataclasses import dataclass

from flask import Flask, Response, jsonify, request
from kafka import KafkaConsumer
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Gauge, generate_latest


logging.getLogger("kafka").setLevel(logging.CRITICAL)

KAFKA_BOOTSTRAP_SERVERS = os.getenv("KAFKA_BOOTSTRAP_SERVERS", "kafka:29092")

app = Flask(__name__)

consumer_records_processed_total = Counter(
    "consumer_records_processed_total",
    "Kafka records fully processed by the consumer",
)
consumer_sink_write_ops_total = Counter(
    "consumer_sink_write_ops_total",
    "Actual append-and-flush sink write operations",
)
consumer_sink_write_bytes_total = Counter(
    "consumer_sink_write_bytes_total",
    "Bytes requested for actual sink write operations",
)
consumer_processing_delay_seconds = Gauge(
    "consumer_processing_delay_seconds",
    "Configured per-record processing delay in seconds",
)


@dataclass
class ControlState:
    extra_delay_ms: int = 0
    writes_per_record: int = 1
    sink_write_bytes: int = 1024


state = ControlState()
state_lock = threading.Lock()
consumer_processing_delay_seconds.set(0)

processed_lock = threading.Lock()
processed_total = 0
committed_total = 0

log_lock = threading.Lock()


def write_log(event, **fields):
    payload = {
        "ts": time.time(),
        "level": "INFO",
        "service": "consumer",
        "event": event,
        **fields,
    }
    line = json.dumps(payload, separators=(",", ":"))
    with log_lock:
        print(line, flush=True)
        with open("/logs/consumer.jsonl", "a", encoding="utf-8") as log_file:
            log_file.write(line + "\n")
            log_file.flush()


def state_snapshot():
    with state_lock:
        return ControlState(
            extra_delay_ms=state.extra_delay_ms,
            writes_per_record=state.writes_per_record,
            sink_write_bytes=state.sink_write_bytes,
        )


def expand(value, target_size):
    if not value:
        return b"\x00" * target_size
    repeats = (target_size + len(value) - 1) // len(value)
    return (value * repeats)[:target_size]


class Sink:
    def __init__(self, path):
        self.file = open(path, "ab", buffering=8192)

    def write(self, data):
        self.file.write(data)

    def flush(self):
        self.file.flush()


def build_consumer():
    return KafkaConsumer(
        "orders",
        bootstrap_servers=KAFKA_BOOTSTRAP_SERVERS,
        group_id="orders-cg",
        enable_auto_commit=False,
        auto_offset_reset="earliest",
        max_poll_records=10,
        max_poll_interval_ms=600000,
        session_timeout_ms=30000,
        heartbeat_interval_ms=10000,
        request_timeout_ms=60000,
        consumer_timeout_ms=-1,
    )


def process_record(record, sink):
    current = state_snapshot()
    data = expand(record.value, current.sink_write_bytes)

    for _ in range(current.writes_per_record):
        sink.write(data)
        sink.flush()
        consumer_sink_write_ops_total.inc()
        consumer_sink_write_bytes_total.inc(current.sink_write_bytes)

    if current.extra_delay_ms > 0:
        time.sleep(current.extra_delay_ms / 1000.0)

    consumer_records_processed_total.inc()
    return current


def consume_forever():
    global processed_total, committed_total

    sink = Sink("/data/orders.bin")
    consumer = None

    while True:
        if consumer is None:
            try:
                consumer = build_consumer()
            except Exception:
                time.sleep(1)
                continue

        try:
            records_by_partition = consumer.poll(timeout_ms=1000, max_records=10)

            for records in records_by_partition.values():
                for record in records:
                    process_record(record, sink)

                    with processed_lock:
                        processed_total += 1
                        current_processed = processed_total

                    if current_processed % 10 == 0:
                        consumer.commit_async()
                        with processed_lock:
                            committed_total += 10

                    if current_processed % 300 == 0:
                        with processed_lock:
                            write_log(
                                "processed_milestone",
                                processed_total=processed_total,
                                committed=committed_total,
                            )
        except Exception:
            time.sleep(0.2)


@app.get("/metrics")
def metrics():
    return Response(generate_latest(), mimetype=CONTENT_TYPE_LATEST)


@app.get("/healthz")
def healthz():
    return jsonify(status="ok"), 200


@app.post("/control")
def control():
    body = request.get_json(silent=True)
    if not isinstance(body, dict):
        return jsonify(error="JSON object body is required"), 400

    expected = ("extra_delay_ms", "writes_per_record", "sink_write_bytes")
    if any(key not in body for key in expected):
        return jsonify(error="all control fields are required"), 400

    try:
        extra_delay_ms = int(body["extra_delay_ms"])
        writes_per_record = int(body["writes_per_record"])
        sink_write_bytes = int(body["sink_write_bytes"])
    except (TypeError, ValueError):
        return jsonify(error="control fields must be integers"), 400

    if extra_delay_ms < 0 or writes_per_record < 1 or sink_write_bytes < 1:
        return jsonify(error="control values are out of range"), 400

    with state_lock:
        state.extra_delay_ms = extra_delay_ms
        state.writes_per_record = writes_per_record
        state.sink_write_bytes = sink_write_bytes
        consumer_processing_delay_seconds.set(extra_delay_ms / 1000.0)

    write_log(
        "control_updated",
        extra_delay_ms=extra_delay_ms,
        writes_per_record=writes_per_record,
        sink_write_bytes=sink_write_bytes,
    )
    return jsonify(
        extra_delay_ms=extra_delay_ms,
        writes_per_record=writes_per_record,
        sink_write_bytes=sink_write_bytes,
    ), 200


if __name__ == "__main__":
    os.makedirs("/logs", exist_ok=True)
    os.makedirs("/data", exist_ok=True)
    threading.Thread(target=consume_forever, name="kafka-consumer", daemon=True).start()
    app.run(host="0.0.0.0", port=8000, threaded=True, use_reloader=False)
