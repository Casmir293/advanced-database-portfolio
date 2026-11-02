-- =====================================================================
-- Udoka Specialist Hospital - synthetic operational data generator
--
-- Produces ~4 years of activity (Jan 2023 - Nov 2026) so that the
-- optimisation work in Portfolio 2 runs on realistic volumes:
--   ~60k patients, ~480k appointments, ~400k encounters, plus
--   diagnoses, prescriptions, lab results, admissions and billing.
--
-- Deterministic: setseed() makes every run produce the same data.
-- "Today" for the case study is fixed at 2026-11-02.
-- All people are fictional; names are randomly combined.
-- =====================================================================
SET search_path = hms, public;
SET timezone = 'Africa/Lagos';
SELECT setseed(0.8103) \g /dev/null

-- ---------------------------------------------------------------------
-- Helper lookups (temporary, dropped at end of session)
-- ---------------------------------------------------------------------
CREATE TEMP TABLE names AS SELECT
 ARRAY['Chiamaka','Ngozi','Adaeze','Chinwe','Ifeoma','Nkechi','Amarachi','Obiageli','Chidinma','Ebere',
       'Ogechi','Oluchi','Ujunwa','Funmilayo','Aisha','Zainab','Fatima','Blessing','Joy','Grace','Esther',
       'Mercy','Precious','Favour','Adanna','Kosisochukwu','Munachi','Nneka','Uloma','Chioma'] AS fem,
 ARRAY['Chukwuemeka','Obinna','Ikenna','Chinedu','Nnamdi','Emeka','Uche','Kelechi','Chibuike','Ifeanyi',
       'Tochukwu','Ebuka','Somto','Kenechukwu','Oluwaseun','Tunde','Musa','Ibrahim','Abubakar','Samuel',
       'Daniel','Emmanuel','Victor','Paul','Godwin','Collins','Chidera','Onyekachi','Nonso','Arinze'] AS male,
 ARRAY['Okafor','Okeke','Eze','Nwosu','Okonkwo','Obi','Nnaji','Ugwu','Onyekwere','Chukwu','Agu','Ani',
       'Nwankwo','Ezeh','Odo','Onah','Asogwa','Ugwuanyi','Okoro','Mbah','Nweke','Ezeani','Udeh','Ogbu',
       'Igwe','Ngwu','Eneh','Uzor','Adeyemi','Bello','Danjuma','Okoye','Nwafor','Onuoha','Chukwuma',
       'Ezenwa','Obiora','Anyanwu','Iloh','Edeh','Nwachukwu','Okpara','Aneke','Ozor','Ude','Ukwueze',
       'Nnamani','Ogbonna','Ihekwoaba','Attah'] AS last,
 ARRAY['Independence Layout','GRA','Trans-Ekulu','Abakpa Nike','New Haven','Achara Layout','Uwani',
       'Ogui Road','Emene','Coal Camp','University Road','Odenigbo','Amawbia','Ifite','Okpuno','Agu-Awka'] AS street;

-- ---------------------------------------------------------------------
-- Staff (290) and doctors (60)
-- ---------------------------------------------------------------------
WITH plan(role, branch_id, n) AS (VALUES
   ('DOCTOR',1,36),('DOCTOR',2,12),('DOCTOR',3,12),
   ('NURSE',1,90),('NURSE',2,30),('NURSE',3,30),
   ('LAB_SCIENTIST',1,13),('LAB_SCIENTIST',2,6),('LAB_SCIENTIST',3,6),
   ('PHARMACIST',1,7),('PHARMACIST',2,4),('PHARMACIST',3,4),
   ('RECORDS_OFFICER',1,10),('RECORDS_OFFICER',2,5),('RECORDS_OFFICER',3,5),
   ('BILLING_OFFICER',1,7),('BILLING_OFFICER',2,4),('BILLING_OFFICER',3,4),
   ('ADMIN',1,5)),
rows AS (
   SELECT p.role, p.branch_id, g,
          CASE p.role
            WHEN 'DOCTOR' THEN (CASE WHEN p.branch_id = 1
                   THEN ARRAY['General Medicine','Paediatrics','Obstetrics & Gynaecology','Surgery','Ophthalmology']
                   ELSE ARRAY['General Medicine','Paediatrics','Obstetrics & Gynaecology'] END)
                 [1 + g % (CASE WHEN p.branch_id = 1 THEN 5 ELSE 3 END)]
            WHEN 'NURSE' THEN (ARRAY['General Medicine','Paediatrics','Obstetrics & Gynaecology'])[1 + g % 3]
            WHEN 'LAB_SCIENTIST'   THEN 'Laboratory'
            WHEN 'PHARMACIST'      THEN 'Pharmacy'
            WHEN 'RECORDS_OFFICER' THEN 'Medical Records'
            WHEN 'BILLING_OFFICER' THEN 'Accounts'
          END AS dept_name,
          random() r1, random() r2, random() r3, random() r4
   FROM plan p CROSS JOIN LATERAL generate_series(1, p.n) g),
