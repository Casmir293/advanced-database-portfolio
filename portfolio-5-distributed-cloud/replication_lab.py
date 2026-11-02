"""
Portfolio 5 - PostgreSQL replication lab (run after scripts/01_setup_replication.sh).

  primary      :5433  Enugu data centre
  replica_nsk  :5434  Nsukka DR site, synchronous standby
  replica_awk  :5435  Awka clinic, asynchronous read replica

Scenarios (each writes evidence/replication_<name>.txt):
  P1 topology and read-only standbys
  P2 consistency of reads: sync 'on' vs 'remote_apply'; stale read on the async replica
  P3 network partition to Nsukka: blocked commits, per-transaction downgrade, quorum commit
  P4 failover: crash the primary, promote Nsukka, measure RPO/RTO, re-point Awka

P4 is destructive (the old primary is left dead); rebuild with scripts/01_setup_replication.sh.
Usage: ../.venv/bin/python replication_lab.py [P1 P2 P3 P4]
"""
import os
import subprocess
import sys
import threading
import time
from pathlib import Path

import psycopg

HERE = Path(__file__).parent
LAB = Path(os.environ.get("LAB", HERE.parent / ".lab"))
PG_BIN = "/opt/homebrew/opt/postgresql@16/bin"
PORTS = {"primary": 5433, "replica_nsk": 5434, "replica_awk": 5435}
OUT = HERE / "evidence"


class Log:
    def __init__(self, name, title):
        self.name, self.t0, self.lines = name, time.perf_counter(), []
        self.write(f"### {title}")

    def write(self, text, who=""):
        stamp = f"[{(time.perf_counter() - self.t0):7.3f} s] {who:<12}"
        for i, line in enumerate(str(text).splitlines() or [""]):
            self.lines.append((stamp if i == 0 else " " * len(stamp)) + " " + line)

    def note(self, text):
        self.write("-- " + text)

    def save(self):
        (OUT / f"replication_{self.name}.txt").write_text("\n".join(self.lines) + "\n")
        print("\n".join(self.lines) + "\n")


def connect(node, **kw):
    return psycopg.connect(host="localhost", port=PORTS[node], user="postgres", dbname="udoka_hms",
                           autocommit=True, application_name=f"lab_{node}", options="-c search_path=hms,public", **kw)


def fmt(cur):
    rows = cur.fetchall()
    cols = [d.name for d in cur.description]
    data = [[("NULL" if v is None else str(v)) for v in r] for r in rows]
    w = [max([len(c)] + [len(r[i]) for r in data]) for i, c in enumerate(cols)]
    out = [" | ".join(c.ljust(x) for c, x in zip(cols, w)), "-+-".join("-" * x for x in w)]
    return "\n".join(out + [" | ".join(v.ljust(x) for v, x in zip(r, w)) for r in data])


def run(log, conn, node, sql, params=None):
    log.write("> " + " ".join(sql.split()), node)
    try:
        cur = conn.execute(sql, params)
        log.write(fmt(cur) if cur.description else cur.statusmessage, node)
        return cur
    except psycopg.Error as e:
        log.write(f"ERROR {e.sqlstate}: {e.diag.message_primary}", node)
        return e


def pg_ctl(*args):
    return subprocess.run([f"{PG_BIN}/pg_ctl", *args], capture_output=True, text=True)


SLOT = [0]


def booking_sql():
    """A new appointment in Feb 2027 for Dr 30; each call uses the next free 15-minute slot."""
    SLOT[0] += 1
    return ("INSERT INTO appointment (patient_id, doctor_id, branch_id, scheduled_at, ends_at) "
            f"VALUES (2, 30, 1, timestamptz '2027-02-01 08:00+01' + interval '{15 * SLOT[0]} min', "
            f"timestamptz '2027-02-01 08:15+01' + interval '{15 * SLOT[0]} min') RETURNING appt_id")


def init_slot():
    with connect("primary") as c:
        n = c.execute("SELECT count(*) FROM appointment WHERE scheduled_at >= '2027-02-01'").fetchone()[0]
    SLOT[0] = n + 1


# ---------------------------------------------------------------------------
def p1():
    log = Log("P1_topology", "P1 Topology, roles and read-only standbys")
    p, n, a = connect("primary"), connect("replica_nsk"), connect("replica_awk")
    run(log, p, "primary", """SELECT application_name, client_addr, state, sync_state, sent_lsn, replay_lsn,
                                     write_lag, flush_lag, replay_lag FROM pg_stat_replication ORDER BY 1""")
    run(log, p, "primary", "SELECT slot_name, slot_type, active, restart_lsn FROM pg_replication_slots ORDER BY 1")
    for node, c in (("primary", p), ("replica_nsk", n), ("replica_awk", a)):
        run(log, c, node, "SELECT pg_is_in_recovery() AS is_standby, current_setting('port') AS port, "
                          "(SELECT count(*) FROM appointment) AS appointments")
    log.note("Standbys serve reads but reject writes:")
    run(log, a, "replica_awk", booking_sql())
    SLOT[0] -= 1
    log.save()


