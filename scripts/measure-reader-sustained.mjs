#!/usr/bin/env node

import { execFileSync, spawn } from "node:child_process";
import {
  existsSync, lstatSync, mkdirSync, readFileSync, readdirSync, renameSync, unlinkSync, writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { performance } from "node:perf_hooks";

const values = process.argv.slice(2);
const value = (name) => {
  const index = values.indexOf(`--${name}`);
  return index < 0 ? undefined : values[index + 1];
};
const output = value("output");
const inputRoot = value("input-root");
const durationMinutes = Number(value("duration-minutes"));
const iterationTimeoutSeconds = Number(value("iteration-timeout-seconds") ?? 600);
if (!output || !inputRoot || !Number.isInteger(durationMinutes) || durationMinutes < 1) {
  throw new Error("usage: measure-reader-sustained.mjs --output <json> --input-root <real-pdf-corpus> --duration-minutes <n> [--iteration-timeout-seconds 600]");
}
if (!Number.isInteger(iterationTimeoutSeconds) || iterationTimeoutSeconds < 600) {
  throw new Error("iteration-timeout-seconds must be at least 600");
}
if (!process.env.DEVELOPER_DIR) throw new Error("DEVELOPER_DIR is required");

const project = resolve(import.meta.dirname, "..");
const worker = join(project, "target/lectura-macos-worker");
const derivedData = process.env.LECTURA_DERIVED_DATA
  ?? "/Volumes/Extreme SSD/LecturaFluida-DerivedData";
const storageRoot = join(
  homedir(),
  "Library/Containers/com.lecturafluida.app/Data/Library/Application Support/LecturaFluida/sessions",
);
const durationMs = durationMinutes * 60_000;
let active;
let iterations = 0;
let maxAppRssBytes = 0;
let criticalThermalObserved = false;
let lastThermalState = "unavailable";
let maxIterationWallMs = 0;
const uiMetricsPath = `/private/tmp/lectura-reader-stress-${process.pid}.json`;
if (existsSync(uiMetricsPath)) unlinkSync(uiMetricsPath);
const documents = pdfs(resolve(inputRoot));
if (documents.length === 0) throw new Error("input-root contains no PDFs");

const commonXcodeArguments = [
  "-quiet", "-project", "apps/macos/LecturaFluida.xcodeproj", "-scheme", "LecturaFluida",
  "-derivedDataPath", derivedData,
  "-testPlan", "CI-Fast", "-configuration", "Release", "-destination", "platform=macOS,arch=arm64",
  "-only-testing:LecturaMacUITests/ReaderWindowUITests/testLongDocumentLifecycleIterationWhenRequested",
  "CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_IDENTITY=-", "ENABLE_TESTABILITY=YES",
  "SWIFT_TREAT_WARNINGS_AS_ERRORS=YES", "SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) STRESS_TEST",
];
execFileSync("xcodebuild", ["build-for-testing", ...commonXcodeArguments], {
  cwd: project, env: process.env, stdio: "inherit",
});
const xcodeArguments = ["test-without-building", ...commonXcodeArguments];
const started = performance.now();
const initialVm = vmCounters();
const initialStorageBytes = storageBytes(storageRoot);

function pdfs(path) {
  if (!existsSync(path)) return [];
  const stat = lstatSync(path);
  if (stat.isSymbolicLink()) return [];
  if (stat.isFile()) return path.toLowerCase().endsWith(".pdf") ? [path] : [];
  return readdirSync(path).flatMap((name) => pdfs(join(path, name))).sort();
}

function vmCounters() {
  const text = execFileSync("vm_stat", [], { encoding: "utf8" });
  const pageSize = Number(text.match(/page size of (\d+) bytes/)?.[1] ?? 0);
  const pages = Number(text.match(/Swapouts:\s+(\d+)\./)?.[1] ?? 0);
  return { pageSize, pages };
}

function thermalState() {
  if (!existsSync(worker)) return "unavailable";
  const request = '{"schema_version":1,"request_id":"reader_stress","command":"system_sample","payload":{}}\n';
  const response = execFileSync(worker, [], { input: request, encoding: "utf8" });
  return JSON.parse(response).result.system.thermal_state;
}

function storageBytes(path) {
  if (!existsSync(path)) return 0;
  const stat = lstatSync(path);
  if (stat.isSymbolicLink()) return 0;
  if (stat.isFile()) return stat.size;
  return readdirSync(path).reduce((total, name) => total + storageBytes(join(path, name)), 0);
}

function appRssBytes() {
  const rows = execFileSync("ps", ["-axo", "rss=,command="], { encoding: "utf8" }).split("\n");
  const row = rows.find((line) => line.includes("/LecturaFluida.app/Contents/MacOS/LecturaFluida"));
  return Number(row?.trim().split(/\s+/, 1)[0] ?? 0) * 1_024;
}

function sample() {
  maxAppRssBytes = Math.max(maxAppRssBytes, appRssBytes());
  lastThermalState = thermalState();
  criticalThermalObserved ||= lastThermalState === "critical";
}

async function runIteration() {
  const began = performance.now();
  const document = documents[iterations % documents.length];
  active = spawn("xcodebuild", [
    ...xcodeArguments,
    "LECTURA_STRESS_ITERATION=1",
    `LECTURA_STRESS_DURATION_SECONDS=${durationMinutes * 60}`,
    `LECTURA_STRESS_METRICS_PATH=${uiMetricsPath}`,
    `LECTURA_STRESS_DOCUMENT=${document}`,
  ], {
    cwd: project, env: process.env, stdio: ["ignore", "ignore", "pipe"],
  });
  let stderr = "";
  active.stderr.on("data", (chunk) => { stderr = `${stderr}${chunk}`.slice(-2_000); });
  const timeoutSeconds = Math.max(iterationTimeoutSeconds, durationMinutes * 60 + 600);
  const timer = setTimeout(() => active.kill("SIGINT"), timeoutSeconds * 1_000);
  const code = await new Promise((done) => active.on("close", done));
  clearTimeout(timer);
  active = undefined;
  if (code !== 0) throw new Error(`iteration ${iterations + 1} failed (${code}): ${stderr}`);
  maxIterationWallMs = Math.max(maxIterationWallMs, Math.round(performance.now() - began));
  iterations += 1;
}

const sampler = setInterval(sample, 1_000);
try {
  await runIteration();
} finally {
  clearInterval(sampler);
  if (active) active.kill("SIGINT");
}
sample();
const uiMetrics = JSON.parse(readFileSync(uiMetricsPath, "utf8"));
unlinkSync(uiMetricsPath);
const finalVm = vmCounters();
const elapsedMs = Math.round(performance.now() - started);
const swapoutBytesDelta = Math.max(0, finalVm.pages - initialVm.pages) * initialVm.pageSize;
const finalStorageBytes = storageBytes(storageRoot);
const checks = {
  continuous_wall_time: elapsedMs >= durationMs,
  iterations: iterations > 0,
  memory: maxAppRssBytes > 0 && maxAppRssBytes <= 3 * 1_024 ** 3,
  swap: swapoutBytesDelta === 0,
  thermal: lastThermalState !== "unavailable" && !criticalThermalObserved,
  ui_actions: uiMetrics.navigation_cycles > 0
    && uiMetrics.surface_switches >= 2
    && uiMetrics.recovery_cycle_completed === true,
};
const report = {
  schema_version: 1,
  scenario: "reader_long_document_lifecycle",
  duration_minutes_requested: durationMinutes,
  elapsed_ms: elapsedMs,
  iterations,
  corpus_document_count: documents.length,
  max_iteration_wall_ms: maxIterationWallMs,
  max_ui_response_ms: uiMetrics.max_ui_response_ms,
  navigation_cycles: uiMetrics.navigation_cycles,
  surface_switches: uiMetrics.surface_switches,
  max_app_rss_bytes: maxAppRssBytes,
  swapout_bytes_delta: swapoutBytesDelta,
  thermal_critical_observed: criticalThermalObserved,
  final_thermal_state: lastThermalState,
  derived_storage_bytes: finalStorageBytes,
  derived_storage_bytes_delta: Math.max(0, finalStorageBytes - initialStorageBytes),
  checks,
};
const destination = resolve(output);
mkdirSync(dirname(destination), { recursive: true });
writeFileSync(`${destination}.tmp`, `${JSON.stringify(report, null, 2)}\n`);
renameSync(`${destination}.tmp`, destination);
process.stdout.write(`${JSON.stringify({ elapsed_ms: elapsedMs, iterations, checks })}\n`);
if (Object.values(checks).includes(false)) process.exitCode = 1;
