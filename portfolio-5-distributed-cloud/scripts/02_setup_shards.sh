#!/usr/bin/env bash
# Two shard servers + postgres_fdw coordinator (the main udoka_hms database on :5432).
#   shard1 (:5436) holds Enugu appointments        (branch_id = 1)
#   shard2 (:5437) holds Nsukka + Awka appointments (branch_id IN (2, 3))
set -euo pipefail
. "$(dirname "$0")/env.sh"
mkdir -p "$LAB"
for pair in "shard1:$PG_SHARD1" "shard2:$PG_SHARD2"; do
  s=${pair%%:*}; port=${pair##*:}
  pg_ctl -D "$LAB/$s" stop -m fast >/dev/null 2>&1 || true
  rm -rf "${LAB:?}/$s"
  initdb -D "$LAB/$s" -U postgres --auth=trust -E UTF8 --locale=C >/dev/null
  cat >> "$LAB/$s/postgresql.conf" <<CONF
port = $port
listen_addresses = 'localhost'
max_prepared_transactions = 10     # needed for two-phase commit
timezone = 'Africa/Lagos'
CONF
  pg_ctl -D "$LAB/$s" -l "$LAB/$s.log" start -w >/dev/null
  createdb -h localhost -p "$port" -U postgres udoka_shard
  # Shard-local table: same columns as hms.appointment. FKs to patient/doctor cannot cross servers,
  # but the double-booking exclusion constraint CAN stay local, because a doctor works at one branch
  # and all of a doctor's appointments therefore land on the same shard.
  psql -X -q -h localhost -p "$port" -U postgres -d udoka_shard <<SQL
CREATE EXTENSION btree_gist;
CREATE SCHEMA hms;
CREATE TABLE hms.appointment (
    appt_id      bigint       PRIMARY KEY,
    patient_id   integer      NOT NULL,
    doctor_id    integer      NOT NULL,
    branch_id    smallint     NOT NULL,
    scheduled_at timestamptz  NOT NULL,
    ends_at      timestamptz  NOT NULL,
    status       varchar(12)  NOT NULL,
    reason       varchar(200),
    created_at   timestamptz  NOT NULL,
    CONSTRAINT shard_branch CHECK (branch_id IN ($( [ "$s" = shard1 ] && echo 1 || echo "2, 3" ))),
    CONSTRAINT no_doctor_double_booking EXCLUDE USING gist (
        doctor_id WITH =, tstzrange(scheduled_at, ends_at) WITH &&) WHERE (status IN ('BOOKED','CHECKED_IN','COMPLETED'))
);
CREATE INDEX ON hms.appointment (doctor_id, scheduled_at);
SQL
done

echo ">> coordinator: postgres_fdw servers and partitioned table dist.appointment"
psql -X -q -d udoka_hms <<SQL
SET client_min_messages = warning;
DROP SCHEMA IF EXISTS dist CASCADE;
DROP SERVER IF EXISTS shard1 CASCADE;
DROP SERVER IF EXISTS shard2 CASCADE;
CREATE EXTENSION IF NOT EXISTS postgres_fdw;
CREATE SERVER shard1 FOREIGN DATA WRAPPER postgres_fdw
  OPTIONS (host 'localhost', port '$PG_SHARD1', dbname 'udoka_shard', async_capable 'true', batch_size '1000', fetch_size '5000');
CREATE SERVER shard2 FOREIGN DATA WRAPPER postgres_fdw
  OPTIONS (host 'localhost', port '$PG_SHARD2', dbname 'udoka_shard', async_capable 'true', batch_size '1000', fetch_size '5000');
CREATE USER MAPPING FOR CURRENT_USER SERVER shard1 OPTIONS (user 'postgres');
CREATE USER MAPPING FOR CURRENT_USER SERVER shard2 OPTIONS (user 'postgres');
CREATE SCHEMA dist;
CREATE TABLE dist.appointment (
    appt_id bigint NOT NULL, patient_id integer NOT NULL, doctor_id integer NOT NULL, branch_id smallint NOT NULL,
    scheduled_at timestamptz NOT NULL, ends_at timestamptz NOT NULL, status varchar(12) NOT NULL,
    reason varchar(200), created_at timestamptz NOT NULL
) PARTITION BY LIST (branch_id);
CREATE FOREIGN TABLE dist.appointment_enu  PARTITION OF dist.appointment FOR VALUES IN (1)
  SERVER shard1 OPTIONS (schema_name 'hms', table_name 'appointment');
CREATE FOREIGN TABLE dist.appointment_east PARTITION OF dist.appointment FOR VALUES IN (2, 3)
  SERVER shard2 OPTIONS (schema_name 'hms', table_name 'appointment');
-- Global id generator lives on the coordinator so ids stay unique across shards.
CREATE SEQUENCE dist.appt_id_seq START 5000000;
\timing on
INSERT INTO dist.appointment SELECT appt_id, patient_id, doctor_id, branch_id, scheduled_at, ends_at, status, reason, created_at
FROM hms.appointment;
\timing off
SQL
for pair in "shard1:$PG_SHARD1" "shard2:$PG_SHARD2"; do
  psql -X -h localhost -p "${pair##*:}" -U postgres -d udoka_shard -Atc "ANALYZE hms.appointment; SELECT '${pair%%:*}: ' || count(*) || ' rows, branches ' || string_agg(DISTINCT branch_id::text, ',') FROM hms.appointment"
done
