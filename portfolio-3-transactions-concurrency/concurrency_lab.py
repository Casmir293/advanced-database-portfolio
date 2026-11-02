"""
Portfolio 3 - transactions and concurrency lab for Udoka Specialist Hospital.

Each scenario opens two (or more) real PostgreSQL sessions and interleaves their
statements in a fixed order, so concurrency effects are reproducible. When a
statement is expected to block, it runs in a background thread; a third
"observer" session then shows the lock wait from pg_stat_activity / pg_locks.

Every statement, result and error is written with a millisecond timestamp to
evidence/transcripts/<scenario>.txt.

Usage:  ../.venv/bin/python concurrency_lab.py            # all scenarios
        ../.venv/bin/python concurrency_lab.py S5 S6      # selected scenarios
"""
import sys
import threading
import time
from pathlib import Path

import psycopg

DSN = "dbname=udoka_hms options='-c search_path=hms,public -c lock_timeout=15s'"
OUT = Path(__file__).parent / "evidence" / "transcripts"


class Log:
    def __init__(self, name, title):
        self.path = OUT / f"{name}.txt"
        self.t0 = time.perf_counter()
        self.lines = []
        self.lock = threading.Lock()
        self.write(f"### {name}: {title}")

    def write(self, text, who=None):
        stamp = f"[{(time.perf_counter() - self.t0) * 1000:8.1f} ms]"
        prefix = f"{stamp} {who:<10}" if who else stamp
        with self.lock:
            for i, line in enumerate(str(text).splitlines() or [""]):
                self.lines.append(prefix + " " + line if i == 0 else " " * len(prefix) + " " + line)

    def note(self, text):
        self.write(f"-- {text}")

    def save(self):
        OUT.mkdir(parents=True, exist_ok=True)
        self.path.write_text("\n".join(self.lines) + "\n")
        print("\n".join(self.lines) + "\n")


def table(cur):
    rows = cur.fetchall()
    cols = [d.name for d in cur.description]
    data = [[("NULL" if v is None else str(v)) for v in r] for r in rows]
    widths = [max(len(c), *(len(r[i]) for r in data)) if data else len(c) for i, c in enumerate(cols)]
    out = [" | ".join(c.ljust(w) for c, w in zip(cols, widths)),
           "-+-".join("-" * w for w in widths)]
    out += [" | ".join(v.ljust(w) for v, w in zip(r, widths)) for r in data[:12]]
    out.append(f"({len(rows)} row{'s' if len(rows) != 1 else ''})")
    return "\n".join(out)


class Session:
    def __init__(self, name, log):
        self.name, self.log = name, log
        self.conn = psycopg.connect(DSN, autocommit=True, application_name=name)
        self.pid = self.conn.info.backend_pid
        self.thread = None

    def run(self, sql, params=None, quiet=False):
        if not quiet:
            self.log.write(f"> {sql.strip()}", self.name)
        try:
            cur = self.conn.execute(sql, params)
            result = table(cur) if cur.description else cur.statusmessage
            if not quiet:
                self.log.write(result, self.name)
            return cur
        except psycopg.Error as e:
            self.log.write(f"ERROR {e.sqlstate}: {e.diag.message_primary}"
                           + (f"\nDETAIL: {e.diag.message_detail}" if e.diag.message_detail else ""), self.name)
            return e

    def value(self, sql, params=None):
        """Run a query that returns one value, log it, and return the value."""
        cur = self.run(sql, params)
        if isinstance(cur, Exception):
            return cur
        # table() consumed the rows, so re-run quietly to fetch the value
        return self.conn.execute(sql, params).fetchone()[0]

    def run_async(self, sql, params=None):
        self.log.write(f"> {sql.strip()}   (sent; may block)", self.name)
        def target():
            try:
                cur = self.conn.execute(sql, params)
                self.log.write("unblocked -> " + (table(cur) if cur.description else cur.statusmessage), self.name)
            except psycopg.Error as e:
                self.log.write(f"unblocked -> ERROR {e.sqlstate}: {e.diag.message_primary}"
                               + (f"\nDETAIL: {e.diag.message_detail}" if e.diag.message_detail else ""), self.name)
        self.thread = threading.Thread(target=target)
        self.thread.start()
        time.sleep(0.4)

    def wait(self):
        if self.thread:
            self.thread.join()
            self.thread = None

    def close(self):
        self.conn.close()


