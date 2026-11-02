-- =====================================================================
-- Udoka Specialist Hospital (simulated) - Hospital Management Database
-- MIT 8103 Portfolio 1 : physical relational schema (PostgreSQL 16)
-- Author : Casmir Onyeka (301911351)
--
-- Run:  psql -d udoka_hms -f 01_schema.sql
-- The script is re-runnable: it drops and recreates schema "hms".
-- =====================================================================

SET client_min_messages = warning;
DROP SCHEMA IF EXISTS hms CASCADE;
CREATE SCHEMA hms;
SET search_path = hms, public;

-- btree_gist lets an exclusion constraint mix "=" on doctor_id with
-- "&&" (overlap) on a time range. Used to stop double-booking a doctor.
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- ---------------------------------------------------------------------
-- Organisation structure
-- ---------------------------------------------------------------------
CREATE TABLE branch (
    branch_id     smallint     PRIMARY KEY,
    branch_code   char(3)      NOT NULL UNIQUE,          -- ENU, NSK, AWK
    name          varchar(80)  NOT NULL,
    city          varchar(40)  NOT NULL,
    state         varchar(40)  NOT NULL,
    phone         varchar(20)  NOT NULL,
    opened_on     date         NOT NULL
);

CREATE TABLE department (
    dept_id       smallint     PRIMARY KEY,
    branch_id     smallint     NOT NULL REFERENCES branch,
    name          varchar(60)  NOT NULL,
    UNIQUE (branch_id, name)
);

CREATE TABLE staff (
    staff_id      integer      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    branch_id     smallint     NOT NULL REFERENCES branch,
    dept_id       smallint     REFERENCES department,
    first_name    varchar(40)  NOT NULL,
    last_name     varchar(40)  NOT NULL,
    role          varchar(20)  NOT NULL
                  CHECK (role IN ('DOCTOR','NURSE','LAB_SCIENTIST','PHARMACIST',
                                  'RECORDS_OFFICER','BILLING_OFFICER','ADMIN')),
    email         varchar(120) NOT NULL UNIQUE,
    phone         varchar(20),
    hired_on      date         NOT NULL,
    is_active     boolean      NOT NULL DEFAULT true
);

-- Doctor is a subtype (IS-A) of staff: shared-primary-key pattern.
CREATE TABLE doctor (
    staff_id      integer      PRIMARY KEY REFERENCES staff ON DELETE CASCADE,
    mdcn_folio    varchar(20)  NOT NULL UNIQUE,   -- Medical & Dental Council licence no.
    specialty     varchar(60)  NOT NULL,
    consult_fee   numeric(10,2) NOT NULL CHECK (consult_fee >= 0)
);

-- On-call roster: used in Portfolio 3 to demonstrate write skew.
CREATE TABLE on_call_roster (
    dept_id       smallint     NOT NULL REFERENCES department,
    shift_date    date         NOT NULL,
    doctor_id     integer      NOT NULL REFERENCES doctor,
    on_call       boolean      NOT NULL DEFAULT true,
    PRIMARY KEY (dept_id, shift_date, doctor_id)
);

-- ---------------------------------------------------------------------
-- Patients
-- ---------------------------------------------------------------------
CREATE TABLE hmo (
    hmo_id        smallint     PRIMARY KEY,
    name          varchar(80)  NOT NULL UNIQUE,
    nhia_code     varchar(12)  NOT NULL UNIQUE
);

CREATE TABLE patient (
    patient_id    integer      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    hospital_no   varchar(12)  NOT NULL UNIQUE,   -- natural/business key, e.g. USH-0001234
    first_name    varchar(40)  NOT NULL,
    last_name     varchar(40)  NOT NULL,
    date_of_birth date         NOT NULL CHECK (date_of_birth > DATE '1900-01-01'),
    sex           char(1)      NOT NULL CHECK (sex IN ('M','F')),
    phone         varchar(20),
    email         varchar(120),
    address       varchar(200),
    blood_group   varchar(3)   CHECK (blood_group IN ('A+','A-','B+','B-','AB+','AB-','O+','O-')),
    genotype      varchar(2)   CHECK (genotype IN ('AA','AS','AC','SS','SC')),
    reg_branch_id smallint     NOT NULL REFERENCES branch,
    registered_at timestamptz  NOT NULL DEFAULT now()
);

