-- Q7 Chronic-care recall list: hypertensive patients (I10) with no visit in the last 12 months.
SELECT p.hospital_no, p.first_name, p.last_name, p.phone
FROM patient p
WHERE p.patient_id IN (SELECT e.patient_id FROM encounter e JOIN diagnosis d USING (encounter_id)
                       WHERE d.icd10_code = 'I10')
  AND p.patient_id NOT IN (SELECT e.patient_id FROM encounter e
                           WHERE e.started_at >= TIMESTAMPTZ '2025-11-02 00:00+01')
ORDER BY p.last_name, p.first_name;
