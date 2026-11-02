-- =====================================================================
-- Portfolio 5 : horizontal sharding with postgres_fdw (coordinator = udoka_hms on :5432)
-- Run: psql -X -e -d udoka_hms -f sql/sharding_demo.sql > evidence/sharding_output.txt 2>&1
-- =====================================================================
SET search_path = dist, hms, public;
DELETE FROM dist.appointment WHERE reason IN ('Routed write', 'Transferred from ENU', 'Conflicting move');  -- re-runnable
ANALYZE dist.appointment;

\echo '=== D1 Data distribution: which shard holds what ==='
SELECT tableoid::regclass AS shard_partition, branch_id, count(*) AS appointments,
       round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct
FROM dist.appointment GROUP BY 1, 2 ORDER BY 1, 2;

\echo '=== D2 Query that includes the shard key -> partition pruning, only shard2 is contacted ==='
EXPLAIN (VERBOSE, COSTS OFF)
SELECT scheduled_at, patient_id, status FROM dist.appointment
WHERE branch_id = 2 AND scheduled_at >= '2026-11-03' AND scheduled_at < '2026-11-04';

\echo '=== D3 Query without the shard key (doctor schedule) -> scatter-gather to both shards ==='
EXPLAIN (VERBOSE, COSTS OFF)
SELECT scheduled_at, patient_id, status FROM dist.appointment
WHERE doctor_id = 78 AND scheduled_at >= '2026-11-03' AND scheduled_at < '2026-11-04';

\echo '=== D4 Distributed aggregate: partition-wise aggregation pushed down, shards scanned asynchronously ==='
SET enable_partitionwise_aggregate = on;
EXPLAIN (VERBOSE, COSTS OFF)
SELECT branch_id, status, count(*) FROM dist.appointment
WHERE scheduled_at >= '2025-01-01' AND scheduled_at < '2026-01-01'
GROUP BY branch_id, status;
SELECT branch_id, status, count(*) FROM dist.appointment
WHERE scheduled_at >= '2025-01-01' AND scheduled_at < '2026-01-01'
GROUP BY branch_id, status ORDER BY 1, 2;

\echo '=== D5 Same aggregate: local table vs sharded (both on one laptop, so this measures FDW overhead, not scale-out) ==='
\timing on
SELECT count(*) FROM hms.appointment  WHERE scheduled_at >= '2025-01-01' AND scheduled_at < '2026-01-01';
SELECT count(*) FROM dist.appointment WHERE scheduled_at >= '2025-01-01' AND scheduled_at < '2026-01-01';
\timing off

\echo '=== D6 Writes are routed by shard key; ids come from the coordinator sequence ==='
INSERT INTO dist.appointment
VALUES (nextval('dist.appt_id_seq'), 2, 78, 3, '2027-03-01 09:00+01', '2027-03-01 09:15+01', 'BOOKED', 'Routed write', now()),
       (nextval('dist.appt_id_seq'), 2, 30, 1, '2027-03-01 09:00+01', '2027-03-01 09:15+01', 'BOOKED', 'Routed write', now());
SELECT tableoid::regclass AS landed_on, appt_id, doctor_id, branch_id FROM dist.appointment WHERE reason = 'Routed write';

\echo '=== D7 Shard-local constraint still works (doctor 78 double-booked on shard2) ==='
INSERT INTO dist.appointment
VALUES (nextval('dist.appt_id_seq'), 3, 78, 3, '2027-03-01 09:05+01', '2027-03-01 09:20+01', 'BOOKED', 'Routed write', now());

\echo '=== D8 A row whose shard key does not match any partition is rejected ==='
INSERT INTO dist.appointment
VALUES (nextval('dist.appt_id_seq'), 3, 30, 4, '2027-03-02 09:00+01', '2027-03-02 09:15+01', 'BOOKED', 'Routed write', now());

\echo '=== D9 Two-phase commit across shards: patient transfers an appointment from Enugu to Awka ==='
-- Atomic commit across two independent servers. Each shard first PREPAREs (votes yes and makes
-- the change durable but invisible); only when both have prepared does the coordinator COMMIT.
\connect "host=localhost port=5436 user=postgres dbname=udoka_shard"
BEGIN;
DELETE FROM hms.appointment WHERE reason = 'Routed write' AND branch_id = 1 RETURNING appt_id, branch_id;
PREPARE TRANSACTION 'move_appt_1';
\connect "host=localhost port=5437 user=postgres dbname=udoka_shard"
BEGIN;
INSERT INTO hms.appointment VALUES (5900001, 2, 70, 3, '2027-03-01 11:00+01', '2027-03-01 11:15+01', 'BOOKED', 'Transferred from ENU', now());
PREPARE TRANSACTION 'move_appt_1';
SELECT gid, prepared, database FROM pg_prepared_xacts;
\echo '--- phase 1 complete on both shards (neither change is visible yet) -> phase 2: COMMIT PREPARED'
COMMIT PREPARED 'move_appt_1';
\connect "host=localhost port=5436 user=postgres dbname=udoka_shard"
COMMIT PREPARED 'move_appt_1';
\connect "host=localhost port=5432 dbname=udoka_hms"
SET search_path = dist, hms, public;
SELECT tableoid::regclass AS shard, appt_id, branch_id, reason FROM dist.appointment
WHERE reason IN ('Routed write', 'Transferred from ENU') ORDER BY appt_id;

\echo '=== D10 2PC abort path: shard2 cannot prepare (double booking) -> shard1 rolls back its prepared delete ==='
\connect "host=localhost port=5436 user=postgres dbname=udoka_shard"
BEGIN;
DELETE FROM hms.appointment WHERE appt_id = (SELECT min(appt_id) FROM hms.appointment WHERE status = 'BOOKED')
RETURNING appt_id, doctor_id, scheduled_at;
PREPARE TRANSACTION 'move_appt_2';
\connect "host=localhost port=5437 user=postgres dbname=udoka_shard"
BEGIN;
INSERT INTO hms.appointment VALUES (5900002, 2, 78, 3, '2027-03-01 09:00+01', '2027-03-01 09:15+01', 'BOOKED', 'Conflicting move', now());
ROLLBACK;
\echo '--- shard2 voted NO -> coordinator aborts the prepared transaction on shard1'
\connect "host=localhost port=5436 user=postgres dbname=udoka_shard"
ROLLBACK PREPARED 'move_appt_2';
SELECT count(*) AS prepared_left FROM pg_prepared_xacts;

\echo '=== cleanup of demo rows ==='
\connect "host=localhost port=5432 dbname=udoka_hms"
DELETE FROM dist.appointment WHERE reason IN ('Routed write', 'Transferred from ENU');
