#!/bin/bash
set -euo pipefail
if [ ! -s "$PGDATA/PG_VERSION" ]; then
  rm -rf "$PGDATA"/*
  until gosu postgres pg_basebackup -h pg-primary -U replicator -D "$PGDATA" -R -C -S pg_replica_lag_slot -X stream; do
    echo "waiting for primary replication endpoint" >&2
    sleep 2
  done
fi
exec /usr/local/bin/docker-entrypoint.sh "$@"