named AS (
   SELECT r.*, d.dept_id,
          CASE WHEN r.r1 < 0.5 THEN n.fem[1 + floor(r.r2 * 30)::int]
               ELSE n.male[1 + floor(r.r2 * 30)::int] END AS fn,
          n.last[1 + floor(r.r3 * 50)::int] AS ln
   FROM rows r CROSS JOIN names n
   LEFT JOIN department d ON d.branch_id = r.branch_id AND d.name = r.dept_name)
INSERT INTO staff (branch_id, dept_id, first_name, last_name, role, email, phone, hired_on)
SELECT branch_id, dept_id, fn, ln, role,
       lower(fn || '.' || ln || row_number() OVER (ORDER BY role, branch_id, g)) || '@udoka-hospital.example',
       '+234803' || lpad((floor(r4 * 9999999))::text, 7, '0'),
       DATE '2010-01-01' + floor(r4 * 5400)::int
FROM named
ORDER BY role, branch_id, g;

INSERT INTO doctor (staff_id, mdcn_folio, specialty, consult_fee)
SELECT s.staff_id,
       'MDCN/' || lpad(s.staff_id::text, 5, '0'),
       CASE d.name WHEN 'General Medicine' THEN CASE WHEN s.staff_id % 2 = 0 THEN 'Internal Medicine' ELSE 'Family Medicine' END
                   WHEN 'Paediatrics' THEN 'Paediatrics'
                   WHEN 'Obstetrics & Gynaecology' THEN 'Obstetrics & Gynaecology'
                   WHEN 'Surgery' THEN 'General Surgery'
                   WHEN 'Ophthalmology' THEN 'Ophthalmology' END,
       CASE WHEN s.staff_id % 3 = 0 THEN 15000 ELSE 8000 END   -- consultant vs medical officer
FROM staff s JOIN department d USING (dept_id)
WHERE s.role = 'DOCTOR';

-- ---------------------------------------------------------------------
-- Patients (60,000). hospital_no is sequential, so lower numbers were
-- registered earlier (and, below, visit more often).
-- ---------------------------------------------------------------------
INSERT INTO patient (hospital_no, first_name, last_name, date_of_birth, sex, phone, email, address,
                     blood_group, genotype, reg_branch_id, registered_at)
SELECT 'USH-' || lpad(g::text, 7, '0'),
       CASE WHEN sex = 'F' THEN n.fem[1 + floor(r2 * 30)::int] ELSE n.male[1 + floor(r2 * 30)::int] END,
       n.last[1 + floor(r3 * 50)::int],
       dob, sex,
       '+23480' || lpad((floor(r4 * 99999999))::text, 8, '0'),
       CASE WHEN r5 < 0.6 THEN 'patient' || g || '@mail.example' END,
       (1 + floor(r6 * 120))::int || ' ' || n.street[1 + floor(r7 * 16)::int] ||
           CASE WHEN br = 3 THEN ', Awka' WHEN br = 2 THEN ', Nsukka' ELSE ', Enugu' END,
       (ARRAY['O+','O+','O+','A+','A+','B+','B+','AB+','O-','A-','B-','AB-'])[1 + floor(r8 * 12)::int],
       (ARRAY['AA','AA','AA','AA','AA','AA','AS','AS','AC','SS'])[1 + floor(r9 * 10)::int],
       br,
       GREATEST(reg_at, dob::timestamptz)
FROM (
   SELECT g, x.*,
          CASE WHEN r1 < 0.52 THEN 'F' ELSE 'M' END AS sex,
          DATE '2026-11-02' - (floor(power(r10, 0.9) * 85 * 365.25))::int AS dob,
          TIMESTAMPTZ '2015-01-05 09:00+01' + (g / 60000.0) * (TIMESTAMPTZ '2026-10-30' - TIMESTAMPTZ '2015-01-05')
              + make_interval(mins => floor(r6 * 480)::int) AS reg_at,
          CASE WHEN g / 60000.0 > 0.40 AND r7 < 0.22 THEN 3      -- Awka opened 2019
               WHEN g / 60000.0 > 0.15 AND r8 < 0.25 THEN 2      -- Nsukka opened 2016
               ELSE 1 END AS br
   FROM generate_series(1, 60000) g
   CROSS JOIN LATERAL (SELECT random() r1, random() r2, random() r3, random() r4, random() r5,
                              random() r6, random() r7, random() r8, random() r9, random() r10
                       WHERE g > 0) x   -- WHERE g > 0 keeps the lateral correlated (fresh randoms per row)
) p CROSS JOIN names n;

INSERT INTO patient_allergy
SELECT patient_id, a, (ARRAY['MILD','MODERATE','SEVERE'])[1 + (patient_id % 3)]
FROM patient
CROSS JOIN LATERAL (VALUES
   ((ARRAY['Penicillin','Sulfonamides','Aspirin','Ibuprofen','Chloroquine','Latex','Peanuts','Seafood','Codeine'])
     [1 + patient_id % 9])) v(a)
WHERE patient_id % 100 < 12
UNION ALL
SELECT patient_id, 'Penicillin', 'SEVERE' FROM patient WHERE patient_id % 100 < 3 AND patient_id % 9 <> 0;

INSERT INTO emergency_contact
SELECT p.patient_id, c, n.male[1 + (p.patient_id * c) % 30] || ' ' || p.last_name,
       (ARRAY['Spouse','Parent','Sibling','Child','Guardian'])[1 + (p.patient_id + c) % 5],
       '+23481' || lpad(((p.patient_id * 7919 + c * 104729) % 99999999)::text, 8, '0')