def show_waits(obs, *sessions):
    pids = [s.pid for s in sessions]
    obs.run("""
        SELECT application_name AS session, pid, state, wait_event_type, wait_event,
               pg_blocking_pids(pid) AS blocked_by
        FROM pg_stat_activity WHERE pid = ANY(%s) ORDER BY application_name""", (pids,))


def scenario(name, title):
    def deco(fn):
        SCENARIOS[name] = (title, fn)
        return fn
    return deco


SCENARIOS = {}


# ---------------------------------------------------------------------------
@scenario("S1_commit", "Atomic consultation workflow - COMMIT")
def s1(log):
    a = Session("doctor", log)
    log.note("A consultation creates an encounter, diagnosis, prescription, lab order and invoice.")
    log.note("Either all five are recorded or none are.")
    a.run("BEGIN")
    a.run("""INSERT INTO encounter (patient_id, doctor_id, branch_id, encounter_type, started_at, ended_at, complaint)
             SELECT p.patient_id, 30, 1, 'OPD', now(), now() + interval '15 min', 'Fever and headache for 3 days'
             FROM patient p WHERE hospital_no = 'USH-0000002'
             RETURNING encounter_id""")
    eid = a.conn.execute("SELECT currval(pg_get_serial_sequence('hms.encounter','encounter_id'))").fetchone()[0]
    a.run("INSERT INTO diagnosis VALUES (%s, 'B50.9', true)", (eid,))
    a.run("INSERT INTO prescription (encounter_id, issued_at) VALUES (%s, now()) RETURNING rx_id", (eid,))
    a.run("""INSERT INTO prescription_item (rx_id, line_no, drug_id, dose, frequency, duration_days, qty_prescribed)
             VALUES (currval(pg_get_serial_sequence('hms.prescription','rx_id')), 1, 1, '1 tab', 'BD', 3, 6),
                    (currval(pg_get_serial_sequence('hms.prescription','rx_id')), 2, 2, '1 g', 'TDS', 3, 18)""")
    a.run("INSERT INTO lab_order (encounter_id, ordered_at, priority) VALUES (%s, now(), 'URGENT')", (eid,))
    a.run("""INSERT INTO invoice (patient_id, encounter_id, branch_id, issued_at)
             SELECT patient_id, encounter_id, branch_id, now() FROM encounter WHERE encounter_id = %s
             RETURNING invoice_id""", (eid,))
    a.run("COMMIT")
    a.run("""SELECT e.encounter_id, d.icd10_code, count(DISTINCT pi.line_no) AS rx_lines,
                    count(DISTINCT o.order_id) AS lab_orders, count(DISTINCT i.invoice_id) AS invoices
             FROM encounter e JOIN diagnosis d USING (encounter_id)
             JOIN prescription rx USING (encounter_id) JOIN prescription_item pi USING (rx_id)
             JOIN lab_order o USING (encounter_id) JOIN invoice i USING (encounter_id)
             WHERE e.encounter_id = %s GROUP BY 1, 2""", (eid,))
    a.run("SELECT table_name, operation, row_pk, changed_by FROM audit_log WHERE row_pk = %s::text ORDER BY audit_id",
          (eid,))
    log.note("All rows are durable after COMMIT; the audit trigger fired in the same transaction.")
    a.close()


