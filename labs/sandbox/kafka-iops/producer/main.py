import json
import os
import threading
import time

import requests
from flask import Flask, jsonify
from kafka import KafkaProducer
from prometheus_client import Counter, start_http_server


KAFKA_BOOTSTRAP_SERVERS = os.getenv("KAFKA_BOOTSTRAP_SERVERS", "kafka:29092")
TARGET_RPS = float(os.getenv("TARGET_RPS", "60"))

app = Flask(__name__)

producer_records_total = Counter(
    "producer_records_total",
    "Kafka records successfully delivered by the producer",
)
producer_delivery_errors_total = Counter(
    "producer_delivery_errors_total",
    "Kafka delivery failures encountered by the producer",
)
app_http_requests_total = Counter(
    "app_http_requests_total",
    "HTTP requests handled by the application",
    ["service", "route", "status"],
)

kafka_producer = KafkaProducer(
    bootstrap_servers=KAFKA_BOOTSTRAP_SERVERS,
    acks="all",
    retries=5,
    max_block_ms=5000,
    request_timeout_ms=5000,
)

partition_lock = threading.Lock()
next_partition = 0

window_lock = threading.Lock()
window_accepted = 0
window_delivery_errors = 0

log_lock = threading.Lock()


def write_log(event, **fields):
    payload = {
        "ts": time.time(),
        "level": "INFO",
        "service": "producer",
        "event": event,
        **fields,
    }
    line = json.dumps(payload, separators=(",", ":"))
    with log_lock:
        print(line, flush=True)
        with open("/logs/producer.jsonl", "a", encoding="utf-8") as log_file:
            log_file.write(line + "\n")
            log_file.flush()


def order_payload():
    return os.urandom(1024)


def choose_partition():
    global next_partition
    with partition_lock:
        partition = next_partition
        next_partition = (next_partition + 1) % 3
        return partition


def note_success():
    global window_accepted, window_delivery_errors
    with window_lock:
        window_accepted += 1
        if window_accepted % 300 == 0:
            write_log(
                "produce_window",
                accepted=window_accepted,
                delivery_errors=window_delivery_errors,
            )
            window_accepted = 0
            window_delivery_errors = 0


def note_failure():
    global window_delivery_errors
    with window_lock:
        window_delivery_errors += 1


@app.post("/orders")
def create_order():
    try:
        partition = choose_partition()
        future = kafka_producer.send(
            "orders",
            value=order_payload(),
            partition=partition,
        )
        future.get(timeout=5)
        producer_records_total.inc()
        app_http_requests_total.labels(
            service="producer",
            route="/orders",
            status="202",
        ).inc()
        note_success()
        return jsonify(status="accepted", partition=partition), 202
    except Exception:
        producer_delivery_errors_total.inc()
        app_http_requests_total.labels(
            service="producer",
            route="/orders",
            status="500",
        ).inc()
        note_failure()
        return jsonify(status="delivery_failed"), 500


@app.get("/healthz")
def healthz():
    return jsonify(status="ok"), 200


def load_generator():
    time.sleep(0.5)
    interval = 1.0 / TARGET_RPS
    next_tick = time.monotonic()

    while True:
        try:
            requests.post(
                "http://localhost:8080/orders",
                timeout=3,
            )
        except requests.RequestException:
            pass

        next_tick += interval
        sleep_seconds = next_tick - time.monotonic()
        if sleep_seconds > 0:
            time.sleep(sleep_seconds)
        else:
            next_tick = time.monotonic()


if __name__ == "__main__":
    os.makedirs("/logs", exist_ok=True)
    start_http_server(8000)
    threading.Thread(target=load_generator, name="load-generator", daemon=True).start()
    app.run(host="0.0.0.0", port=8080, threaded=True, use_reloader=False)