FROM patient p CROSS JOIN names n
CROSS JOIN LATERAL generate_series(1, CASE WHEN p.patient_id % 10 < 3 THEN 2 ELSE 1 END) c;

INSERT INTO patient_coverage
SELECT patient_id, 1 + patient_id % 4, 'POL' || lpad(patient_id::text, 8, '0'),
       y, (y + interval '1 year')::date
FROM patient
CROSS JOIN LATERAL (VALUES (DATE '2024-01-01'), (DATE '2025-01-01'), (DATE '2026-01-01')) v(y)
WHERE patient_id % 20 < 7;                         -- ~35% of patients are on an HMO plan

-- ---------------------------------------------------------------------
-- Appointments (~480k): 15-minute slots, Mon-Fri 08:00-16:00.
-- Each (doctor, slot) is used at most once, so the exclusion
-- constraint against double booking is satisfied by construction.
-- ---------------------------------------------------------------------
CREATE TEMP TABLE pmap AS
SELECT reg_branch_id AS branch_id, patient_id, registered_at,
       row_number() OVER (PARTITION BY reg_branch_id ORDER BY patient_id) AS ord,
       count(*)     OVER (PARTITION BY reg_branch_id)                     AS cnt
FROM patient;
CREATE INDEX ON pmap (branch_id, ord);
ANALYZE pmap;

INSERT INTO appointment (patient_id, doctor_id, branch_id, scheduled_at, ends_at, status, reason, created_at)
SELECT pm.patient_id, s.doctor_id, s.branch_id, s.slot, s.slot + interval '15 minutes',
       CASE WHEN s.slot >= TIMESTAMPTZ '2026-11-02 00:00+01' THEN 'BOOKED'
            WHEN s.r2 < 0.80 THEN 'COMPLETED'
            WHEN s.r2 < 0.90 THEN 'NO_SHOW'
            ELSE 'CANCELLED' END,
       CASE WHEN s.r3 < 0.6 THEN 'Follow-up visit' ELSE 'New complaint' END,
       s.slot - make_interval(days => 1 + floor(s.r3 * 20)::int)
FROM (
   SELECT d.staff_id AS doctor_id, st.branch_id,
          day + time '08:00' + make_interval(mins => 15 * k) AS slot,
          random() r1, random() r2, random() r3
   FROM doctor d JOIN staff st USING (staff_id)
   CROSS JOIN generate_series(DATE '2023-01-02', DATE '2026-11-30', interval '1 day') day
   CROSS JOIN generate_series(0, 31) k
   WHERE extract(isodow FROM day) < 6
     AND random() < 0.25
) s
JOIN (SELECT branch_id, max(cnt) AS cnt FROM pmap GROUP BY branch_id) bc USING (branch_id)
-- Skewed choice: power(r1, 1.2) favours long-standing (low-number) patients.
JOIN pmap pm ON pm.branch_id = s.branch_id
            AND pm.ord = 1 + floor(power(s.r1, 1.2) * bc.cnt)::int
WHERE pm.registered_at < s.slot
ORDER BY s.slot;

-- ---------------------------------------------------------------------
-- Encounters: one per completed appointment (OPD) + emergency walk-ins
-- ---------------------------------------------------------------------
INSERT INTO encounter (appt_id, patient_id, doctor_id, branch_id, encounter_type, started_at, ended_at)
SELECT appt_id, patient_id, doctor_id, branch_id, 'OPD',
       scheduled_at + make_interval(mins => (appt_id % 10)::int),
       scheduled_at + make_interval(mins => 12 + (appt_id % 14)::int)
FROM appointment WHERE status = 'COMPLETED'
ORDER BY scheduled_at;

-- 25,000 emergency attendances at the main hospital, any hour of the day.
CREATE TEMP TABLE er_docs AS
SELECT row_number() OVER (ORDER BY staff_id) AS ord, staff_id
FROM doctor JOIN staff USING (staff_id)
WHERE branch_id = 1 AND specialty IN ('Internal Medicine','Family Medicine','General Surgery','Paediatrics');

INSERT INTO encounter (patient_id, doctor_id, branch_id, encounter_type, started_at, ended_at)
SELECT p.patient_id, ed.staff_id, 1, 'EMERGENCY', t, t + interval '50 minutes'
FROM (SELECT TIMESTAMPTZ '2023-01-01 00:00+01'
             + random() * (TIMESTAMPTZ '2026-11-01 23:00+01' - TIMESTAMPTZ '2023-01-01 00:00+01') AS t,
             1 + floor(random() * 60000)::int AS pid,
             1 + floor(random() * (SELECT count(*) FROM er_docs))::int AS dord
      FROM generate_series(1, 25000) g) x
JOIN patient p ON p.patient_id = x.pid AND p.registered_at < x.t
JOIN er_docs ed ON ed.ord = x.dord
ORDER BY t;

