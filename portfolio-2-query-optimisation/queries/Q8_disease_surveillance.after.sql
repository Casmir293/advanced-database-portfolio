-- @set work_mem=64MB
-- Q8 (optimised): same SQL; work_mem raised for this reporting session so the hash join and
-- aggregate fit in memory (no temp-file batches). See README for the trade-off.
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
