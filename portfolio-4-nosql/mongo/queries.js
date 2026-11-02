// =====================================================================
// Portfolio 4 - MongoDB queries, indexes and validation for udoka_ehr
// Run: mongosh --quiet udoka_ehr mongo/queries.js > evidence/mongo_queries_output.txt
// =====================================================================
const h = (t) => print(`\n=== ${t} ===`);
const day = (s) => new Date(s);

function stats(cursorOrAgg) {
  const s = cursorOrAgg.executionStats || cursorOrAgg;
  return {
    stage: JSON.stringify(s.executionStages ? s.executionStages.stage : "?"),
    plan: winning(cursorOrAgg),
    nReturned: s.nReturned,
    totalDocsExamined: s.totalDocsExamined,
    totalKeysExamined: s.totalKeysExamined,
    executionTimeMillis: s.executionTimeMillis,
  };
}
function winning(ex) {
  // walk the winning plan and list its stages, e.g. FETCH <- IXSCAN
  let p = ex.queryPlanner.winningPlan.queryPlan || ex.queryPlanner.winningPlan;
  const out = [];
  while (p) {
    out.push(p.stage + (p.indexName ? `(${p.indexName})` : ""));
    p = p.inputStage;
  }
  return out.join(" <- ");
}

// ---------------------------------------------------------------------
h("Collections and sizes");
db.getCollectionNames().sort().forEach((c) => {
  const s = db.runCommand({ collStats: c });
  const n = s.count !== undefined ? s.count : db[c].countDocuments();
  print(`${c.padEnd(14)} docs=${String(n).padStart(8)}  avgDocBytes=${String(Math.round(s.avgObjSize || 0)).padStart(5)}  size=${(s.size / 1048576).toFixed(1)} MB`);
});

h("One encounter document (the shape of the model)");
printjson(db.encounters.findOne({ type: "INPATIENT", labOrders: { $exists: true }, prescription: { $exists: true } }));

h("One patient document");
printjson(db.patients.findOne({ hospitalNo: "USH-0000002" }));

// ---------------------------------------------------------------------
h("M1 Patient history - explain BEFORE index (collection scan)");
db.encounters.dropIndexes();
const q1 = { "patient.id": 2 };
printjson(stats(db.encounters.find(q1).sort({ startedAt: -1 }).explain("executionStats")));

h("Create indexes");
print(db.encounters.createIndex({ "patient.id": 1, startedAt: -1 }, { name: "patient_history" }));
print(db.encounters.createIndex({ "diagnoses.code": 1, startedAt: -1 }, { name: "dx_time" }));        // multikey
print(db.encounters.createIndex({ branch: 1, startedAt: -1 }, { name: "branch_time" }));
print(db.encounters.createIndex({ "labOrders.results.resultedAt": -1 },
      { name: "abnormal_results", partialFilterExpression: { "labOrders.results.flag": { $in: ["H", "L", "A"] } } }));
print(db.encounters.createIndex({ complaint: "text", notes: "text" }, { name: "clinical_text" }));
print(db.patients.createIndex({ hospitalNo: 1 }, { unique: true, name: "hospital_no_unique" }));
print(db.patients.createIndex({ "summary.chronicConditions": 1, "summary.lastVisitAt": 1 }, { name: "chronic_recall" }));
print(db.ward_contacts.createIndex({ from: 1, overlapTo: 1 }, { name: "graph_from" }));

h("M1 Patient history - explain AFTER index");
printjson(stats(db.encounters.find(q1).sort({ startedAt: -1 }).explain("executionStats")));

h("M1 result: last 5 encounters of USH-0000002, one read, no joins");
db.encounters.find(q1, { _id: 1, startedAt: 1, type: 1, "doctor.name": 1, "diagnoses.code": 1,
                         "prescription.items.drug": 1, "labOrders.results.test": 1 })
  .sort({ startedAt: -1 }).limit(5).forEach((d) => print(EJSON.stringify(d)));

