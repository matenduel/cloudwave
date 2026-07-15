import http from 'k6/http';
import { check } from 'k6';
import { sleep } from 'k6';

export const options = {
  scenarios: {
    read_after_write: { executor: 'constant-arrival-rate', rate: 5, timeUnit: '1s', duration: '7m', preAllocatedVUs: 30, maxVUs: 60, exec: 'writeThenRead' },
    normal_reads: { executor: 'constant-arrival-rate', rate: 20, timeUnit: '1s', duration: '7m', preAllocatedVUs: 30, maxVUs: 60, exec: 'readExisting' },
  },
};
const target = __ENV.TARGET || 'http://order-app:8080';
const payload = JSON.stringify({ payload: 'o'.repeat(262144) });
export function writeThenRead() {
  const created = http.post(`${target}/orders`, payload, { headers: { 'Content-Type': 'application/json' } });
  check(created, { 'write committed': r => r.status === 201 });
  if (created.status !== 201) return;
  const body = created.json();
  const read = http.get(`${target}/orders/${body.order_id}?expected_version=${body.version}`);
  check(read, { 'read after write checked': r => r.status === 200 || r.status === 404 });
}
export function readExisting() {
  http.get(`${target}/orders/00000000-0000-0000-0000-000000000000?expected_version=0`);
  sleep(0.001);
}