def p2():
    log = Log("P2_read_consistency", "P2 Read-your-writes and stale reads")
    p, n, a = connect("primary"), connect("replica_nsk"), connect("replica_awk")

    log.note("(a) synchronous_commit = on: COMMIT waits until Nsukka has FLUSHED the WAL, not REPLAYED it.")
    log.note("    A read on the standby immediately after commit is therefore not guaranteed to see the row.")
    seen = 0
    for _ in range(50):
        appt = p.execute(booking_sql()).fetchone()[0]
        seen += n.execute("SELECT count(*) FROM appointment WHERE appt_id = %s", (appt,)).fetchone()[0]
    log.write(f"50 bookings committed on primary; visible on replica_nsk immediately after COMMIT: {seen}/50", "test")

    log.note("(b) synchronous_commit = remote_apply: COMMIT waits until Nsukka has REPLAYED it.")
    p.execute("SET synchronous_commit = remote_apply")
    seen, t = 0, time.perf_counter()
    for _ in range(50):
        appt = p.execute(booking_sql()).fetchone()[0]
        seen += n.execute("SELECT count(*) FROM appointment WHERE appt_id = %s", (appt,)).fetchone()[0]
    log.write(f"visible on replica_nsk immediately after COMMIT: {seen}/50 "
              f"(avg {(time.perf_counter() - t) / 50 * 1000:.2f} ms per booking incl. read)", "test")
    p.execute("RESET synchronous_commit")

    log.note("(c) Asynchronous Awka replica: pause WAL replay to simulate a slow WAN link.")
    run(log, a, "replica_awk", "SELECT pg_wal_replay_pause()")
    cur = run(log, p, "primary", booking_sql())
    appt = p.execute("SELECT max(appt_id) FROM appointment").fetchone()[0]
    run(log, a, "replica_awk", f"SELECT count(*) AS found FROM appointment WHERE appt_id = {appt}")
    run(log, p, "primary", """SELECT application_name, sync_state,
                                     pg_wal_lsn_diff(sent_lsn, replay_lsn) AS bytes_behind, replay_lag
                              FROM pg_stat_replication ORDER BY 1""")
    log.note("Awka staff would not see the new booking: a STALE READ (eventual consistency).")
    run(log, a, "replica_awk", "SELECT pg_wal_replay_resume()")
    time.sleep(0.5)
    run(log, a, "replica_awk", f"SELECT count(*) AS found FROM appointment WHERE appt_id = {appt}")
    log.note("After replay resumes, the replica converges.")
    log.save()


def p3():
    log = Log("P3_partition", "P3 Network partition between Enugu and Nsukka (CAP in practice)")
    p, obs = connect("primary"), connect("primary")
    log.note("Simulate the Enugu-Nsukka link failing by stopping replica_nsk.")
    log.write(pg_ctl("-D", str(LAB / "replica_nsk"), "stop", "-m", "fast").stdout.strip(), "shell")
    run(log, obs, "primary", "SELECT application_name, sync_state FROM pg_stat_replication ORDER BY 1")

    log.note("(a) A normal booking now waits for an acknowledgement that cannot arrive:")
    holder = {}

    def commit():
        t = time.perf_counter()
        try:
            p.execute(booking_sql())
            holder["msg"] = "returned"
        except psycopg.Error as e:
            holder["msg"] = f"ERROR {e.sqlstate}: {e.diag.message_primary}"
        holder["t"] = time.perf_counter() - t

    notices = []
    p.add_notice_handler(lambda d: notices.append(f"{d.severity}: {d.message_primary} {d.message_detail or ''}"))
    th = threading.Thread(target=commit)
    th.start()
    time.sleep(3)
    run(log, obs, "primary", """SELECT application_name, state, wait_event_type, wait_event, left(query, 40) AS query
                                FROM pg_stat_activity WHERE application_name = 'lab_primary' AND wait_event = 'SyncRep'""")
    log.note("After 3 s the receptionist gives up; the server cancels the WAIT (not the commit):")
    obs.execute("SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE wait_event = 'SyncRep'")
    th.join()
    log.write(f"booking statement {holder['msg']} after {holder['t']:.2f} s", "primary")
    for msg in notices:
        log.write(msg, "primary")
    log.note("The row IS committed locally but NOT on the DR site: consistency + durability were chosen")
    log.note("over availability (CP behaviour). Silent data-loss risk if Enugu now failed.")

    log.note("(b) Per-transaction downgrade for non-critical writes:")
    p2 = connect("primary")
    t = time.perf_counter()
    run(log, p2, "primary", "BEGIN")
    run(log, p2, "primary", "SET LOCAL synchronous_commit = local")
    run(log, p2, "primary", booking_sql())
    run(log, p2, "primary", "COMMIT")
    log.write(f"committed in {(time.perf_counter() - t) * 1000:.1f} ms (available, but not yet on DR)", "primary")

    log.note("(c) Quorum commit: any ONE of Nsukka or Awka may acknowledge.")
    run(log, obs, "primary", "ALTER SYSTEM SET synchronous_standby_names = 'ANY 1 (replica_nsk, replica_awk)'")
    run(log, obs, "primary", "SELECT pg_reload_conf()")
    time.sleep(0.5)
    run(log, obs, "primary", "SELECT application_name, sync_state FROM pg_stat_replication ORDER BY 1")
    t = time.perf_counter()
    run(log, p2, "primary", booking_sql())
    log.write(f"committed in {(time.perf_counter() - t) * 1000:.1f} ms with Awka's acknowledgement", "primary")

    log.note("Link restored: restart Nsukka; it catches up from its replication slot.")
    pg_ctl("-D", str(LAB / "replica_nsk"), "-l", str(LAB / "replica_nsk.log"), "start", "-w")
    run(log, obs, "primary", "ALTER SYSTEM SET synchronous_standby_names = 'FIRST 1 (replica_nsk)'")
    run(log, obs, "primary", "SELECT pg_reload_conf()")
    time.sleep(1.5)
    run(log, obs, "primary", """SELECT application_name, state, sync_state,
                                       pg_wal_lsn_diff(sent_lsn, replay_lsn) AS bytes_behind FROM pg_stat_replication ORDER BY 1""")
    log.save()


