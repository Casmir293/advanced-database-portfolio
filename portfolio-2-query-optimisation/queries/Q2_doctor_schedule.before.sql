-- Q2 Doctor's clinic list for one day (front desk, printed every morning).
-- Written the "natural" way: cast the timestamp to a date.
SELECT a.scheduled_at::time AS slot, p.hospital_no,
       p.first_name || ' ' || p.last_name AS patient, a.status, a.reason
FROM appointment a JOIN patient p USING (patient_id)
WHERE a.doctor_id = 78
  AND a.scheduled_at::date = DATE '2026-11-03'
ORDER BY a.scheduled_at;
