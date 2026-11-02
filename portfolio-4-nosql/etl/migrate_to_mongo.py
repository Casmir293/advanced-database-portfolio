"""
ETL: PostgreSQL (udoka_hms) -> MongoDB (udoka_ehr)

Builds the document model described in ../README.md:
  patients    - one document per patient, small bounded arrays embedded
                (allergies, emergency contacts, HMO cover) + a computed summary
  encounters  - one document per clinical encounter with diagnoses,
                prescription items and lab results embedded, plus snapshot
                copies of the patient, doctor and branch (extended reference)
  ward_contacts - graph edges: two patients who were in the same ward at
                the same time (used for contact tracing with $graphLookup)
  vitals      - time-series collection of bedside observations for the
                current inpatients (synthetic, generated here)

PostgreSQL does the document assembly with jsonb_build_object / jsonb_agg,
streamed through a server-side cursor in batches, so memory stays flat.

Usage: ../../.venv/bin/python etl/migrate_to_mongo.py
"""
import math
import random
import time
from datetime import datetime, timedelta, timezone

import psycopg
from pymongo import MongoClient

PG_DSN = "dbname=udoka_hms options='-c search_path=hms,public'"
BATCH = 5000

PATIENT_SQL = """
SELECT jsonb_strip_nulls(jsonb_build_object(
  '_id', p.patient_id,
  'hospitalNo', p.hospital_no,
  'name', jsonb_build_object('first', p.first_name, 'last', p.last_name),
  'dob', (extract(epoch FROM p.date_of_birth::timestamptz) * 1000)::bigint,
  'sex', p.sex,
  'contact', jsonb_build_object('phone', p.phone, 'email', p.email, 'address', p.address),
  'bloodGroup', p.blood_group,
  'genotype', p.genotype,
  'registeredBranch', b.branch_code,
  'registeredAt', (extract(epoch FROM p.registered_at) * 1000)::bigint,
  'allergies', (SELECT jsonb_agg(jsonb_build_object('allergen', a.allergen, 'severity', a.severity))
                FROM patient_allergy a WHERE a.patient_id = p.patient_id),
  'emergencyContacts', (SELECT jsonb_agg(jsonb_build_object('name', c.full_name, 'relationship', c.relationship,
                                                            'phone', c.phone) ORDER BY c.contact_no)
                        FROM emergency_contact c WHERE c.patient_id = p.patient_id),
  'coverage', (SELECT jsonb_agg(jsonb_build_object('hmo', h.name, 'policyNo', pc.policy_no,
                       'validFrom', (extract(epoch FROM pc.valid_from::timestamptz) * 1000)::bigint,
                       'validTo',   (extract(epoch FROM pc.valid_to::timestamptz) * 1000)::bigint) ORDER BY pc.valid_from)
               FROM patient_coverage pc JOIN hmo h USING (hmo_id) WHERE pc.patient_id = p.patient_id),
  'summary', (SELECT jsonb_build_object(
                 'visitCount', count(*),
                 'lastVisitAt', (extract(epoch FROM max(e.started_at)) * 1000)::bigint,
                 'chronicConditions', (SELECT jsonb_agg(DISTINCT d.icd10_code)
                                       FROM encounter e2 JOIN diagnosis d USING (encounter_id)
                                       WHERE e2.patient_id = p.patient_id
                                         AND d.icd10_code IN ('I10','E11.9','D57.1','B20','B18.1','N18.9','J45.9','G40.9')))
              FROM encounter e WHERE e.patient_id = p.patient_id)
)) AS doc
FROM patient p JOIN branch b ON b.branch_id = p.reg_branch_id
ORDER BY p.patient_id
"""