-- ---------------------------------------------------------------------
-- Admissions: each bed hosts back-to-back stays on a 9-day cycle with
-- length of stay 1-8 days, so stays in one bed never overlap.
-- ---------------------------------------------------------------------
CREATE TEMP TABLE adm_plan AS
SELECT b.bed_id, w.branch_id, w.ward_type, k,
       TIMESTAMPTZ '2023-01-03 10:00+01' + make_interval(days => 9 * k + (b.bed_id % 5)::int, hours => (b.bed_id % 7)::int) AS adm_at,
       1 + floor(random() * 8)::int AS los,
       random() AS rp, random() AS rd, random() AS rc
FROM bed b JOIN ward w USING (ward_id)
CROSS JOIN generate_series(0, 156) k
WHERE random() < 0.75;                                   -- ~75% bed-cycle utilisation
DELETE FROM adm_plan WHERE adm_at >= TIMESTAMPTZ '2026-11-02 00:00+01';

-- Candidate patient pools per ward type (age/sex appropriate)
CREATE TEMP TABLE adm_pool AS
SELECT pool, row_number() OVER (PARTITION BY pool ORDER BY patient_id) AS ord, patient_id, registered_at
FROM (
   SELECT 'MATERNITY' AS pool, patient_id, registered_at FROM patient
    WHERE sex = 'F' AND date_of_birth BETWEEN DATE '1978-01-01' AND DATE '2006-01-01'
   UNION ALL
   SELECT 'PAEDIATRIC', patient_id, registered_at FROM patient WHERE date_of_birth > DATE '2012-01-01'
   UNION ALL
   SELECT 'ADULT', patient_id, registered_at FROM patient WHERE date_of_birth < DATE '2008-01-01'
) z;
CREATE INDEX ON adm_pool (pool, ord);

CREATE TEMP TABLE adm_docs AS
SELECT st.branch_id,
       CASE d.specialty WHEN 'Obstetrics & Gynaecology' THEN 'MATERNITY'
                        WHEN 'Paediatrics' THEN 'PAEDIATRIC' ELSE 'ADULT' END AS pool,
       row_number() OVER (PARTITION BY st.branch_id,
            CASE d.specialty WHEN 'Obstetrics & Gynaecology' THEN 'MATERNITY'
                             WHEN 'Paediatrics' THEN 'PAEDIATRIC' ELSE 'ADULT' END ORDER BY st.staff_id) AS ord,
       d.staff_id
FROM doctor d JOIN staff st USING (staff_id)
WHERE d.specialty <> 'Ophthalmology';

ALTER TABLE adm_plan ADD COLUMN pool text, ADD COLUMN patient_id int, ADD COLUMN doctor_id int,
                     ADD COLUMN dis_at timestamptz, ADD COLUMN dx text;
UPDATE adm_plan SET pool = CASE ward_type WHEN 'MATERNITY' THEN 'MATERNITY'
                                          WHEN 'PAEDIATRIC' THEN 'PAEDIATRIC' ELSE 'ADULT' END,
                    dis_at = adm_at + make_interval(days => los, hours => 3);
UPDATE adm_plan a SET patient_id = p.patient_id
FROM (SELECT pool, max(ord) AS cnt FROM adm_pool GROUP BY pool) c, adm_pool p
WHERE c.pool = a.pool AND p.pool = a.pool AND p.ord = 1 + floor(a.rp * c.cnt)::int;
UPDATE adm_plan a SET doctor_id = d.staff_id
FROM (SELECT branch_id, pool, max(ord) AS cnt FROM adm_docs GROUP BY 1, 2) c, adm_docs d
WHERE c.branch_id = a.branch_id AND c.pool = a.pool
  AND d.branch_id = a.branch_id AND d.pool = a.pool AND d.ord = 1 + floor(a.rd * c.cnt)::int;
DELETE FROM adm_plan a USING patient p WHERE p.patient_id = a.patient_id AND p.registered_at > a.adm_at;
UPDATE adm_plan SET dx = CASE pool
     WHEN 'MATERNITY'  THEN (ARRAY['O80','O80','O80','O14.9'])[1 + floor(rc * 4)::int]
     WHEN 'PAEDIATRIC' THEN (ARRAY['B50.9','B50.9','D57.0','J18.9','A09'])[1 + floor(rc * 5)::int]
     ELSE CASE WHEN ward_type = 'ICU' THEN (ARRAY['I63.9','J18.9','I50.9','N18.9'])[1 + floor(rc * 4)::int]
               ELSE (ARRAY['B50.9','A01.0','I10','E11.9','J18.9','D57.0','N18.9','I50.9'])[1 + floor(rc * 8)::int] END
  END;

-- Stays still in progress on 2026-11-02 stay open (discharged_at NULL),
-- keeping only one open stay per patient.
UPDATE adm_plan a SET dis_at = NULL
FROM (SELECT bed_id, k, row_number() OVER (PARTITION BY patient_id ORDER BY adm_at) AS rn
      FROM adm_plan WHERE dis_at > TIMESTAMPTZ '2026-11-02 00:00+01') cur
WHERE a.bed_id = cur.bed_id AND a.k = cur.k AND cur.rn = 1;
UPDATE adm_plan SET dis_at = TIMESTAMPTZ '2026-11-01 18:00+01'
WHERE dis_at > TIMESTAMPTZ '2026-11-02 00:00+01' AND adm_at < TIMESTAMPTZ '2026-11-01 18:00+01';
DELETE FROM adm_plan WHERE dis_at > TIMESTAMPTZ '2026-11-02 00:00+01';

