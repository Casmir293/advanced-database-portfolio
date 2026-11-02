-- Q3 Monthly revenue by branch and revenue stream for 2025 (management dashboard).
SELECT b.branch_code, date_trunc('month', i.issued_at) AS month, l.item_type,
       SUM(l.qty * l.unit_price) AS revenue
FROM invoice i
JOIN invoice_line l USING (invoice_id)
JOIN branch b       USING (branch_id)
WHERE i.issued_at >= TIMESTAMPTZ '2025-01-01 00:00+01'
  AND i.issued_at <  TIMESTAMPTZ '2026-01-01 00:00+01'
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3;
