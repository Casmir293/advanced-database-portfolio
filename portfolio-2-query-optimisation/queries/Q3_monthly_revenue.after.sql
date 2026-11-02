-- Q3 (optimised): read the pre-aggregated materialized view mv_monthly_revenue
-- (refreshed nightly with REFRESH MATERIALIZED VIEW CONCURRENTLY).
SELECT b.branch_code, m.month, m.item_type, m.revenue
FROM mv_monthly_revenue m JOIN branch b USING (branch_id)
WHERE m.month >= TIMESTAMPTZ '2025-01-01 00:00+01'
  AND m.month <  TIMESTAMPTZ '2026-01-01 00:00+01'
ORDER BY 1, 2, 3;