INSERT INTO encounter (patient_id, doctor_id, branch_id, encounter_type, started_at, ended_at)
SELECT patient_id, doctor_id, branch_id, 'INPATIENT', adm_at, dis_at FROM adm_plan ORDER BY adm_at;

INSERT INTO admission (patient_id, bed_id, encounter_id, admitted_at, discharged_at)
SELECT a.patient_id, a.bed_id, e.encounter_id, a.adm_at, a.dis_at
FROM adm_plan a
JOIN encounter e ON e.encounter_type = 'INPATIENT' AND e.patient_id = a.patient_id AND e.started_at = a.adm_at
ORDER BY a.adm_at;

UPDATE bed SET is_occupied = true
WHERE bed_id IN (SELECT bed_id FROM admission WHERE discharged_at IS NULL);

-- ---------------------------------------------------------------------
-- Diagnoses: drawn from a specialty-appropriate pool, skewed so the
-- first codes in each pool (e.g. malaria) are the most common.
-- ---------------------------------------------------------------------
CREATE TEMP TABLE dx_pool(specialty text, codes text[]);
INSERT INTO dx_pool VALUES
 ('Internal Medicine', ARRAY['B54','B50.9','I10','A01.0','E11.9','J06.9','K29.7','N39.0','D64.9','M54.5','A09','J18.9',
                             'B18.1','B20','G43.9','F32.9','I50.9','N18.9','M17.9','A15.0','I63.9','L30.9','B35.9','J45.9','A96.2']),
 ('Family Medicine',   ARRAY['B54','B50.9','J06.9','A01.0','I10','K29.7','N39.0','A09','M54.5','E11.9','L30.9','B35.9',
                             'G43.9','D64.9','J45.9','H66.9','F32.9','M17.9','B18.1','B20']),
 ('Paediatrics',       ARRAY['B50.9','B54','J06.9','A09','D57.0','D57.1','J18.9','H66.9','D64.9','L30.9','J45.9','G40.9','B35.9']),
 ('Obstetrics & Gynaecology', ARRAY['Z34.9','Z34.9','N39.0','B54','D64.9','O14.9']),
 ('General Surgery',   ARRAY['K40.9','L02.9','M54.5','M17.9','K29.7','K35.8']),
 ('Ophthalmology',     ARRAY['H10.9','H26.9','H40.9']);

INSERT INTO diagnosis (encounter_id, icd10_code, is_primary)
SELECT e.encounter_id, p.codes[1 + floor(power(random(), 1.7) * array_length(p.codes, 1))::int], true
FROM encounter e JOIN doctor d ON d.staff_id = e.doctor_id JOIN dx_pool p USING (specialty)
WHERE e.encounter_type <> 'INPATIENT';

INSERT INTO diagnosis (encounter_id, icd10_code, is_primary)
SELECT e.encounter_id, a.dx, true
FROM adm_plan a JOIN encounter e ON e.encounter_type = 'INPATIENT' AND e.patient_id = a.patient_id AND e.started_at = a.adm_at;

-- ~30% of encounters get a secondary diagnosis
INSERT INTO diagnosis (encounter_id, icd10_code, is_primary)
SELECT e.encounter_id, p.codes[1 + floor(random() * array_length(p.codes, 1))::int], false
FROM encounter e JOIN doctor d ON d.staff_id = e.doctor_id JOIN dx_pool p USING (specialty)
WHERE random() < 0.30
ON CONFLICT DO NOTHING;

-- Presenting complaint follows the primary diagnosis
CREATE TEMP TABLE complaint_map(icd10_code text, complaint text);
INSERT INTO complaint_map VALUES
 ('B54','Fever, headache and body aches'),('B50.9','High-grade fever with chills and vomiting'),
 ('A01.0','Prolonged fever and abdominal pain'),('J06.9','Cough, catarrh and sore throat'),
 ('I10','Routine BP review / headache'),('A09','Diarrhoea and vomiting'),('E11.9','Diabetes clinic review'),
 ('N39.0','Painful and frequent urination'),('K29.7','Upper abdominal pain and heartburn'),
 ('D57.1','Sickle cell clinic review'),('D57.0','Severe bone pain (crisis)'),('J18.9','Fever, cough and difficulty breathing'),
 ('D64.9','Weakness and dizziness'),('M54.5','Low back pain'),('J45.9','Wheeze and shortness of breath'),
 ('O80','Labour pains at term'),('Z34.9','Antenatal clinic visit'),('O14.9','Raised BP in pregnancy, swollen feet'),
 ('H10.9','Red, itchy eyes'),('H26.9','Gradual blurring of vision'),('H40.9','Eye pain / glaucoma review'),
 ('H66.9','Ear pain and discharge'),('L30.9','Itchy skin rash'),('B35.9','Ringworm / itchy scaly patches'),
 ('G43.9','Recurrent severe headache'),('G40.9','Seizure / epilepsy review'),('I63.9','Sudden weakness of one side'),
 ('I50.9','Breathlessness and leg swelling'),('N18.9','Renal clinic review'),('F32.9','Low mood and poor sleep'),
 ('B20','ART clinic refill'),('B18.1','Hepatitis B review'),('A15.0','Chronic cough and weight loss'),
 ('K35.8','Right lower abdominal pain'),('K40.9','Painless groin swelling'),('L02.9','Painful swelling with pus'),('M17.9','Knee pain on walking'),('A96.2','Fever with bleeding tendency');