def p4():
    log = Log("P4_failover", "P4 Primary failure and failover to the Nsukka DR site")
    p = connect("primary")
    p.execute("CREATE TABLE IF NOT EXISTS failover_probe (id serial PRIMARY KEY, note text, at timestamptz DEFAULT clock_timestamp())")
    for i in range(1, 6):
        p.execute("INSERT INTO failover_probe (note) VALUES (%s)", (f"payment batch {i}",))
    last_appt = p.execute(booking_sql()).fetchone()[0]
    run(log, p, "primary", "SELECT count(*) AS probes, max(id) AS last_probe FROM failover_probe")
    log.write(f"last booking committed on primary: appt_id {last_appt}", "primary")
    run(log, p, "primary", "SELECT ('x' || substr(pg_walfile_name(pg_current_wal_lsn()), 1, 8))::bit(32)::int AS timeline_id")
    p.close()

    log.note("Enugu primary crashes (power failure): pg_ctl stop -m immediate (no clean shutdown).")
    t_crash = time.perf_counter()
    log.write(pg_ctl("-D", str(LAB / "primary"), "stop", "-m", "immediate").stdout.strip() or "stopped", "shell")
    try:
        connect("primary")
    except psycopg.OperationalError as e:
        log.write(f"connection refused: {str(e).splitlines()[0][:90]}", "app")

    log.note("Operator (or Patroni/repmgr in production) promotes the synchronous standby:")
    n = connect("replica_nsk")
    run(log, n, "replica_nsk", "SELECT pg_promote(wait => true)")
    run(log, n, "replica_nsk", "SELECT pg_is_in_recovery() AS is_standby, "
                              "('x' || substr(pg_walfile_name(pg_current_wal_lsn()), 1, 8))::bit(32)::int AS timeline_id")
    t_write = time.perf_counter()
    new = n.execute(booking_sql()).fetchone()[0]
    log.write(f"first write accepted on new primary (appt_id {new}) "
              f"{t_write - t_crash:.2f} s after the crash  -> RTO (scripted)", "replica_nsk")
    log.note("RPO check - is every transaction committed before the crash present?")
    run(log, n, "replica_nsk", "SELECT count(*) AS probes, max(id) AS last_probe FROM failover_probe")
    run(log, n, "replica_nsk", f"SELECT appt_id, scheduled_at FROM appointment WHERE appt_id = {last_appt}")
    log.note("RPO = 0: synchronous replication guaranteed nothing acknowledged to a user was lost.")

    log.note("Re-point the Awka async replica at the new primary (timeline switch).")
    run(log, n, "replica_nsk", "SELECT pg_create_physical_replication_slot('slot_awk')")
    conf = LAB / "replica_awk" / "postgresql.auto.conf"
    conf.write_text(conf.read_text() + "primary_conninfo = 'host=localhost port=5434 user=postgres application_name=replica_awk'\n")
    pg_ctl("-D", str(LAB / "replica_awk"), "-l", str(LAB / "replica_awk.log"), "restart", "-m", "fast", "-w")
    time.sleep(2)
    run(log, n, "replica_nsk", "SELECT application_name, state, sync_state FROM pg_stat_replication")
    a = connect("replica_awk")
    run(log, a, "replica_awk", f"SELECT pg_is_in_recovery() AS is_standby, (SELECT count(*) FROM appointment WHERE appt_id = {new}) AS sees_new_write")
    log.note("Old Enugu primary must NOT be restarted as a primary (split brain). It would rejoin as a")
    log.note("standby of Nsukka after pg_rewind; in production a fencing step (STONITH) enforces this.")
    log.save()


def main():
    OUT.mkdir(exist_ok=True)
    init_slot()
    todo = sys.argv[1:] or ["P1", "P2", "P3"]
    for s in todo:
        {"P1": p1, "P2": p2, "P3": p3, "P4": p4}[s]()


if __name__ == "__main__":
    main()