ENCOUNTER_SQL = """
SELECT jsonb_strip_nulls(jsonb_build_object(
  '_id', e.encounter_id,
  'type', e.encounter_type,
  'branch', b.branch_code,
  'startedAt', (extract(epoch FROM e.started_at) * 1000)::bigint,
  'endedAt',   (extract(epoch FROM e.ended_at) * 1000)::bigint,
  'appointmentId', e.appt_id,
  'patient', jsonb_build_object('id', p.patient_id, 'hospitalNo', p.hospital_no,
                                'name', p.first_name || ' ' || p.last_name, 'sex', p.sex,
                                'dob', (extract(epoch FROM p.date_of_birth::timestamptz) * 1000)::bigint),
  'doctor', jsonb_build_object('id', d.staff_id, 'name', 'Dr ' || s.first_name || ' ' || s.last_name,
                               'specialty', d.specialty),
  'complaint', e.complaint,
  'notes', e.clinical_notes,
  'diagnoses', (SELECT jsonb_agg(jsonb_build_object('code', dg.icd10_code, 'description', ic.description,
                                                    'primary', dg.is_primary) ORDER BY dg.is_primary DESC)
                FROM diagnosis dg JOIN icd10_code ic USING (icd10_code) WHERE dg.encounter_id = e.encounter_id),
  'prescription', (SELECT jsonb_build_object('rxId', rx.rx_id, 'status', rx.status,
                     'issuedAt', (extract(epoch FROM rx.issued_at) * 1000)::bigint,
                     'items', (SELECT jsonb_agg(jsonb_build_object('drug', dr.generic_name, 'strength', dr.strength,
                                 'form', dr.form, 'dose', pi.dose, 'frequency', pi.frequency, 'days', pi.duration_days,
                                 'qty', pi.qty_prescribed, 'dispensed', pi.qty_dispensed) ORDER BY pi.line_no)
                               FROM prescription_item pi JOIN drug dr USING (drug_id) WHERE pi.rx_id = rx.rx_id))
                   FROM prescription rx WHERE rx.encounter_id = e.encounter_id LIMIT 1),
  'labOrders', (SELECT jsonb_agg(jsonb_build_object('orderId', o.order_id, 'priority', o.priority, 'status', o.status,
                   'orderedAt', (extract(epoch FROM o.ordered_at) * 1000)::bigint,
                   'results', (SELECT jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                                  'test', r.test_code, 'name', t.name, 'value', r.value_num, 'text', r.value_text,
                                  'unit', t.unit, 'refLow', t.ref_low, 'refHigh', t.ref_high, 'flag', r.abnormal_flag,
                                  'resultedAt', (extract(epoch FROM r.resulted_at) * 1000)::bigint)) ORDER BY r.test_code)
                               FROM lab_result r JOIN lab_test t USING (test_code) WHERE r.order_id = o.order_id)))
                FROM lab_order o WHERE o.encounter_id = e.encounter_id),
  'admission', (SELECT jsonb_build_object('ward', w.name, 'bed', bd.label,
                   'admittedAt',   (extract(epoch FROM a.admitted_at) * 1000)::bigint,
                   'dischargedAt', (extract(epoch FROM a.discharged_at) * 1000)::bigint)
                FROM admission a JOIN bed bd USING (bed_id) JOIN ward w USING (ward_id)
                WHERE a.encounter_id = e.encounter_id)
)) AS doc
FROM encounter e
JOIN patient p ON p.patient_id = e.patient_id
JOIN doctor d  ON d.staff_id = e.doctor_id
JOIN staff s   ON s.staff_id = d.staff_id
JOIN branch b  ON b.branch_id = e.branch_id
ORDER BY e.encounter_id
"""

# Graph edges: patients whose stays in the same ward overlapped in time.
CONTACT_SQL = """
SELECT a1.patient_id AS src, a2.patient_id AS dst, w.name AS ward, br.branch_code AS branch,
       (extract(epoch FROM GREATEST(a1.admitted_at, a2.admitted_at)) * 1000)::bigint AS overlap_from,
       (extract(epoch FROM LEAST(COALESCE(a1.discharged_at, now()), COALESCE(a2.discharged_at, now()))) * 1000)::bigint AS overlap_to
FROM admission a1
JOIN bed b1 ON b1.bed_id = a1.bed_id
JOIN admission a2 ON a2.patient_id <> a1.patient_id
JOIN bed b2 ON b2.bed_id = a2.bed_id AND b2.ward_id = b1.ward_id
JOIN ward w ON w.ward_id = b1.ward_id
JOIN branch br ON br.branch_id = w.branch_id
WHERE tstzrange(a1.admitted_at, COALESCE(a1.discharged_at, 'infinity'))
   && tstzrange(a2.admitted_at, COALESCE(a2.discharged_at, 'infinity'))
"""

CURRENT_INPATIENTS_SQL = """
SELECT a.patient_id, p.hospital_no, w.name AS ward, bd.label AS bed, a.admitted_at, dg.icd10_code
FROM admission a JOIN patient p USING (patient_id) JOIN bed bd USING (bed_id) JOIN ward w USING (ward_id)
LEFT JOIN diagnosis dg ON dg.encounter_id = a.encounter_id AND dg.is_primary
WHERE a.discharged_at IS NULL ORDER BY a.patient_id
"""


def to_dates(obj):
    """Convert every integer field whose name ends in 'At' (or is dob/validFrom/validTo) to a UTC datetime."""
    if isinstance(obj, dict):
        for k, v in obj.items():
            if isinstance(v, int) and (k.endswith("At") or k in ("dob", "validFrom", "validTo")):
                obj[k] = datetime.fromtimestamp(v / 1000, tz=timezone.utc)
            else:
                to_dates(v)
    elif isinstance(obj, list):
        for v in obj:
            to_dates(v)
    return obj


