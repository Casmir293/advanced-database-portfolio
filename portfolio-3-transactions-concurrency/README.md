# Portfolio 3 – Transactions and Concurrency

**Case study:** Udoka Specialist Hospital · **DBMS:** PostgreSQL 16.15 · **Driver:** Python 3 + psycopg 3

## 1. Why concurrency matters at the hospital

At 8 a.m. on a clinic day, several records officers, two pharmacy windows, the maternity desk and the
cashiers all write to the same tables. These are the risks this portfolio examines:

| Risk | Hospital consequence |
|---|---|
| Lost update on stock | The pharmacy believes it has drugs it has already given out |
| Double booking | Two patients arrive for the same 10:00 slot |
| Two patients assigned one bed | A safety incident in maternity |
| Write skew on the roster | A department is left with no doctor on call |
| Partial transaction | Paracetamol deducted but artesunate never dispensed |
| Duplicate payment | A retried POS request charges the patient twice |

## 2. How the evidence was produced

- [`sql/01_transaction_functions.sql`](sql/01_transaction_functions.sql) implements the business
  transactions as PL/pgSQL functions: `dispense_prescription`, `admit_patient`, `discharge_patient`,
  `post_payment` and `transfer_stock`.
- [`concurrency_lab.py`](concurrency_lab.py) opens **real, separate database sessions**, one per user
  (e.g. `pharm_A`, `pharm_B`), and interleaves their statements in a fixed order so each anomaly
  reproduces every time. When a statement is expected to block, it runs in a background thread, and an
  `observer` session queries `pg_stat_activity` / `pg_locks` to show *who is waiting for whom*.
- Every statement, result and error is time-stamped in [`evidence/transcripts/`](evidence/transcripts/).

```bash
export PATH=/opt/homebrew/opt/postgresql@16/bin:$PATH
psql -d udoka_hms -f sql/01_transaction_functions.sql
../.venv/bin/python concurrency_lab.py          # all 10 scenarios (~5 s); or e.g. "... S5 S6"
```

## 3. Scenarios and results

| # | Scenario | Concept | Outcome (from transcript) |
|---|---|---|---|
| [S1](evidence/transcripts/S1_commit.txt) | Doctor records a consultation: encounter, diagnosis, prescription, lab order, invoice | **Atomicity, COMMIT, durability** | All 5 inserts become visible together at COMMIT; the audit trigger's rows commit in the same transaction |
| [S2](evidence/transcripts/S2_rollback.txt) | Dispense paracetamol + artesunate when only 2 of 6 artesunate vials are in stock | **ROLLBACK, consistency via CHECK** | `23514 violates check constraint pharmacy_stock_qty_on_hand_check`; the transaction enters the aborted state (`25P02`) and after ROLLBACK the paracetamol stock is unchanged at 600 |
| [S3](evidence/transcripts/S3_savepoint.txt) | HMO remittance file with one line for a non-existent invoice | **SAVEPOINT / partial rollback** | Bad line → `ROLLBACK TO SAVEPOINT line_2`; lines 1 and 3 still commit and the invoices become PARTIAL |
| [S4](evidence/transcripts/S4_isolation_reads.txt) | Billing reads an invoice total twice while the lab adds a charge | **Isolation levels, MVCC** | Dirty read impossible even at READ UNCOMMITTED. READ COMMITTED: total changes between two reads (non-repeatable read + phantom line). REPEATABLE READ: both reads agree. The writer never blocks the reader; the new row version carries the writer's `xmin` |
| [S5](evidence/transcripts/S5_lost_update.txt) | Two pharmacists dispense 18 and 30 tablets from a stock of 500 | **Lost update + 3 fixes** | Read-modify-write: final **470** (18 tablets lost). Atomic `SET qty = qty - n`: **452** ✔. `SELECT … FOR UPDATE`: **452** ✔. REPEATABLE READ: loser gets `40001 could not serialize access due to concurrent update`, retries, **452** ✔ |
| [S6](evidence/transcripts/S6_write_skew.txt) | Both on-call doctors ask to come off call ("allowed if ≥ 2 on call") | **Write skew, SSI** | REPEATABLE READ: both commit → **0 doctors on call** (rule broken although no row was written twice). SERIALIZABLE: `40001 … read/write dependencies among transactions`; the retry sees 1 on call and the request is refused → rule kept |
| [S7](evidence/transcripts/S7_double_booking.txt) | Walk-in desk and call centre book Dr 30 at 10:00 simultaneously | **Constraint-based concurrency control** | The second insert *waits* on the first transaction (`wait_event = transactionid`, `blocked_by = [pid]`). If the first commits → `23P01 conflicting key value violates exclusion constraint`; if it rolls back → the waiter succeeds |
| [S8](evidence/transcripts/S8_bed_allocation.txt) | Two nurses admit women to Nsukka maternity at once | **Row locks, `SKIP LOCKED`** | Naive "first free bed": both pick B01, nurse_B blocks then fails with `23P01 … no_bed_overlap`. `admit_patient()` with `FOR UPDATE SKIP LOCKED`: nurse_A → B01, nurse_B → B02 immediately, no waiting |
| [S9](evidence/transcripts/S9_deadlock.txt) | Enugu ↔ Nsukka stock transfers in opposite directions | **Deadlock detection & prevention** | Naive: after `deadlock_timeout` (1 s) PostgreSQL aborts one side with `40P01 deadlock detected`. `transfer_stock()` locks rows in `branch_id` order: the second waits briefly, then both commit (995 / 1005) |
| [S10](evidence/transcripts/S10_payment_idempotency.txt) | Two cashiers post the two halves of one bill; then the POS re-sends a request | **Serialising on a parent row, idempotency** | `post_payment` locks the invoice row, so cashier_B waits and then sees A's payment → status **PAID** (not stuck at PARTIAL). The retried request is a no-op thanks to `ON CONFLICT (reference) DO NOTHING` |

