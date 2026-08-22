#!/usr/bin/env node

import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { execFileSync, spawn } from "node:child_process";
import { join, resolve } from "node:path";
import { performance } from "node:perf_hooks";

const args = Object.fromEntries(process.argv.slice(2).reduce((pairs, value, index, values) => {
  if (value.startsWith("--")) pairs.push([value.slice(2), values[index + 1]]);
  return pairs;
}, []));
for (const name of ["input", "output-root", "model-root"]) {
  if (!args[name]) throw new Error(`missing --${name}`);
}

const durationMinutes = Number(args["duration-minutes"] ?? 60);
const narrationUnitLimit = Number(args["narration-unit-limit"] ?? 64);
if (!Number.isInteger(durationMinutes) || durationMinutes < 1 || !Number.isInteger(narrationUnitLimit)
  || narrationUnitLimit < 1 || narrationUnitLimit > 64) {
  throw new Error("duration-minutes must be >= 1 and narration-unit-limit must be 1..64");
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
const documentSha256 = createHash("sha256").update(readFileSync(input)).digest("hex");
const durationMs = durationMinutes * 60_000;
const env = {
  ...process.env,
  LECTURA_MACOS_WORKER: worker,
  LECTURA_ESPEAK: "/opt/homebrew/bin/espeak-ng",
  LECTURA_TTS_MANIFEST: join(project, "models/manifests/kokoro-82m-4bit.json"),
  LECTURA_TTS_PACKAGE: modelPackage,
  LECTURA_TTS_MODEL: join(modelPackage, "data"),
  LECTURA_TTS_RUNTIME: runtime,
};

const metric = (summary, name) => summary.metrics.find((item) => item.name === name);
const parseRows = () => execFileSync("ps", ["-axo", "pid=,ppid=,rss=,%cpu="], { encoding: "utf8" })
  .trim().split("\n").filter(Boolean).map((line) => line.trim().split(/\s+/).map(Number));
const processTree = (pid) => {
  const rows = parseRows(); const descendants = new Set([pid]);
  for (let changed = true; changed;) {
    changed = false;
    for (const [child, parent] of rows) if (descendants.has(parent) && !descendants.has(child)) {
      descendants.add(child); changed = true;
    }
  }
  return rows.filter(([child]) => descendants.has(child)).reduce((total, row) => ({
    rss_bytes: total.rss_bytes + row[2] * 1024, cpu_percent: total.cpu_percent + row[3],
  }), { rss_bytes: 0, cpu_percent: 0 });
};
const vmCounters = () => {
  const text = execFileSync("vm_stat", [], { encoding: "utf8" });
  const pageSize = Number(text.match(/page size of (\d+) bytes/)?.[1] ?? 0);
  const value = (label) => Number(text.match(new RegExp(`${label}:\\s+(\\d+)\\.`))?.[1] ?? 0);
  return { page_size_bytes: pageSize, swapins_pages: value("Swapins"), swapouts_pages: value("Swapouts") };
};
const diskAvailableBytes = () => Number(execFileSync("df", ["-k", outputRoot], { encoding: "utf8" })
  .trim().split("\n").at(-1).trim().split(/\s+/)[3]) * 1024;
const thermalState = () => {
  const request = JSON.stringify({ schema_version: 1, request_id: "sustained_sample", command: "system_sample", payload: {} });
  const result = execFileSync(worker, [], { input: `${request}\n`, env, encoding: "utf8", stdio: ["pipe", "pipe", "ignore"] });
  return JSON.parse(result).result.system.thermal_state;
};
const manifestFor = () => ({
  schema_version: 1,
  request: {
    scenario: "sustained_session", condition: "sustained", corpus_id: `sha256-${documentSha256.slice(0, 16)}`,
    revisions: { app: "worktree", corpus: `sha256-${documentSha256.slice(0, 16)}`,
      runtime: "mlx-audio-swift-v0.1.3", model: "kokoro-82m-4bit-e4468a46" },
    expected_repetitions: 1, expected_duration_ms: 7_200_000,
  },
  document: { input, language: "es", unit: "paragraph", narration_unit_limit: narrationUnitLimit },
  tts: { model_id: "kokoro-82m-4bit", model_revision: "e4468a460f6f70b9125a003e0adb1ab7d4904bbd",
    runtime_id: "mlx-audio-swift", runtime_version: "v0.1.3", voice_id: "ef_dora" },
});

mkdirSync(outputRoot, { recursive: true });
const started = performance.now();
const initialVm = vmCounters();
const samples = [];
const operations = [];
let maxRssBytes = 0;
let maxCpuPercent = 0;
let sampler;
let activeChild;
const sample = () => {
  if (!activeChild?.pid) return;
  const tree = processTree(activeChild.pid);
  const vm = vmCounters();
  const item = {
    monotonic_elapsed_ms: Math.round(performance.now() - started), rss_bytes: tree.rss_bytes,
    cpu_percent: tree.cpu_percent, swapin_pages_delta: vm.swapins_pages - initialVm.swapins_pages,
    swapout_pages_delta: vm.swapouts_pages - initialVm.swapouts_pages,
    page_size_bytes: vm.page_size_bytes, thermal_state: thermalState(),
    disk_available_bytes: diskAvailableBytes(),
  };
  maxRssBytes = Math.max(maxRssBytes, item.rss_bytes);
  maxCpuPercent = Math.max(maxCpuPercent, item.cpu_percent);
  samples.push(item);
};

try {
  sampler = setInterval(sample, 1_000);
  let index = 0;
  while (performance.now() - started < durationMs) {
    const directory = join(outputRoot, `operation-${String(++index).padStart(4, "0")}`);
    mkdirSync(directory, { recursive: true });
    const manifest = join(directory, ".manifest.json");
    writeFileSync(manifest, JSON.stringify(manifestFor()));
    const began = performance.now(); let stdout = ""; let stderr = "";
    activeChild = spawn(lectura, ["gate-a", "run", "--manifest", manifest, "--output", directory, "--json"],
      { env, stdio: ["ignore", "pipe", "pipe"] });
    activeChild.stdout.on("data", (chunk) => { stdout += chunk; });
    activeChild.stderr.on("data", (chunk) => { stderr += chunk; });
    const exitCode = await new Promise((done) => activeChild.on("close", done));
    sample();
    activeChild = undefined;
    rmSync(manifest, { force: true });
    if (exitCode !== 0) throw new Error(`operation ${index} failed (${exitCode}): ${stderr.trim()}`);
    const summary = JSON.parse(readFileSync(join(directory, "summary.json"), "utf8"));
    const rtf = metric(summary, "real_time_factor");
    const transport = metric(summary, "transport_ack");
    operations.push({
      operation: index, wall_ms: Math.round(performance.now() - began),
      audio_ms: rtf.denominator, synthesis_ms: rtf.numerator,
      real_time_factor: rtf.numerator / rtf.denominator,
      boundary_transport_ms: transport.numerator,
      model_load_inference_fragment_write: "combined_by_mlx_audio_swift_v0.1.3",
      audio_copy_assembly_write: "combined_by_model_services",
    });
  }
} finally {
  clearInterval(sampler);
}

const elapsedMs = Math.round(performance.now() - started);
const finalVm = vmCounters();
const totalAudioMs = operations.reduce((total, item) => total + item.audio_ms, 0);
const totalSynthesisMs = operations.reduce((total, item) => total + item.synthesis_ms, 0);
const finalThermal = thermalState();
const nfr5 = {
  tts_rtf_max: 0.5, operation_memory_max_bytes: 6 * 1024 ** 3,
  thermal_critical_forbidden: true, sustained_swap_forbidden: true,
};
const criticalThermal = samples.some((item) => item.thermal_state === "critical") || finalThermal === "critical";
const swapPages = finalVm.swapouts_pages - initialVm.swapouts_pages;
const report = {
  schema_version: 1, scenario: "sustained_session", duration_minutes_requested: durationMinutes,
  elapsed_ms: elapsedMs, continuous_wall_time_met: elapsedMs >= durationMs,
  document_sha256: documentSha256, runtime: "mlx-audio-swift-v0.1.3", model: "kokoro-82m-4bit-e4468a46",
  operation_policy: "one sequential gate-a operation; no overlapping model processes",
  environment: {
    hardware: execFileSync("sysctl", ["-n", "hw.model"], { encoding: "utf8" }).trim(),
    macos: execFileSync("sw_vers", ["-productVersion"], { encoding: "utf8" }).trim(),
    energy: execFileSync("pmset", ["-g", "batt"], { encoding: "utf8" }).trim(),
  },
  components: {
    model_load_inference_fragment_write: "runtime reports a single completed synthesis interval; no false sub-phase split",
    audio_copy_assembly_write: "ModelServices does not expose an independent timer; retained as combined",
    boundary_transport: "parent CLI wall interval per operation",
  },
  operations, samples, maxima: { rss_bytes: maxRssBytes, cpu_percent: maxCpuPercent },
  swap: {
    source: "vm_stat", page_size_bytes: initialVm.page_size_bytes,
    swapin_pages_delta: finalVm.swapins_pages - initialVm.swapins_pages, swapout_pages_delta: swapPages,
    swapout_bytes_delta: swapPages * initialVm.page_size_bytes,
  },
  thermal: { source: "ProcessInfo.thermalState in macOS worker", final_state: finalThermal, critical_observed: criticalThermal },
  aggregate: { audio_ms: totalAudioMs, synthesis_ms: totalSynthesisMs, real_time_factor: totalSynthesisMs / Math.max(1, totalAudioMs) },
  nfr5: { ...nfr5, checks: {
    real_time_factor: totalSynthesisMs / Math.max(1, totalAudioMs) <= nfr5.tts_rtf_max,
    memory: maxRssBytes <= nfr5.operation_memory_max_bytes,
    thermal: !criticalThermal,
    swap: swapPages === 0,
  } },
};
writeFileSync(join(outputRoot, "sustained-summary.json"), `${JSON.stringify(report, null, 2)}\n`);
process.stdout.write(`${JSON.stringify({ elapsed_ms: elapsedMs, operations: operations.length, nfr5: report.nfr5 })}\n`);
