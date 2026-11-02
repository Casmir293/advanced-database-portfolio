-- Q4 Abnormal lab results from the last 7 days at the Enugu branch, for clinician review.
SELECT r.resulted_at, p.hospital_no, p.last_name, t.name AS test,
       COALESCE(r.value_num::text, r.value_text) AS result, t.unit, r.abnormal_flag, o.priority
FROM lab_result r
JOIN lab_order o  USING (order_id)
JOIN encounter e  USING (encounter_id)
JOIN patient p    ON p.patient_id = e.patient_id
JOIN lab_test t   USING (test_code)
WHERE r.abnormal_flag <> 'N'
  AND r.resulted_at >= TIMESTAMPTZ '2026-10-26 00:00+01'
  AND r.resulted_at <  TIMESTAMPTZ '2026-11-02 00:00+01'
  AND e.branch_id = 1
ORDER BY CASE o.priority WHEN 'STAT' THEN 1 WHEN 'URGENT' THEN 2 ELSE 3 END, r.resulted_at DESC;
