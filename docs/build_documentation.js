// Builds the 2-3 page LMS documentation (Word) from the portfolio evidence.
// Usage: NODE_PATH=<dir with docx installed>/node_modules node docs/build_documentation.js <output.docx>
const fs = require("fs");
const path = require("path");
const {
  Document,
  Packer,
  Paragraph,
  TextRun,
  ImageRun,
  Table,
  TableRow,
  TableCell,
  WidthType,
  ShadingType,
  AlignmentType,
  BorderStyle,
  LevelFormat,
  ExternalHyperlink,
  VerticalAlign,
  Footer,
  PageNumber,
} = require("docx");

const ROOT = path.resolve(__dirname, "..");
const OUT =
  process.argv[2] ||
  path.join(ROOT, "Onyeka_Casmir_301911351_Documentation.docx");
const GITHUB = "https://github.com/Casmir293/advanced-database-portfolio";

const FONT = "Calibri";
const BODY = 19; // 9.5 pt
const NAVY = "1F3864";
const CONTENT_W = 10466; // A4 width 11906 - 2 x 720 margins (DXA)

const img = (rel) => fs.readFileSync(path.join(ROOT, rel));
const run = (text, o = {}) =>
  new TextRun({ text, font: FONT, size: BODY, ...o });
const b = (text) => run(text, { bold: true });
const todo = (text) => run(text, { highlight: "yellow", bold: true });

function p(children, o = {}) {
  return new Paragraph({
    children: typeof children === "string" ? [run(children)] : children,
    spacing: { after: 60, line: 252 },
    ...o,
  });
}
function h(text) {
  return new Paragraph({
    children: [
      new TextRun({ text, font: FONT, size: 22, bold: true, color: NAVY }),
    ],
    spacing: { before: 120, after: 50 },
    keepNext: true,
    border: {
      bottom: { style: BorderStyle.SINGLE, size: 6, color: "8EA9DB", space: 1 },
    },
  });
}
function bullet(children) {
  return new Paragraph({
    children: typeof children === "string" ? [run(children)] : children,
    numbering: { reference: "bullets", level: 0 },
    spacing: { after: 30, line: 245 },
  });
}
function picture(rel, wPx, hPx, widthCm) {
  const w = Math.round(widthCm * 37.8);
  return new ImageRun({
    type: "png",
    data: img(rel),
    transformation: { width: w, height: Math.round((w * hPx) / wPx) },
  });
}
const border = { style: BorderStyle.SINGLE, size: 4, color: "BFBFBF" };
const borders = { top: border, bottom: border, left: border, right: border };

function cell(content, width, o = {}) {
  return new TableCell({
    width: { size: width, type: WidthType.DXA },
    borders,
    verticalAlign: VerticalAlign.CENTER,
    margins: { top: 30, bottom: 30, left: 70, right: 70 },
    shading: o.fill
      ? { fill: o.fill, type: ShadingType.CLEAR, color: "auto" }
      : undefined,
    children: [
      new Paragraph({
        alignment: o.align || AlignmentType.LEFT,
        spacing: { after: 0 },
        children: [
          run(content, { size: o.size || 17, bold: !!o.bold, color: o.color }),
        ],
      }),
    ],
  });
}
function table(widths, rows, header = true) {
  return new Table({
    width: { size: widths.reduce((a, c) => a + c, 0), type: WidthType.DXA },
    columnWidths: widths,
    rows: rows.map(
      (r, i) =>
        new TableRow({
          children: r.map((c, j) =>
            cell(String(c), widths[j], {
              bold: header && i === 0,
              fill: header && i === 0 ? "D9E2F3" : undefined,
              align:
                j >= 2 && widths.length === 5
                  ? AlignmentType.RIGHT
                  : AlignmentType.LEFT,
            }),
          ),
        }),
    ),
  });
}

// ---------------------------------------------------------------------------
const children = [];

