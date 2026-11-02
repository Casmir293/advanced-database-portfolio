"""
Renders terminal-style PNG "screenshots" of key evidence lines, taken verbatim from the
captured output files, for the LMS documentation.

Usage: .venv/bin/python docs/render_evidence.py   -> docs/screenshots/*.png
"""
import re
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "docs" / "screenshots"
FONT = ImageFont.truetype("/System/Library/Fonts/Menlo.ttc", 26)
BG, FG, DIM, ERR, OK, HEAD = "#1E1E1E", "#D4D4D4", "#808080", "#F48771", "#89D185", "#569CD6"


def pick(path, patterns, max_len=118):
    """Return lines of `path` matching any regex in `patterns`, in file order."""
    lines = (ROOT / path).read_text().splitlines()
    out = []
    for line in lines:
        if any(re.search(p, line) for p in patterns):
            out.append(line.rstrip()[:max_len])
    return out


def render(name, title, lines):
    pad, lh = 28, 34
    width = max(len(l) for l in lines + [title]) * 16 + 2 * pad
    height = (len(lines) + 2) * lh + 2 * pad
    img = Image.new("RGB", (width, height), BG)
    d = ImageDraw.Draw(img)
    for i, c in enumerate(("#FF5F56", "#FFBD2E", "#27C93F")):
        d.ellipse((pad + i * 30, pad - 6, pad + i * 30 + 18, pad + 12), fill=c)
    d.text((pad + 110, pad - 12), title, font=FONT, fill=DIM)
    y = pad + 2 * lh
    for l in lines:
        colour = ERR if ("ERROR" in l or "WARNING" in l or "LOST" in l or "broken" in l) else \
                 OK if ("452" in l or "RPO = 0" in l or "50/50" in l or "preserved" in l) else \
                 HEAD if l.lstrip().startswith(("[", "###")) and "--" in l else FG
        d.text((pad, y), l, font=FONT, fill=colour)
        y += lh
    OUT.mkdir(parents=True, exist_ok=True)
    img.save(OUT / f"{name}.png")
    print(OUT / f"{name}.png", img.size)


render("p3_lost_update_write_skew", "concurrency_lab.py  (Portfolio 3: S5 lost update, S6 write skew)",
       pick("portfolio-3-transactions-concurrency/evidence/transcripts/S5_lost_update.txt",
            [r"-- \(1\)", r"pharm_B +> UPDATE .* = 470", r"pharm_B +\| \d+ +\| active", r"LOST UPDATE",
             r"-- \(4\)", r"40001"]) +
       pick("portfolio-3-transactions-concurrency/evidence/transcripts/S6_write_skew.txt",
            [r"-- \(1\)", r"WRITE SKEW", r"-- \(2\)", r"40001", r"request denied"]))

render("p5_partition_failover", "replication_lab.py  (Portfolio 5: P2 consistency, P3 partition, P4 failover)",
       pick("portfolio-5-distributed-cloud/evidence/replication_P2_read_consistency.txt",
            [r"visible on replica_nsk"]) +
       pick("portfolio-5-distributed-cloud/evidence/replication_P3_partition.txt",
            [r"lab_primary +\| active", r"returned after", r"WARNING", r"committed in"]) +
       pick("portfolio-5-distributed-cloud/evidence/replication_P4_failover.txt",
            [r"crashes", r"False +\| 2", r"RTO", r"RPO = 0"]))

render("p2_q1_plans", "EXPLAIN (ANALYZE, BUFFERS)  (Portfolio 2: Q1 patient history before / after)",
       ["BEFORE"] +
       [l.strip()[:116] for l in pick("portfolio-2-query-optimisation/evidence/plans/Q1_before.txt",
            [r"Parallel Seq Scan on encounter", r"Seq Scan on (prescription|lab_order)", r"Rows Removed by Filter",
             r"^Execution Time"], 200)] +
       ["", "AFTER"] +
       [l.strip()[:116] for l in pick("portfolio-2-query-optimisation/evidence/plans/Q1_after.txt",
            [r"Index Scan using ix_", r"^Execution Time"], 200)])