-- Multi-valued attributes of patient moved to their own tables (1NF).
CREATE TABLE patient_allergy (
    patient_id    integer      NOT NULL REFERENCES patient ON DELETE CASCADE,
    allergen      varchar(60)  NOT NULL,
    severity      varchar(10)  NOT NULL CHECK (severity IN ('MILD','MODERATE','SEVERE')),
    PRIMARY KEY (patient_id, allergen)
);

CREATE TABLE emergency_contact (
    patient_id    integer      NOT NULL REFERENCES patient ON DELETE CASCADE,
    contact_no    smallint     NOT NULL CHECK (contact_no BETWEEN 1 AND 3),
    full_name     varchar(80)  NOT NULL,
    relationship  varchar(20)  NOT NULL,
    phone         varchar(20)  NOT NULL,
    PRIMARY KEY (patient_id, contact_no)
);

CREATE TABLE patient_coverage (
    patient_id    integer      NOT NULL REFERENCES patient ON DELETE CASCADE,
    hmo_id        smallint     NOT NULL REFERENCES hmo,
    policy_no     varchar(20)  NOT NULL,
    valid_from    date         NOT NULL,
    valid_to      date         NOT NULL,
    PRIMARY KEY (patient_id, hmo_id, valid_from),
    CHECK (valid_to > valid_from)
);

-- ---------------------------------------------------------------------
-- Appointments and clinical encounters
-- ---------------------------------------------------------------------
CREATE TABLE appointment (
    appt_id       bigint       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    patient_id    integer      NOT NULL REFERENCES patient,
    doctor_id     integer      NOT NULL REFERENCES doctor,
    branch_id     smallint     NOT NULL REFERENCES branch,
    scheduled_at  timestamptz  NOT NULL,
    -- End time is stored (not duration) because "timestamptz + interval" is only
    -- STABLE in PostgreSQL and cannot be used inside the exclusion constraint below.
    ends_at       timestamptz  NOT NULL,
    status        varchar(12)  NOT NULL DEFAULT 'BOOKED'
                  CHECK (status IN ('BOOKED','CHECKED_IN','COMPLETED','CANCELLED','NO_SHOW')),
    reason        varchar(200),
    created_at    timestamptz  NOT NULL DEFAULT now(),
    CONSTRAINT appt_length CHECK (ends_at - scheduled_at BETWEEN interval '5 minutes' AND interval '2 hours'),
    -- A doctor cannot hold two live appointments whose time slots overlap.
    -- Cancelled / no-show bookings release the slot.
    CONSTRAINT no_doctor_double_booking EXCLUDE USING gist (
        doctor_id WITH =,
        tstzrange(scheduled_at, ends_at) WITH &&
    ) WHERE (status IN ('BOOKED','CHECKED_IN','COMPLETED'))
);

CREATE TABLE encounter (
    encounter_id  bigint       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    appt_id       bigint       UNIQUE REFERENCES appointment,  -- NULL for walk-in / emergency
    patient_id    integer      NOT NULL REFERENCES patient,
    doctor_id     integer      NOT NULL REFERENCES doctor,
    branch_id     smallint     NOT NULL REFERENCES branch,
    encounter_type varchar(10) NOT NULL CHECK (encounter_type IN ('OPD','EMERGENCY','INPATIENT')),
    started_at    timestamptz  NOT NULL,
    ended_at      timestamptz,
    complaint     varchar(300),
    clinical_notes text,
    CHECK (ended_at IS NULL OR ended_at >= started_at)
);

CREATE TABLE icd10_code (
    icd10_code    varchar(7)   PRIMARY KEY,
    description   varchar(200) NOT NULL,
    chapter       varchar(60)  NOT NULL
);

CREATE TABLE diagnosis (
    encounter_id  bigint       NOT NULL REFERENCES encounter ON DELETE CASCADE,
    icd10_code    varchar(7)   NOT NULL REFERENCES icd10_code,
    is_primary    boolean      NOT NULL DEFAULT false,
    PRIMARY KEY (encounter_id, icd10_code)
);
-- At most one primary diagnosis per encounter.
CREATE UNIQUE INDEX one_primary_diagnosis ON diagnosis (encounter_id) WHERE is_primary;

-- ---------------------------------------------------------------------
-- Pharmacy
-- ---------------------------------------------------------------------
CREATE TABLE drug (
    drug_id       integer      PRIMARY KEY,
    generic_name  varchar(80)  NOT NULL,
    form          varchar(20)  NOT NULL,          -- tablet, syrup, injection...
    strength      varchar(20)  NOT NULL,
    unit_price    numeric(10,2) NOT NULL CHECK (unit_price >= 0),
    UNIQUE (generic_name, form, strength)
);