children.push(
  new Paragraph({
    alignment: AlignmentType.CENTER,
    spacing: { after: 20 },
    children: [
      new TextRun({
        text: "MIT 8103 Advanced Database Systems: Practical Database Portfolio",
        font: FONT,
        size: 30,
        bold: true,
        color: NAVY,
      }),
    ],
  }),
);
children.push(
  new Paragraph({
    alignment: AlignmentType.CENTER,
    spacing: { after: 100 },
    children: [
      run(
        "Portfolio documentation and technical reflection · 2026/2027 First Semester Continuous Assessment",
        { size: 18, italics: true },
      ),
    ],
  }),
);

const W2 = [2000, CONTENT_W - 2000];
children.push(
  new Table({
    width: { size: CONTENT_W, type: WidthType.DXA },
    columnWidths: W2,
    rows: [
      [
        "Student",
        "Casmir Onyeka   ·   Student ID 301911351   ·   Master of Information Technology",
      ],
      [
        "Case study",
        "Udoka Specialist Hospital, Enugu (simulated organisation)",
      ],
      ["GitHub repository", null],
    ].map(
      ([k, v]) =>
        new TableRow({
          children: [
            cell(k, W2[0], { bold: true, fill: "D9E2F3" }),
            v !== null
              ? cell(v, W2[1])
              : new TableCell({
                  width: { size: W2[1], type: WidthType.DXA },
                  borders,
                  margins: { top: 30, bottom: 30, left: 70, right: 70 },
                  children: [
                    new Paragraph({
                      spacing: { after: 0 },
                      children: [
                        new ExternalHyperlink({
                          link: GITHUB,
                          children: [
                            run(GITHUB, {
                              size: 17,
                              style: "Hyperlink",
                              highlight: "yellow",
                            }),
                          ],
                        }),
                        run("  (private; assessor added as collaborator)", {
                          size: 17,
                        }),
                      ],
                    }),
                  ],
                }),
          ],
        }),
    ),
  }),
);

// 1. Case study ---------------------------------------------------------------
children.push(h("1. Selected organisation"));
children.push(
  p([
    run(
      "Udoka Specialist Hospital is a fictional private hospital group in South-East Nigeria. It has a 120-bed main hospital in ",
    ),
    b("Enugu"),
    run(
      " (outpatients, 24-hour emergency, five wards including an ICU) and outpatient clinics with small maternity wards in ",
    ),
    b("Nsukka"),
    run(" and "),
    b("Awka"),
    run(". The group is replacing paper folders with one shared database. "),
    b("Users: "),
    run(
      "records officers, doctors, nurses, laboratory scientists, pharmacists, billing officers and management. ",
    ),
    b("Data: "),
    run(
      "patients (allergies, emergency contacts, HMO cover), staff, appointments, encounters with ICD-10 diagnoses, prescriptions and stock, lab results, wards, beds and admissions, invoices and payments. ",
    ),
    b("Key operations: "),
    run(
      "register patients, book appointments without double-booking, record consultations, prescribe and dispense, verify lab results, admit and discharge, bill, and report.",
    ),
  ]),
);

