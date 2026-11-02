-- =====================================================================
-- Udoka Specialist Hospital - reference / master data
-- Branches, departments, wards, beds, HMOs, ICD-10 subset, drugs, lab tests.
-- All organisation names below are fictional.
-- =====================================================================
SET search_path = hms, public;

INSERT INTO branch VALUES
 (1, 'ENU', 'Udoka Specialist Hospital - Main', 'Enugu',  'Enugu',   '+2348031000001', '2009-03-02'),
 (2, 'NSK', 'Udoka Outpatient Clinic Nsukka',   'Nsukka', 'Enugu',   '+2348031000002', '2016-07-11'),
 (3, 'AWK', 'Udoka Outpatient Clinic Awka',     'Awka',   'Anambra', '+2348031000003', '2019-01-14');

-- Departments: the main hospital has all specialties; the satellite clinics a subset.
INSERT INTO department (dept_id, branch_id, name)
SELECT row_number() OVER (ORDER BY b.branch_id, d.ord), b.branch_id, d.name
FROM branch b
CROSS JOIN (VALUES (1,'General Medicine'),(2,'Paediatrics'),(3,'Obstetrics & Gynaecology'),
                   (4,'Surgery'),(5,'Ophthalmology'),(6,'Laboratory'),(7,'Pharmacy'),
                   (8,'Medical Records'),(9,'Accounts')) AS d(ord, name)
WHERE b.branch_code = 'ENU' OR d.name NOT IN ('Surgery','Ophthalmology');

INSERT INTO ward VALUES
 (1, 1, 'Ward A (Male Medical)',   'GENERAL',    15000),
 (2, 1, 'Ward B (Female Medical)', 'GENERAL',    15000),
 (3, 1, 'Maternity',               'MATERNITY',  20000),
 (4, 1, 'Children''s Ward',        'PAEDIATRIC', 12000),
 (5, 1, 'Intensive Care Unit',     'ICU',        85000),
 (6, 2, 'Observation Ward',        'GENERAL',    10000),
 (7, 2, 'Maternity',               'MATERNITY',  15000),
 (8, 3, 'Observation Ward',        'GENERAL',    10000),
 (9, 3, 'Maternity',               'MATERNITY',  15000);

INSERT INTO bed (bed_id, ward_id, label)
SELECT row_number() OVER (ORDER BY w.ward_id, n), w.ward_id, 'B' || lpad(n::text, 2, '0')
FROM ward w
CROSS JOIN LATERAL generate_series(1, CASE WHEN w.ward_type = 'ICU' THEN 8
                                           WHEN w.branch_id = 1 THEN 20 ELSE 12 END) AS n;

INSERT INTO hmo VALUES
 (1, 'NHIA Formal Sector Scheme',   'NHIA-FSS'),
 (2, 'Coal City Health HMO',        'HMO-CCH01'),
 (3, 'Eastgate Care HMO',           'HMO-EGC02'),
 (4, 'Niger Basin Health Partners', 'HMO-NBH03');

INSERT INTO icd10_code VALUES
 ('B54',   'Unspecified malaria',                                 'Infectious and parasitic'),
 ('B50.9', 'Plasmodium falciparum malaria, unspecified',          'Infectious and parasitic'),
 ('A01.0', 'Typhoid fever',                                       'Infectious and parasitic'),
 ('J06.9', 'Acute upper respiratory infection, unspecified',      'Respiratory'),
 ('I10',   'Essential (primary) hypertension',                    'Circulatory'),
 ('A09',   'Infectious gastroenteritis and colitis, unspecified', 'Infectious and parasitic'),
 ('E11.9', 'Type 2 diabetes mellitus without complications',      'Endocrine and metabolic'),
 ('N39.0', 'Urinary tract infection, site not specified',         'Genitourinary'),
 ('K29.7', 'Gastritis, unspecified',                              'Digestive'),
 ('D57.1', 'Sickle-cell disease without crisis',                  'Blood'),
 ('D57.0', 'Hb-SS disease with crisis',                           'Blood'),
 ('J18.9', 'Pneumonia, unspecified organism',                     'Respiratory'),
 ('D64.9', 'Anaemia, unspecified',                                'Blood'),
 ('M54.5', 'Low back pain',                                       'Musculoskeletal'),
 ('J45.9', 'Asthma, unspecified',                                 'Respiratory'),
 ('O80',   'Encounter for full-term uncomplicated delivery',      'Pregnancy and childbirth'),
 ('Z34.9', 'Supervision of normal pregnancy, unspecified',        'Factors influencing health'),
 ('O14.9', 'Pre-eclampsia, unspecified',                          'Pregnancy and childbirth'),
 ('H10.9', 'Conjunctivitis, unspecified',                         'Eye'),
 ('H26.9', 'Cataract, unspecified',                               'Eye'),
 ('H40.9', 'Glaucoma, unspecified',                               'Eye'),
 ('H66.9', 'Otitis media, unspecified',                           'Ear'),
 ('L30.9', 'Dermatitis, unspecified',                             'Skin'),
 ('B35.9', 'Dermatophytosis, unspecified',                        'Infectious and parasitic'),
 ('G43.9', 'Migraine, unspecified',                               'Nervous system'),
 ('G40.9', 'Epilepsy, unspecified',                               'Nervous system'),
 ('I63.9', 'Cerebral infarction, unspecified',                    'Circulatory'),
 ('I50.9', 'Heart failure, unspecified',                          'Circulatory'),
 ('N18.9', 'Chronic kidney disease, unspecified',                 'Genitourinary'),
 ('F32.9', 'Depressive episode, unspecified',                     'Mental and behavioural'),
 ('B20',   'HIV disease',                                         'Infectious and parasitic'),
 ('B18.1', 'Chronic viral hepatitis B',                           'Infectious and parasitic'),
 ('A15.0', 'Tuberculosis of lung',                                'Infectious and parasitic'),
 ('K35.8', 'Acute appendicitis, other and unspecified',           'Digestive'),
 ('K40.9', 'Unilateral inguinal hernia, without obstruction',     'Digestive'),
 ('L02.9', 'Cutaneous abscess, furuncle and carbuncle, unspec.', 'Skin'),
 ('M17.9', 'Gonarthrosis (knee osteoarthritis), unspecified',     'Musculoskeletal'),
 ('A96.2', 'Lassa fever',                                         'Infectious and parasitic');