Transcript excerpt (S5, lost update):

```
[   4.0 ms] pharm_B  > UPDATE pharmacy_stock SET qty_on_hand = 470 WHERE ...   (sent; may block)
[ 412.8 ms] observer session | state               | wait_event_type | wait_event    | blocked_by
                     pharm_A | idle in transaction | Client          | ClientRead    | []
                     pharm_B | active              | Lock            | transactionid | [34331]
[ 413.4 ms] observer final_stock = 470     -- should be 452: A's 18 tablets vanished
```

## 4. Analysis

**Isolation in PostgreSQL is snapshot-based (MVCC).** Each row version carries `xmin`/`xmax`
transaction ids, and a transaction sees only versions committed before its snapshot. That is why
readers never block writers (S4), and why PostgreSQL has no dirty reads at any level: READ UNCOMMITTED
is silently treated as READ COMMITTED. The isolation level only decides *when* the snapshot is taken:
for every statement (READ COMMITTED) or once per transaction (REPEATABLE READ / SERIALIZABLE).

**Isolation level alone does not prevent every anomaly.** The lost update in S5 happened at the
default READ COMMITTED, because the *application* computed the new value from a stale read. Three
fixes worked, and they suit different situations:

| Technique | Behaviour | Best for at the hospital |
|---|---|---|
| Atomic `UPDATE … SET x = x - n` | Second writer waits, then re-applies to the newest version | Simple counters: stock, bed counts |
| Pessimistic `SELECT … FOR UPDATE` | Block early, compute safely | Multi-step logic that must read first (dispense, payment status) |
| Optimistic REPEATABLE READ / SERIALIZABLE + retry | No waiting; loser gets 40001 and retries | Low-conflict, complex rules (rosters, scheduling) |

**Write skew (S6) is the subtle one.** Two transactions read the same set of rows, then each update a
*different* row. No row is written twice, so snapshot isolation sees no conflict. Only SERIALIZABLE,
which PostgreSQL implements as *Serializable Snapshot Isolation* with predicate (SIRead) locks,
detects the dangerous read-write dependency cycle. The cost is that the application **must** retry on
SQLSTATE `40001`.

**Constraints are the last line of defence.** In S7 and S8 the application logic was racy, but the
exclusion constraints from Portfolio 1 still prevented double booking and bed sharing. Under the hood,
the second inserter waited on the first one's transaction id and was then rejected. Correctness that
lives in the database survives buggy or concurrent clients. `SKIP LOCKED` then turns "correct but
slow" into "correct and fast" for queue-like work.

**Deadlocks are prevented by lock ordering, not by luck.** `dispense_prescription` locks stock rows
in `drug_id` order and `transfer_stock` locks in `branch_id` order, so any two transactions request
locks in the same sequence and a wait-for cycle cannot form.

**Durability.** COMMIT returns only after the WAL record is flushed (`synchronous_commit = on`, the
default). Portfolio 5 extends this to a replica.

## 5. Problems met while building the lab

- **Hard-coded IDs:** I first used staff 7 as the doctor, but staff IDs are assigned by role, and staff 7
  is a billing officer. The exclusion test would have failed on the FK, not on the overlap. I switched to
  doctor 30 after checking the catalog.
- **Scenario interference:** an early version of S3 inserted payments directly. That left
  `invoice.status = 'OPEN'` on a part-paid invoice, which S10 then picked and "over-paid" to a balance of
  −5,000. The remedy was the same rule the hospital needs: all payments go through `post_payment()`,
  which keeps the status consistent, and every scenario now cleans up after itself.
