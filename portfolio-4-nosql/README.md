# Portfolio 4 – NoSQL and Advanced Data Models

**Case study:** Udoka Specialist Hospital · **Stores:** MongoDB 9.0 (document, time-series, graph via `$graphLookup`), Redis 8.8 (key-value)

## 1. Why NoSQL for this hospital?

PostgreSQL (Portfolios 1–3) remains the **system of record** for anything with money, stock or strict
cross-row rules (billing, pharmacy stock, bookings). Three needs fit other data models better:

| Need | Pain in the relational model | Model chosen |
|---|---|---|
| **Electronic health record (EHR) view**: a doctor opens a patient's full history | Q1 in Portfolio 2 joins 8 tables and runs 3 correlated subqueries per encounter | **Document** (MongoDB): one encounter = one self-contained document |
| **Bedside monitor vitals** every 15 min for every inpatient | Very high insert rate of narrow rows; queries are always "this patient, recent window" | **Time-series** collection (MongoDB) |
| **Infection-control contact tracing** (e.g. Lassa fever) | "Who shared a ward with someone who shared a ward with X" is a recursive self-join | **Graph** traversal (`$graphLookup`) |
| **Short-lived, very hot state**: slot holds, triage queue, bed board, cached patient card | Rows that expire after minutes; polling the DB for a queue | **Key-value** (Redis) with TTLs, sorted sets, atomic scripts |

This is **polyglot persistence**: each store does what it is good at, and PostgreSQL feeds the others.

## 2. Document model (MongoDB `udoka_ehr`)

### 2.1 Design decisions: embed or reference?

| Relationship | Decision | Reason |
|---|---|---|
| Encounter → diagnoses, prescription items, lab orders/results | **Embed** | Always read together with the encounter; bounded (≤ 10 diagnoses, a few drugs/tests); written at the same time. Gives one atomic document write (M9) |
| Patient → allergies, emergency contacts, HMO cover | **Embed** | Small, bounded, read on every screen |
| Patient → encounters | **Reference** (`encounter.patient.id`) | Unbounded growth: a chronic patient accumulates hundreds of visits, which risks the 16 MB document limit and causes write contention on one hot document |
| Encounter → patient / doctor details | **Extended reference** (copy `hospitalNo`, name, sex, dob, doctor name/specialty) | Lists render without a lookup. A name copied at visit time is also the *correct* medico-legal record of who was seen |
| Patient → visit statistics | **Computed pattern** (`summary.visitCount`, `lastVisitAt`, `chronicConditions`) | The recall list (M4) becomes an index lookup instead of an aggregation over encounters |
| Vital signs | **Time-series collection** (`timeField: ts`, `metaField: meta`, 90-day TTL) | MongoDB buckets measurements per patient/device internally: 13,208 measurements in 162 buckets |
| Ward co-location | **Edge collection** `ward_contacts {from, to, ward, overlapFrom, overlapTo}` | Feeds `$graphLookup` |

Billing is deliberately **not** migrated: money needs multi-document ACID across invoice, payment and
stock, and the relational model already gives that with constraints.

### 2.2 Example encounter document (trimmed)

```js
{
  _id: 344129, type: 'INPATIENT', branch: 'ENU',
  startedAt: ISODate('2023-01-03T12:00:00Z'), endedAt: ISODate('2023-01-11T15:00:00Z'),
  patient:  { id: 39558, hospitalNo: 'USH-0039558', name: 'Mercy Attah', sex: 'F', dob: ISODate('1985-07-21T23:00:00Z') },
  doctor:   { id: 42, name: 'Dr Grace Obi', specialty: 'Obstetrics & Gynaecology' },
  complaint: 'Raised BP in pregnancy, swollen feet',
  diagnoses: [ { code: 'O14.9', description: 'Pre-eclampsia, unspecified', primary: true } ],
  admission: { ward: 'Maternity', bed: 'B05', admittedAt: ISODate(...), dischargedAt: ISODate(...) },
  labOrders: [ { orderId: 150318, priority: 'ROUTINE', status: 'RESULTED', results: [
      { test: 'CREAT', name: 'Serum creatinine', value: 83.96, unit: 'umol/L', refLow: 60, refHigh: 110, flag: 'N' },
      { test: 'URINE', name: 'Urinalysis', text: 'No abnormality detected' } ] } ],
  prescription: { rxId: 313219, status: 'DISPENSED', items: [
      { drug: 'Amlodipine', strength: '10mg', dose: '10 mg', frequency: 'OD', days: 14, qty: 14, dispensed: 14 } ] }
}
```

