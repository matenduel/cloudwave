import http from "k6/http";
import { check, sleep } from "k6";

const TARGET = __ENV.TARGET || "http://app:8080";

// One 30-VU CPU burst every 30 seconds. 30 × 250 ms = 7.5 CPU-seconds;
// under a 0.50 CPU quota it occupies roughly half of each 30-second window.
const scenarios = {
  baseline: {
    executor: "constant-arrival-rate",
    exec: "baseline",
    rate: 1,
    timeUnit: "1s",
    duration: "5m30s",
    preAllocatedVUs: 2,
    maxVUs: 10,
    gracefulStop: "5s",
  },
};

for (let i = 1; i <= 10; i += 1) {
  scenarios[`burst_${String(i).padStart(2, "0")}`] = {
    executor: "per-vu-iterations",
    exec: "burst",
    vus: 30,
    iterations: 1,
    startTime: `${i * 30}s`,
    maxDuration: "29s",
    gracefulStop: "2s",
  };
}

export const options = { scenarios };

export function baseline() {
  const response = http.get(`${TARGET}/work?cpu_ms=20`);
  check(response, { "baseline status is 200": (r) => r.status === 200 });
  sleep(0.01);
}

export function burst() {
  const response = http.get(`${TARGET}/work?cpu_ms=250`);
  check(response, { "burst status is 200": (r) => r.status === 200 });
}
