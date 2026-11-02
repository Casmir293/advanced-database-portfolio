# Portfolio 2 – Query Processing and Optimisation

**Case study:** Udoka Specialist Hospital · **DBMS:** PostgreSQL 16.15 on an Apple M5 laptop (SSD, default configuration)
**Data:** the 4.9 M-row data set from Portfolio 1 (370 k encounters, 430 k appointments, 1.39 M invoice lines)

## 1. Method

1. I wrote eight queries that real hospital users run every day. Each has a *before* version, the
   natural first attempt, and an *after* version: [`queries/`](queries/).
2. [`run_benchmark.py`](run_benchmark.py) resets the database to the Portfolio 1 baseline, where only
   PK, UNIQUE and exclusion indexes exist ([`sql/01_reset_baseline.sql`](sql/01_reset_baseline.sql)).
   For each *before* query it captures `EXPLAIN (ANALYZE, BUFFERS, SETTINGS)`, runs it once to warm
   the cache, then takes the **median of 7 runs**. It then applies
   [`sql/02_optimisations.sql`](sql/02_optimisations.sql) and repeats with the *after* queries.
3. Correctness check: before and after return the same row counts. For the two rewritten queries
   (Q6, Q7) an `EXCEPT` in both directions returns 0 rows, so the results are identical.
4. **Harness bug found and fixed:** in an early run the *before* plans showed `random_page_cost = 1.1`
   (`EXPLAIN (SETTINGS)` reports it). `RESET` returns a setting to the *connection's* default, and that
   default already contained the `ALTER DATABASE … SET` from the previous run. The reset script now uses
   an explicit `SET random_page_cost = 4`, and the numbers below come from the corrected run.
5. [`sql/03_experiments.sql`](sql/03_experiments.sql) holds eight smaller experiments (E1–E8) that
   look at *why* the optimiser makes its choices.

All plans are in [`evidence/plans/`](evidence/plans/), sample result sets in
[`evidence/results/`](evidence/results/), and the experiments output in
[`evidence/experiments_output.txt`](evidence/experiments_output.txt).

## 2. Results

| Query (user) | Problem in the *before* plan | Optimisation | Before (ms) | After (ms) | Speed-up |
|---|---|---|---:|---:|---:|
| **Q1** Patient history (doctor) | Seq scan of `encounter`, plus a seq scan of `prescription` and `lab_order` **for every encounter** in the correlated subqueries. Foreign keys are not indexed automatically in PostgreSQL | Indexes on `encounter(patient_id, started_at DESC)`, `prescription(encounter_id)`, `lab_order(encounter_id)` | 385.53 | 0.55 | **699×** |
| **Q2** Doctor's clinic list (front desk) | `scheduled_at::date = …` wraps the column in a function, so no index can be used (non-sargable). The double-booking GiST index exists but is *partial* and the query doesn't match its predicate | Rewrite as a half-open range `>= day AND < day+1`; composite B-tree `(doctor_id, scheduled_at)` with the equality column first | 7.21 | 0.16 | **45×** |
| **Q3** Monthly revenue (management) | Hash join of 1.39 M invoice lines with a full year of invoices, then aggregation, on every dashboard refresh | Materialized view `mv_monthly_revenue` with a unique index, so it can be `REFRESH … CONCURRENTLY`ed nightly | 128.83 | 0.39 | **332×** |
| **Q4** Abnormal lab results, last 7 days (clinicians) | Parallel seq scan over 401 k results to find about 1 k rows | Partial index `lab_result(resulted_at) WHERE abnormal_flag <> 'N'`, plus `random_page_cost = 1.1` for SSD (see below) | 10.44 | 2.91 | **3.6×** |
| **Q5** Search by part of a name (records) | `ILIKE '%chukw%'` has a leading wildcard, so a B-tree is useless and the whole table is scanned | `pg_trgm` GIN indexes; the plan does a **BitmapAnd** of both name indexes | 10.04 | 0.54 | **19×** |
| **Q6** Largest unpaid balances (billing) | The `invoice_summary` view aggregates *all* 1.39 M lines and 345 k payments before the branch/age/balance filter is applied | Rewrite: filter unpaid invoices first (partial index `WHERE status IN ('OPEN','PARTIAL')`), then sum each one's lines/payments in `LATERAL` subqueries | 342.11 | 28.62 | **12×** |
| **Q7** Hypertension recall list (chronic care) | `IN` + `NOT IN` subqueries, with full scans of `encounter` and `diagnosis` | `EXISTS` / `NOT EXISTS` (semi- and anti-join), index on `diagnosis(icd10_code)` | 56.00 | 10.90 | **5.1×** |
| **Q8** Top-5 diagnoses per branch per quarter (public health) | The hash table for 188 k encounters didn't fit in `work_mem = 4MB`, so it split into 2 batches and spilled to temp files | `SET work_mem = '64MB'` for the reporting session, giving 1 batch and no temp I/O | 87.65 | 68.20 | **1.3×** |

Full numbers, buffer counts and plan shapes: [`evidence/benchmark_results.md`](evidence/benchmark_results.md).

Plan excerpt for Q1, showing the key change:

