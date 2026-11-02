"""
Portfolio 2 benchmark harness.

For every query Qn it:
  1. resets the database to the baseline (Portfolio 1 indexes only),
  2. runs Qn.before.sql: EXPLAIN (ANALYZE, BUFFERS) saved to evidence/plans,
     then 1 warm-up + 7 timed executions (median reported),
  3. applies sql/02_optimisations.sql and repeats with Qn.after.sql,
  4. measures write overhead (bulk insert of 20,000 appointments, rolled back)
     with and without the new indexes,
  5. writes evidence/benchmark_results.md and evidence/benchmark_results.csv.

Usage: ../.venv/bin/python run_benchmark.py
"""
import csv
import json
import platform
import re
import statistics
import time
from pathlib import Path

import psycopg

HERE = Path(__file__).parent
QUERIES = HERE / "queries"
PLANS = HERE / "evidence" / "plans"
DSN = "dbname=udoka_hms options='-c search_path=hms,public'"
RUNS = 7

TECHNIQUE = {
    "Q1": "B-tree indexes on FK columns used by correlated subqueries",
    "Q2": "Sargable range predicate + composite index (doctor_id, scheduled_at)",
    "Q3": "Materialized view (pre-aggregation)",
    "Q4": "Partial index on abnormal results + random_page_cost 1.1 (SSD)",
    "Q5": "pg_trgm GIN indexes for wildcard ILIKE",
    "Q6": "Query rewrite (filter before aggregate, LATERAL) + partial index",
    "Q7": "NOT IN -> NOT EXISTS (anti-join) + index",
    "Q8": "work_mem tuning (hash join / aggregate in memory)",
}


def speedup(b, a):
    x = b["median_ms"] / a["median_ms"]
    return f"{x:.1f}×" if x < 10 else f"{x:.0f}×"


def run_script(conn, path):
    conn.execute(Path(path).read_text())


def settings_for(sql):
    return re.findall(r"^--\s*@set\s+(\w+)=(\S+)", sql, flags=re.M)


def strip_comments(sql):
    return "\n".join(l for l in sql.splitlines() if not l.strip().startswith("--")).strip().rstrip(";")


def plan_summary(node, acc=None):
    """Collect the distinct node types in a JSON plan (e.g. 'Seq Scan on encounter')."""
    acc = acc if acc is not None else []
    label = node["Node Type"]
    if "Relation Name" in node:
        label += f" on {node['Relation Name']}"
    if "Index Name" in node:
        label += f" using {node['Index Name']}"
    acc.append(label)
    for child in node.get("Plans", []):
        plan_summary(child, acc)
    return acc


def measure(conn, qid, phase, sql_file):
    raw = sql_file.read_text()
    sql = strip_comments(raw)
    with conn.transaction():
        for name, value in settings_for(raw):
            conn.execute(f"SET LOCAL {name} = '{value}'")
        text_plan = "\n".join(r[0] for r in conn.execute(f"EXPLAIN (ANALYZE, BUFFERS, SETTINGS) {sql}"))
        json_plan = conn.execute(f"EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) {sql}").fetchone()[0][0]
        conn.execute(sql).fetchall()                       # warm-up
        times = []
        for _ in range(RUNS):
            t0 = time.perf_counter()
            rows = conn.execute(sql).fetchall()
            times.append((time.perf_counter() - t0) * 1000)
    (PLANS / f"{qid}_{phase}.txt").write_text(f"-- {sql_file.name}\n{raw}\n\n{text_plan}\n")
    top = json_plan["Plan"]
    return {
        "median_ms": statistics.median(times),
        "rows": len(rows),
        "shared_hit": top.get("Shared Hit Blocks", 0),
        "shared_read": top.get("Shared Read Blocks", 0),
        "temp_written": top.get("Temp Written Blocks", 0),
        "planning_ms": json_plan["Planning Time"],
        "nodes": plan_summary(top),
    }


def write_cost(conn):
    """Time to insert 20,000 future appointments (rolled back) - shows index maintenance cost."""
    sql = """
        INSERT INTO appointment (patient_id, doctor_id, branch_id, scheduled_at, ends_at, status)
        SELECT 1 + g % 50000, d.staff_id, 1,
               TIMESTAMPTZ '2030-01-01 08:00+01' + make_interval(mins => 15 * g),
               TIMESTAMPTZ '2030-01-01 08:15+01' + make_interval(mins => 15 * g), 'BOOKED'
        FROM generate_series(1, 20000) g CROSS JOIN (SELECT min(staff_id) AS staff_id FROM doctor) d"""
    times = []
    for _ in range(3):
        with conn.transaction():
            t0 = time.perf_counter()
            conn.execute(sql)
            times.append((time.perf_counter() - t0) * 1000)
            raise psycopg.Rollback()        # leave the data unchanged
    return statistics.median(times)


