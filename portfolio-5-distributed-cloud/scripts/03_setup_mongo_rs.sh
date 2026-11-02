#!/usr/bin/env bash
# Three-member MongoDB replica set "rs_udoka" on ports 27018-27020:
#   27018 Enugu (priority 2, preferred primary)  27019 Nsukka (priority 1)  27020 Awka (priority 1)
set -euo pipefail
. "$(dirname "$0")/env.sh"
for p in $MONGO_PORTS; do
  mongosh --quiet --port "$p" --eval 'db.adminCommand({shutdown: 1, force: true})' >/dev/null 2>&1 || true
  rm -rf "${LAB:?}/mongo$p"; mkdir -p "$LAB/mongo$p"
  # --fork is not supported on macOS, so each member is started as a background process
  nohup mongod --replSet rs_udoka --port "$p" --bind_ip localhost --dbpath "$LAB/mongo$p" \
        --logpath "$LAB/mongo$p.log" --wiredTigerCacheSizeGB 0.25 >/dev/null 2>&1 &
done
for p in $MONGO_PORTS; do
  until mongosh --quiet --port "$p" --eval 'db.hello().ok' >/dev/null 2>&1; do sleep 0.5; done
done
mongosh --quiet --port 27018 --eval '
rs.initiate({_id: "rs_udoka", members: [
  {_id: 0, host: "localhost:27018", priority: 2, tags: {site: "ENU"}},
  {_id: 1, host: "localhost:27019", priority: 1, tags: {site: "NSK"}},
  {_id: 2, host: "localhost:27020", priority: 1, tags: {site: "AWK"}}]});
let tries = 0;
while (!db.hello().isWritablePrimary && tries++ < 60) sleep(500);
rs.status().members.forEach(m => print(m.name, m.stateStr));'
