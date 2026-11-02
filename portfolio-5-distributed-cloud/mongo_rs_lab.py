"""
Portfolio 5 - MongoDB replica set availability lab (run after scripts/03_setup_mongo_rs.sh).

  M1 write-concern cost: w:1 vs w:"majority"
  M2 automatic failover while the records desk keeps writing (retryable writes)
  M3 loss of majority: reads still served by a secondary, writes refused (CP for writes)
  M4 recovery: members rejoin, the priority-2 Enugu node takes back the primary role

Writes evidence/mongo_replica_set.txt
"""
import os
import signal
import statistics
import subprocess
import threading
import time
from pathlib import Path

from pymongo import MongoClient, ReadPreference, WriteConcern
from pymongo.errors import PyMongoError

HERE = Path(__file__).resolve().parent
LAB = Path(os.environ.get("LAB", HERE.parent / ".lab"))
URI = "mongodb://localhost:27018,localhost:27019,localhost:27020/?replicaSet=rs_udoka"
lines, T0 = [], time.perf_counter()


def log(msg):
    line = f"[{time.perf_counter() - T0:7.2f} s] {msg}"
    print(line)
    lines.append(line)


def members(client):
    st = client.admin.command("replSetGetStatus")
    return ", ".join(f"{m['name'].split(':')[1]}={m['stateStr']}" for m in st["members"])


def start_member(port):
    subprocess.Popen(["mongod", "--replSet", "rs_udoka", "--port", str(port), "--bind_ip", "localhost",
                      "--dbpath", str(LAB / f"mongo{port}"), "--logpath", str(LAB / f"mongo{port}.log"),
                      "--logappend", "--wiredTigerCacheSizeGB", "0.25"],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def crash_member(port):
    """kill -9: a real crash. (A 'shutdown' command is NOT a crash: a primary first hands over to a
    secondary via replSetStepUp, which hides the election delay - found in the first run.)"""
    pid = MongoClient(f"mongodb://localhost:{port}/?directConnection=true").admin.command("serverStatus")["pid"]
    os.kill(int(pid), signal.SIGKILL)


def main():
    client = MongoClient(URI, serverSelectionTimeoutMS=4000)
    db = client.udoka_ehr
    db.patients.drop()
    src = MongoClient().udoka_ehr.patients.find({}, {"summary": 0}).limit(5000)
    db.patients.insert_many(list(src))
    log(f"replica set: {members(client)}; seeded {db.patients.count_documents({})} patients")

    # -----------------------------------------------------------------
    log("=== M1 Cost of write concern (500 single-document inserts each) ===")
    for wc in (WriteConcern(w=1), WriteConcern(w="majority", j=True)):
        coll = db.get_collection("wc_test", write_concern=wc)
        coll.drop()
        ts = []
        for i in range(500):
            t = time.perf_counter()
            coll.insert_one({"i": i})
            ts.append((time.perf_counter() - t) * 1000)
        log(f"w={wc.document.get('w')!s:<9} j={wc.document.get('j', False)!s:<5} median {statistics.median(ts):.3f} ms, "
            f"p95 {sorted(ts)[int(len(ts) * .95)]:.3f} ms")
    log("w:1 is acknowledged by the primary alone and can be ROLLED BACK if that primary dies;")
    log("w:'majority' survives any single-node failure.")

    # -----------------------------------------------------------------
    log("=== M2 Failover while the records desk keeps registering visits ===")
    events = db.get_collection("visit_events", write_concern=WriteConcern(w="majority"))
    events.drop()
    stop_flag, ok, failed, first_fail, last_ok = threading.Event(), [0], [0], [None], [time.perf_counter()]
    stall = [0.0]

    def writer():
        n = 0
        while not stop_flag.is_set():
            n += 1
            try:
                events.insert_one({"seq": n, "at": time.time()})       # retryWrites=true by default
                ok[0] += 1
                now = time.perf_counter()
                stall[0] = max(stall[0], now - last_ok[0])
                last_ok[0] = now
            except PyMongoError as e:
                failed[0] += 1
                first_fail[0] = first_fail[0] or (time.perf_counter() - T0, type(e).__name__)
            time.sleep(0.02)

    th = threading.Thread(target=writer)
    th.start()
    time.sleep(2)
    log(f"before failure: {ok[0]} inserts OK; primary = {client.primary}")
    t_kill = time.perf_counter()
    log("Enugu primary (27018) crashes (kill -9)")
    crash_member(27018)
    new_primary = None
    while new_primary is None and time.perf_counter() - t_kill < 60:
        for port in (27019, 27020):
            try:
                h = MongoClient(f"mongodb://localhost:{port}/?directConnection=true",
                                serverSelectionTimeoutMS=500).admin.command("hello")
                if h.get("isWritablePrimary"):
                    new_primary = port
            except PyMongoError:
                pass
        time.sleep(0.1)
    log(f"new primary elected: localhost:{new_primary} after {time.perf_counter() - t_kill:.2f} s")
    time.sleep(3)
    stop_flag.set()
    th.join()
    log(f"writer: {ok[0]} inserts OK, {failed[0]} raised an error to the application, "
        f"longest write stall {stall[0]:.2f} s"
        + (f" (first: {first_fail[0][1]} at {first_fail[0][0]:.2f} s)" if first_fail[0] else ""))
    count = events.count_documents({})
    seqs = sorted(d["seq"] for d in events.find({}, {"seq": 1}))
    gaps = [s for s in range(1, seqs[-1] + 1) if s not in set(seqs)]
    log(f"documents stored: {count}; missing sequence numbers: {gaps if gaps else 'none'}")
    log(f"replica set now: {members(client)}")

    # -----------------------------------------------------------------
    log("=== M3 Second failure: only one of three members left (no majority) ===")
    other = 27020 if new_primary == 27019 else 27019
    crash_member(new_primary)
    time.sleep(3)
    survivor = MongoClient(f"mongodb://localhost:{other}/?directConnection=true")
    log(f"survivor localhost:{other} state = {survivor.admin.command('replSetGetStatus')['myState']} "
        f"(1=PRIMARY, 2=SECONDARY)")
    try:
        MongoClient(URI, serverSelectionTimeoutMS=3000).udoka_ehr.patients.insert_one({"_id": -1, "hospitalNo": "USH-9999999"})
        log("write accepted (unexpected)")
    except PyMongoError as e:
        log(f"write refused: {type(e).__name__} - no primary can be elected without a majority")
    rp = MongoClient(URI, serverSelectionTimeoutMS=3000, readPreference="secondaryPreferred")
    doc = rp.udoka_ehr.patients.find_one({"hospitalNo": "USH-0000002"}, {"name": 1, "genotype": 1})
    log(f"read with readPreference=secondaryPreferred still works: {doc}")
    log("-> reads stay available (possibly stale); writes are unavailable until a majority returns.")

    # -----------------------------------------------------------------
    log("=== M4 Recovery ===")
    for port in (27018, new_primary):
        start_member(port)
    t = time.perf_counter()
    while time.perf_counter() - t < 90:
        try:
            if MongoClient("mongodb://localhost:27018/?directConnection=true",
                           serverSelectionTimeoutMS=500).admin.command("hello").get("isWritablePrimary"):
                break
        except PyMongoError:
            pass
        time.sleep(0.5)
    log(f"all members back after {time.perf_counter() - t:.1f} s: {members(MongoClient(URI))}")
    log("Enugu (priority 2) caught up from the oplog and took back the primary role (priority takeover).")
    (HERE / "evidence" / "mongo_replica_set.txt").write_text("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