@scenario("S2_rollback", "Dispense fails on one drug - whole transaction ROLLBACK")
def s2(log):
    a = Session("pharmacist", log)
    log.note("Setup: Nsukka has only 2 vials of artesunate (drug 18); the prescription needs 6.")
    a.run("UPDATE pharmacy_stock SET qty_on_hand = 2 WHERE branch_id = 2 AND drug_id = 18", quiet=True)
    a.run("UPDATE pharmacy_stock SET qty_on_hand = 600 WHERE branch_id = 2 AND drug_id = 2", quiet=True)
    enc = a.conn.execute("""INSERT INTO encounter (patient_id, doctor_id, branch_id, encounter_type, started_at)
                            VALUES (14483, (SELECT min(staff_id) FROM staff WHERE role='DOCTOR' AND branch_id=2), 2,
                                    'OPD', now()) RETURNING encounter_id""").fetchone()[0]
    rx = a.conn.execute("INSERT INTO prescription (encounter_id, issued_at) VALUES (%s, now()) RETURNING rx_id",
                        (enc,)).fetchone()[0]
    a.conn.execute("""INSERT INTO prescription_item (rx_id, line_no, drug_id, dose, frequency, duration_days, qty_prescribed)
                      VALUES (%s, 1, 2, '1 g', 'TDS', 3, 18), (%s, 2, 18, '120 mg', 'stat', 1, 6)""", (rx, rx))
    a.run("SELECT drug_id, qty_on_hand FROM pharmacy_stock WHERE branch_id = 2 AND drug_id IN (2, 18) ORDER BY 1")
    a.run("BEGIN")
    a.run("SELECT dispense_prescription(%s, 2::smallint)", (rx,))
    a.run("SELECT count(*) FROM pharmacy_stock")   # any statement now fails: the transaction is aborted
    a.run("ROLLBACK")
    log.note("Paracetamol (drug 2) was decremented first, then artesunate violated CHECK (qty_on_hand >= 0).")
    log.note("Because the transaction aborted, the paracetamol decrement is undone too:")
    a.run("SELECT drug_id, qty_on_hand FROM pharmacy_stock WHERE branch_id = 2 AND drug_id IN (2, 18) ORDER BY 1")
    a.run("SELECT line_no, drug_id, qty_prescribed, qty_dispensed FROM prescription_item WHERE rx_id = %s", (rx,))
    a.close()


@scenario("S3_savepoint", "HMO remittance batch - SAVEPOINT isolates one bad line")
def s3(log):
    a = Session("billing", log)
    # make the scenario re-runnable: remove payments from a previous run and recompute status
    old = [r[0] for r in a.conn.execute(
        "DELETE FROM payment WHERE reference LIKE 'HMO-REMIT-%' RETURNING invoice_id")]
    for inv_id in old:
        a.conn.execute("UPDATE invoice SET status = 'OPEN' WHERE invoice_id = %s", (inv_id,))
    inv = [r[0] for r in a.conn.execute(
        "SELECT invoice_id FROM invoice_summary WHERE status = 'OPEN' AND amount_paid = 0 AND branch_id = 1 "
        "ORDER BY invoice_id LIMIT 2")]
    batch = [(inv[0], "HMO-REMIT-001"), (99999999, "HMO-REMIT-002"), (inv[1], "HMO-REMIT-003")]
    log.note(f"An HMO remittance file pays 3 invoices {[b[0] for b in batch]}.")
    log.note("Line 2 quotes an invoice number that does not exist in our system.")
    a.run("BEGIN")
    for n, (inv_id, ref) in enumerate(batch, 1):
        a.run(f"SAVEPOINT line_{n}")
        res = a.run("SELECT post_payment(%s, 5000, 'HMO', %s)", (inv_id, ref))
        if isinstance(res, Exception):
            a.run(f"ROLLBACK TO SAVEPOINT line_{n}")
            log.note(f"Line {n} undone and queued for manual reconciliation; the transaction is still usable.")
        else:
            a.run(f"RELEASE SAVEPOINT line_{n}")
    a.run("COMMIT")
    a.run("SELECT p.invoice_id, p.amount, p.reference, i.status FROM payment p JOIN invoice i USING (invoice_id) "
          "WHERE p.reference LIKE 'HMO-REMIT-%' ORDER BY 1")
    log.note("Without savepoints, the single bad line would have aborted the whole remittance.")
    a.close()


