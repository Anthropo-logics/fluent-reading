#!/usr/bin/env node

import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { execFileSync, spawnSync } from "node:child_process";

const args = Object.fromEntries(process.argv.slice(2).reduce((pairs, value, index, values) => {
  if (value.startsWith("--")) pairs.push([value.slice(2), values[index + 1]]);
  return pairs;
}, []));
for (const name of ["input", "output-root", "model-root"]) {
  if (!args[name]) throw new Error(`missing --${name}`);
}

const project = resolve(import.meta.dirname, "..");
const input = resolve(args.input);
const outputRoot = resolve(args["output-root"]);
const modelRoot = resolve(args["model-root"]);
const lectura = process.env.LECTURA_CLI ?? join(project, "target/release/lectura");
const worker = process.env.LECTURA_MACOS_WORKER ?? join(project, "target/lectura-macos-worker");
const runtime = process.env.LECTURA_TTS_RUNTIME
  ?? join(modelRoot, "runtime/xcode-derived-mlx-audio-swift-v0.1.3/Build/Products/Release/mlx-audio-swift-tts");
const modelPackage = join(modelRoot, "verified-packages/kokoro-82m-4bit");
const documentHash = createHash("sha256").update(readFileSync(input)).digest("hex");
const env = {
  ...process.env,
  LECTURA_MACOS_WORKER: worker,
  LECTURA_ESPEAK: "/opt/homebrew/bin/espeak-ng",
  LECTURA_TTS_MANIFEST: join(project, "models/manifests/kokoro-82m-4bit.json"),
  LECTURA_TTS_PACKAGE: modelPackage,
  LECTURA_TTS_MODEL: join(modelPackage, "data"),
  LECTURA_TTS_RUNTIME: runtime,
};

const metric = (summary, name) => summary.metrics.find((item) => item.name === name)?.numerator;
const percentile95 = (values) => [...values].sort((left, right) => left - right)[values.length - 1];
const median = (values) => [...values].sort((left, right) => left - right)[Math.floor(values.length / 2)];
const manifestFor = (condition) => ({
  schema_version: 1,
  request: {
    scenario: "integrated_chain", condition, corpus_id: `sha256-${documentHash.slice(0, 16)}`,
    revisions: { app: "worktree", corpus: `sha256-${documentHash.slice(0, 16)}`,
      runtime: "mlx-audio-swift-v0.1.3", model: "kokoro-82m-4bit-e4468a46" },
    expected_repetitions: 1, expected_duration_ms: 120000,
  },
  // Extraction remains whole-document. Limiting narration isolates the first usable unit.
  document: { input, language: "es", unit: "paragraph", narration_unit_limit: 1, page_limit: 1 },
  tts: { model_id: "kokoro-82m-4bit", model_revision: "e4468a460f6f70b9125a003e0adb1ab7d4904bbd",
    runtime_id: "mlx-audio-swift", runtime_version: "v0.1.3", voice_id: "ef_dora" },
});

function run(condition, index) {
  const directory = join(outputRoot, `${condition}-${index + 1}`);
  const summaryPath = join(directory, "summary.json");
  if (existsSync(summaryPath)) {
    const summary = JSON.parse(readFileSync(summaryPath, "utf8"));
    return {
      first_page_ms: metric(summary, "open_to_first_frame"),
      first_unit_ms: metric(summary, "open_to_first_unit"),
      synthesis_ms: metric(summary, "transport_ack"),
      rss_bytes: summary.resources.at(-1)?.rss_bytes,
    };
  }
  mkdirSync(directory, { recursive: true });
  const manifest = join(directory, ".manifest.json");
  writeFileSync(manifest, JSON.stringify(manifestFor(condition)));
  const result = spawnSync(lectura, ["gate-a", "run", "--manifest", manifest, "--output", directory, "--json"],
    { env, encoding: "utf8", timeout: 120000 });
  rmSync(manifest, { force: true });
  if (result.error || result.status !== 0) throw new Error(`${condition}-${index + 1} failed`);
  const summary = JSON.parse(readFileSync(join(directory, "summary.json"), "utf8"));
  return {
    first_page_ms: metric(summary, "open_to_first_frame"),
    first_unit_ms: metric(summary, "open_to_first_unit"),
    synthesis_ms: metric(summary, "transport_ack"),
    rss_bytes: summary.resources.at(-1)?.rss_bytes,
  };
}

mkdirSync(outputRoot, { recursive: true });
const cold = Array.from({ length: 5 }, (_, index) => run("cold", index));
// Both series use fresh CLI, worker and runtime processes. The hot series follows the cold one,
// so it can benefit only from macOS file cache; it never implies a resident model.
const hot = Array.from({ length: 5 }, (_, index) => run("hot", index));
const summarize = (runs) => Object.fromEntries(["first_page_ms", "first_unit_ms", "synthesis_ms"].map((key) => {
  const values = runs.map((run) => run[key]);
  return [key, { values, median: median(values), p95: percentile95(values) }];
}));
const report = {
  schema_version: 1, document_sha256: documentHash, runtime: "mlx-audio-swift-v0.1.3",
  model: "kokoro-82m-4bit-e4468a46", cache_definition: "cold=fresh CLI/worker/runtime; hot=same fresh processes after cold series, with possible kernel file cache; no resident model",
  environment: {
    hardware: execFileSync("sysctl", ["-n", "hw.model"], { encoding: "utf8" }).trim(),
    macos: execFileSync("sw_vers", ["-productVersion"], { encoding: "utf8" }).trim(),
    energy: execFileSync("pmset", ["-g", "batt"], { encoding: "utf8" }).trim(),
  },
  cold: summarize(cold), hot: summarize(hot), nfr4: { first_page_ms: 2000, first_unit_ms: 8000, pause_resume_ms: 150 },
};
writeFileSync(join(outputRoot, "nfr4-summary.json"), `${JSON.stringify(report, null, 2)}\n`);
process.stdout.write(`${JSON.stringify(report)}\n`);