INSERT INTO drug VALUES
 ( 1, 'Artemether/Lumefantrine', 'tablet',    '80/480mg',  2500),
 ( 2, 'Paracetamol',             'tablet',    '500mg',       20),
 ( 3, 'Amoxicillin',             'capsule',   '500mg',       80),
 ( 4, 'Ciprofloxacin',           'tablet',    '500mg',      120),
 ( 5, 'Amlodipine',              'tablet',    '10mg',        60),
 ( 6, 'Lisinopril',              'tablet',    '10mg',        90),
 ( 7, 'Metformin',               'tablet',    '500mg',       45),
 ( 8, 'Glibenclamide',           'tablet',    '5mg',         30),
 ( 9, 'Omeprazole',              'capsule',   '20mg',        70),
 (10, 'Folic acid',              'tablet',    '5mg',         10),
 (11, 'Ferrous sulphate',        'tablet',    '200mg',       15),
 (12, 'Ibuprofen',               'tablet',    '400mg',       35),
 (13, 'Salbutamol',              'inhaler',   '100mcg',    3500),
 (14, 'Ceftriaxone',             'injection', '1g',        1800),
 (15, 'Metronidazole',           'tablet',    '400mg',       40),
 (16, 'Oral rehydration salts',  'sachet',    '20.5g',      150),
 (17, 'Zinc sulphate',           'tablet',    '20mg',        25),
 (18, 'Artesunate',              'injection', '60mg',      2200),
 (19, 'Hydroxyurea',             'capsule',   '500mg',      300),
 (20, 'Losartan',                'tablet',    '50mg',       110),
 (21, 'Chloramphenicol',         'eye drop',  '0.5%',       900),
 (22, 'Timolol',                 'eye drop',  '0.5%',      2400),
 (23, 'Clotrimazole',            'cream',     '1%',         600),
 (24, 'Carbamazepine',           'tablet',    '200mg',       85),
 (25, 'Furosemide',              'tablet',    '40mg',        30),
 (26, 'Oxytocin',                'injection', '10IU',       700),
 (27, 'Magnesium sulphate',      'injection', '50%',       1500),
 (28, 'Tenofovir/Lamivudine/Dolutegravir', 'tablet', '300/300/50mg', 0),
 (29, 'Fluoxetine',              'capsule',   '20mg',       150),
 (30, 'Cetirizine',              'tablet',    '10mg',        25);

-- Every branch stocks every drug; the satellite clinics hold less.
INSERT INTO pharmacy_stock (branch_id, drug_id, qty_on_hand, reorder_level)
SELECT b.branch_id, d.drug_id,
       CASE WHEN b.branch_id = 1 THEN 2000 ELSE 600 END,
       CASE WHEN b.branch_id = 1 THEN 300  ELSE 100 END
FROM branch b CROSS JOIN drug d;

INSERT INTO lab_test VALUES
 ('HB',     'Haemoglobin',                 'Blood', 'g/dL',     11.5,  17.0,  1500),
 ('PCV',    'Packed cell volume',          'Blood', '%',        35.0,  50.0,  1000),
 ('WBC',    'White blood cell count',      'Blood', 'x10^9/L',   4.0,  11.0,  1500),
 ('PLT',    'Platelet count',              'Blood', 'x10^9/L', 150.0, 400.0,  1500),
 ('MP',     'Malaria parasite (film)',     'Blood', NULL,       NULL,  NULL,  1000),
 ('WIDAL',  'Widal test',                  'Blood', NULL,       NULL,  NULL,  2000),
 ('FBS',    'Fasting blood sugar',         'Blood', 'mmol/L',    3.9,   5.5,  1500),
 ('HBA1C',  'Glycated haemoglobin',        'Blood', '%',         4.0,   5.6,  6000),
 ('CREAT',  'Serum creatinine',            'Blood', 'umol/L',   60.0, 110.0,  3000),
 ('UREA',   'Serum urea',                  'Blood', 'mmol/L',    2.5,   7.1,  3000),
 ('ALT',    'Alanine aminotransferase',    'Blood', 'U/L',       7.0,  56.0,  3500),
 ('NA',     'Serum sodium',                'Blood', 'mmol/L',  135.0, 145.0,  2500),
 ('K',      'Serum potassium',             'Blood', 'mmol/L',    3.5,   5.1,  2500),
 ('HBSAG',  'Hepatitis B surface antigen', 'Blood', NULL,       NULL,  NULL,  2500),
 ('URINE',  'Urinalysis',                  'Urine', NULL,       NULL,  NULL,  1500);