def index_sizes(conn):
    return conn.execute("""
        SELECT c.relname, pg_size_pretty(pg_relation_size(c.oid)), pg_relation_size(c.oid)
        FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'hms' AND (c.relname LIKE 'ix\\_%' OR c.relname LIKE 'mv\\_%' OR c.relname LIKE 'ux\\_mv%')
        ORDER BY 3 DESC""").fetchall()


def main():
    PLANS.mkdir(parents=True, exist_ok=True)
    qids = sorted({p.name.split("_")[0] for p in QUERIES.glob("Q*.sql")})
    results = {}
    with psycopg.connect(DSN, autocommit=True) as conn:
        server = conn.execute("SELECT version()").fetchone()[0]
        run_script(conn, HERE / "sql" / "01_reset_baseline.sql")
        before = {q: measure(conn, q, "before", next(QUERIES.glob(f"{q}_*.before.sql"))) for q in qids}
        wc_before = write_cost(conn)
        run_script(conn, HERE / "sql" / "02_optimisations.sql")
        after = {q: measure(conn, q, "after", next(QUERIES.glob(f"{q}_*.after.sql"))) for q in qids}
        wc_after = write_cost(conn)
        sizes = index_sizes(conn)

    for q in qids:
        b, a = before[q], after[q]
        results[q] = (b, a)
        print(f"{q}: {b['median_ms']:9.2f} ms -> {a['median_ms']:8.2f} ms  "
              f"(x{b['median_ms'] / a['median_ms']:.0f})  rows {b['rows']}/{a['rows']}")
    print(f"write cost (20k appointment inserts): {wc_before:.0f} ms -> {wc_after:.0f} ms")

    with open(HERE / "evidence" / "benchmark_results.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["query", "technique", "before_ms", "after_ms", "speedup", "rows_before", "rows_after",
                    "buffers_before", "buffers_after", "temp_blocks_before", "temp_blocks_after"])
        for q, (b, a) in results.items():
            w.writerow([q, TECHNIQUE[q], f"{b['median_ms']:.2f}", f"{a['median_ms']:.2f}",
                        f"{b['median_ms'] / a['median_ms']:.1f}", b["rows"], a["rows"],
                        b["shared_hit"] + b["shared_read"], a["shared_hit"] + a["shared_read"],
                        b["temp_written"], a["temp_written"]])

    md = [f"# Benchmark results\n",
          f"- Server: `{server.split(',')[0]}` on {platform.machine()} macOS, default config "
          f"(shared_buffers 128MB, work_mem 4MB)",
          f"- Median of {RUNS} warm runs after 1 warm-up, client-side wall time incl. fetching rows\n",
          "| Query | Technique | Before (ms) | After (ms) | Speed-up | Buffers before → after | Rows |",
          "|---|---|---:|---:|---:|---|---:|"]
    for q, (b, a) in results.items():
        md.append(f"| {q} | {TECHNIQUE[q]} | {b['median_ms']:.2f} | {a['median_ms']:.2f} | "
                  f"{speedup(b, a)} | {b['shared_hit'] + b['shared_read']:,} → "
                  f"{a['shared_hit'] + a['shared_read']:,} | {a['rows']} |")
    md.append("\n## Plan shape (node types)\n")
    for q, (b, a) in results.items():
        md.append(f"**{q}** before: " + " → ".join(dict.fromkeys(b["nodes"])) + "  ")
        md.append(f"**{q}** after: " + " → ".join(dict.fromkeys(a["nodes"])) + "\n")
    md.append(f"\n## Cost of the optimisations\n")
    md.append(f"- Bulk insert of 20,000 appointments: **{wc_before:.0f} ms** before vs "
              f"**{wc_after:.0f} ms** after (extra index maintenance)")
    md.append("- Storage of new objects:\n")
    md.append("| Object | Size |\n|---|---:|")
    md += [f"| {n} | {s} |" for n, s, _ in sizes]
    (HERE / "evidence" / "benchmark_results.md").write_text("\n".join(md) + "\n")
    (HERE / "evidence" / "benchmark_results.json").write_text(json.dumps(
        {q: {"before": b, "after": a} for q, (b, a) in results.items()}, indent=1, default=str))


if __name__ == "__main__":
    main()