// 2. Portfolio 1 --------------------------------------------------------------
children.push(
  h("2. Portfolio 1 – Database design and modelling (PostgreSQL 16)"),
);
const P1W = [6300, CONTENT_W - 6300];
children.push(
  new Table({
    width: { size: CONTENT_W, type: WidthType.DXA },
    columnWidths: P1W,
    rows: [
      new TableRow({
        children: [
          new TableCell({
            width: { size: P1W[0], type: WidthType.DXA },
            borders: {
              top: { style: BorderStyle.NONE },
              bottom: { style: BorderStyle.NONE },
              left: { style: BorderStyle.NONE },
              right: { style: BorderStyle.NONE },
            },
            margins: { right: 120 },
            children: [
              p(
                "The schema has 28 tables in seven subject areas (organisation, patient registry, clinical, pharmacy, laboratory, inpatient, billing), with 28 primary keys, 39 foreign keys, 12 unique, 35 CHECK and 2 exclusion constraints.",
              ),
              bullet([
                b("Keys: "),
                run(
                  "surrogate identity keys for high-volume tables, with the business identifier kept as an alternate key (hospital_no, MDCN folio, payment reference); composite keys for weak and associative entities; IS-A subtype doctor ⊂ staff.",
                ),
              ]),
              bullet([
                b("Rules enforced in the database: "),
                run(
                  "a GiST exclusion constraint stops a doctor being double-booked (cancelled slots free up automatically); a second one stops two overlapping stays in one bed; stock can never go negative; there is exactly one primary diagnosis per encounter; and a trigger writes before/after JSONB images of clinical changes to audit_log (NDPA 2023 accountability).",
                ),
              ]),
              bullet([
                b("Normalisation: "),
                run(
                  'the paper "Patient Visit Sheet" was taken from UNF to 1NF (repeating allergies, diagnoses, drugs and tests split out), 2NF (code → description moved to ICD10_CODE, DRUG, LAB_TEST) and 3NF/BCNF (doctor, branch and patient facts separated). Invoice totals are derived in a view, not stored. bed.is_occupied is a documented, deliberate redundancy.',
                ),
              ]),
              bullet([
                b("Evidence: "),
                run(
                  "a deterministic generator creates 4.8 M realistic rows (60 k patients, 414 k appointments, 357 k encounters). 14 negative tests show each constraint rejecting bad data. The ER diagram is generated from the live catalog.",
                ),
              ]),
            ],
          }),
          new TableCell({
            width: { size: P1W[1], type: WidthType.DXA },
            borders: {
              top: { style: BorderStyle.NONE },
              bottom: { style: BorderStyle.NONE },
              left: { style: BorderStyle.NONE },
              right: { style: BorderStyle.NONE },
            },
            verticalAlign: VerticalAlign.CENTER,
            children: [
              new Paragraph({
                alignment: AlignmentType.CENTER,
                spacing: { after: 0 },
                children: [
                  picture(
                    "portfolio-1-database-design/diagrams/er_diagram.png",
                    2497,
                    2767,
                    6.9,
                  ),
                ],
              }),
              new Paragraph({
                alignment: AlignmentType.CENTER,
                spacing: { after: 0 },
                children: [
                  run(
                    "Figure 1. ER diagram (crow's foot), generated from the catalog",
                    { size: 15, italics: true },
                  ),
                ],
              }),
            ],
          }),
        ],
      }),
    ],
  }),
);

// 3. Portfolio 2 --------------------------------------------------------------
children.push(h("3. Portfolio 2 – Query processing and optimisation"));
children.push(
  p(
    "Eight queries that real users run were measured with EXPLAIN (ANALYZE, BUFFERS) before and after optimisation (median of 7 warm runs; results checked to be identical with EXCEPT in both directions):",
  ),
);
const P2W = [3000, 4566, 1000, 950, 950];
children.push(
  table(P2W, [
    ["Query (user)", "Optimisation", "Before ms", "After ms", "Gain"],
    [
      "Q1 Patient history (doctor)",
      "Index FK columns used by correlated subqueries",
      "385.5",
      "0.55",
      "699×",
    ],
    [
      "Q2 Doctor's clinic list",
      "Sargable date range + composite index",
      "7.2",
      "0.16",
      "45×",
    ],
    [
      "Q3 Monthly revenue",
      "Materialized view, refreshed concurrently",
      "128.8",
      "0.39",
      "332×",
    ],
    [
      "Q4 Abnormal labs, 7 days",
      "Partial index + random_page_cost 1.1 (SSD)",
      "10.4",
      "2.9",
      "3.6×",
    ],
    [
      "Q5 Name search",
      "pg_trgm GIN indexes (BitmapAnd)",
      "10.0",
      "0.54",
      "19×",
    ],
    [
      "Q6 Unpaid balances",
      "Rewrite: filter before aggregate (LATERAL)",
      "342.1",
      "28.6",
      "12×",
    ],
    [
      "Q7 Hypertension recall",
      "NOT IN → NOT EXISTS anti-join",
      "56.0",
      "10.9",
      "5.1×",
    ],
    [
      "Q8 Disease surveillance",
      "work_mem 64 MB (no temp-file batches)",
      "87.7",
      "68.2",
      "1.3×",
    ],
  ]),
);
children.push(
  p(
    [
      run(
        "The biggest gains came from reading less data: Q1 fell from 179,425 to 917 buffers. The new indexes cost 64 MB and slowed a 20,000-row insert by 13%. Eight further experiments explain the planner's behaviour. ",
      ),
      b("NOT IN"),
      run(
        " returned 0 rows instead of 2,063 because of a NULL, and took 4,001 ms against 7.8 ms for NOT EXISTS. Extended statistics corrected a row estimate from 786 to 4,965 (actual 4,864). BRIN was 24 kB against 7.7 MB for a B-tree, but was inefficient because the column's physical correlation was only 0.11.",
      ),
    ],
    { spacing: { before: 60, after: 60, line: 252 } },
  ),
);

