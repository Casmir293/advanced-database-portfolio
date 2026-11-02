# Shared settings for the Portfolio 5 lab. Source this file: . scripts/env.sh
export PATH=/opt/homebrew/opt/postgresql@16/bin:$PATH
export LAB="${LAB:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)/.lab}"   # repo/.lab, git-ignored
export PG_PRIMARY=5433      # Enugu data centre (primary)
export PG_NSK=5434          # Nsukka DR site   - synchronous standby
export PG_AWK=5435          # Awka clinic      - asynchronous read replica
export PG_SHARD1=5436       # shard: Enugu appointments
export PG_SHARD2=5437       # shard: Nsukka + Awka appointments
export MONGO_PORTS="27018 27019 27020"
