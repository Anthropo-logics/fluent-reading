import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import test from "node:test";

const project = resolve(import.meta.dirname, "../..");
const aggregate = join(project, "scripts/aggregate-nfr7.mjs");
const passages = JSON.parse(readFileSync(join(import.meta.dirname, "corpus.json"), "utf8")).passages;

function packageRoot({ wrongLanguage = false } = {}) {
  const root = mkdtempSync(join(tmpdir(), "lf-nfr7-test-"));
  const mappings = [];
  for (const [reviewerIndex, reviewer] of ["R01", "R02", "R03"].entries()) {
    const directory = join(root, reviewer);
    mkdirSync(directory);
    const responses = passages.map((passage, passageIndex) => {
      const stimulus = `${reviewer}-${String(passageIndex).padStart(2, "0")}`;
      const file = `${stimulus}.wav`;
      const audio = Buffer.from(`${reviewer}|${passage.id}`);
      writeFileSync(join(directory, file), audio);
      mappings.push({ reviewer, stimulus_id: stimulus, passage_id: passage.id,
        candidate_id: "kokoro-82m-4bit" });
      return {
        stimulus_id: stimulus,
        file,
        language: wrongLanguage && reviewer === "R01" && passageIndex === 0 ? "en" : passage.language,
        audio_sha256: createHash("sha256").update(audio).digest("hex"),
        naturalness: [5, 4, 3][reviewerIndex],
        pronunciation: [4, 4, 5][reviewerIndex],
        defects: [],
      };
    });
    writeFileSync(join(directory, "response.json"), JSON.stringify({ reviewer_id: reviewer, responses }));
  }
  writeFileSync(join(root, "key.json"), JSON.stringify({ mappings }));
  return root;
}

test("reports each candidate and passage with reviewer denominators", () => {
  const root = packageRoot();
  try {
    const result = JSON.parse(execFileSync(process.execPath, [aggregate, "--root", root], { encoding: "utf8" }));
    assert.equal(result.candidate_id, "kokoro-82m-4bit");
    assert.deepEqual(result.passages["es-long"], {
      language: "es",
      denominator: 3,
      naturalness_mean: 4,
      pronunciation_mean: 13 / 3,
      high_defect_count: 0,
    });
    assert.equal(Object.keys(result.passages).length, 15);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("rejects a response language that disagrees with the corpus", () => {
  const root = packageRoot({ wrongLanguage: true });
  try {
    const result = spawnSync(process.execPath, [aggregate, "--root", root], { encoding: "utf8" });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /language mismatch/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