// 4. Portfolio 3 --------------------------------------------------------------
children.push(h("4. Portfolio 3 – Transactions and concurrency"));
children.push(
  p([
    run(
      "Business transactions are PL/pgSQL functions (dispense, admit, post payment, stock transfer). A Python lab drives ",
    ),
    b("real concurrent sessions"),
    run(
      " in a fixed interleaving, and an observer session shows lock waits from pg_stat_activity. Ten scenarios were run:",
    ),
  ]),
);
children.push(
  bullet([
    b("Atomicity: "),
    run(
      "a consultation commits 5 related inserts together. A dispense that runs out of artesunate fails the CHECK, and the earlier paracetamol decrement is rolled back as well. Savepoints isolate one bad line in an HMO remittance.",
    ),
  ]),
);
children.push(
  bullet([
    b("Isolation: "),
    run(
      "no dirty reads even at READ UNCOMMITTED; a non-repeatable read under READ COMMITTED; stable reads under REPEATABLE READ (MVCC).",
    ),
  ]),
);
children.push(
  bullet([
    b("Anomalies and control: "),
    run(
      "a lost update on stock (470 instead of 452), fixed three ways: atomic UPDATE, SELECT … FOR UPDATE, and REPEATABLE READ with retry. Write skew on the on-call roster left nobody on call under snapshot isolation; SERIALIZABLE (SSI) aborted one doctor's request. Exclusion constraints blocked concurrent double booking and bed sharing, and SKIP LOCKED gave two nurses different beds without waiting. A deadlock between opposite stock transfers was removed by lock ordering, and idempotent payments survive POS retries.",
    ),
  ]),
);
children.push(
  new Paragraph({
    alignment: AlignmentType.CENTER,
    spacing: { before: 40, after: 0 },
    children: [
      picture(
        "docs/screenshots/p3_lost_update_write_skew.png",
        1944,
        566,
        15.5,
      ),
    ],
  }),
);
children.push(
  new Paragraph({
    alignment: AlignmentType.CENTER,
    spacing: { after: 40 },
    children: [
      run(
        "Figure 2. Lost update and write-skew evidence (verbatim transcript lines)",
        { size: 15, italics: true },
      ),
    ],
  }),
);

