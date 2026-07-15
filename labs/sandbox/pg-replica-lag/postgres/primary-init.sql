CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'replica_secret';
CREATE ROLE app WITH LOGIN PASSWORD 'app_secret';
-- pg_wal_replay_pause/resume are superuser-only PostgreSQL recovery controls.
CREATE ROLE controller WITH LOGIN SUPERUSER PASSWORD 'controller_secret';
GRANT CONNECT ON DATABASE orders TO app, controller;
GRANT USAGE ON SCHEMA public TO app, controller;
GRANT CREATE ON SCHEMA public TO app;
ALTER ROLE app SET application_name = 'order-app';
ALTER ROLE controller SET application_name = 'replica-controller';
