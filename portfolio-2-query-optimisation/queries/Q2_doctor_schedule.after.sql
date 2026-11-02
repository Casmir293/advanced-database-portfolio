-- Q2 (optimised): sargable half-open range instead of a cast on the column,
-- served by a composite B-tree index on appointment(doctor_id, scheduled_at).
SELECT a.scheduled_at::time AS slot, p.hospital_no,
       p.first_name || ' ' || p.last_name AS patient, a.status, a.reason
FROM appointment a JOIN patient p USING (patient_id)
WHERE a.doctor_id = 78
  AND a.scheduled_at >= TIMESTAMPTZ '2026-11-03 00:00+01'
  AND a.scheduled_at <  TIMESTAMPTZ '2026-11-04 00:00+01'
ORDER BY a.scheduled_at;
