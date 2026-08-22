#!/usr/bin/env node

import { execFileSync, spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { cpSync, existsSync, mkdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { performance } from "node:perf_hooks";

import { punctuatedIpa, runEspeak } from "./spoken-normalize.mjs";

const args = Object.fromEntries(
  process.argv.slice(2).reduce((pairs, value, index, all) => {
    if (value.startsWith("--")) pairs.push([value.slice(2), all[index + 1]]);
    return pairs;
  }, []),
);
for (const required of ["candidate", "language", "passage", "output-dir"]) {
  if (!args[required]) throw new Error(`missing --${required}`);
}

const project = resolve(import.meta.dirname, "..");
const corpusRoot = join(project, "tests/tts");
const corpus = JSON.parse(readFileSync(join(corpusRoot, "corpus.json"), "utf8"));
const candidate = corpus.candidates.find((item) => item.model_id === args.candidate);
const passage = corpus.passages.find((item) => item.id === args.passage);
if (!candidate || !passage || passage.language !== args.language) throw new Error("unknown candidate/passage pair");
const source = corpus.sources.find((item) => item.id === passage.source_id);
let text = readFileSync(join(corpusRoot, source.path), "utf8")
  .split(/\r?\n/)
  .slice(passage.line_start - 1, passage.line_end)
  .join(" ")
  .replace(/\s+/g, " ")
  .trim();
if (text.split(/\s+/).length !== passage.word_count) throw new Error("passage word count drifted");
const wordLimit = args["word-limit"] ? Number(args["word-limit"]) : passage.word_count;
if (!Number.isSafeInteger(wordLimit) || wordLimit < 1 || wordLimit > passage.word_count) {
  throw new Error("invalid --word-limit");
}
text = text.split(/\s+/).slice(0, wordLimit).join(" ");
const rawIPA = candidate.model_id === "kokoro-82m-4bit";
const synthesisText = rawIPA
  ? punctuatedIpa(text, args.language, runEspeak)
  : text;

const modelRoot = process.env.LECTURA_MODEL_ROOT;
if (!modelRoot) throw new Error("missing LECTURA_MODEL_ROOT");
const runtime = process.env.LECTURA_TTS_RUNTIME
  ?? join(modelRoot, "runtime/xcode-derived-mlx-audio-swift-v0.1.3/Build/Products/Release/mlx-audio-swift-tts");
const verifiedPackage = join(modelRoot, "verified-packages", candidate.model_id);
const packageRoot = existsSync(verifiedPackage)
  ? verifiedPackage
  : join(modelRoot, "models", candidate.model_id);
const runtimeModel = candidate.model_id === "kokoro-82m-4bit"
  ? join(modelRoot, "models", candidate.model_id, "data")
  : join(modelRoot, "runtime-views", candidate.model_id);
const outputDir = resolve(args["output-dir"]);
mkdirSync(outputDir, { recursive: true });
const requestPath = join(outputDir, ".request.json");
const request = {
  model_id: candidate.model_id,
  model_revision: candidate.model_revision,
  runtime_id: candidate.runtime_id,
  runtime_version: candidate.runtime_version,
  voice_id: candidate.voices[args.language],
  language: args.language,
  raw_ipa: rawIPA,
  units: [{ unit_id: passage.id, text: synthesisText }],
};
writeFileSync(requestPath, JSON.stringify(request));

const lectura = process.env.LECTURA_CLI ?? join(project, "target/release/lectura");
const worker = process.env.LECTURA_MACOS_WORKER ?? join(project, "target/lectura-macos-worker");
const commandArgs = [lectura, "tts", "synthesize", "--request", requestPath, "--json"];
const auxiliaryId = candidate.model_id === "kokoro-82m-4bit"
  && !rawIPA ? (args.language === "en" ? "kokoro-kitten-tts-g2p" : "kokoro-ipa-lexicons-es-pt")
  : null;
const child = spawn("/usr/bin/sandbox-exec", ["-p", "(version 1)(allow default)(deny network*)", ...commandArgs], {
  env: {
    ...process.env,
    LECTURA_MACOS_WORKER: worker,
    LECTURA_TTS_MANIFEST: join(project, "models/manifests", `${candidate.model_id}.json`),
    LECTURA_TTS_PACKAGE: packageRoot,
    LECTURA_TTS_MODEL: runtimeModel,
    LECTURA_TTS_RUNTIME: runtime,
    HF_HOME: join(modelRoot, "hf-home"),
    ...(auxiliaryId ? {
      LECTURA_TTS_AUX_MANIFEST: join(project, "models/manifests", `${auxiliaryId}.json`),
      LECTURA_TTS_AUX_PACKAGE: join(modelRoot, "verified-packages", auxiliaryId),
    } : {}),
  },
  stdio: ["ignore", "pipe", "pipe"],
});
let stdout = "";
let stderr = "";
let maxRssBytes = 0;
let maxCpuPercent = 0;
child.stdout.on("data", (chunk) => { stdout += chunk; });
child.stderr.on("data", (chunk) => { stderr += chunk; });
const started = performance.now();
const sampler = setInterval(() => {
  try {
    const rows = execFileSync("ps", ["-axo", "pid=,ppid=,rss=,%cpu="], { encoding: "utf8" })
      .trim().split("\n").map((line) => line.trim().split(/\s+/).map(Number));
    const descendants = new Set([child.pid]);
    let changed = true;
    while (changed) {
      changed = false;
      for (const [pid, ppid] of rows) if (descendants.has(ppid) && !descendants.has(pid)) {
        descendants.add(pid); changed = true;
      }
    }
    const active = rows.filter(([pid]) => descendants.has(pid));
    maxRssBytes = Math.max(maxRssBytes, active.reduce((sum, row) => sum + row[2] * 1024, 0));
    maxCpuPercent = Math.max(maxCpuPercent, active.reduce((sum, row) => sum + row[3], 0));
  } catch { /* sample loss is reported through zero values */ }
}, 100);
const exitCode = await new Promise((done) => child.on("close", done));
clearInterval(sampler);
rmSync(requestPath, { force: true });
const wallMs = Math.round(performance.now() - started);
if (exitCode !== 0) throw new Error(`synthesis failed (${exitCode}): ${stderr.trim()}`);
const event = JSON.parse(stdout);
if (event.kind !== "completed") throw new Error(`unexpected terminal: ${event.kind}`);
const result = event.result;
const segments = result.segments;
const anomalies = [];
if (result.omitted_unit_ids.length) anomalies.push("omitted_unit");
let expectedOffset = 0;
for (const [index, segment] of segments.entries()) {
  if (segment.unit_id !== passage.id) anomalies.push(`wrong_unit:${index}`);
  if (segment.segment_index !== index) anomalies.push(`segment_order:${index}`);
  if (segment.unit_sample_offset !== expectedOffset) anomalies.push(`sample_gap:${index}`);
  expectedOffset += segment.sample_count;
}
const audioSource = result.audio_path;
const audioName = `${candidate.model_id}-${args.language}-${passage.id}.wav`;
const audioTarget = join(outputDir, audioName);
cpSync(audioSource, audioTarget);
const ownedRoot = dirname(audioSource);
if (basename(ownedRoot).startsWith("lectura-tts-cli-")) rmSync(ownedRoot, { recursive: true, force: true });
const audioHash = createHash("sha256").update(readFileSync(audioTarget)).digest("hex");
const durationSeconds = expectedOffset / segments[0].sample_rate_hz;
if (passage.long && durationSeconds < 600) anomalies.push("duration_below_10_minutes");
const silenceProbe = spawnSync("/opt/homebrew/bin/ffmpeg", [
  "-hide_banner", "-nostats", "-i", audioTarget, "-af", "silencedetect=noise=-50dB:d=2", "-f", "null", "-",
], { encoding: "utf8" });
if (silenceProbe.status !== 0) throw new Error("audio silence probe failed");
const silenceOutput = silenceProbe.stderr;
const longSilences = [...silenceOutput.matchAll(/silence_duration: ([0-9.]+)/g)].map((match) => Number(match[1]));
if (longSilences.some((seconds) => seconds >= 2)) anomalies.push("long_silence");

const metrics = segments.map((segment) => ({
  run_id: basename(outputDir), candidate_id: candidate.model_id, language: args.language,
  passage_id: passage.id, unit_id: segment.unit_id, segment_index: segment.segment_index,
  elapsed_ms: segment.elapsed_ms, sample_count: segment.sample_count,
  sample_rate_hz: segment.sample_rate_hz,
  audio_seconds: segment.sample_count / segment.sample_rate_hz,
  rtf: segment.elapsed_ms / 1000 / (segment.sample_count / segment.sample_rate_hz),
  artifact_hash: segment.artifact_hash,
}));
writeFileSync(join(outputDir, "metrics.jsonl"), `${metrics.map((item) => JSON.stringify(item)).join("\n")}\n`);
const summary = {
  schema_version: 1, status: anomalies.length ? "failed" : "completed",
  candidate_id: candidate.model_id, model_revision: candidate.model_revision,
  runtime_id: candidate.runtime_id, runtime_version: candidate.runtime_version,
  language: args.language, voice_id: candidate.voices[args.language], passage_id: passage.id,
  input_word_count: wordLimit,
  spoken_frontend: rawIPA ? `espeak-ng-1.52.0-${args.language === "pt" ? "pt-br" : args.language === "en" ? "en-us" : "es"}` : "runtime-default",
  offline_enforced: true, wall_ms: wallMs, fragment_count: segments.length,
  first_fragment_ms: segments[0].elapsed_ms,
  median_fragment_ms: [...segments].map((item) => item.elapsed_ms).sort((a, b) => a - b)[Math.floor(segments.length / 2)],
  duration_seconds: durationSeconds, rtf: wallMs / 1000 / durationSeconds,
  max_rss_bytes: maxRssBytes, max_cpu_percent: maxCpuPercent,
  swap: "unavailable_in_managed_session", thermal: "pmset_unavailable_0xe00002bc",
  disk_bytes: statSync(audioTarget).size, audio_sha256: audioHash,
  long_silence_count: longSilences.length, anomalies,
};
writeFileSync(join(outputDir, "summary.json"), `${JSON.stringify(summary, null, 2)}\n`);
process.stdout.write(`${JSON.stringify(summary)}\n`);
