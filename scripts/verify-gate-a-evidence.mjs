#!/usr/bin/env node

import { createHash } from "node:crypto";
import { isDeepStrictEqual } from "node:util";
import { readFileSync } from "node:fs";
import { join, resolve } from "node:path";

const values = process.argv.slice(2);
const directoryIndex = values.indexOf("--directory");
if (directoryIndex < 0 || !values[directoryIndex + 1]) {
  throw new Error("usage: verify-gate-a-evidence.mjs --directory <run> [--forbid <sentinel>]...");
}
const directory = resolve(values[directoryIndex + 1]);
const forbidden = values.flatMap((value, index) => value === "--forbid" ? [values[index + 1]] : [])
  .filter(Boolean);
const bytes = (name) => readFileSync(join(directory, name));
const hash = (value) => createHash("sha256").update(value).digest("hex");
const environmentBytes = bytes("environment.json");
const metricsBytes = bytes("metrics.jsonl");
const summaryBytes = bytes("summary.json");
const summary = JSON.parse(summaryBytes);
if (summary.validation_run.artifacts.environment_sha256 !== hash(environmentBytes)
  || summary.validation_run.artifacts.metrics_sha256 !== hash(metricsBytes)) {
  throw new Error("artifact hash mismatch");
}
const canonicalSummary = summaryBytes.toString("utf8").replace(
  /("summary_sha256":\s*)"[0-9a-f]{64}"/,
  `$1"${"0".repeat(64)}"`,
);
if (summary.validation_run.artifacts.summary_sha256 !== hash(canonicalSummary)) {
  throw new Error("summary hash mismatch");
}
const metrics = JSON.parse(metricsBytes);
if (!metrics.metrics.every((metric) => metric.denominator > 0)
  || !summary.metrics.every((metric) => metric.denominator > 0)
  || !isDeepStrictEqual(metrics.metrics, summary.metrics)
  || !isDeepStrictEqual(metrics.resources, summary.resources)) {
  throw new Error("metrics denominator or summary mismatch");
}
const persisted = [environmentBytes, metricsBytes, summaryBytes]
  .map((value) => value.toString("utf8")).join("\n");
for (const sentinel of forbidden) if (persisted.includes(sentinel)) {
  throw new Error("forbidden sentinel persisted");
}
process.stdout.write(`${JSON.stringify({ verified: true, forbidden_checked: forbidden.length })}\n`);