// 5. Portfolio 4 --------------------------------------------------------------
children.push(
  h("5. Portfolio 4 – NoSQL and advanced data models (MongoDB 9, Redis 8)"),
);
children.push(
  p([
    run("PostgreSQL remains the system of record. A Python ETL builds a "),
    b("document model"),
    run(
      " of the electronic health record. Diagnoses, prescriptions and lab results are embedded in each encounter; patients are referenced, with an extended-reference snapshot and a computed summary; a $jsonSchema validator checks each document. Reconciliation was exact (357,225 encounters, 448,374 diagnoses, 378,337 lab results). Patient history went from a COLLSCAN of 357,225 documents to an IXSCAN examining 42. The top diagnoses per quarter, abnormal-lab and recall queries gave ",
    ),
    b("the same answers as SQL"),
    run(". Advanced models: a "),
    b("time-series"),
    run(
      " collection of ward vitals with $setWindowFields early-warning alerts (3 of 68 inpatients flagged), and ",
    ),
    b("graph"),
    run(
      " contact tracing for Lassa fever with $graphLookup (13 first-degree and 10 second-degree contacts). ",
    ),
    b("Redis key-value"),
    run(
      " handles 5-minute slot holds (SET NX EX), a cache-aside patient card (64 µs against 223 µs from MongoDB), an A&E triage queue in a sorted set, and an atomic Lua bed board (15 concurrent claims for 12 beds granted exactly 12).",
    ),
  ]),
);

// 6. Portfolio 5 --------------------------------------------------------------
children.push(h("6. Portfolio 5 – Distributed and cloud databases"));
children.push(
  p([
    run("A local multi-node lab models the three sites. "),
    b("Replication: "),
    run(
      "an Enugu primary with a synchronous Nsukka DR standby and an asynchronous Awka read replica. With synchronous_commit = on, only 49/50 writes were readable on the standby straight away; with remote_apply, 50/50. A paused async replica served stale reads (eventual consistency). During a partition, commits blocked on SyncRep: PostgreSQL chose consistency over availability. Quorum commit (ANY 1) restored availability. After a crash, Nsukka was promoted (timeline 2) with ",
    ),
    b("RPO = 0"),
    run(". "),
    b("Sharding: "),
    run(
      "postgres_fdw partitions appointments by branch across two servers, with partition pruning, aggregate pushdown and an explicit ",
    ),
    b("two-phase commit"),
    run(" for moving an appointment between shards (commit and abort paths). "),
    b("MongoDB replica set: "),
    run(
      "w:majority costs about 10 ms per write; failover after a kill -9 took 10.9 s with no acknowledged write lost; with no majority, writes stop but reads continue. A Multi-AZ managed deployment in a South-African cloud region (or Lagos colocation) is proposed, taking the NDPA 2023 cross-border rules into account.",
    ),
  ]),
);
children.push(
  new Paragraph({
    alignment: AlignmentType.CENTER,
    spacing: { before: 40, after: 0 },
    children: [
      picture("docs/screenshots/p5_partition_failover.png", 1944, 498, 15.5),
    ],
  }),
);
children.push(
  new Paragraph({
    alignment: AlignmentType.CENTER,
    spacing: { after: 40 },
    children: [
      run("Figure 3. Read consistency, partition and failover evidence", {
        size: 15,
        italics: true,
      }),
    ],
  }),
);

// 7. Reflection ----------------------------------------------------------------
children.push(h("7. Individual technical reflection"));
children.push(
  p([
    todo(
      "[DRAFT – rewrite this section in your own words before submitting; it must reflect your own experience.]",
    ),
  ]),
);
children.push(
  p([
    b("Design choices. "),
    run(
      "I chose a hospital because its rules (one doctor per slot, one patient per bed, no negative stock) are concrete and testable. I put those rules into the database as constraints rather than application code, and Portfolio 3 showed why: when the application logic raced, the exclusion constraints still prevented double booking. I kept PostgreSQL as the system of record and used MongoDB and Redis only where their model clearly fits.",
    ),
  ]),
);
children.push(
  p([
    b("Challenges. "),
    run(
      'Several failures taught me more than the successes. PostgreSQL rejected my first double-booking constraint because timestamptz + interval is not IMMUTABLE, so I stored an explicit end time. A NOT IN query ran for ten minutes before I understood the work_mem fallback and the NULL trap. A benchmark baseline was silently wrong because RESET returned to a database-level setting. Synchronous replication hung my data load, because I enabled it before the standby existed. A MongoDB "failover" showed zero errors only because a shutdown command hands over gracefully; kill -9 revealed the real 11-second election.',
    ),
  ]),
);
children.push(
  p([
    b("Lessons learned. "),
    run(
      "Measure before tuning, and check that the baseline is really a baseline. Isolation levels do not remove the need to think about application read-modify-write. Every distributed setting is a trade-off between latency, consistency and availability that the hospital must choose per operation, not globally.",
    ),
  ]),
);