// ---------------------------------------------------------------------
h("M2 Top 5 primary diagnoses per branch per quarter since 2025 ($unwind, $group, $topN)");
const m2 = [
  { $match: { startedAt: { $gte: day("2025-01-01T00:00:00+01:00") } } },
  { $unwind: "$diagnoses" },
  { $match: { "diagnoses.primary": true } },
  { $group: { _id: { branch: "$branch", quarter: { $dateTrunc: { date: "$startedAt", unit: "quarter", timezone: "Africa/Lagos" } },
                     code: "$diagnoses.code" }, cases: { $sum: 1 } } },
  { $group: { _id: { branch: "$_id.branch", quarter: "$_id.quarter" },
              top5: { $topN: { n: 5, sortBy: { cases: -1 }, output: { code: "$_id.code", cases: "$cases" } } } } },
  { $sort: { "_id.branch": 1, "_id.quarter": 1 } },
];
let t = Date.now();
const m2res = db.encounters.aggregate(m2).toArray();
print(`${m2res.length} branch-quarters in ${Date.now() - t} ms; first three:`);
m2res.slice(0, 3).forEach((d) => print(EJSON.stringify(d)));

h("M3 Abnormal lab results in the last 7 days at Enugu (partial index)");
const m3 = [
  { $match: { branch: "ENU", "labOrders.results.resultedAt": { $gte: day("2026-10-26T00:00:00+01:00"), $lt: day("2026-11-02T00:00:00+01:00") },
              "labOrders.results.flag": { $in: ["H", "L", "A"] } } },
  { $unwind: "$labOrders" }, { $unwind: "$labOrders.results" },
  { $match: { "labOrders.results.flag": { $in: ["H", "L", "A"] },
              "labOrders.results.resultedAt": { $gte: day("2026-10-26T00:00:00+01:00"), $lt: day("2026-11-02T00:00:00+01:00") } } },
  { $project: { _id: 0, hospitalNo: "$patient.hospitalNo", test: "$labOrders.results.name",
                value: { $ifNull: ["$labOrders.results.value", "$labOrders.results.text"] },
                flag: "$labOrders.results.flag", priority: "$labOrders.priority", at: "$labOrders.results.resultedAt" } },
  { $sort: { at: -1 } },
];
t = Date.now();
const m3res = db.encounters.aggregate(m3).toArray();
print(`${m3res.length} abnormal results in ${Date.now() - t} ms (SQL Q4 returned 496); first three:`);
m3res.slice(0, 3).forEach((d) => print(EJSON.stringify(d)));
print("plan: " + winning(db.encounters.explain().aggregate(m3).stages
  ? db.encounters.explain().aggregate(m3).stages[0].$cursor
  : db.encounters.explain().aggregate(m3)));

h("M4 Hypertension recall list from the embedded patient summary (no join needed)");
const m4 = { "summary.chronicConditions": "I10", "summary.lastVisitAt": { $lt: day("2025-11-02T00:00:00+01:00") } };
print(`count = ${db.patients.countDocuments(m4)}  (SQL Q7 returned 714)`);
printjson(stats(db.patients.find(m4).explain("executionStats")));

h("M5 Full-text search of clinical notes / complaints");
db.encounters.find({ $text: { $search: "\"bleeding tendency\"" } }, { score: { $meta: "textScore" }, complaint: 1, "patient.hospitalNo": 1, startedAt: 1 })
  .sort({ score: { $meta: "textScore" } }).limit(3).forEach((d) => print(EJSON.stringify(d)));

// ---------------------------------------------------------------------
h("M6 Time-series: all inpatients' vitals with a 1-hour moving average and early-warning flag ($setWindowFields)");
const m6 = [
  { $setWindowFields: {
      partitionBy: "$meta.patientId", sortBy: { ts: 1 },
      output: {
        hr1h:   { $avg: "$hr",   window: { range: [-1, 0], unit: "hour" } },
        spo21h: { $avg: "$spo2", window: { range: [-1, 0], unit: "hour" } },
      } } },
  { $match: { ts: { $gte: day("2026-11-02T07:00:00Z") } } },
  { $project: { _id: 0, patient: "$meta.hospitalNo", bed: "$meta.bed", ts: 1, hr: 1, spo2: 1, tempC: 1,
                hr1h: { $round: ["$hr1h", 0] }, spo21h: { $round: ["$spo21h", 1] },
                alert: { $or: [{ $gt: ["$hr1h", 110] }, { $lt: ["$spo21h", 92] }, { $gt: ["$tempC", 38.5] }] } } },
  { $sort: { alert: -1, patient: 1, ts: -1 } },
];
const m6res = db.vitals.aggregate(m6).toArray();
const flagged = [...new Set(m6res.filter((d) => d.alert).map((d) => d.patient))];
print(`${flagged.length} of 68 inpatients trigger an early-warning alert in the last hour: ${flagged.join(", ")}`);
m6res.slice(0, 4).forEach((d) => print(EJSON.stringify(d)));
const ts = db.runCommand({ collStats: "vitals" }).timeseries;
print(`time-series storage: ${db.vitals.countDocuments()} measurements packed into ${ts.bucketCount} buckets ` +
      `(avg bucket ${ts.avgBucketSize} bytes)`);

