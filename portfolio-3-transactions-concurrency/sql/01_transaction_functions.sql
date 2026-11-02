-- =====================================================================
-- Portfolio 3 : business transactions as server-side functions
-- Each function runs inside the caller's transaction, so either all of
-- its changes commit or none do.
-- =====================================================================
SET search_path = hms, public;

-- ---------------------------------------------------------------------
-- Dispense every outstanding line of a prescription at a branch.
-- Stock rows are locked in drug_id order, so two pharmacists dispensing
-- overlapping prescriptions always lock in the same order (no deadlock).
-- If any drug is short, the CHECK (qty_on_hand >= 0) fails and the
-- whole dispense - every line - is rolled back.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION dispense_prescription(p_rx_id bigint, p_branch_id smallint)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
    r       record;
    n_lines integer := 0;
BEGIN
    FOR r IN
        SELECT pi.line_no, pi.drug_id, pi.qty_prescribed - pi.qty_dispensed AS qty
        FROM prescription_item pi
        WHERE pi.rx_id = p_rx_id AND pi.qty_dispensed < pi.qty_prescribed
        ORDER BY pi.drug_id
        FOR UPDATE
    LOOP
        UPDATE pharmacy_stock
           SET qty_on_hand = qty_on_hand - r.qty          -- atomic decrement, no read-modify-write
         WHERE branch_id = p_branch_id AND drug_id = r.drug_id;
        UPDATE prescription_item SET qty_dispensed = qty_prescribed
         WHERE rx_id = p_rx_id AND line_no = r.line_no;
        n_lines := n_lines + 1;
    END LOOP;
    UPDATE prescription SET status = 'DISPENSED' WHERE rx_id = p_rx_id;
    RETURN n_lines;
END $$;

-- ---------------------------------------------------------------------
-- Admit a patient to the first free bed in a ward.
-- FOR UPDATE SKIP LOCKED: a nurse admitting at the same moment does not
-- wait for (or collide with) the bed this transaction has claimed - she
-- simply gets the next free one.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION admit_patient(p_patient_id integer, p_ward_id smallint, p_encounter_id bigint DEFAULT NULL)
RETURNS TABLE (admission_id bigint, bed_id integer, bed_label varchar) LANGUAGE plpgsql AS $$
DECLARE
    v_bed bed%ROWTYPE;
BEGIN
    SELECT * INTO v_bed FROM bed b
    WHERE b.ward_id = p_ward_id AND NOT b.is_occupied
    ORDER BY b.bed_id
    LIMIT 1
    FOR UPDATE SKIP LOCKED;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No free bed in ward %', p_ward_id USING ERRCODE = 'P0001';
    END IF;

    INSERT INTO admission (patient_id, bed_id, encounter_id, admitted_at)
    VALUES (p_patient_id, v_bed.bed_id, p_encounter_id, now())
    RETURNING admission.admission_id INTO admission_id;

    UPDATE bed SET is_occupied = true WHERE bed.bed_id = v_bed.bed_id;
    bed_id := v_bed.bed_id;
    bed_label := v_bed.label;
    RETURN NEXT;
END $$;

CREATE OR REPLACE FUNCTION discharge_patient(p_admission_id bigint)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_bed integer;
BEGIN
    UPDATE admission SET discharged_at = now()
     WHERE admission_id = p_admission_id AND discharged_at IS NULL
    RETURNING bed_id INTO v_bed;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Admission % is not open', p_admission_id;
    END IF;
    UPDATE bed SET is_occupied = false WHERE bed_id = v_bed;
END $$;

-- ---------------------------------------------------------------------
-- Post a payment idempotently and keep invoice.status in step.
-- The invoice row is locked first so that two cashiers posting part-
-- payments on the same invoice are serialised and the status is right.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION post_payment(p_invoice_id bigint, p_amount numeric, p_method varchar, p_reference varchar)
RETURNS varchar LANGUAGE plpgsql AS $$
DECLARE
    v_total numeric;
    v_paid  numeric;
    v_status varchar;
BEGIN
    PERFORM 1 FROM invoice WHERE invoice_id = p_invoice_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Invoice % does not exist', p_invoice_id;
    END IF;

    INSERT INTO payment (invoice_id, amount, method, reference, paid_at)
    VALUES (p_invoice_id, p_amount, p_method, p_reference, now())
    ON CONFLICT (reference) DO NOTHING;            -- a retried request is a no-op

    SELECT COALESCE(SUM(qty * unit_price), 0) INTO v_total FROM invoice_line WHERE invoice_id = p_invoice_id;
    SELECT COALESCE(SUM(amount), 0)           INTO v_paid  FROM payment      WHERE invoice_id = p_invoice_id;
    v_status := CASE WHEN v_paid = 0 THEN 'OPEN' WHEN v_paid >= v_total THEN 'PAID' ELSE 'PARTIAL' END;
    UPDATE invoice SET status = v_status WHERE invoice_id = p_invoice_id;
    RETURN v_status;
END $$;

-- ---------------------------------------------------------------------
-- Move stock between branches. Both rows are locked in a fixed order
-- (branch_id ascending) before any update, which removes the deadlock
-- that a naive "debit source, then credit destination" can cause.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION transfer_stock(p_drug_id integer, p_from smallint, p_to smallint, p_qty integer)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    PERFORM 1 FROM pharmacy_stock
     WHERE drug_id = p_drug_id AND branch_id IN (p_from, p_to)
     ORDER BY branch_id
     FOR UPDATE;
    UPDATE pharmacy_stock SET qty_on_hand = qty_on_hand - p_qty WHERE drug_id = p_drug_id AND branch_id = p_from;
    UPDATE pharmacy_stock SET qty_on_hand = qty_on_hand + p_qty WHERE drug_id = p_drug_id AND branch_id = p_to;
END $$;
