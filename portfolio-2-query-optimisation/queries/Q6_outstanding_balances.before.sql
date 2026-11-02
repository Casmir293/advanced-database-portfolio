-- Q6 Debt follow-up: 50 largest unpaid balances at Nsukka older than 30 days.
-- Uses the invoice_summary view, which aggregates ALL invoice lines and payments first.
SELECT s.invoice_id, p.hospital_no, p.last_name, s.issued_at, s.total_amount, s.amount_paid, s.balance
FROM invoice_summary s JOIN patient p USING (patient_id)
WHERE s.balance > 0 AND s.branch_id = 2
  AND s.issued_at < TIMESTAMPTZ '2026-10-03 00:00+01'
ORDER BY s.balance DESC
LIMIT 50;
