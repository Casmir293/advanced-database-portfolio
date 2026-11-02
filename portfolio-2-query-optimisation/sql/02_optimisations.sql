-- =====================================================================
-- Portfolio 2 : physical optimisations (indexes, materialized view)
-- Each object is tied to the query it serves. Run after 01_reset_baseline.sql.
-- =====================================================================
SET search_path = hms, public;
SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- Q1, Q7: patient history in reverse date order; also gives NOT EXISTS an index probe.
CREATE INDEX ix_encounter_patient_started ON encounter (patient_id, started_at DESC);
-- Q1: foreign keys are NOT indexed automatically in PostgreSQL.
CREATE INDEX ix_prescription_encounter ON prescription (encounter_id);
CREATE INDEX ix_lab_order_encounter    ON lab_order (encounter_id);

-- Q2: equality column first, range column second.
CREATE INDEX ix_appointment_doctor_time ON appointment (doctor_id, scheduled_at);

-- Q4: only ~40% of results are abnormal; a partial index stores just those rows.
CREATE INDEX ix_lab_result_abnormal_recent ON lab_result (resulted_at) WHERE abnormal_flag <> 'N';

-- Q5: trigram indexes support LIKE/ILIKE with a leading wildcard.
CREATE INDEX ix_patient_last_name_trgm  ON patient USING gin (last_name gin_trgm_ops);
CREATE INDEX ix_patient_first_name_trgm ON patient USING gin (first_name gin_trgm_ops);

-- Q6: unpaid invoices are ~12% of the table; index only those.
CREATE INDEX ix_invoice_unpaid_branch ON invoice (branch_id, issued_at) WHERE status IN ('OPEN','PARTIAL');
CREATE INDEX ix_payment_invoice       ON payment (invoice_id);

-- Q7: find encounters by diagnosis code.
CREATE INDEX ix_diagnosis_code ON diagnosis (icd10_code, encounter_id);

-- Q3: pre-aggregated monthly revenue. The unique index allows REFRESH ... CONCURRENTLY,
-- so dashboards can still read the old version while the refresh runs.
CREATE MATERIALIZED VIEW mv_monthly_revenue AS
SELECT i.branch_id, date_trunc('month', i.issued_at) AS month, l.item_type,
       SUM(l.qty * l.unit_price) AS revenue, count(DISTINCT i.invoice_id) AS invoices
FROM invoice i JOIN invoice_line l USING (invoice_id)
GROUP BY 1, 2, 3;
CREATE UNIQUE INDEX ux_mv_monthly_revenue ON mv_monthly_revenue (branch_id, month, item_type);

-- Planner cost model: the default random_page_cost = 4 assumes spinning disks, where a
-- random read costs 4x a sequential one. This server runs on NVMe SSD, so 1.1 is realistic
-- and lets the planner pick index nested loops for selective joins (seen in Q4).
ALTER DATABASE udoka_hms SET random_page_cost = 1.1;
SET random_page_cost = 1.1;

ANALYZE;
