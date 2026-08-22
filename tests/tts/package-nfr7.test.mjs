import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import test from "node:test";

const project = resolve(import.meta.dirname, "../..");
const packager = join(project, "scripts/package-nfr7.mjs");
const passages = JSON.parse(readFileSync(join(import.meta.dirname, "corpus.json"), "utf8")).passages;

test("places blind instructions inside every reviewer package", () => {
  const root = mkdtempSync(join(tmpdir(), "lf-nfr7-package-test-"));
  const benchmarks = join(root, "benchmarks");
  const output = join(root, "output");
  mkdirSync(benchmarks);
  try {
    for (const passage of passages) {
      const directory = join(benchmarks, passage.id);
      mkdirSync(directory);
      writeFileSync(join(directory, "sample.wav"), passage.id);
      writeFileSync(join(directory, "summary.json"), JSON.stringify({
        candidate_id: "kokoro-82m-4bit",
        passage_id: passage.id,
        status: "completed",
        anomalies: [],
        duration_seconds: passage.long ? 600 : 30,
      }));
    }
    execFileSync(process.execPath, [packager, "--benchmark-root", benchmarks, "--output-root", output]);
    for (const reviewer of ["R01", "R02", "R03"]) {
      const instructions = readFileSync(join(output, reviewer, "instructions.md"), "utf8");
      assert.match(instructions, /Protocolo ciego NFR7/);
      assert.doesNotMatch(instructions, /Kokoro|Qwen|mlx/i);
    }
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