```
BEFORE (evidence/plans/Q1_before.txt)
  ->  Parallel Seq Scan on encounter e   (actual rows=119074 loops=3)        -- whole table read to find 40 rows
  SubPlan 2 ->  Seq Scan on prescription rx (loops=40)  Rows Removed by Filter: 326310   -- per encounter!
  SubPlan 3 ->  Seq Scan on lab_order o     (loops=40)  Rows Removed by Filter: 157582
  Buffers: shared hit=164562 read=14883                 Execution Time: 436 ms
AFTER (evidence/plans/Q1_after.txt)
  ->  Index Scan using ix_encounter_patient_started on encounter e
  SubPlan 2 ->  Index Scan using ix_prescription_encounter on prescription rx
  SubPlan 3 ->  Index Scan using ix_lab_order_encounter on lab_order o
  Buffers: shared hit=620 read=297                      Execution Time: < 1 ms
```

## 3. Performance analysis

**Where the big gains came from.** The three largest speed-ups (Q1, Q3, Q2) share one cause: the
*before* plan read far more data than the answer needed. Q1 touched 179 k buffers to return 40 rows;
after the change it touched 917. Q3 aggregated a whole year of data that changes only once a day.
Two rules follow for this hospital: **index every foreign key used in lookups**, and **pre-compute
reports that tolerate staleness**.

**Q4: an index alone was not enough.** With the partial index in place the plan improved, but the
planner still hash-joined `lab_order` using a parallel seq scan of 157 k rows. PostgreSQL's cost model
assumes `random_page_cost = 4`, which suits spinning disks. On an SSD a random read costs about the
same as a sequential one. With `random_page_cost = 1.1` it chose index nested loops all the way and
the median went from 6.5 ms (partial index alone, first benchmark run) to 2.9 ms. I set this at database level, because it is a property of the
hardware, not of one query.

**Q6 and Q7 read *more* buffers but run faster.** Buffers rose (Q6: 30 k → 67 k) because the new plan
does many small index probes, which mostly hit pages already in shared buffers. The old plan did a few
big sequential scans with hashing and aggregation over the whole table. "Buffers touched" alone is not
a measure of cost; CPU work and data volume through the plan also matter.

**Q8: a tuning knob with little benefit.** `work_mem` removed the disk batch (Batches 2 → 1) but saved
only 22%, because the real work is scanning about 550 k rows. I keep it as a lesson: `work_mem` is
allocated *per sort or hash node, per connection*, so raising it globally on a busy server is risky. It
should be set only for the reporting role. The better fix for Q8 is the same as for Q3: a
materialized view.

**The cost side.** The 10 indexes and the materialized view add about 64 MB, about 8% of the 770 MB database.
A bulk insert of 20,000 appointments went from 365 ms to 413 ms (+13%), because every insert now also
maintains `ix_appointment_doctor_time`. The materialized view takes 1.6 s to refresh and is stale
between refreshes. That is acceptable for a monthly revenue dashboard, but not for clinical data.

## 4. Query-processing experiments (`sql/03_experiments.sql`)

| # | Experiment | Observation |
|---|---|---|
| E1 | Same B-tree, 1 day vs 1 year of invoices | 1 day (387 rows): **Index Scan**, 0.11 ms. 1 year (99 k rows, 27% of the table): **Bitmap Heap Scan**, 8.6 ms. The planner switches access path based on estimated selectivity |
| E2 | BRIN vs B-tree on `invoice.issued_at` | BRIN is **24 kB vs 7.7 MB**, but `pg_stats.correlation` is only 0.11, because the generator inserted OPD, emergency and inpatient invoices as three separate time-ordered runs. BRIN therefore read 758 lossy blocks and threw away 73 k rows on recheck. **BRIN pays off only when physical order follows the column**, e.g. an append-only audit log |
| E3 | `NOT IN` with a NULL in the subquery | Appointments in October 2026 without an encounter: `NOT IN` returns **0** (wrong), `NOT EXISTS` returns **2,063** (right). `encounter.appt_id` is NULL for emergency visits, and `x NOT IN (…, NULL)` is never true. My first attempt over all data never finished: it was cancelled after 10 minutes (see E4) |
| E4 | `NOT IN` when the hash doesn't fit in memory | With `work_mem = 64kB`: `NOT IN` becomes a plain SubPlan re-run 1,011 times, **4,001 ms**. `NOT EXISTS` becomes an anti-join using an index-only scan, **7.8 ms** |
| E5 | Correlated predicates `doctor_id = 78 AND branch_id = 3` | The planner assumes the columns are independent and estimates **786** rows; actual **4,864**. After `CREATE STATISTICS … (dependencies)` the estimate is **4,965**. Bad estimates are the main cause of bad join choices |
| E6 | Covering index `INCLUDE (status)` | Bitmap heap scan 1.8 ms → **Index Only Scan, Heap Fetches: 0**, 0.23 ms. This needs a recent VACUUM so the visibility map is set |
| E7 | One join, three algorithms | Nested loop 6.1 ms (planner's choice) · hash join 23.4 ms · merge join 25.3 ms. The cost model ranked them correctly |
| E8 | MV refresh | `REFRESH … CONCURRENTLY` takes 1.6 s; readers are not blocked during the refresh |

## 5. How to reproduce

```bash
export PATH=/opt/homebrew/opt/postgresql@16/bin:$PATH
../.venv/bin/python run_benchmark.py              # ~20 s; writes evidence/benchmark_results.*
psql -X -e -d udoka_hms -f sql/03_experiments.sql > evidence/experiments_output.txt 2>&1
```
Timings will vary by machine; the plan shapes and relative speed-ups should hold.
