-- Q8 Disease surveillance: top 5 primary diagnoses per branch per quarter since 2025.
WITH counts AS (
    SELECT e.branch_id, date_trunc('quarter', e.started_at) AS quarter, d.icd10_code, count(*) AS cases
    FROM encounter e JOIN diagnosis d USING (encounter_id)
    WHERE d.is_primary AND e.started_at >= TIMESTAMPTZ '2025-01-01 00:00+01'
    GROUP BY 1, 2, 3)
SELECT branch_code, quarter, icd10_code, cases, rk
FROM (SELECT b.branch_code, c.*, rank() OVER (PARTITION BY c.branch_id, c.quarter ORDER BY c.cases DESC) AS rk
      FROM counts c JOIN branch b USING (branch_id)) ranked
WHERE rk <= 5
ORDER BY branch_code, quarter, rk;
