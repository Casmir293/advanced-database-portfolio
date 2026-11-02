#!/usr/bin/env bash
# Stops every lab process and deletes the lab directory.
. "$(dirname "$0")/env.sh"
for d in primary replica_nsk replica_awk shard1 shard2; do
  [ -d "$LAB/$d" ] && pg_ctl -D "$LAB/$d" stop -m fast >/dev/null 2>&1
done
for p in $MONGO_PORTS; do mongosh --quiet --port "$p" --eval 'db.adminCommand({shutdown:1, force:true})' >/dev/null 2>&1; done
rm -rf "${LAB:?}"
echo "lab removed"