def stream(pg, sql, name):
    with pg.cursor(name=name) as cur:
        cur.itersize = BATCH
        cur.execute(sql)
        batch = []
        for (doc,) in cur:
            batch.append(to_dates(doc))
            if len(batch) == BATCH:
                yield batch
                batch = []
        if batch:
            yield batch


def load(pg, coll, sql, name):
    t0, n = time.perf_counter(), 0
    for batch in stream(pg, sql, name):
        coll.insert_many(batch, ordered=False)
        n += len(batch)
    print(f"  {coll.name:<14} {n:>8,} documents in {time.perf_counter() - t0:5.1f} s")
    return n


def synthetic_vitals(pg, db):
    """Every 15 minutes for the last 72 h, per current inpatient. Septic-looking trend for a few patients."""
    rng = random.Random(8103)
    now = datetime(2026, 11, 2, 8, 0, tzinfo=timezone.utc)
    docs = []
    rows = pg.execute(CURRENT_INPATIENTS_SQL).fetchall()
    for pid, hno, ward, bed, admitted, dx in rows:
        start = max(admitted.astimezone(timezone.utc), now - timedelta(hours=72))
        deteriorating = pid % 9 == 0
        t, k = start, 0
        while t <= now:
            drift = (k / 288) if deteriorating else 0
            docs.append({
                "ts": t,
                "meta": {"patientId": pid, "hospitalNo": hno, "ward": ward, "bed": bed, "device": f"MON-{bed}"},
                "hr": round(rng.gauss(82 + 35 * drift, 5)),
                "rr": round(rng.gauss(16 + 10 * drift, 1.5)),
                "spo2": min(100, round(rng.gauss(97 - 7 * drift, 1))),
                "tempC": round(rng.gauss(36.9 + 2.0 * drift, 0.25), 1),
                "sbp": round(rng.gauss(122 - 30 * drift, 8)),
            })
            t += timedelta(minutes=15)
            k += 1
    db.vitals.insert_many(docs, ordered=False)
    print(f"  {'vitals':<14} {len(docs):>8,} measurements for {len(rows)} inpatients")


def main():
    mongo = MongoClient("mongodb://localhost:27017")
    mongo.drop_database("udoka_ehr")
    db = mongo.udoka_ehr

    # Collections with validation / special types are created explicitly (see ../mongo/01_collections.js)
    with open(__file__.replace("etl/migrate_to_mongo.py", "mongo/encounter_schema.json")) as f:
        import json
        db.create_collection("encounters", validator={"$jsonSchema": json.load(f)}, validationLevel="strict")
    db.create_collection("vitals", timeseries={"timeField": "ts", "metaField": "meta", "granularity": "minutes"},
                         expireAfterSeconds=60 * 60 * 24 * 90)

    with psycopg.connect(PG_DSN) as pg:
        print("Migrating from PostgreSQL to MongoDB ...")
        load(pg, db.patients, PATIENT_SQL, "patients_cur")
        load(pg, db.encounters, ENCOUNTER_SQL, "encounters_cur")
        edges = [{"from": s, "to": d, "ward": w, "branch": b,
                  "overlapFrom": datetime.fromtimestamp(f / 1000, tz=timezone.utc),
                  "overlapTo": datetime.fromtimestamp(t / 1000, tz=timezone.utc)}
                 for s, d, w, b, f, t in pg.execute(CONTACT_SQL)]
        db.ward_contacts.insert_many(edges)
        print(f"  {'ward_contacts':<14} {len(edges):>8,} edges")
        synthetic_vitals(pg, db)

        # Reconciliation: counts must match the source
        checks = {
            "patients": (pg.execute("SELECT count(*) FROM patient").fetchone()[0], db.patients.count_documents({})),
            "encounters": (pg.execute("SELECT count(*) FROM encounter").fetchone()[0], db.encounters.count_documents({})),
            "diagnoses": (pg.execute("SELECT count(*) FROM diagnosis").fetchone()[0],
                          next(db.encounters.aggregate([{"$project": {"n": {"$size": {"$ifNull": ["$diagnoses", []]}}}},
                                                        {"$group": {"_id": None, "n": {"$sum": "$n"}}}]))["n"]),
            "lab results": (pg.execute("SELECT count(*) FROM lab_result").fetchone()[0],
                            next(db.encounters.aggregate([{"$unwind": "$labOrders"}, {"$unwind": "$labOrders.results"},
                                                          {"$count": "n"}]))["n"]),
        }
    print("Reconciliation (PostgreSQL vs MongoDB):")
    for k, (a, b) in checks.items():
        print(f"  {k:<12} {a:>9,} {b:>9,}  {'OK' if a == b else 'MISMATCH'}")


if __name__ == "__main__":
    main()
