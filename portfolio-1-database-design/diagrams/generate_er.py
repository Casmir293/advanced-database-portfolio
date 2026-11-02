"""
Generates the ER diagram (crow's foot notation) straight from the live
PostgreSQL catalog, so the picture always matches 01_schema.sql.

  .venv/bin/python portfolio-1-database-design/diagrams/generate_er.py
  -> er_diagram.dot, er_diagram.png, er_diagram.svg

Cardinality rules read from the catalog:
  parent end : exactly one (tee) if the FK columns are NOT NULL,
               zero-or-one (odot+tee) if nullable
  child end  : zero-or-one if the FK columns are also UNIQUE/PK (1:1),
               otherwise zero-or-many (crow + odot)
"""
import subprocess
from pathlib import Path

import psycopg

HERE = Path(__file__).parent
DSN = "dbname=udoka_hms"

# Visual grouping of tables into subject areas
GROUPS = {
    "Organisation & Staff": ["branch", "department", "staff", "doctor", "on_call_roster"],
    "Patient Registry": ["patient", "patient_allergy", "emergency_contact", "patient_coverage", "hmo"],
    "Clinical": ["appointment", "encounter", "diagnosis", "icd10_code"],
    "Pharmacy": ["drug", "pharmacy_stock", "prescription", "prescription_item"],
    "Laboratory": ["lab_test", "lab_order", "lab_result"],
    "Inpatient": ["ward", "bed", "admission"],
    "Billing": ["invoice", "invoice_line", "payment"],
}
COLOURS = {
    "Organisation & Staff": "#E8EEF7", "Patient Registry": "#E9F5EC", "Clinical": "#FDF1E4",
    "Pharmacy": "#F3E8F7", "Laboratory": "#E6F4F7", "Inpatient": "#F7F3E3", "Billing": "#F7E6E6",
}

COLS_SQL = """
SELECT c.table_name, c.column_name, c.data_type, c.is_nullable = 'YES', c.ordinal_position
FROM information_schema.columns c
JOIN information_schema.tables t USING (table_schema, table_name)
WHERE c.table_schema = 'hms' AND t.table_type = 'BASE TABLE'
ORDER BY c.table_name, c.ordinal_position"""

PK_SQL = """
SELECT tc.table_name, kcu.column_name
FROM information_schema.table_constraints tc
JOIN information_schema.key_column_usage kcu USING (constraint_schema, constraint_name)
WHERE tc.table_schema = 'hms' AND tc.constraint_type = 'PRIMARY KEY'"""

FK_SQL = """
SELECT con.conname, src.relname, tgt.relname,
       array(SELECT a.attname FROM unnest(con.conkey) k JOIN pg_attribute a
             ON a.attrelid = con.conrelid AND a.attnum = k ORDER BY a.attnum) AS cols,
       bool_and(a.attnotnull) AS not_null,
       EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = con.conrelid AND i.indisunique
               AND i.indpred IS NULL
               AND (SELECT array_agg(x ORDER BY x) FROM unnest(i.indkey::int2[]) x)
                 = (SELECT array_agg(x ORDER BY x) FROM unnest(con.conkey) x)) AS one_to_one
FROM pg_constraint con
JOIN pg_class src ON src.oid = con.conrelid
JOIN pg_class tgt ON tgt.oid = con.confrelid
JOIN pg_namespace n ON n.oid = src.relnamespace
JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = ANY (con.conkey)
WHERE con.contype = 'f' AND n.nspname = 'hms'
GROUP BY con.oid, con.conname, src.relname, tgt.relname, con.conkey, con.conrelid"""

SHORT_TYPES = {
    "character varying": "varchar", "timestamp with time zone": "timestamptz",
    "character": "char", "boolean": "bool", "numeric": "numeric", "integer": "int",
    "smallint": "smallint", "bigint": "bigint", "date": "date", "text": "text", "jsonb": "jsonb",
}


def main():
    with psycopg.connect(DSN) as conn:
        cols = conn.execute(COLS_SQL).fetchall()
        pks = {(t, c) for t, c in conn.execute(PK_SQL).fetchall()}
        fks = conn.execute(FK_SQL).fetchall()

    fk_cols = {(src, c) for _, src, _, cs, _, _ in fks for c in cs}
    tables = {}
    for t, c, dtype, nullable, _ in cols:
        tables.setdefault(t, []).append((c, SHORT_TYPES.get(dtype, dtype), nullable))

    lines = [
        "digraph ER {",
        '  graph [rankdir=LR, splines=polyline, nodesep=0.35, ranksep=0.9, fontname="Helvetica", '
        'label="Udoka Specialist Hospital - Entity Relationship Diagram (crow\'s foot)", labelloc=t, fontsize=20];',
        '  node  [shape=plain, fontname="Helvetica", fontsize=10];',
        '  edge  [dir=both, color="#555555", penwidth=1.1];',
    ]
    for gi, (group, members) in enumerate(GROUPS.items()):
        lines.append(f'  subgraph cluster_{gi} {{ label="{group}"; style="rounded,filled"; '
                     f'fillcolor="{COLOURS[group]}"; color="#999999"; fontsize=13;')
        for t in members:
            rows = [f'<tr><td bgcolor="#2F4B7C" colspan="3"><font color="white"><b>{t}</b></font></td></tr>']
            for c, dtype, nullable in tables[t]:
                key = (("PK" if (t, c) in pks else "") + (" FK" if (t, c) in fk_cols else "")).strip()
                key_cell = f'<font color="#B03A2E">{key}</font>' if key else " "
                name = f"<b>{c}</b>" if (t, c) in pks else (f"<i>{c}</i>" if nullable else c)
                rows.append(f'<tr><td align="left" port="{c}">{name}</td>'
                            f'<td align="left"><font color="#666666">{dtype}</font></td>'
                            f'<td align="left">{key_cell}</td></tr>')
            lines.append(f'    {t} [label=<<table border="0" cellborder="1" cellspacing="0" '
                         f'cellpadding="3" bgcolor="white">{"".join(rows)}</table>>];')
        lines.append("  }")

    for _, src, tgt, cs, not_null, one_to_one in sorted(fks, key=lambda r: (r[1], r[2])):
        parent_end = "tee" if not_null else "teeodot"
        child_end = "teeodot" if one_to_one else "crowodot"
        lines.append(f'  {src} -> {tgt} [arrowtail={child_end}, arrowhead={parent_end}];')
    lines.append("}")

    dot = HERE / "er_diagram.dot"
    dot.write_text("\n".join(lines))
    for fmt in ("png", "svg"):
        subprocess.run(["dot", f"-T{fmt}", "-Gdpi=110", str(dot), "-o", str(HERE / f"er_diagram.{fmt}")], check=True)
    print(f"{len(tables)} tables, {len(fks)} relationships -> {dot.with_suffix('.png')}")


if __name__ == "__main__":
    main()
