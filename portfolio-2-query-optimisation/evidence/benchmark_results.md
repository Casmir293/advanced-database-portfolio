# Benchmark results

- Server: `PostgreSQL 16.15 (Homebrew) on aarch64-apple-darwin25.6.0` on arm64 macOS, default config (shared_buffers 128MB, work_mem 4MB)
- Median of 7 warm runs after 1 warm-up, client-side wall time incl. fetching rows

| Query | Technique | Before (ms) | After (ms) | Speed-up | Buffers before → after | Rows |
|---|---|---:|---:|---:|---|---:|
| Q1 | B-tree indexes on FK columns used by correlated subqueries | 385.53 | 0.55 | 699× | 179,425 → 917 | 40 |
| Q2 | Sargable range predicate + composite index (doctor_id, scheduled_at) | 7.21 | 0.16 | 45× | 5,377 → 50 | 14 |
| Q3 | Materialized view (pre-aggregation) | 128.83 | 0.39 | 332× | 20,012 → 12 | 144 |
| Q4 | Partial index on abnormal results + random_page_cost 1.1 (SSD) | 10.44 | 2.91 | 3.6× | 14,359 → 10,277 | 496 |
| Q5 | pg_trgm GIN indexes for wildcard ILIKE | 10.04 | 0.54 | 19× | 1,029 → 121 | 113 |
| Q6 | Query rewrite (filter before aggregate, LATERAL) + partial index | 342.11 | 28.62 | 12× | 30,680 → 67,128 | 50 |
| Q7 | NOT IN -> NOT EXISTS (anti-join) + index | 56.00 | 10.90 | 5.1× | 40,075 → 50,737 | 714 |
| Q8 | work_mem tuning (hash join / aggregate in memory) | 87.65 | 68.20 | 1.3× | 14,618 → 14,618 | 120 |

## Plan shape (node types)

**Q1** before: Gather Merge → Sort → Nested Loop → Hash Join → Seq Scan on encounter → Hash → Index Scan on patient using patient_hospital_no_key → Index Scan on branch using branch_pkey → Index Scan on staff using staff_pkey → Aggregate → Index Scan on diagnosis using diagnosis_pkey → Seq Scan on drug → Materialize → Seq Scan on prescription → Index Scan on prescription_item using prescription_item_pkey → Seq Scan on lab_order → Bitmap Heap Scan on lab_result → Bitmap Index Scan using lab_result_pkey  
**Q1** after: Sort → Nested Loop → Index Scan on patient using patient_hospital_no_key → Index Scan on encounter using ix_encounter_patient_started → Memoize → Index Scan on branch using branch_pkey → Index Scan on staff using staff_pkey → Aggregate → Index Scan on diagnosis using diagnosis_pkey → Index Scan on prescription using ix_prescription_encounter → Index Scan on prescription_item using prescription_item_pkey → Index Scan on drug using drug_pkey → Index Scan on lab_order using ix_lab_order_encounter → Index Scan on lab_result using lab_result_pkey

**Q2** before: Gather Merge → Sort → Nested Loop → Seq Scan on appointment → Index Scan on patient using patient_pkey  
**Q2** after: Nested Loop → Index Scan on appointment using ix_appointment_doctor_time → Index Scan on patient using patient_pkey

**Q3** before: Aggregate → Gather Merge → Sort → Hash Join → Seq Scan on invoice_line → Hash → Seq Scan on invoice → Seq Scan on branch  
**Q3** after: Sort → Nested Loop → Seq Scan on branch → Index Scan on mv_monthly_revenue using ux_mv_monthly_revenue

**Q4** before: Gather Merge → Sort → Hash Join → Nested Loop → Seq Scan on lab_result → Index Scan on lab_order using lab_order_pkey → Index Scan on encounter using encounter_pkey → Index Scan on patient using patient_pkey → Hash → Seq Scan on lab_test  
**Q4** after: Sort → Nested Loop → Bitmap Heap Scan on lab_result → Bitmap Index Scan using ix_lab_result_abnormal_recent → Index Scan on lab_order using lab_order_pkey → Index Scan on encounter using encounter_pkey → Index Scan on patient using patient_pkey → Memoize → Index Scan on lab_test using lab_test_pkey

**Q5** before: Sort → Seq Scan on patient  
**Q5** after: Sort → Bitmap Heap Scan on patient → BitmapAnd → Bitmap Index Scan using ix_patient_first_name_trgm → Bitmap Index Scan using ix_patient_last_name_trgm

**Q6** before: Limit → Sort → Hash Join → Aggregate → Index Scan on invoice_line using invoice_line_pkey → Hash → Seq Scan on payment → Seq Scan on invoice → Seq Scan on patient  
**Q6** after: Limit → Sort → Nested Loop → Hash Join → Index Scan on invoice using ix_invoice_unpaid_branch → Hash → Seq Scan on patient → Aggregate → Index Scan on invoice_line using invoice_line_pkey → Index Scan on payment using ix_payment_invoice

**Q7** before: Gather Merge → Sort → Hash Join → Seq Scan on patient → Seq Scan on encounter → Hash → Seq Scan on diagnosis  
**Q7** after: Gather Merge → Sort → Nested Loop → Hash Join → Seq Scan on patient → Hash → Bitmap Heap Scan on diagnosis → Bitmap Index Scan using ix_diagnosis_code → Index Scan on encounter using encounter_pkey → Index Only Scan on encounter using ix_encounter_patient_started

**Q8** before: Sort → Subquery Scan → WindowAgg → Hash Join → Aggregate → Seq Scan on diagnosis → Hash → Seq Scan on encounter → Seq Scan on branch  
**Q8** after: Sort → Subquery Scan → WindowAgg → Hash Join → Aggregate → Seq Scan on diagnosis → Hash → Seq Scan on encounter → Seq Scan on branch


## Cost of the optimisations

- Bulk insert of 20,000 appointments: **365 ms** before vs **413 ms** after (extra index maintenance)
- Storage of new objects:

| Object | Size |
|---|---:|
| ix_appointment_doctor_time | 14 MB |
| ix_diagnosis_code | 14 MB |
| ix_encounter_patient_started | 11 MB |
| ix_payment_invoice | 7352 kB |
| ix_prescription_encounter | 7184 kB |
| ix_lab_order_encounter | 3480 kB |
| ix_lab_result_abnormal_recent | 3144 kB |
| ix_invoice_unpaid_branch | 1376 kB |
| ix_patient_first_name_trgm | 1216 kB |
| ix_patient_last_name_trgm | 920 kB |
| mv_monthly_revenue | 64 kB |
| ux_mv_monthly_revenue | 40 kB |
