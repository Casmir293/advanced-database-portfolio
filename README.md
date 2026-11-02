# MIT 8103 Advanced Database Systems – Practical Portfolio

**Student:** Casmir Onyeka · **Student ID:** 301911351 · **Programme:** Master of Information Technology, Miva Open University
**Session:** 2026/2027, First Semester Continuous Assessment

## Selected case study: Udoka Specialist Hospital (simulated)

Udoka Specialist Hospital is a **fictional** private hospital group in South-East Nigeria: a main
hospital in Enugu (outpatients, 24-hour emergency, five wards including an ICU) and two satellite
clinics in Nsukka and Awka. All five portfolios use this one organisation.

- **Users of the database:** records officers, doctors, nurses, laboratory scientists, pharmacists,
  billing officers, management and (in future) patients through a portal.
- **Major data:** patients (allergies, emergency contacts, HMO cover), staff and doctors, appointments,
  clinical encounters with ICD-10 diagnoses, prescriptions and pharmacy stock, lab orders and results,
  wards, beds and admissions, invoices and payments, and an audit trail.
- **Key operations:** register patients; book appointments without double-booking; record consultations;
  prescribe and dispense; order and verify lab tests; admit and discharge; bill and receive payments;
  retrieve a patient's full history; management reporting.

## Portfolio map

| # | Activity | Folder | Technology |
|---|---|---|---|
| 1 | Database design and modelling | [portfolio-1-database-design](portfolio-1-database-design/) | PostgreSQL 16, Graphviz |
| 2 | Query processing and optimisation | [portfolio-2-query-optimisation](portfolio-2-query-optimisation/) | PostgreSQL `EXPLAIN (ANALYZE, BUFFERS)` |
| 3 | Transactions and concurrency | [portfolio-3-transactions-concurrency](portfolio-3-transactions-concurrency/) | PostgreSQL + Python (psycopg) |
| 4 | NoSQL and advanced data models | [portfolio-4-nosql](portfolio-4-nosql/) | MongoDB 9, Redis |
| 5 | Distributed and cloud databases | portfolio-5-distributed-cloud | PostgreSQL streaming replication, postgres_fdw sharding, MongoDB replica set |

## Environment

macOS (Apple Silicon), PostgreSQL 16.15, Python 3.9 with the packages in `requirements.txt`.

```bash
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
cd portfolio-1-database-design && ./build_database.sh
```