@scenario("S4_isolation_reads", "Read phenomena: dirty read, non-repeatable read, phantom (READ COMMITTED vs REPEATABLE READ)")
def s4(log):
    a, b = Session("lab", log), Session("billing", log)
    inv = a.conn.execute("SELECT invoice_id FROM invoice WHERE status = 'OPEN' ORDER BY invoice_id LIMIT 1").fetchone()[0]
    a.conn.execute("DELETE FROM invoice_line WHERE invoice_id = %s AND description = 'Repeat malaria film'", (inv,))
    q_total = f"SELECT SUM(qty * unit_price) AS total, count(*) AS lines FROM invoice_line WHERE invoice_id = {inv}"

    log.note("(1) Dirty read: even at READ UNCOMMITTED, PostgreSQL never shows uncommitted data.")
    b.run("BEGIN ISOLATION LEVEL READ UNCOMMITTED")
    a.run("BEGIN")
    a.run(f"INSERT INTO invoice_line VALUES ({inv}, 50, 'LAB', 'Repeat malaria film', 1, 1000)")
    b.run(q_total)
    a.run("ROLLBACK")
    b.run("COMMIT")

    log.note("(2) READ COMMITTED: each statement sees a fresh snapshot -> non-repeatable read + phantom row.")
    b.run("BEGIN ISOLATION LEVEL READ COMMITTED")
    b.run(q_total)
    a.run(f"INSERT INTO invoice_line VALUES ({inv}, 50, 'LAB', 'Repeat malaria film', 1, 1000)")
    b.run(q_total)
    b.run("COMMIT")
    a.run(f"DELETE FROM invoice_line WHERE invoice_id = {inv} AND line_no = 50")

    log.note("(3) REPEATABLE READ: one snapshot for the whole transaction -> both reads agree.")
    b.run("BEGIN ISOLATION LEVEL REPEATABLE READ")
    b.run(q_total)
    a.run(f"INSERT INTO invoice_line VALUES ({inv}, 50, 'LAB', 'Repeat malaria film', 1, 1000)")
    b.run(q_total)
    b.run("COMMIT")
    b.run(q_total)
    log.note("MVCC: the writer never blocked the reader; the new row version carries the writer's xmin.")
    a.run(f"SELECT xmin, xmax, line_no, description FROM invoice_line WHERE invoice_id = {inv} AND line_no = 50")
    a.run(f"DELETE FROM invoice_line WHERE invoice_id = {inv} AND line_no = 50", quiet=True)
    a.close(); b.close()


