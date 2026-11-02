-- Q1 Patient history: every encounter for one patient with diagnoses, drugs and lab results.
-- Used by the doctor at the start of each consultation.
SELECT e.encounter_id, e.started_at, e.encounter_type, b.branch_code,
       s.first_name || ' ' || s.last_name AS doctor,
       (SELECT string_agg(d.icd10_code || CASE WHEN d.is_primary THEN '*' ELSE '' END, ', ')
          FROM diagnosis d WHERE d.encounter_id = e.encounter_id)              AS diagnoses,
       (SELECT string_agg(dr.generic_name, ', ')
          FROM prescription rx JOIN prescription_item pi USING (rx_id) JOIN drug dr USING (drug_id)
         WHERE rx.encounter_id = e.encounter_id)                               AS drugs,
       (SELECT string_agg(r.test_code || '=' || COALESCE(r.value_num::text, r.value_text), '; ')
          FROM lab_order o JOIN lab_result r USING (order_id)
         WHERE o.encounter_id = e.encounter_id)                                AS labs
FROM patient p
JOIN encounter e ON e.patient_id = p.patient_id
JOIN branch b    ON b.branch_id = e.branch_id
JOIN staff s     ON s.staff_id = e.doctor_id
WHERE p.hospital_no = 'USH-0000002'
ORDER BY e.started_at DESC;
