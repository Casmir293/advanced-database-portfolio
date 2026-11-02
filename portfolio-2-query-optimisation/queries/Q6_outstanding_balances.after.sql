-- Q6 (optimised): filter first, aggregate later. Only OPEN/PARTIAL invoices at the
-- branch are found (partial index), then their lines and payments are summed per
-- invoice through LATERAL subqueries that use the PK / payment(invoice_id) indexes.
SELECT i.invoice_id, p.hospital_no, p.last_name, i.issued_at,
       t.total AS total_amount, COALESCE(pd.paid, 0) AS amount_paid,
       t.total - COALESCE(pd.paid, 0) AS balance
FROM invoice i
JOIN patient p USING (patient_id)
CROSS JOIN LATERAL (SELECT SUM(qty * unit_price) AS total FROM invoice_line l
                    WHERE l.invoice_id = i.invoice_id) t
LEFT JOIN LATERAL (SELECT SUM(amount) AS paid FROM payment y
                   WHERE y.invoice_id = i.invoice_id) pd ON true
WHERE i.status IN ('OPEN', 'PARTIAL') AND i.branch_id = 2
  AND i.issued_at < TIMESTAMPTZ '2026-10-03 00:00+01'
ORDER BY balance DESC
LIMIT 50;