@scenario("S5_lost_update", "Lost update on pharmacy stock and three fixes")
def s5(log):
    a, b, obs = Session("pharm_A", log), Session("pharm_B", log), Session("observer", log)
    reset = "UPDATE pharmacy_stock SET qty_on_hand = 500 WHERE branch_id = 2 AND drug_id = 2"
    read = "SELECT qty_on_hand FROM pharmacy_stock WHERE branch_id = 2 AND drug_id = 2"
    check = "SELECT qty_on_hand AS final_stock FROM pharmacy_stock WHERE branch_id = 2 AND drug_id = 2"
    log.note("Two pharmacists dispense paracetamol at Nsukka at the same time: A gives 18 tablets, B gives 30.")
    log.note("Correct final stock = 500 - 18 - 30 = 452.")

    log.note("(1) PROBLEM: application-side read-modify-write under READ COMMITTED.")
    a.run(reset, quiet=True)
    a.run("BEGIN"); b.run("BEGIN")
    qa = a.value(read); qb = b.value(read)
    a.run(f"UPDATE pharmacy_stock SET qty_on_hand = {qa - 18} WHERE branch_id = 2 AND drug_id = 2")
    b.run_async(f"UPDATE pharmacy_stock SET qty_on_hand = {qb - 30} WHERE branch_id = 2 AND drug_id = 2")
    show_waits(obs, a, b)
    a.run("COMMIT"); b.wait(); b.run("COMMIT")
    obs.run(check)
    log.note("LOST UPDATE: A's 18 tablets vanished from the books (470 instead of 452).")

    log.note("(2) FIX A: atomic UPDATE ... SET qty = qty - n (row lock + re-check of the latest version).")
    a.run(reset, quiet=True)
    a.run("BEGIN"); b.run("BEGIN")
    a.run("UPDATE pharmacy_stock SET qty_on_hand = qty_on_hand - 18 WHERE branch_id = 2 AND drug_id = 2")
    b.run_async("UPDATE pharmacy_stock SET qty_on_hand = qty_on_hand - 30 WHERE branch_id = 2 AND drug_id = 2")
    a.run("COMMIT"); b.wait(); b.run("COMMIT")
    obs.run(check)

    log.note("(3) FIX B: pessimistic locking with SELECT ... FOR UPDATE.")
    a.run(reset, quiet=True)
    a.run("BEGIN"); b.run("BEGIN")
    qa = a.value(read + " FOR UPDATE")
    b.run_async(read + " FOR UPDATE")
    show_waits(obs, a, b)
    a.run(f"UPDATE pharmacy_stock SET qty_on_hand = {qa - 18} WHERE branch_id = 2 AND drug_id = 2")
    a.run("COMMIT"); b.wait()
    qb = b.conn.execute(read).fetchone()[0]
    b.run(f"UPDATE pharmacy_stock SET qty_on_hand = {qb - 30} WHERE branch_id = 2 AND drug_id = 2")
    b.run("COMMIT")
    obs.run(check)

    log.note("(4) FIX C: optimistic - REPEATABLE READ detects the conflict; the loser retries.")
    a.run(reset, quiet=True)
    a.run("BEGIN ISOLATION LEVEL REPEATABLE READ"); b.run("BEGIN ISOLATION LEVEL REPEATABLE READ")
    qa = a.value(read); qb = b.value(read)
    a.run(f"UPDATE pharmacy_stock SET qty_on_hand = {qa - 18} WHERE branch_id = 2 AND drug_id = 2")
    b.run_async(f"UPDATE pharmacy_stock SET qty_on_hand = {qb - 30} WHERE branch_id = 2 AND drug_id = 2")
    a.run("COMMIT"); b.wait(); b.run("ROLLBACK")
    log.note("B retries the whole transaction with a new snapshot:")
    b.run("BEGIN ISOLATION LEVEL REPEATABLE READ")
    qb = b.value(read)
    b.run(f"UPDATE pharmacy_stock SET qty_on_hand = {qb - 30} WHERE branch_id = 2 AND drug_id = 2")
    b.run("COMMIT")
    obs.run(check)
    for s in (a, b, obs):
        s.close()


