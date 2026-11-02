#!/usr/bin/env bash
# Builds a 3-node PostgreSQL streaming-replication cluster on one machine:
#   primary (5433) --sync--> replica_nsk (5434)
#                  --async-> replica_awk (5435)
set -euo pipefail
. "$(dirname "$0")/env.sh"
mkdir -p "$LAB"
for d in primary replica_nsk replica_awk; do
  pg_ctl -D "$LAB/$d" stop -m fast >/dev/null 2>&1 || true
  rm -rf "${LAB:?}/$d"
done

echo ">> initdb primary"
initdb -D "$LAB/primary" -U postgres --auth=trust -E UTF8 --locale=C >/dev/null
cat >> "$LAB/primary/postgresql.conf" <<CONF
port = $PG_PRIMARY
listen_addresses = 'localhost'
wal_level = replica
max_wal_senders = 10
max_replication_slots = 10
wal_keep_size = 512MB
max_wal_size = 2GB
hot_standby = on
synchronous_commit = on
# synchronous_standby_names is switched on only after the standbys exist (see end of script):
# set here, every commit of the initial load would wait forever for a standby that is not there yet.
timezone = 'Africa/Lagos'
logging_collector = on
log_filename = 'primary.log'
CONF
echo "host replication all 127.0.0.1/32 trust" >> "$LAB/primary/pg_hba.conf"
pg_ctl -D "$LAB/primary" -l "$LAB/primary.log" start >/dev/null
psql -X -q -h localhost -p $PG_PRIMARY -U postgres -c "SELECT pg_create_physical_replication_slot('slot_nsk'), pg_create_physical_replication_slot('slot_awk')" >/dev/null

echo ">> loading the hospital database onto the primary (Portfolio 1 build script)"
PGHOST=localhost PGPORT=$PG_PRIMARY PGUSER=postgres DB=udoka_hms \
  "$(dirname "$0")/../../portfolio-1-database-design/build_database.sh" >/dev/null

for pair in "nsk:$PG_NSK" "awk:$PG_AWK"; do
  r=${pair%%:*}; port=${pair##*:}
  echo ">> pg_basebackup -> replica_$r (port $port)"
  pg_basebackup -h localhost -p $PG_PRIMARY -U postgres -D "$LAB/replica_$r" -X stream -S "slot_$r" -R --checkpoint=fast
  # pg_basebackup -R writes primary_conninfo into postgresql.auto.conf, which is read last and
  # would override postgresql.conf - so these settings go into the auto.conf file.
  cat >> "$LAB/replica_$r/postgresql.auto.conf" <<CONF
port = $port
primary_conninfo = 'host=localhost port=$PG_PRIMARY user=postgres application_name=replica_$r'
primary_slot_name = 'slot_$r'
log_filename = 'replica_$r.log'
CONF
  pg_ctl -D "$LAB/replica_$r" -l "$LAB/replica_$r.log" start >/dev/null
done
sleep 2
echo ">> making replica_nsk synchronous"
psql -X -q -h localhost -p $PG_PRIMARY -U postgres -c "ALTER SYSTEM SET synchronous_standby_names = 'FIRST 1 (replica_nsk)'" -c "SELECT pg_reload_conf()" >/dev/null
sleep 1
psql -X -h localhost -p $PG_PRIMARY -U postgres -c \
  "SELECT application_name, state, sync_state, write_lag, replay_lag FROM pg_stat_replication ORDER BY 1"
