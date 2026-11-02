-- Q7 (optimised): NOT IN rewritten as NOT EXISTS so the planner can use an anti-join
-- (NOT IN cannot be, because of its NULL semantics); index on diagnosis(icd10_code).
SELECT p.hospital_no, p.first_name, p.last_name, p.phone
FROM patient p
WHERE EXISTS (SELECT 1 FROM encounter e JOIN diagnosis d USING (encounter_id)
              WHERE e.patient_id = p.patient_id AND d.icd10_code = 'I10')
  AND NOT EXISTS (SELECT 1 FROM encounter e
                  WHERE e.patient_id = p.patient_id
                    AND e.started_at >= TIMESTAMPTZ '2025-11-02 00:00+01')
ORDER BY p.last_name, p.first_name;
