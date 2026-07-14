import http from "k6/http";
import { check, fail, sleep } from "k6";

const TARGET = __ENV.TARGET || "http://app:8080";
const INCIDENT_DELAY_MS = 70_000;
const CONTROL_LEAD_MS = 30_000;
const HOT_KEYS = [
  "hot-1", "hot-2", "hot-3", "hot-4", "hot-5", "hot-6",
  "hot-7", "hot-8", "hot-9", "hot-10", "hot-11", "hot-12",
];

export const options = {
  scenarios: {
    baseline: {
      executor: "constant-arrival-rate",
      exec: "baseline",
      rate: 30,
      timeUnit: "1s",
      duration: "25s",
      preAllocatedVUs: 10,
      maxVUs: 30,
      gracefulStop: "2s",
    },

    control_burst: {
      executor: "shared-iterations",
      exec: "controlBurst",
      vus: 40,
      iterations: 40,
      maxDuration: "90s",
      gracefulStop: "1s",
    },

    stampede: {
      executor: "shared-iterations",
      exec: "stampede",
      vus: 40,
      iterations: 40,
      maxDuration: "90s",
      gracefulStop: "1s",
    },
  },

  thresholds: {
    http_req_failed: ["rate<0.01"],
  },
};

export function setup() {
  const expiresAtMs = Date.now() + INCIDENT_DELAY_MS;
  const response = http.get(
    `${TARGET}/admin/warm?expires_at_ms=${expiresAtMs}`,
  );

  if (response.status !== 200) {
    fail(`cache warm failed: ${response.status} ${response.body}`);
  }

  return { expiresAtMs };
}

export function baseline() {
  const key = HOT_KEYS[Math.floor(Math.random() * HOT_KEYS.length)];
  const response = http.get(`${TARGET}/data?key=${key}`);

  check(response, {
    "baseline request is successful": (r) => r.status === 200,
    "baseline is cache hit": (r) => r.headers["X-Cache"] === "HIT",
  });
}

export function controlBurst(data) {
  waitUntil(data.expiresAtMs - CONTROL_LEAD_MS);

  // Same 40 VU × 12 hot-key request shape as the incident.
  // Keys are still cached, so this burst should not affect backend latency.
  const responses = http.batch(
    HOT_KEYS.map((key) => ["GET", `${TARGET}/data?key=${key}`]),
  );

  check(responses, {
    "control burst all requests succeed": (rs) => rs.every((r) => r.status === 200),
    "control burst all requests are cache hits": (rs) =>
      rs.every((r) => r.headers["X-Cache"] === "HIT"),
  });
}

export function stampede(data) {
  // Date.now() barrier: all VUs fire at the PXAT expiration instant.
  waitUntil(data.expiresAtMs);

  // Deliberately identical burst geometry to controlBurst.
  // The shared PXAT expiration makes all requests miss together.
  const responses = http.batch(
    HOT_KEYS.map((key) => ["GET", `${TARGET}/data?key=${key}`]),
  );

  check(responses, {
    "stampede requests eventually succeed": (rs) => rs.every((r) => r.status === 200),
  });
}

function waitUntil(targetMs) {
  while (Date.now() < targetMs) {
    const remainingSeconds = (targetMs - Date.now()) / 1000;
    sleep(Math.min(remainingSeconds, 1));
  }
}
