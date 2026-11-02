-- =====================================================================
-- Portfolio 2 : query-processing experiments
-- Explores *why* the planner makes its choices, not only how fast a query runs.
-- Run AFTER 02_optimisations.sql:
--   psql -X -e -d udoka_hms -f sql/03_experiments.sql > evidence/experiments_output.txt 2>&1
-- DDL inside BEGIN ... ROLLBACK is transactional in PostgreSQL, so test indexes vanish afterwards.
-- =====================================================================
SET search_path = hms, public;
SET random_page_cost = 1.1;

\echo '=== E1  Selectivity decides access path: index for 1 day, seq scan for 1 year ==='
BEGIN;
CREATE INDEX tmp_invoice_issued_btree ON invoice (issued_at);
ANALYZE invoice;
EXPLAIN (ANALYZE, COSTS ON, BUFFERS) SELECT count(*), max(invoice_id) FROM invoice
WHERE issued_at >= '2025-06-02' AND issued_at < '2025-06-03';
EXPLAIN (ANALYZE, COSTS ON, BUFFERS) SELECT count(*), max(invoice_id) FROM invoice
WHERE issued_at >= '2025-01-01' AND issued_at < '2026-01-01';
ROLLBACK;

\echo '=== E2  BRIN vs B-tree on an append-only timestamp column ==='
-- Invoices are inserted in time order, so physical order ~ issued_at order (correlation ~1).
SELECT attname, round(correlation::numeric, 4) AS correlation
FROM pg_stats WHERE schemaname = 'hms' AND tablename = 'invoice' AND attname IN ('issued_at', 'patient_id');
BEGIN;
CREATE INDEX tmp_btree ON invoice (issued_at);
CREATE INDEX tmp_brin  ON invoice USING brin (issued_at) WITH (pages_per_range = 32);
SELECT relname, pg_size_pretty(pg_relation_size(oid)) AS size FROM pg_class WHERE relname IN ('tmp_btree', 'tmp_brin');
-- one month of invoices, BRIN only
DROP INDEX tmp_btree;
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM invoice
WHERE issued_at >= '2025-06-01' AND issued_at < '2025-07-01';
ROLLBACK;

\echo '=== E3  NOT IN pitfall 1: wrong answer when the subquery can return NULL ==='
-- October 2026 appointments that never turned into an encounter.
-- encounter.appt_id is NULL for emergency/inpatient encounters, and "x NOT IN (..., NULL)"
-- is never TRUE, so NOT IN silently returns 0 rows.
SELECT count(*) AS not_in_result
FROM appointment a
WHERE a.scheduled_at >= '2026-10-01' AND a.scheduled_at < '2026-11-01'
  AND a.appt_id NOT IN (SELECT e.appt_id FROM encounter e
                        WHERE e.started_at >= '2026-10-01' AND e.started_at < '2026-11-01');
SELECT count(*) AS not_exists_result
FROM appointment a
WHERE a.scheduled_at >= '2026-10-01' AND a.scheduled_at < '2026-11-01'
  AND NOT EXISTS (SELECT 1 FROM encounter e WHERE e.appt_id = a.appt_id);
-- (A first attempt ran this over all 414k appointments: the 357k-row subquery did not fit
--  in work_mem, PostgreSQL fell back to a plain SubPlan and the query was cancelled after 10 min.)

\echo '=== E4  NOT IN pitfall 2: when the subquery hash does not fit in work_mem ==='
SET work_mem = '64kB';
EXPLAIN (ANALYZE, COSTS OFF)
SELECT count(*) FROM patient p
WHERE p.reg_branch_id = 3
  AND p.patient_id NOT IN (SELECT e.patient_id FROM encounter e WHERE e.started_at >= '2026-10-01');
EXPLAIN (ANALYZE, COSTS OFF)
SELECT count(*) FROM patient p
WHERE p.reg_branch_id = 3
  AND NOT EXISTS (SELECT 1 FROM encounter e WHERE e.patient_id = p.patient_id AND e.started_at >= '2026-10-01');
RESET work_mem;

\echo '=== E5  Cardinality estimation with correlated columns (extended statistics) ==='
-- doctor 78 works only at branch 3, so (doctor_id = 78 AND branch_id = 3) is no more selective
-- than doctor_id = 78 alone. The planner assumes independence and multiplies selectivities.
EXPLAIN (ANALYZE, TIMING OFF) SELECT * FROM encounter WHERE doctor_id = 78 AND branch_id = 3;
BEGIN;
CREATE STATISTICS st_encounter_doctor_branch (dependencies) ON doctor_id, branch_id FROM encounter;
ANALYZE encounter;
EXPLAIN (ANALYZE, TIMING OFF) SELECT * FROM encounter WHERE doctor_id = 78 AND branch_id = 3;
ROLLBACK;
ANALYZE encounter;

\echo '=== E6  Covering index -> Index Only Scan (no heap access) ==='
EXPLAIN (ANALYZE, BUFFERS) SELECT status, count(*) FROM appointment
WHERE doctor_id = 78 AND scheduled_at >= '2026-01-01' AND scheduled_at < '2026-11-01' GROUP BY status;
-- VACUUM (which sets the visibility map that index-only scans rely on) cannot run inside a
-- transaction, so this index is created for real and dropped afterwards.
CREATE INDEX tmp_appt_cover ON appointment (doctor_id, scheduled_at) INCLUDE (status);
VACUUM (ANALYZE) appointment;
EXPLAIN (ANALYZE, BUFFERS) SELECT status, count(*) FROM appointment
WHERE doctor_id = 78 AND scheduled_at >= '2026-01-01' AND scheduled_at < '2026-11-01' GROUP BY status;
DROP INDEX tmp_appt_cover;

\echo '=== E7  Same join, three algorithms (planner choice vs forced alternatives) ==='
-- Encounters with their primary diagnosis for one week at Enugu.
EXPLAIN (ANALYZE, COSTS ON) SELECT e.encounter_id, d.icd10_code
FROM encounter e JOIN diagnosis d ON d.encounter_id = e.encounter_id AND d.is_primary
WHERE e.branch_id = 1 AND e.started_at >= '2026-10-01' AND e.started_at < '2026-10-08';
BEGIN;
SET LOCAL enable_nestloop = off;
EXPLAIN (ANALYZE, COSTS ON) SELECT e.encounter_id, d.icd10_code
FROM encounter e JOIN diagnosis d ON d.encounter_id = e.encounter_id AND d.is_primary
WHERE e.branch_id = 1 AND e.started_at >= '2026-10-01' AND e.started_at < '2026-10-08';
SET LOCAL enable_hashjoin = off;
EXPLAIN (ANALYZE, COSTS ON) SELECT e.encounter_id, d.icd10_code
FROM encounter e JOIN diagnosis d ON d.encounter_id = e.encounter_id AND d.is_primary
WHERE e.branch_id = 1 AND e.started_at >= '2026-10-01' AND e.started_at < '2026-10-08';
ROLLBACK;

\echo '=== E8  Materialized view staleness and concurrent refresh ==='
SELECT max(month) AS latest_month_in_mv FROM mv_monthly_revenue;
\timing on
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_monthly_revenue;
\timing off