// ---------------------------------------------------------------------
h("M7 Graph: Lassa-fever contact tracing with $graphLookup (21-day window)");
// Scenario: the inpatient in Ward A bed B01 is confirmed with Lassa fever on 2 Nov 2026.
const index = db.encounters.findOne({ type: "INPATIENT", "admission.ward": "Ward A (Male Medical)",
                                      "admission.dischargedAt": { $exists: false } }, { patient: 1, admission: 1 });
print(`index case: ${index.patient.hospitalNo} (${index.patient.name}), ${index.admission.ward} bed ${index.admission.bed}`);
const since = day("2026-10-12T00:00:00+01:00");   // 21-day incubation period
const m7 = db.patients.aggregate([
  { $match: { _id: index.patient.id } },
  { $graphLookup: { from: "ward_contacts", startWith: "$_id", connectFromField: "to", connectToField: "from",
                    as: "chain", maxDepth: 1, depthField: "degree",
                    restrictSearchWithMatch: { overlapTo: { $gte: since } } } },
  { $unwind: "$chain" },
  { $group: { _id: "$chain.to", degree: { $min: "$chain.degree" }, wards: { $addToSet: "$chain.ward" } } },
  { $match: { _id: { $ne: index.patient.id } } },
  { $group: { _id: "$degree", contacts: { $sum: 1 }, wards: { $addToSet: "$wards" } } },
  { $sort: { _id: 1 } },
]).toArray();
m7.forEach((d) => print(`degree ${Number(d._id) + 1} contacts: ${d.contacts}  wards: ${EJSON.stringify(d.wards.flat().filter((v, i, a) => a.indexOf(v) === i))}`));

// ---------------------------------------------------------------------
h("M8 Schema validation rejects a malformed encounter");
try {
  db.encounters.insertOne({ _id: 9999999, type: "OPD", branch: "LAG", startedAt: "yesterday",
                            patient: { id: 2, hospitalNo: "2", name: "X" }, doctor: { id: 30, name: "Dr X", specialty: "?" } });
} catch (e) {
  print(`rejected: ${e.errorResponse ? e.errorResponse.errmsg : e.message}`);
  const d = e.errInfo || (e.errorResponse && e.errorResponse.errInfo);
  if (d) print(EJSON.stringify(d.details.schemaRulesNotSatisfied.map((r) => r.propertiesNotSatisfied || r).flat()
    .map((p) => p.propertyName)));
}

h("M9 Atomic single-document update: dispense a prescription and append a lab result together");
const target = db.encounters.findOne({ "prescription.status": "PENDING" }, { _id: 1 });
const res = db.encounters.updateOne(
  { _id: target._id, "prescription.status": "PENDING" },                        // optimistic guard
  { $set: { "prescription.status": "DISPENSED", "prescription.items.$[].dispensed": 1 },
    $push: { labOrders: { orderId: -1, priority: "ROUTINE", status: "RESULTED",
                          results: [{ test: "MP", text: "No malaria parasite seen", flag: "N", resultedAt: new Date() }] } } });
printjson(res);
const again = db.encounters.updateOne({ _id: target._id, "prescription.status": "PENDING" }, { $set: { "prescription.status": "DISPENSED" } });
print(`second dispense attempt matched ${again.matchedCount} document(s) -> no double dispensing`);
db.encounters.updateOne({ _id: target._id }, { $set: { "prescription.status": "PENDING" }, $pull: { labOrders: { orderId: -1 } } });
