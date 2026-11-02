"""
Portfolio 4 - Redis key-value patterns for Udoka Specialist Hospital.

  R1 appointment slot hold      SET key value NX EX 300 (temporary reservation)
  R2 cache-aside patient summary  Redis in front of MongoDB, with invalidation
  R3 emergency triage queue     sorted set scored by (priority, arrival time)
  R4 bed board                  atomic Lua check-and-decrement under 15 concurrent nurses
  R5 durability settings        what Redis does (and does not) promise

Usage: ../../.venv/bin/python redis/redis_demo.py   (writes ../evidence/redis_output.txt)
"""
import json
import statistics
import threading
import time
from pathlib import Path

import redis
from pymongo import MongoClient

r = redis.Redis(decode_responses=True)
mongo = MongoClient().udoka_ehr
OUT = Path(__file__).resolve().parent.parent / "evidence" / "redis_output.txt"
lines = []


def log(text=""):
    print(text)
    lines.append(str(text))


def cmd(*args):
    """Run a raw Redis command and log it the way redis-cli shows it."""
    res = r.execute_command(*args)
    log(f"redis> {' '.join(str(a) for a in args)}")
    log(f"  {res!r}")
    return res


for k in r.scan_iter("ush:*"):
    r.delete(k)

# ---------------------------------------------------------------------
log("=== R1 Appointment slot hold (patient portal) ===")
log("Two patients pick Dr 30's 10:00 slot on 11 Jan 2027 within seconds of each other.")
key = "ush:hold:dr30:2027-01-11T10:00"
cmd("SET", key, "USH-0000002", "NX", "EX", 300)
cmd("SET", key, "USH-0000003", "NX", "EX", 300)      # second patient is refused: key exists
cmd("TTL", key)
log("-- Patient 2 abandons checkout; the hold expires on its own (demo uses a 2 s hold):")
cmd("SET", "ush:hold:dr30:2027-01-11T10:15", "USH-0000002", "NX", "EX", 2)
time.sleep(2.2)
cmd("GET", "ush:hold:dr30:2027-01-11T10:15")
log("-- Only on payment confirmation is the booking written to PostgreSQL, whose exclusion")
log("   constraint remains the source of truth; Redis just stops two people paying for one slot.")

# ---------------------------------------------------------------------
log("\n=== R2 Cache-aside: patient summary card (shown on every screen the patient appears on) ===")
hno = "USH-0000002"
ckey = f"ush:patient:{hno}:card"


def card_from_mongo():
    p = mongo.patients.find_one({"hospitalNo": hno}, {"_id": 0, "hospitalNo": 1, "name": 1, "sex": 1, "dob": 1,
                                                     "genotype": 1, "bloodGroup": 1, "allergies": 1, "summary": 1})
    return json.dumps(p, default=str)


def get_card():
    v = r.get(ckey)
    if v is None:                      # miss -> load from MongoDB and populate with a TTL
        v = card_from_mongo()
        r.set(ckey, v, ex=600)
    return v


def bench(fn, n=300):
    ts = []
    for _ in range(n):
        t0 = time.perf_counter()
        fn()
        ts.append((time.perf_counter() - t0) * 1e6)
    return statistics.median(ts)


r.delete(ckey)
log(f"first read (miss) populates the cache: {json.loads(get_card())['name']}")
cmd("TTL", ckey)
mongo_us = bench(card_from_mongo)
redis_us = bench(lambda: r.get(ckey))
log(f"median latency over 300 reads: MongoDB {mongo_us:.0f} µs vs Redis {redis_us:.0f} µs "
    f"({mongo_us / redis_us:.1f}x faster)")
log("-- A new allergy is recorded -> the writer updates MongoDB and deletes the cached card:")
cmd("DEL", ckey)
cmd("EXISTS", ckey)

# ---------------------------------------------------------------------
log("\n=== R3 Emergency triage queue (Enugu A&E) ===")
log("score = priority * 1e10 + arrival_epoch  -> most urgent first, then first-come-first-served")
qkey = "ush:triage:ENU"
base = 1793600000                                         # arrival times (epoch seconds)
arrivals = [("USH-0012001", 3, base + 0, "Minor laceration"),
            ("USH-0012002", 2, base + 60, "Fever 40C, child"),
            ("USH-0012003", 1, base + 90, "Road traffic accident, unconscious"),
            ("USH-0012004", 3, base + 120, "Sprained ankle"),
            ("USH-0012005", 2, base + 150, "Chest pain")]
for hno_, prio, t, why in arrivals:
    r.hset(f"ush:triage:case:{hno_}", mapping={"priority": prio, "complaint": why})
    cmd("ZADD", qkey, prio * 10**10 + t, hno_)
cmd("ZRANGE", qkey, 0, -1, "WITHSCORES")
log("-- Doctors pull the next patient atomically (two doctors can never get the same one):")
for _ in range(3):
    nxt = cmd("ZPOPMIN", qkey)
    log(f"   -> {nxt[0]}: {r.hget('ush:triage:case:' + nxt[0], 'complaint')}")
cmd("ZCARD", qkey)

# ---------------------------------------------------------------------
log("\n=== R4 Bed board: 15 nurses try to claim the last 12 maternity beds at once ===")
bkey = "ush:beds:NSK:Maternity"
r.hset(bkey, mapping={"total": 12, "free": 12})
claim = r.register_script("""
local free = tonumber(redis.call('HGET', KEYS[1], 'free'))
if free > 0 then
  redis.call('HINCRBY', KEYS[1], 'free', -1)
  return 1
end
return 0
""")
results = []
threads = [threading.Thread(target=lambda: results.append(claim(keys=[bkey]))) for _ in range(15)]
for t in threads:
    t.start()
for t in threads:
    t.join()
log(f"claims granted: {results.count(1)}, refused: {results.count(0)}")
cmd("HGETALL", bkey)
log("-- The Lua script runs atomically on Redis' single command thread, so 'check then decrement'")
log("   cannot interleave; a plain GET followed by DECR from 15 clients could drive 'free' negative.")

# ---------------------------------------------------------------------
log("\n=== R5 Durability settings ===")
cmd("CONFIG", "GET", "appendonly")
cmd("CONFIG", "GET", "save")
log("-- Default: RDB snapshots only, so up to minutes of writes can be lost on a crash. Acceptable for")
log("   holds, caches and the bed board (all rebuildable from PostgreSQL); NOT acceptable for clinical")
log("   records, which is why Redis is never the system of record here.")

OUT.write_text("\n".join(lines) + "\n")
