-- =====================================================================
-- Portfolio 1 : constraint tests
-- Each test tries to break a business rule; the database must refuse.
-- Everything runs inside one transaction that is rolled back at the end,
-- so the data set is left unchanged.
--
-- Run: psql -X -e -d udoka_hms -f 04_constraint_tests.sql > ../evidence/constraint_tests_output.txt 2>&1
-- =====================================================================
\set ON_ERROR_ROLLBACK on
SET search_path = hms, public;
BEGIN;

\echo '--- T1 (entity integrity / candidate key): duplicate hospital number must be rejected'
INSERT INTO patient (hospital_no, first_name, last_name, date_of_birth, sex, reg_branch_id)
VALUES ('USH-0000001', 'Test', 'Duplicate', '1990-01-01', 'F', 1);

\echo '--- T2 (domain constraint): genotype must be one of AA, AS, AC, SS, SC'
INSERT INTO patient (hospital_no, first_name, last_name, date_of_birth, sex, genotype, reg_branch_id)
VALUES ('USH-9999991', 'Test', 'Genotype', '1990-01-01', 'M', 'XY', 1);

\echo '--- T3 (referential integrity): appointment for a doctor that does not exist'
INSERT INTO appointment (patient_id, doctor_id, branch_id, scheduled_at, ends_at)
VALUES (1, 999999, 1, '2026-11-20 09:00+01', '2026-11-20 09:15+01');

\echo '--- T4 (exclusion constraint): book a doctor into a slot that overlaps a live booking'
SELECT appt_id, doctor_id, scheduled_at, ends_at, status
FROM appointment WHERE status = 'BOOKED' ORDER BY appt_id LIMIT 1 \gset b_
INSERT INTO appointment (patient_id, doctor_id, branch_id, scheduled_at, ends_at)
SELECT 2, :b_doctor_id, branch_id, scheduled_at + interval '5 minutes', ends_at + interval '5 minutes'
FROM appointment WHERE appt_id = :b_appt_id;

\echo '--- T5 (partial exclusion): once that booking is CANCELLED the slot can be re-used (expect INSERT 0 1)'
UPDATE appointment SET status = 'CANCELLED' WHERE appt_id = :b_appt_id;
INSERT INTO appointment (patient_id, doctor_id, branch_id, scheduled_at, ends_at)
SELECT 2, :b_doctor_id, branch_id, scheduled_at + interval '5 minutes', ends_at + interval '5 minutes'
FROM appointment WHERE appt_id = :b_appt_id;

\echo '--- T6 (CHECK): appointment longer than 2 hours'
INSERT INTO appointment (patient_id, doctor_id, branch_id, scheduled_at, ends_at)
VALUES (1, :b_doctor_id, 1, '2027-01-04 08:00+01', '2027-01-04 12:00+01');

\echo '--- T7 (CHECK): pharmacy stock may never go negative'
UPDATE pharmacy_stock SET qty_on_hand = qty_on_hand - 1000000 WHERE branch_id = 2 AND drug_id = 1;

\echo '--- T8 (CHECK): cannot dispense more than was prescribed'
UPDATE prescription_item SET qty_dispensed = qty_prescribed + 1
WHERE (rx_id, line_no) = (SELECT rx_id, line_no FROM prescription_item LIMIT 1);

\echo '--- T9 (partial unique index): an encounter may have only one PRIMARY diagnosis'
INSERT INTO diagnosis (encounter_id, icd10_code, is_primary)
SELECT encounter_id, 'J06.9', true FROM diagnosis
WHERE is_primary AND icd10_code <> 'J06.9' ORDER BY encounter_id LIMIT 1;

\echo '--- T10 (exclusion constraint): admit a second patient into a bed that is currently occupied'
INSERT INTO admission (patient_id, bed_id, admitted_at)
SELECT 3, bed_id, now() FROM admission WHERE discharged_at IS NULL ORDER BY bed_id LIMIT 1;

\echo '--- T11 (unique / idempotency): the same payment reference cannot be posted twice'
INSERT INTO payment (invoice_id, amount, method, reference, paid_at)
SELECT invoice_id, amount, method, reference, now() FROM payment ORDER BY payment_id LIMIT 1;

\echo '--- T12 (FK, ON DELETE restrict): a patient with clinical history cannot be deleted'
DELETE FROM patient WHERE patient_id = 1;

\echo '--- T13 (trigger): changing a diagnosis writes an audit_log row with before/after images'
UPDATE diagnosis SET icd10_code = 'B50.9'
WHERE (encounter_id, icd10_code) = (SELECT encounter_id, icd10_code FROM diagnosis
                                    WHERE icd10_code = 'B54' AND is_primary ORDER BY encounter_id LIMIT 1);
SELECT table_name, operation, row_pk, old_row->>'icd10_code' AS old_code, new_row->>'icd10_code' AS new_code
FROM audit_log ORDER BY audit_id DESC LIMIT 1;

\echo '--- T14 (view): invoice totals are derived, never stored'
SELECT * FROM invoice_summary WHERE status = 'PARTIAL' ORDER BY invoice_id LIMIT 3;

ROLLBACK;
\echo '--- all test changes rolled back'
