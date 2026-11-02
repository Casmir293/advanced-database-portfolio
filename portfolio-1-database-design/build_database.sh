#!/usr/bin/env bash
# Rebuilds the udoka_hms database from scratch (schema + reference data + generated data).
# Usage: ./build_database.sh            (needs PostgreSQL 16 client tools on PATH)
set -euo pipefail
cd "$(dirname "$0")/sql"
DB=${DB:-udoka_hms}

createdb "$DB" 2>/dev/null || true
psql -X -q -d "$DB" -c "ALTER DATABASE $DB SET timezone = 'Africa/Lagos'"
for f in 01_schema.sql 02_reference_data.sql 03_generate_data.sql; do
  echo ">> running $f"
  psql -X -q -v ON_ERROR_STOP=1 -d "$DB" -f "$f"
done
psql -X -d "$DB" -f 05_row_counts.sql