@scenario("S6_write_skew", "Write skew on the on-call roster: REPEATABLE READ vs SERIALIZABLE (SSI)")
def s6(log):
    a, b, obs = Session("dr_A", log), Session("dr_B", log), Session("observer", log)
    dept, day = 1, "2026-11-15"
    docs = [r[0] for r in obs.conn.execute(
        "SELECT doctor_id FROM on_call_roster WHERE dept_id = %s AND shift_date = %s ORDER BY 1", (dept, day))]
    count_sql = f"SELECT count(*) AS on_call_now FROM on_call_roster WHERE dept_id = {dept} AND shift_date = '{day}' AND on_call"
    log.note(f"Rule: General Medicine (dept {dept}) must have at least one doctor on call on {day}.")
    log.note(f"Doctors {docs} are both on call. Each, feeling unwell, asks to come off call.")
    log.note("App logic: 'if at least 2 are on call, I may go off call'.")

    def attempt(level):
        obs.conn.execute(f"UPDATE on_call_roster SET on_call = true WHERE dept_id = {dept} AND shift_date = '{day}'")
        a.run(f"BEGIN ISOLATION LEVEL {level}"); b.run(f"BEGIN ISOLATION LEVEL {level}")
        ca = a.value(count_sql); cb = b.value(count_sql)
        if ca >= 2:
            a.run(f"UPDATE on_call_roster SET on_call = false WHERE dept_id = {dept} AND shift_date = '{day}' AND doctor_id = {docs[0]}")
        if cb >= 2:
            b.run(f"UPDATE on_call_roster SET on_call = false WHERE dept_id = {dept} AND shift_date = '{day}' AND doctor_id = {docs[1]}")
        a.run("COMMIT")
        r = b.run("COMMIT")
        return r

    log.note("(1) REPEATABLE READ (snapshot isolation): both see 2, both update DIFFERENT rows -> no conflict.")
    attempt("REPEATABLE READ")
    obs.run(count_sql)
    log.note("WRITE SKEW: the rule is broken - nobody is on call.")

    log.note("(2) SERIALIZABLE: SSI tracks the read/write dependency and aborts one transaction.")
    r = attempt("SERIALIZABLE")
    if isinstance(r, Exception):
        log.note("dr_B retries; the new snapshot shows only 1 doctor on call, so the app refuses the request.")
        b.run("BEGIN ISOLATION LEVEL SERIALIZABLE")
        cb = b.value(count_sql)
        b.run("COMMIT")
        log.note(f"on_call_now = {cb} -> request denied, rule preserved.")
    obs.run(count_sql)
    obs.conn.execute(f"UPDATE on_call_roster SET on_call = true WHERE dept_id = {dept} AND shift_date = '{day}'")
    for s in (a, b, obs):
        s.close()


@scenario("S7_double_booking", "Two receptionists book the same doctor slot (exclusion constraint as concurrency control)")
def s7(log):
    a, b, obs = Session("desk_ENU", log), Session("desk_call", log), Session("observer", log)
    doc, slot = 30, "2027-01-11 10:00+01"
    obs.conn.execute("DELETE FROM appointment WHERE doctor_id = %s AND scheduled_at >= '2027-01-11' "
                     "AND scheduled_at < '2027-01-12'", (doc,))
    ins = ("INSERT INTO appointment (patient_id, doctor_id, branch_id, scheduled_at, ends_at) "
           f"VALUES (%s, {doc}, 1, '{slot}', timestamptz '{slot}' + interval '15 min') RETURNING appt_id")

    log.note("(1) Both try 10:00 with Dr #30. First one commits.")
    a.run("BEGIN"); b.run("BEGIN")
    a.run(ins, (101,))
    b.run_async(ins, (202,))
    log.note("desk_call cannot decide yet: it must wait to see whether desk_ENU commits.")
    show_waits(obs, a, b)
    obs.run("""SELECT l.pid, a.application_name, l.locktype, l.mode, l.granted
               FROM pg_locks l JOIN pg_stat_activity a USING (pid)
               WHERE a.application_name IN ('desk_ENU','desk_call') AND l.locktype = 'transactionid'
               ORDER BY l.granted DESC""")
    a.run("COMMIT"); b.wait(); b.run("ROLLBACK")

    log.note("(2) Same race, but the first receptionist cancels (ROLLBACK): the waiter now succeeds.")
    obs.conn.execute("DELETE FROM appointment WHERE doctor_id = %s AND scheduled_at = %s", (doc, slot))
    a.run("BEGIN"); b.run("BEGIN")
    a.run(ins, (101,))
    b.run_async(ins, (202,))
    a.run("ROLLBACK"); b.wait(); b.run("COMMIT")
    obs.run(f"SELECT appt_id, patient_id, doctor_id, scheduled_at, status FROM appointment "
            f"WHERE doctor_id = {doc} AND scheduled_at = '{slot}'")
    for s in (a, b, obs):
        s.close()


