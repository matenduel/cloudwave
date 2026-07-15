# PostgreSQL replica replay lag — live reproduction kit

Primary write and hot-standby replica read are deliberately separated. At minute 2 the controller pauses only replica WAL replay; primary commits continue. The attractive but wrong diagnosis is **connection-pool exhaustion**.

## Run the fixed seven-minute scenario

```bash
chmod +x postgres/replica-entrypoint.sh scripts/run-scenario.sh
./scripts/run-scenario.sh
```

Grafana is `http://localhost:13000`, Prometheus is `http://localhost:19090`, and Loki is `http://localhost:13100`. Grafana is anonymous. The k6 scenario is 0–120 s normal, 120–240 s replay paused with 50 × 128 KiB WAL updates/s, then 240–420 s replay resumed.

## Investigation starting points

```promql
pg_stat_replication_pg_wal_lsn_diff{db_role="primary"} / 1024 / 1024
```

```promql
sum(rate(app_read_after_write_mismatch_total[30s])) / clamp_min(sum(rate(app_read_after_write_checks_total[30s])), 0.001)
```

```promql
sum by (db_role) (pg_stat_activity_count{application_name="order-app"})
```

```promql
sum by (db_role, mode) (pg_locks_count{mode=~"accessexclusivelock|exclusivelock"})
```

```logql
{container="app"} | json | match="false"
```

The primary-side WAL byte lag rises while replay is paused, then drains after resume. The app's two stable DB sessions and high-impact lock modes remain flat; mismatch events identify `observed_node="replica"`. On macOS Docker Desktop, replay and WAL throughput are VM/virtiofs dependent; use the baked kit for the fixed teaching dataset.

Stop and remove lab volumes with `docker compose down -v`.
