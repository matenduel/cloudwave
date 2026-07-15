import base64, json, os, time
from datetime import datetime, timezone
import psycopg

PRIMARY=os.environ["PRIMARY_DSN"]; REPLICA=os.environ["REPLICA_DSN"]; LOG=os.environ["LOG_PATH"]
PAUSE=int(os.getenv("PAUSE_AFTER_SECONDS", "120")); RESUME=int(os.getenv("RESUME_AFTER_SECONDS", "240"))

def event(name, **fields):
    fields.update(event=name, ts=datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"))
    with open(LOG, "a", buffering=1) as f: f.write(json.dumps(fields, separators=(",", ":")) + "\n")

def connect(dsn):
    for _ in range(90):
        try: return psycopg.connect(dsn, autocommit=True)
        except Exception: time.sleep(1)
    raise RuntimeError("database did not become ready")

p=connect(PRIMARY); r=connect(REPLICA)
with p.cursor() as c:
    c.execute("CREATE TABLE IF NOT EXISTS wal_pressure (id integer PRIMARY KEY, payload text NOT NULL, version bigint NOT NULL)")
    c.execute("INSERT INTO wal_pressure VALUES (1, %s, 0) ON CONFLICT (id) DO NOTHING", ("seed",))
event("controller_ready", target_node="replica", pause_after_seconds=PAUSE, resume_after_seconds=RESUME)
started=time.monotonic(); paused=False; resumed=False; last=0
while time.monotonic() - started < 425:
    elapsed=time.monotonic()-started
    if not paused and elapsed >= PAUSE:
        with r.cursor() as c: c.execute("SELECT pg_wal_replay_pause()")
        paused=True; event("replay_paused", target_node="replica", elapsed_seconds=round(elapsed,3))
    if paused and not resumed and elapsed >= RESUME:
        with r.cursor() as c: c.execute("SELECT pg_wal_replay_resume()")
        resumed=True; event("replay_resumed", target_node="replica", elapsed_seconds=round(elapsed,3))
    # During the paused interval create 50 changing 128 KiB tuples/s. This is a
    # deterministic WAL source, independent of request scheduling jitter.
    if paused and not resumed:
        due=int((elapsed-PAUSE)*50)
        while last < due:
            last += 1
            # Repeated bytes are TOAST-compressed and do not make physical WAL
            # pressure.  This is incompressible 128 KiB source data (base64 is
            # ~171 KiB text), so the pause has a reproducible byte-lag signal.
            payload=("w%08d-" % last) + base64.b64encode(os.urandom(131072)).decode()
            with p.cursor() as c: c.execute("UPDATE wal_pressure SET payload=%s, version=version+1 WHERE id=1", (payload,))
        time.sleep(.01)
    else:
        time.sleep(.05)
event("controller_finished", wal_updates=last)