UPDATE encounter e SET complaint = c.complaint,
       clinical_notes = 'Assessed by attending doctor. Working diagnosis ' || d.icd10_code || '. Plan discussed with patient.'
FROM diagnosis d JOIN complaint_map c USING (icd10_code)
WHERE d.encounter_id = e.encounter_id AND d.is_primary;

-- ---------------------------------------------------------------------
-- Prescriptions: standard treatment per primary diagnosis
-- ---------------------------------------------------------------------
CREATE TEMP TABLE dx_drug(icd10_code text, drug_id int, dose text, freq text, days int, qty int);
INSERT INTO dx_drug VALUES
 ('B54',1,'1 tab','BD',3,6),('B54',2,'1 g','TDS',3,18),
 ('B50.9',1,'1 tab','BD',3,6),('B50.9',2,'1 g','TDS',3,18),
 ('A01.0',4,'500 mg','BD',7,14),('A01.0',2,'1 g','TDS',3,18),
 ('J06.9',2,'1 g','TDS',3,18),('J06.9',30,'10 mg','nocte',5,5),
 ('I10',5,'10 mg','OD',30,30),('I10',20,'50 mg','OD',30,30),
 ('A09',16,'1 sachet','after each stool',3,6),('A09',17,'20 mg','OD',10,10),('A09',15,'400 mg','TDS',5,15),
 ('E11.9',7,'500 mg','BD',30,60),('E11.9',8,'5 mg','OD',30,30),
 ('N39.0',4,'500 mg','BD',5,10),
 ('K29.7',9,'20 mg','BD',14,28),
 ('D57.1',10,'5 mg','OD',30,30),('D57.1',19,'500 mg','OD',30,30),
 ('D57.0',14,'1 g','OD',3,3),('D57.0',2,'1 g','TDS',5,30),('D57.0',10,'5 mg','OD',30,30),
 ('J18.9',3,'500 mg','TDS',7,21),('J18.9',2,'1 g','TDS',3,18),
 ('D64.9',11,'200 mg','BD',30,60),('D64.9',10,'5 mg','OD',30,30),
 ('M54.5',12,'400 mg','TDS',5,15),
 ('J45.9',13,'2 puffs','PRN',30,1),
 ('O80',26,'10 IU','stat',1,1),
 ('Z34.9',10,'5 mg','OD',30,30),('Z34.9',11,'200 mg','OD',30,30),
 ('O14.9',27,'4 g','stat',1,1),('O14.9',5,'10 mg','OD',14,14),
 ('H10.9',21,'1 drop','QDS',7,1),('H40.9',22,'1 drop','BD',30,1),
 ('H66.9',3,'500 mg','TDS',5,15),('H66.9',2,'1 g','TDS',3,18),
 ('L30.9',30,'10 mg','OD',7,7),('B35.9',23,'apply','BD',14,1),
 ('G43.9',2,'1 g','TDS',3,18),('G43.9',12,'400 mg','TDS',3,9),
 ('G40.9',24,'200 mg','BD',30,60),
 ('I63.9',5,'10 mg','OD',30,30),
 ('I50.9',25,'40 mg','OD',30,30),('I50.9',6,'10 mg','OD',30,30),
 ('N18.9',25,'40 mg','OD',30,30),
 ('F32.9',29,'20 mg','OD',30,30),
 ('B20',28,'1 tab','OD',30,30),
 ('K35.8',14,'1 g','BD',3,6),('K35.8',15,'500 mg','TDS',3,9),
 ('M17.9',12,'400 mg','TDS',7,21),
 ('L02.9',3,'500 mg','TDS',7,21),('L02.9',12,'400 mg','TDS',5,15);

INSERT INTO prescription (encounter_id, issued_at, status)
SELECT e.encounter_id, COALESCE(e.ended_at, e.started_at + interval '20 minutes'),
       CASE WHEN e.started_at > TIMESTAMPTZ '2026-10-31' THEN 'PENDING'
            WHEN e.encounter_id % 50 = 0 THEN 'PARTIAL'
            ELSE 'DISPENSED' END
FROM encounter e JOIN diagnosis d ON d.encounter_id = e.encounter_id AND d.is_primary
WHERE EXISTS (SELECT 1 FROM dx_drug x WHERE x.icd10_code = d.icd10_code)
ORDER BY e.encounter_id;

INSERT INTO prescription_item (rx_id, line_no, drug_id, dose, frequency, duration_days, qty_prescribed, qty_dispensed)
SELECT rx.rx_id, row_number() OVER (PARTITION BY rx.rx_id ORDER BY x.drug_id),
       x.drug_id, x.dose, x.freq, x.days, x.qty,
       CASE rx.status WHEN 'DISPENSED' THEN x.qty WHEN 'PARTIAL' THEN x.qty / 2 ELSE 0 END
FROM prescription rx
JOIN diagnosis d ON d.encounter_id = rx.encounter_id AND d.is_primary
JOIN dx_drug x USING (icd10_code);

