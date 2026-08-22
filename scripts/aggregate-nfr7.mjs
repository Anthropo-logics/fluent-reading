#!/usr/bin/env node

import { createHash } from "node:crypto";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";

const rootIndex = process.argv.indexOf("--root");
if (rootIndex < 0 || !process.argv[rootIndex + 1]) throw new Error("missing --root");
const root = resolve(process.argv[rootIndex + 1]);
const project = resolve(import.meta.dirname, "..");
const corpus = JSON.parse(readFileSync(join(project, "tests/tts/corpus.json"), "utf8"));
const passages = new Map(corpus.passages.map((item) => [item.id, item]));
const key = JSON.parse(readFileSync(join(root, "key.json"), "utf8"));
const mappings = new Map(key.mappings.map((item) => [`${item.reviewer}:${item.stimulus_id}`, item]));
const candidateIDs = new Set(key.mappings.map((item) => item.candidate_id));
if (candidateIDs.size !== 1) throw new Error("evaluation package must contain one candidate");
const candidateID = [...candidateIDs][0];
const accepted = [];
let pending = 0;
for (const reviewer of ["R01", "R02", "R03"]) {
  const form = JSON.parse(readFileSync(join(root, reviewer, "response.json"), "utf8"));
  if (form.reviewer_id !== reviewer || form.responses.length !== 15) throw new Error(`invalid form ${reviewer}`);
  for (const response of form.responses) {
    const mapping = mappings.get(`${reviewer}:${response.stimulus_id}`);
    const passage = mapping && passages.get(mapping.passage_id);
    if (!mapping || !passage) throw new Error("invalid mapping");
    if (response.language !== passage.language) throw new Error(`language mismatch ${response.stimulus_id}`);
    const audio = join(root, reviewer, response.file);
    if (!existsSync(audio)) throw new Error(`missing audio ${response.stimulus_id}`);
    const hash = createHash("sha256").update(readFileSync(audio)).digest("hex");
    if (hash !== response.audio_sha256) throw new Error(`audio hash mismatch ${response.stimulus_id}`);
    if (response.naturalness === null || response.pronunciation === null) { pending += 1; continue; }
    if (![response.naturalness, response.pronunciation].every((score) => Number.isInteger(score) && score >= 1 && score <= 5)) {
      throw new Error(`invalid score ${response.stimulus_id}`);
    }
    if (!response.defects.every((defect) =>
      ["omission", "repetition", "invention", "cut", "artifact"].includes(defect.type)
      && ["low", "medium", "high"].includes(defect.severity))) throw new Error(`invalid defect ${response.stimulus_id}`);
    accepted.push({ ...response, passage_id: mapping.passage_id });
  }
}

if (pending) {
  process.stdout.write(`${JSON.stringify({ status: "pending", reviewers: 3, pending_responses: pending })}\n`);
  process.exit(0);
}
const summarize = (rows) => {
  const mean = (field) => rows.reduce((sum, row) => sum + row[field], 0) / rows.length;
  return {
    denominator: rows.length,
    naturalness_mean: mean("naturalness"),
    pronunciation_mean: mean("pronunciation"),
    high_defect_count: rows.flatMap((row) => row.defects).filter((item) => item.severity === "high").length,
  };
};
const languages = Object.fromEntries(["es", "en", "pt"].map((language) =>
  [language, summarize(accepted.filter((row) => row.language === language))]));
const passageResults = Object.fromEntries(corpus.passages.map((passage) =>
  [passage.id, { language: passage.language,
    ...summarize(accepted.filter((row) => row.passage_id === passage.id)) }]));
const passed = Object.values(languages).every((result) =>
  result.denominator === 15 && result.naturalness_mean >= 4 && result.pronunciation_mean >= 4
  && result.high_defect_count === 0);
const aggregate = { schema_version: 1, status: "completed", candidate_id: candidateID,
  reviewer_count: 3, languages, passages: passageResults, nfr7_passed: passed };
writeFileSync(join(root, "aggregate.json"), `${JSON.stringify(aggregate, null, 2)}\n`);
process.stdout.write(`${JSON.stringify(aggregate)}\n`);