// 8. AI use + references --------------------------------------------------------
children.push(h("8. AI use declaration"));
children.push(
  p([
    b("Tool: "),
    run(
      "Claude Code (Anthropic; model Claude Opus 5.5) in Visual Studio Code. ",
    ),
    b("Used for: "),
    run(
      "generating most of the SQL, PL/pgSQL, Python and MongoDB scripts; running them on my machine; diagnosing the errors described above; and drafting the README files and this summary from the captured outputs. ",
    ),
    b("Review and verification: "),
    todo(
      "[Complete truthfully – e.g. which scripts you re-ran yourself, which outputs and plans you checked, what you changed, and confirm that you can explain each portfolio.]",
    ),
    run(
      " All results quoted here come from executed runs whose raw output is committed in the repository's evidence folders.",
    ),
  ]),
);
children.push(h("9. References"));
[
  "Elmasri, R. and Navathe, S. B. (2016) Fundamentals of Database Systems. 7th edn. Pearson.",
  "Kleppmann, M. (2017) Designing Data-Intensive Applications. O'Reilly Media.",
  "Ports, D. R. K. and Grittner, K. (2012) 'Serializable Snapshot Isolation in PostgreSQL', Proceedings of the VLDB Endowment, 5(12), pp. 1850–1861.",
  "PostgreSQL Global Development Group (2026) PostgreSQL 16 Documentation. Available at: https://www.postgresql.org/docs/16/",
  "MongoDB Inc. (2026) MongoDB Manual. Available at: https://www.mongodb.com/docs/manual/ ; Redis Ltd. (2026) Redis Documentation. Available at: https://redis.io/docs/",
  "Federal Republic of Nigeria (2023) Nigeria Data Protection Act 2023. World Health Organization (2019) ICD-10 Version: 2019.",
].forEach((r) =>
  children.push(
    new Paragraph({
      children: [run(r, { size: 17 })],
      numbering: { reference: "refs", level: 0 },
      spacing: { after: 10 },
    }),
  ),
);

// ---------------------------------------------------------------------------
const doc = new Document({
  creator: "Casmir Onyeka",
  title: "MIT 8103 Portfolio Documentation - Onyeka Casmir 301911351",
  styles: { default: { document: { run: { font: FONT, size: BODY } } } },
  numbering: {
    config: [
      {
        reference: "bullets",
        levels: [
          {
            level: 0,
            format: LevelFormat.BULLET,
            text: "•",
            alignment: AlignmentType.LEFT,
            style: { paragraph: { indent: { left: 300, hanging: 200 } } },
          },
        ],
      },
      {
        reference: "refs",
        levels: [
          {
            level: 0,
            format: LevelFormat.DECIMAL,
            text: "%1.",
            alignment: AlignmentType.LEFT,
            style: { paragraph: { indent: { left: 300, hanging: 300 } } },
          },
        ],
      },
    ],
  },
  sections: [
    {
      properties: {
        page: {
          size: { width: 11906, height: 16838 },
          margin: { top: 680, bottom: 680, left: 720, right: 720 },
        },
      },
      footers: {
        default: new Footer({
          children: [
            new Paragraph({
              alignment: AlignmentType.CENTER,
              children: [
                run("Onyeka Casmir · 301911351 · MIT 8103 Portfolio · page ", {
                  size: 15,
                  color: "808080",
                }),
                new TextRun({
                  children: [PageNumber.CURRENT],
                  font: FONT,
                  size: 15,
                  color: "808080",
                }),
              ],
            }),
          ],
        }),
      },
      children,
    },
  ],
});
Packer.toBuffer(doc).then((buf) => {
  fs.writeFileSync(OUT, buf);
  console.log("wrote", OUT);
});