@scenario("S8_bed_allocation", "Two nurses admit patients to the same ward: naive SELECT vs FOR UPDATE SKIP LOCKED")
def s8(log):
    a, b, obs = Session("nurse_A", log), Session("nurse_B", log), Session("observer", log)
    ward = 7   # Nsukka maternity
    pats = [r[0] for r in obs.conn.execute("""
        SELECT patient_id FROM patient p WHERE sex = 'F' AND reg_branch_id = 2
          AND date_of_birth BETWEEN '1990-01-01' AND '2000-01-01'
          AND NOT EXISTS (SELECT 1 FROM admission a WHERE a.patient_id = p.patient_id AND a.discharged_at IS NULL)
        ORDER BY patient_id LIMIT 2""")]

    def cleanup():
        obs.conn.execute("DELETE FROM admission WHERE patient_id = ANY(%s) AND admitted_at > '2026-11-02 12:00'", (pats,))
        obs.conn.execute("""UPDATE bed b SET is_occupied = EXISTS (SELECT 1 FROM admission a
                            WHERE a.bed_id = b.bed_id AND a.discharged_at IS NULL) WHERE ward_id = %s""", (ward,))
    cleanup()
    free = "SELECT bed_id, label FROM bed WHERE ward_id = 7 AND NOT is_occupied ORDER BY bed_id LIMIT 1"

    log.note(f"(1) NAIVE: both nurses look up 'first free bed' then insert. Patients {pats}.")
    a.run("BEGIN"); b.run("BEGIN")
    bed_a = a.value(free)
    bed_b = b.value(free)
    a.run(f"INSERT INTO admission (patient_id, bed_id, admitted_at) VALUES ({pats[0]}, {bed_a}, now())")
    b.run_async(f"INSERT INTO admission (patient_id, bed_id, admitted_at) VALUES ({pats[1]}, {bed_b}, now())")
    a.run(f"UPDATE bed SET is_occupied = true WHERE bed_id = {bed_a}")
    a.run("COMMIT"); b.wait(); b.run("ROLLBACK")
    log.note("Integrity held (the exclusion constraint stopped two patients in one bed), but nurse_B")
    log.note("waited and then had to start again - poor throughput at a busy maternity desk.")
    cleanup()

    log.note("(2) admit_patient(): SELECT ... FOR UPDATE SKIP LOCKED - each nurse gets a different bed, no waiting.")
    a.run("BEGIN"); b.run("BEGIN")
    a.run(f"SELECT * FROM admit_patient({pats[0]}, {ward}::smallint)")
    b.run(f"SELECT * FROM admit_patient({pats[1]}, {ward}::smallint)")
    a.run("COMMIT"); b.run("COMMIT")
    obs.run(f"""SELECT a.admission_id, a.patient_id, b.label AS bed, a.admitted_at
                FROM admission a JOIN bed b USING (bed_id) WHERE a.patient_id = ANY(ARRAY{pats}) AND a.discharged_at IS NULL""")
    cleanup()
    for s in (a, b, obs):
        s.close()