CREATE TABLE pharmacy_stock (
    branch_id     smallint     NOT NULL REFERENCES branch,
    drug_id       integer      NOT NULL REFERENCES drug,
    qty_on_hand   integer      NOT NULL CHECK (qty_on_hand >= 0),  -- stock can never go negative
    reorder_level integer      NOT NULL DEFAULT 50 CHECK (reorder_level >= 0),
    PRIMARY KEY (branch_id, drug_id)
);

CREATE TABLE prescription (
    rx_id         bigint       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    encounter_id  bigint       NOT NULL REFERENCES encounter ON DELETE CASCADE,
    issued_at     timestamptz  NOT NULL,
    status        varchar(10)  NOT NULL DEFAULT 'PENDING'
                  CHECK (status IN ('PENDING','DISPENSED','PARTIAL','CANCELLED'))
);

CREATE TABLE prescription_item (
    rx_id         bigint       NOT NULL REFERENCES prescription ON DELETE CASCADE,
    line_no       smallint     NOT NULL,
    drug_id       integer      NOT NULL REFERENCES drug,
    dose          varchar(30)  NOT NULL,
    frequency     varchar(20)  NOT NULL,          -- e.g. 'BD', 'TDS', 'nocte'
    duration_days smallint     NOT NULL CHECK (duration_days > 0),
    qty_prescribed integer     NOT NULL CHECK (qty_prescribed > 0),
    qty_dispensed integer      NOT NULL DEFAULT 0,
    PRIMARY KEY (rx_id, line_no),
    CHECK (qty_dispensed BETWEEN 0 AND qty_prescribed)
);

-- ---------------------------------------------------------------------
-- Laboratory
-- ---------------------------------------------------------------------
CREATE TABLE lab_test (
    test_code     varchar(10)  PRIMARY KEY,
    name          varchar(80)  NOT NULL,
    specimen      varchar(20)  NOT NULL,
    unit          varchar(20),
    ref_low       numeric(10,2),
    ref_high      numeric(10,2),
    price         numeric(10,2) NOT NULL CHECK (price >= 0),
    CHECK (ref_low IS NULL OR ref_high IS NULL OR ref_low <= ref_high)
);

CREATE TABLE lab_order (
    order_id      bigint       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    encounter_id  bigint       NOT NULL REFERENCES encounter ON DELETE CASCADE,
    ordered_at    timestamptz  NOT NULL,
    priority      varchar(7)   NOT NULL DEFAULT 'ROUTINE' CHECK (priority IN ('ROUTINE','URGENT','STAT')),
    status        varchar(10)  NOT NULL DEFAULT 'ORDERED'
                  CHECK (status IN ('ORDERED','COLLECTED','RESULTED','CANCELLED'))
);

CREATE TABLE lab_result (
    order_id      bigint       NOT NULL REFERENCES lab_order ON DELETE CASCADE,
    test_code     varchar(10)  NOT NULL REFERENCES lab_test,
    value_num     numeric(10,2),
    value_text    varchar(100),
    abnormal_flag char(1)      CHECK (abnormal_flag IN ('L','H','N','A')),  -- A = abnormal qualitative result
    verified_by   integer      REFERENCES staff,
    resulted_at   timestamptz,
    PRIMARY KEY (order_id, test_code)
);

-- ---------------------------------------------------------------------
-- Wards, beds and admissions
-- ---------------------------------------------------------------------
CREATE TABLE ward (
    ward_id       smallint     PRIMARY KEY,
    branch_id     smallint     NOT NULL REFERENCES branch,
    name          varchar(40)  NOT NULL,
    ward_type     varchar(12)  NOT NULL CHECK (ward_type IN ('GENERAL','MATERNITY','PAEDIATRIC','ICU','SURGICAL')),
    daily_rate    numeric(10,2) NOT NULL CHECK (daily_rate >= 0),
    UNIQUE (branch_id, name)
);

CREATE TABLE bed (
    bed_id        integer      PRIMARY KEY,
    ward_id       smallint     NOT NULL REFERENCES ward,
    label         varchar(10)  NOT NULL,
    is_occupied   boolean      NOT NULL DEFAULT false,
    UNIQUE (ward_id, label)
);