-- ---------------------------------------------------------------------
-- Laboratory: investigations per primary diagnosis, ~75% of the time
-- ---------------------------------------------------------------------
CREATE TEMP TABLE dx_lab(icd10_code text, tests text[]);
INSERT INTO dx_lab VALUES
 ('B54',ARRAY['MP','PCV']),('B50.9',ARRAY['MP','HB','PLT']),('A01.0',ARRAY['WIDAL','WBC']),
 ('I10',ARRAY['CREAT','UREA','NA','K']),('E11.9',ARRAY['FBS','HBA1C']),('N39.0',ARRAY['URINE']),
 ('D64.9',ARRAY['HB','PCV']),('D57.1',ARRAY['HB','PCV','WBC']),('D57.0',ARRAY['HB','PCV','WBC']),
 ('J18.9',ARRAY['WBC']),('Z34.9',ARRAY['HB','URINE','HBSAG']),('O14.9',ARRAY['URINE','CREAT','PLT']),
 ('N18.9',ARRAY['CREAT','UREA','K','NA']),('I50.9',ARRAY['NA','K','CREAT']),('B18.1',ARRAY['HBSAG','ALT']),
 ('B20',ARRAY['WBC','ALT']),('A96.2',ARRAY['PLT','ALT']),('A09',ARRAY['NA','K']),('K35.8',ARRAY['WBC']);

CREATE TEMP TABLE lab_staff AS
SELECT branch_id, row_number() OVER (PARTITION BY branch_id ORDER BY staff_id) AS ord,
       count(*) OVER (PARTITION BY branch_id) AS cnt, staff_id
FROM staff WHERE role = 'LAB_SCIENTIST';

INSERT INTO lab_order (encounter_id, ordered_at, priority, status)
SELECT e.encounter_id, e.started_at + interval '10 minutes',
       CASE WHEN e.encounter_type = 'EMERGENCY' THEN 'STAT'
            WHEN e.encounter_id % 7 = 0 THEN 'URGENT' ELSE 'ROUTINE' END,
       CASE WHEN e.started_at > TIMESTAMPTZ '2026-11-01' THEN 'COLLECTED' ELSE 'RESULTED' END
FROM encounter e JOIN diagnosis d ON d.encounter_id = e.encounter_id AND d.is_primary
WHERE EXISTS (SELECT 1 FROM dx_lab l WHERE l.icd10_code = d.icd10_code)
  AND e.encounter_id % 4 <> 0
ORDER BY e.encounter_id;

INSERT INTO lab_result (order_id, test_code, value_num, value_text, abnormal_flag, verified_by, resulted_at)
SELECT o.order_id, t.test_code, v.num,
       CASE t.test_code
         WHEN 'MP'    THEN CASE WHEN v.r < 0.65 THEN 'P. falciparum seen (++)' ELSE 'No malaria parasite seen' END
         WHEN 'WIDAL' THEN CASE WHEN v.r < 0.40 THEN 'O 1:160, H 1:160 (significant)' ELSE 'Not significant' END
         WHEN 'HBSAG' THEN CASE WHEN d.icd10_code = 'B18.1' OR v.r < 0.06 THEN 'Reactive' ELSE 'Non-reactive' END
         WHEN 'URINE' THEN CASE WHEN v.r < 0.45 THEN 'Leucocytes ++, nitrite positive' ELSE 'No abnormality detected' END
       END,
       CASE WHEN t.ref_low IS NULL THEN
              CASE WHEN (t.test_code = 'MP' AND v.r < 0.65) OR (t.test_code = 'WIDAL' AND v.r < 0.40)
                     OR (t.test_code = 'HBSAG' AND (d.icd10_code = 'B18.1' OR v.r < 0.06))
                     OR (t.test_code = 'URINE' AND v.r < 0.45) THEN 'A' ELSE 'N' END
            WHEN v.num < t.ref_low  THEN 'L'
            WHEN v.num > t.ref_high THEN 'H'
            ELSE 'N' END,
       CASE WHEN o.status = 'RESULTED' THEN ls.staff_id END,
       CASE WHEN o.status = 'RESULTED' THEN o.ordered_at + interval '3 hours' END
FROM lab_order o
JOIN encounter e USING (encounter_id)
JOIN diagnosis d ON d.encounter_id = o.encounter_id AND d.is_primary
JOIN dx_lab l USING (icd10_code)
CROSS JOIN LATERAL unnest(l.tests) AS u(code)
JOIN lab_test t ON t.test_code = u.code
CROSS JOIN LATERAL (SELECT random() AS r,
                           round((t.ref_low + (t.ref_high - t.ref_low) * (random() * 1.7 - 0.35))::numeric, 2) AS num
                    WHERE o.order_id > 0) v
JOIN lab_staff ls ON ls.branch_id = e.branch_id AND ls.ord = 1 + o.order_id % ls.cnt
WHERE o.status <> 'CANCELLED';
UPDATE lab_result SET value_num = NULL WHERE value_text IS NOT NULL;

-- ---------------------------------------------------------------------
-- Billing: one invoice per encounter, lines for consult, labs, drugs, bed
-- ---------------------------------------------------------------------
INSERT INTO invoice (patient_id, encounter_id, branch_id, issued_at)
SELECT patient_id, encounter_id, branch_id, COALESCE(ended_at, started_at + interval '1 hour')
FROM encounter ORDER BY encounter_id;

