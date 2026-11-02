-- Returns the database to the Portfolio 1 baseline: only PK / UNIQUE / exclusion indexes.
SET search_path = hms, public;
SET client_min_messages = warning;
DROP MATERIALIZED VIEW IF EXISTS mv_monthly_revenue;
DROP INDEX IF EXISTS ix_encounter_patient_started, ix_prescription_encounter, ix_lab_order_encounter,
                     ix_appointment_doctor_time, ix_lab_result_abnormal_recent,
                     ix_patient_last_name_trgm, ix_patient_first_name_trgm,
                     ix_invoice_unpaid_branch, ix_payment_invoice, ix_diagnosis_code,
                     ix_invoice_issued_brin;
ALTER DATABASE udoka_hms RESET random_page_cost;
SET random_page_cost = 4;   -- explicit: RESET would return to the connection default, which may include the ALTER DATABASE value
ANALYZE;