CREATE TABLE admission (
    admission_id  bigint       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    patient_id    integer      NOT NULL REFERENCES patient,
    bed_id        integer      NOT NULL REFERENCES bed,
    encounter_id  bigint       REFERENCES encounter,
    admitted_at   timestamptz  NOT NULL,
    discharged_at timestamptz,
    CHECK (discharged_at IS NULL OR discharged_at > admitted_at),
    -- Two stays in the same bed may never overlap in time (open stay = until 'infinity').
    CONSTRAINT no_bed_overlap EXCLUDE USING gist (
        bed_id WITH =,
        tstzrange(admitted_at, COALESCE(discharged_at, 'infinity')) WITH &&
    )
);
-- A patient can only have one current (not yet discharged) admission.
CREATE UNIQUE INDEX one_current_admission_per_patient ON admission (patient_id) WHERE discharged_at IS NULL;

-- ---------------------------------------------------------------------
-- Billing
-- ---------------------------------------------------------------------
CREATE TABLE invoice (
    invoice_id    bigint       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    patient_id    integer      NOT NULL REFERENCES patient,
    encounter_id  bigint       REFERENCES encounter,
    branch_id     smallint     NOT NULL REFERENCES branch,
    issued_at     timestamptz  NOT NULL,
    status        varchar(10)  NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','PAID','PARTIAL','VOID'))
);

CREATE TABLE invoice_line (
    invoice_id    bigint       NOT NULL REFERENCES invoice ON DELETE CASCADE,
    line_no       smallint     NOT NULL,
    item_type     varchar(12)  NOT NULL CHECK (item_type IN ('CONSULT','LAB','DRUG','BED','PROCEDURE')),
    description   varchar(120) NOT NULL,
    qty           integer      NOT NULL CHECK (qty > 0),
    unit_price    numeric(10,2) NOT NULL CHECK (unit_price >= 0),
    PRIMARY KEY (invoice_id, line_no)
);

CREATE TABLE payment (
    payment_id    bigint       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    invoice_id    bigint       NOT NULL REFERENCES invoice,
    amount        numeric(12,2) NOT NULL CHECK (amount > 0),
    method        varchar(10)  NOT NULL CHECK (method IN ('CASH','CARD','TRANSFER','HMO')),
    reference     varchar(40)  NOT NULL UNIQUE,   -- idempotency key from POS / bank / HMO
    paid_at       timestamptz  NOT NULL
);

-- Invoice totals are DERIVED, not stored (avoids a transitive dependency
-- and update anomalies). Reports read them from this view.
CREATE VIEW invoice_summary AS
SELECT i.invoice_id, i.patient_id, i.branch_id, i.issued_at, i.status,
       COALESCE(l.total, 0)                        AS total_amount,
       COALESCE(p.paid, 0)                         AS amount_paid,
       COALESCE(l.total, 0) - COALESCE(p.paid, 0)  AS balance
FROM invoice i
LEFT JOIN (SELECT invoice_id, SUM(qty * unit_price) AS total FROM invoice_line GROUP BY invoice_id) l USING (invoice_id)
LEFT JOIN (SELECT invoice_id, SUM(amount) AS paid FROM payment GROUP BY invoice_id) p USING (invoice_id);

-- ---------------------------------------------------------------------
-- Audit trail for clinical record changes (NDPA 2023 accountability)
-- ---------------------------------------------------------------------
CREATE TABLE audit_log (
    audit_id      bigint       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    table_name    text         NOT NULL,
    operation     char(1)      NOT NULL CHECK (operation IN ('I','U','D')),
    row_pk        text         NOT NULL,
    changed_by    text         NOT NULL DEFAULT current_user,
    changed_at    timestamptz  NOT NULL DEFAULT now(),
    old_row       jsonb,
    new_row       jsonb
);

CREATE FUNCTION audit_clinical_change() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO audit_log (table_name, operation, row_pk, old_row, new_row)
    VALUES (TG_TABLE_NAME,
            left(TG_OP, 1),
            COALESCE(to_jsonb(NEW) ->> TG_ARGV[0], to_jsonb(OLD) ->> TG_ARGV[0]),
            CASE WHEN TG_OP <> 'INSERT' THEN to_jsonb(OLD) END,
            CASE WHEN TG_OP <> 'DELETE' THEN to_jsonb(NEW) END);
    RETURN NULL;
END $$;

-- Attached after bulk loading (see 03_generate_data.sql) so the seed
-- data does not flood the audit table.