INSERT INTO invoice_line (invoice_id, line_no, item_type, description, qty, unit_price)
SELECT invoice_id, row_number() OVER (PARTITION BY invoice_id ORDER BY sort_key), item_type, description, qty, unit_price
FROM (
   SELECT i.invoice_id, 1 AS sort_key, 'CONSULT' AS item_type,
          CASE e.encounter_type WHEN 'EMERGENCY' THEN 'Emergency consultation' ELSE 'Consultation - ' || d.specialty END AS description,
          1 AS qty, d.consult_fee + CASE WHEN e.encounter_type = 'EMERGENCY' THEN 5000 ELSE 0 END AS unit_price
   FROM invoice i JOIN encounter e USING (encounter_id) JOIN doctor d ON d.staff_id = e.doctor_id
   UNION ALL
   SELECT i.invoice_id, 2, 'LAB', t.name, 1, t.price
   FROM invoice i JOIN lab_order o USING (encounter_id) JOIN lab_result r USING (order_id) JOIN lab_test t USING (test_code)
   UNION ALL
   SELECT i.invoice_id, 3, 'DRUG', dr.generic_name || ' ' || dr.strength, pi.qty_prescribed, dr.unit_price
   FROM invoice i JOIN prescription rx USING (encounter_id) JOIN prescription_item pi USING (rx_id)
   JOIN drug dr USING (drug_id) WHERE dr.unit_price > 0
   UNION ALL
   SELECT i.invoice_id, 4, 'BED', 'Bed charge - ' || w.name,
          GREATEST(1, ceil(extract(epoch FROM COALESCE(a.discharged_at, TIMESTAMPTZ '2026-11-02') - a.admitted_at) / 86400))::int,
          w.daily_rate
   FROM invoice i JOIN admission a USING (encounter_id) JOIN bed b USING (bed_id) JOIN ward w USING (ward_id)
) lines;

-- Payments: most invoices settled in full, some partially, recent ones often still open.
WITH tot AS (
   SELECT i.invoice_id, i.patient_id, i.issued_at, SUM(l.qty * l.unit_price) AS total, random() AS r
   FROM invoice i JOIN invoice_line l USING (invoice_id) GROUP BY i.invoice_id)
INSERT INTO payment (invoice_id, amount, method, reference, paid_at)
SELECT t.invoice_id,
       CASE WHEN t.r < 0.88 THEN t.total ELSE round(t.total / 2, 2) END,
       CASE WHEN EXISTS (SELECT 1 FROM patient_coverage c WHERE c.patient_id = t.patient_id
                           AND t.issued_at::date >= c.valid_from AND t.issued_at::date < c.valid_to) THEN 'HMO'
            ELSE (ARRAY['CASH','CARD','TRANSFER','TRANSFER'])[1 + (t.invoice_id % 4)::int] END,
       'PAY-' || t.invoice_id || '-1',
       t.issued_at + make_interval(mins => 5 + (t.invoice_id % 50)::int)
FROM tot t
WHERE (t.issued_at < TIMESTAMPTZ '2026-10-20' AND t.r < 0.94)
   OR (t.issued_at >= TIMESTAMPTZ '2026-10-20' AND t.r < 0.50);

UPDATE invoice i SET status = CASE WHEN s.amount_paid = 0 THEN 'OPEN'
                                   WHEN s.balance <= 0 THEN 'PAID' ELSE 'PARTIAL' END
FROM invoice_summary s WHERE s.invoice_id = i.invoice_id;

-- ---------------------------------------------------------------------
-- On-call roster for November 2026 (two doctors per clinical dept/day)
-- ---------------------------------------------------------------------
INSERT INTO on_call_roster (dept_id, shift_date, doctor_id)
SELECT dept_id, day::date, staff_id
FROM (SELECT s.dept_id, s.staff_id,
             row_number() OVER (PARTITION BY s.dept_id ORDER BY s.staff_id) AS rn
      FROM staff s JOIN doctor USING (staff_id)) d
CROSS JOIN generate_series(DATE '2026-11-01', DATE '2026-11-30', interval '1 day') day
WHERE d.rn <= 2;

-- ---------------------------------------------------------------------
-- Audit triggers on clinical tables (attached after bulk load)
-- ---------------------------------------------------------------------
CREATE TRIGGER trg_audit_encounter    AFTER INSERT OR UPDATE OR DELETE ON encounter
    FOR EACH ROW EXECUTE FUNCTION audit_clinical_change('encounter_id');
CREATE TRIGGER trg_audit_diagnosis    AFTER INSERT OR UPDATE OR DELETE ON diagnosis
    FOR EACH ROW EXECUTE FUNCTION audit_clinical_change('encounter_id');
CREATE TRIGGER trg_audit_prescription AFTER INSERT OR UPDATE OR DELETE ON prescription_item
    FOR EACH ROW EXECUTE FUNCTION audit_clinical_change('rx_id');
CREATE TRIGGER trg_audit_lab_result   AFTER INSERT OR UPDATE OR DELETE ON lab_result
    FOR EACH ROW EXECUTE FUNCTION audit_clinical_change('order_id');

VACUUM ANALYZE;
