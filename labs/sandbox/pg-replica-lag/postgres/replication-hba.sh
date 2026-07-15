#!/bin/sh
set -eu
# The image's default host line is intentionally database-user specific and
# excludes physical replication; this lab needs the replica subnet endpoint.
echo 'host replication replicator all scram-sha-256' >> "$PGDATA/pg_hba.conf"