Lab results are a good example of **schema flexibility**: numeric tests carry
`value/unit/refLow/refHigh`, while qualitative tests (malaria film, urinalysis, HBsAg) carry `text`.
In SQL the same thing needed two nullable columns and a CHECK.

### 2.3 Implementation

| File | What it does |
|---|---|
| [`etl/migrate_to_mongo.py`](etl/migrate_to_mongo.py) | PostgreSQL assembles each document with `jsonb_build_object` / `jsonb_agg`, streamed by a server-side cursor in batches of 5,000 into `insert_many`. Also builds graph edges (overlapping ward stays via `tstzrange &&`) and synthetic vitals. Ends with a **reconciliation** of counts |
| [`mongo/encounter_schema.json`](mongo/encounter_schema.json) | `$jsonSchema` validator: required fields, enums for type/branch/priority/flag, hospital-number and ICD-10 regex patterns |
| [`mongo/queries.js`](mongo/queries.js) | Indexes, queries M1–M9, explain plans → [`evidence/mongo_queries_output.txt`](evidence/mongo_queries_output.txt) |

ETL reconciliation (from the run):

```
patients        60,000    60,000  OK        diagnoses     448,374   448,374  OK
encounters     357,225   357,225  OK        lab results   378,337   378,337  OK
```

### 2.4 Queries and evidence

| # | Query | Technique | Result |
|---|---|---|---|
| M1 | Patient history (same as SQL Q1) | Compound index `{patient.id: 1, startedAt: -1}` | Before: `SORT ← COLLSCAN`, **357,225 docs examined**, 51 ms. After: `FETCH ← IXSCAN(patient_history)`, **42 docs examined for 42 returned**, 2 ms, with no joins |
| M2 | Top-5 diagnoses per branch per quarter (SQL Q8) | `$unwind` → `$group` → `$topN` | 24 branch-quarters in about 280 ms; **identical counts to SQL** (e.g. Awka Q1-2025: Z34.9 = 683, B54 = 541) |
| M3 | Abnormal labs, last 7 days, Enugu (SQL Q4) | **Partial** multikey index on `labOrders.results.resultedAt` where flag ∈ {H, L, A} | `IXSCAN(abnormal_results)`; **496 rows, same as SQL** |
| M4 | Hypertension recall list (SQL Q7) | Computed `summary` + compound index | `IXSCAN(chronic_recall)`, 714 examined = 714 returned, about 0 ms. **Same 714 patients as SQL** |
| M5 | Free-text search in complaints/notes | Text index | "bleeding tendency" → Lassa-fever presentations ranked by `textScore` |
| M6 | Early-warning on vitals | Time-series + `$setWindowFields` 1-hour moving average | **3 of 68 inpatients** flagged (HR > 110, SpO₂ < 92 % or T > 38.5 °C), e.g. USH-0002070: HR 116, SpO₂ 89.6 %, 38.8 °C |
| M7 | Lassa-fever contact tracing | `$graphLookup` on `ward_contacts`, `maxDepth: 1`, 21-day `restrictSearchWithMatch` | Index case USH-0050167 (Ward A, bed B10): **13 first-degree and 10 second-degree contacts** to isolate and monitor |
| M8 | Insert a malformed encounter | `$jsonSchema` validator | `Document failed validation`; rules broken: `branch`, `startedAt`, `patient` |
| M9 | Dispense + add lab result in one update | Single-document atomicity + optimistic guard `{"prescription.status": "PENDING"}` | First update modifies 1 document; a repeat matches **0**, so there is no double dispensing |

Since the same questions were answered in SQL (Portfolio 2) and MongoDB with identical results, the
migration is verified and the two models can be compared fairly:

| | PostgreSQL (optimised) | MongoDB |
|---|---|---|
| Patient history (Q1/M1) | 0.55 ms, 8 tables, 3 correlated subqueries | 2 ms, 1 collection, 0 joins |
| Storage for the clinical data | 367 MB incl. indexes (encounter + 6 child tables) | 347 MB uncompressed BSON, but only **96 MB on disk** (WiredTiger snappy compression) + 52 MB indexes |
| Changing a patient's name | 1 row | 1 patient doc + `updateMany` on that patient's encounter snapshots (or keep them as the historical record) |

On a warm cache the indexed relational query is actually faster. The document model's gain here is
**simplicity and locality** (one read, one shape for the API), not raw speed.

## 3. Key-value model (Redis)

[`redis/redis_demo.py`](redis/redis_demo.py) → [`evidence/redis_output.txt`](evidence/redis_output.txt)

| # | Hospital use | Redis structure / command | Result |
|---|---|---|---|
| R1 | Hold a slot for 5 minutes while the patient pays in the portal | `SET ush:hold:dr30:2027-01-11T10:00 USH-0000002 NX EX 300` | Second patient's `SET … NX` returns nil; an abandoned hold expires automatically. PostgreSQL's exclusion constraint stays the final authority |
| R2 | Patient summary card, read on every screen | Cache-aside, `EX 600`, delete on write | Median read **64 µs (Redis) vs 223 µs (MongoDB)**, 3.5× faster |
| R3 | A&E triage queue | Sorted set, score = priority × 10¹⁰ + arrival time; `ZPOPMIN` | Unconscious RTA patient (P1) is seen first, then P2 cases in arrival order. The pop is atomic, so two doctors never call the same patient |
| R4 | Free maternity beds | Hash + Lua check-and-decrement | 15 concurrent claims for 12 beds: **12 granted, 3 refused, `free` = 0**, never negative |
| R5 | Durability | `appendonly no`, RDB `save 3600 1 300 100 60 10000` | Recent writes can be lost on a crash, so Redis only holds data that can be rebuilt |

## 4. Suitability of each data model for the hospital

| Model | Fits | Does not fit | Verdict for Udoka |
|---|---|---|---|
| **Relational** (PostgreSQL) | Billing, stock, bookings: multi-row ACID, constraints, ad-hoc reporting | Deep nested reads, high-rate telemetry | **System of record** |
| **Document** (MongoDB) | EHR timeline, heterogeneous lab results, API-shaped reads, flexible schema with validation | Cross-document invariants (stock never negative across many prescriptions); duplicated snapshots must be maintained | **Read-optimised clinical record**, fed from PostgreSQL |
| **Key-value** (Redis) | Expiring holds, caches, queues, counters at sub-millisecond latency | Anything that must survive a crash or be queried by value | **Ephemeral operational state** |
| **Time-series** (MongoDB TS / InfluxDB) | Vitals, device telemetry, windowed analytics, automatic expiry | Updates to past points | **Ward monitoring** |
| **Graph** (`$graphLookup` here; Neo4j at scale) | Contact tracing, referral networks, drug-interaction chains | Bulk aggregation | `$graphLookup` is enough at this size. A dedicated graph DB would be justified for state-wide surveillance |
| **Wide-column** (Cassandra) | Write-heavy telemetry across many sites, partitioned by `(patient_id, day)` | Ad-hoc queries, joins, strong consistency by default | Not needed for 3 branches; would suit a national vitals platform |

**Consistency trade-off.** The MongoDB copy is refreshed by ETL, so it is *eventually consistent*
with PostgreSQL. In production I would replace the batch ETL with change-data-capture (logical
decoding from PostgreSQL), bringing the lag down to seconds. Clinicians would still write
prescriptions and results through the relational system.

## 5. How to reproduce

```bash
brew tap mongodb/brew && brew install mongodb-community mongosh redis
brew services start mongodb/brew/mongodb-community && brew services start redis
../.venv/bin/python etl/migrate_to_mongo.py                              # ~2.5 min
mongosh --quiet udoka_ehr mongo/queries.js > evidence/mongo_queries_output.txt
../.venv/bin/python redis/redis_demo.py
```