@scenario("S9_deadlock", "Inter-branch stock transfers in opposite directions: deadlock and the lock-ordering fix")
def s9(log):
    a, b, obs = Session("enu_store", log), Session("nsk_store", log), Session("observer", log)
    obs.conn.execute("UPDATE pharmacy_stock SET qty_on_hand = 1000 WHERE drug_id = 1 AND branch_id IN (1, 2)")
    check = "SELECT branch_id, qty_on_hand FROM pharmacy_stock WHERE drug_id = 1 AND branch_id IN (1, 2) ORDER BY 1"
    log.note("Enugu sends 10 packs of drug 1 to Nsukka while Nsukka sends 5 packs back to Enugu.")

    log.note("(1) NAIVE: each debits its own row first, then credits the other.")
    a.run("BEGIN"); b.run("BEGIN")
    a.run("UPDATE pharmacy_stock SET qty_on_hand = qty_on_hand - 10 WHERE drug_id = 1 AND branch_id = 1")
    b.run("UPDATE pharmacy_stock SET qty_on_hand = qty_on_hand - 5  WHERE drug_id = 1 AND branch_id = 2")
    a.run_async("UPDATE pharmacy_stock SET qty_on_hand = qty_on_hand + 10 WHERE drug_id = 1 AND branch_id = 2")
    show_waits(obs, a, b)
    b.run("UPDATE pharmacy_stock SET qty_on_hand = qty_on_hand + 5  WHERE drug_id = 1 AND branch_id = 1")
    a.wait()
    a.run("COMMIT"); b.run("COMMIT")
    log.note("PostgreSQL's deadlock detector (deadlock_timeout = 1s) aborted one transaction (its COMMIT")
    log.note("becomes ROLLBACK). Only the survivor's transfer is applied; the victim must be retried.")
    obs.run(check)

    log.note("(2) FIX: transfer_stock() locks both rows in branch_id order before updating.")
    obs.conn.execute("UPDATE pharmacy_stock SET qty_on_hand = 1000 WHERE drug_id = 1 AND branch_id IN (1, 2)")
    a.run("BEGIN"); b.run("BEGIN")
    a.run("SELECT transfer_stock(1, 1::smallint, 2::smallint, 10)")
    b.run_async("SELECT transfer_stock(1, 2::smallint, 1::smallint, 5)")
    show_waits(obs, a, b)
    a.run("COMMIT"); b.wait(); b.run("COMMIT")
    obs.run(check)
    log.note("Both transfers committed: 1000 - 10 + 5 = 995 at Enugu, 1000 + 10 - 5 = 1005 at Nsukka.")
    for s in (a, b, obs):
        s.close()


@scenario("S10_payment_idempotency", "Concurrent part-payments on one invoice + retried POS request")
def s10(log):
    a, b, obs = Session("cashier_A", log), Session("cashier_B", log), Session("observer", log)
    inv = obs.conn.execute("""SELECT invoice_id FROM invoice_summary
                              WHERE status = 'OPEN' AND amount_paid = 0 AND total_amount BETWEEN 10000 AND 20000
                              ORDER BY invoice_id LIMIT 1""").fetchone()[0]
    obs.conn.execute("UPDATE invoice SET status = 'OPEN' WHERE invoice_id IN "
                     "(SELECT invoice_id FROM payment WHERE reference LIKE 'POS-S10-%')")
    obs.conn.execute("DELETE FROM payment WHERE reference LIKE 'POS-S10-%'")
    obs.run(f"SELECT invoice_id, total_amount, amount_paid, balance, status FROM invoice_summary WHERE invoice_id = {inv}")
    total = obs.conn.execute(f"SELECT total_amount FROM invoice_summary WHERE invoice_id = {inv}").fetchone()[0]
    half = round(total / 2, 2)
    log.note("Patient pays half by card at one desk while a relative pays the other half by transfer at another.")
    a.run("BEGIN"); b.run("BEGIN")
    a.run(f"SELECT post_payment({inv}, {half}, 'CARD', 'POS-S10-A')")
    b.run_async(f"SELECT post_payment({inv}, {total - half}, 'TRANSFER', 'POS-S10-B')")
    show_waits(obs, a, b)
    a.run("COMMIT"); b.wait(); b.run("COMMIT")
    obs.run(f"SELECT invoice_id, total_amount, amount_paid, balance, status FROM invoice_summary WHERE invoice_id = {inv}")
    log.note("Without the invoice row lock, both would compute PARTIAL from their own snapshot and the")
    log.note("invoice would stay PARTIAL although fully paid.")
    log.note("The POS terminal times out and re-sends cashier_A's request:")
    a.run(f"SELECT post_payment({inv}, {half}, 'CARD', 'POS-S10-A')")
    obs.run(f"SELECT count(*) AS payments, SUM(amount) AS paid FROM payment WHERE invoice_id = {inv}")
    for s in (a, b, obs):
        s.close()


def main():
    wanted = sys.argv[1:] or list(SCENARIOS)
    for key in SCENARIOS:
        if any(key.split('_')[0] == w or key == w for w in wanted):
            title, fn = SCENARIOS[key]
            log = Log(key, title)
            fn(log)
            log.save()


if __name__ == "__main__":
    main()
