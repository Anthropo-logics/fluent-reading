#!/usr/bin/env node

import { createHash } from "node:crypto";
import { copyFileSync, existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { basename, join, resolve } from "node:path";

const args = Object.fromEntries(
  process.argv.slice(2).reduce((pairs, value, index, all) => {
    if (value.startsWith("--")) pairs.push([value.slice(2), all[index + 1]]);
    return pairs;
  }, []),
);
if (!args["benchmark-root"] || !args["output-root"]) throw new Error("missing benchmark/output root");
const benchmarkRoot = resolve(args["benchmark-root"]);
const outputRoot = resolve(args["output-root"]);
const project = resolve(import.meta.dirname, "..");
const corpus = JSON.parse(readFileSync(join(project, "tests/tts/corpus.json"), "utf8"));
const seed = "lf-nfr7-v1-2026-08-17";
const runs = readdirSync(benchmarkRoot, { withFileTypes: true })
  .filter((entry) => entry.isDirectory() && existsSync(join(benchmarkRoot, entry.name, "summary.json")))
  .map((entry) => {
    const directory = join(benchmarkRoot, entry.name);
    return { directory, summary: JSON.parse(readFileSync(join(directory, "summary.json"), "utf8")) };
  });
const inputs = corpus.passages.map((passage) => {
  const run = runs
    .filter(({ summary }) => summary.candidate_id === "kokoro-82m-4bit" && summary.passage_id === passage.id)
    .sort((left, right) => right.summary.duration_seconds - left.summary.duration_seconds)[0];
  if (!run) throw new Error(`missing source ${passage.id}`);
  const { directory, summary } = run;
  if (summary.status !== "completed" || summary.anomalies.length) throw new Error(`invalid source ${passage.id}`);
  if (passage.long && summary.duration_seconds < 600) throw new Error(`short long-passage ${passage.id}`);
  const audio = readdirSync(directory).find((name) => name.endsWith(".wav"));
  if (!audio) throw new Error(`missing audio ${passage.id}`);
  return { passage, source: join(directory, audio), summary };
});

function shuffle(items, reviewer) {
  const ranked = items.map((item) => ({
    item,
    rank: createHash("sha256").update(`${seed}|${reviewer}|${item.passage.id}`).digest("hex"),
  }));
  return ranked.sort((left, right) => left.rank.localeCompare(right.rank)).map(({ item }) => item);
}

mkdirSync(outputRoot, { recursive: true });
const key = { schema_version: 1, seed_sha256: createHash("sha256").update(seed).digest("hex"), mappings: [] };
for (const reviewer of ["R01", "R02", "R03"]) {
  const directory = join(outputRoot, reviewer);
  mkdirSync(directory, { recursive: true });
  copyFileSync(join(project, "tests/tts/nfr7-protocol.md"), join(directory, "instructions.md"));
  const responses = [];
  for (const [order, input] of shuffle(inputs, reviewer).entries()) {
    const stimulusId = createHash("sha256")
      .update(`${seed}|${reviewer}|${input.passage.id}|stimulus`)
      .digest("hex").slice(0, 12);
    const file = `${String(order + 1).padStart(2, "0")}-${stimulusId}.wav`;
    copyFileSync(input.source, join(directory, file));
    const audioSha256 = createHash("sha256").update(readFileSync(input.source)).digest("hex");
    responses.push({ stimulus_id: stimulusId, file, language: input.passage.language,
      audio_sha256: audioSha256, naturalness: null, pronunciation: null, defects: [] });
    key.mappings.push({ reviewer, stimulus_id: stimulusId, passage_id: input.passage.id,
      candidate_id: input.summary.candidate_id, source_file: basename(input.source) });
  }
  writeFileSync(join(directory, "response.json"), `${JSON.stringify({
    schema_version: 1, protocol: "nfr7-v1", reviewer_id: reviewer, responses,
  }, null, 2)}\n`);
}
writeFileSync(join(outputRoot, "key.json"), `${JSON.stringify(key, null, 2)}\n`);
process.stdout.write(`${JSON.stringify({ reviewers: 3, stimuli_per_reviewer: 15, output_root: outputRoot })}\n`);
