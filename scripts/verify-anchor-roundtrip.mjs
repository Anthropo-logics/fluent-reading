#!/usr/bin/env node
import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const usage =
  "usage: verify-anchor-roundtrip --input <pdf> --language <es|en|pt> --lectura <bin> --worker <bin> --output <report.json> --case <digital|multi_column|scanned|mixed>:<page[,page]>:<route|mixed>:<count> [...]";

export function parseCase(value) {
  const [type, pages, route, count] = value.split(":");
  const pageIndexes = pages?.split(",").map(Number);
  if (
    !["digital", "multi_column", "scanned", "mixed"].includes(type)
    || !pageIndexes?.length
    || pageIndexes.some((page) => !Number.isInteger(page) || page < 0)
    || !["direct_text", "ocr", "mixed"].includes(route)
    || !Number.isInteger(Number(count))
    || Number(count) < 1
  ) throw new Error(`invalid case: ${value}`);
  return { type, pageIndexes, route, count: Number(count) };
}

function sourceRegion(unit, anchor) {
  const region = unit.source_regions?.[anchor.source_region_index];
  if (!region || !Array.isArray(region.rect_pdf_points)) return null;
  return region;
}

function reportAnchor(documentID, page, unit, anchor) {
  const region = sourceRegion(unit, anchor);
  const initial = { view: "pdf", narration: "original", documentID, anchor, viewport: [720, 520] };
  const immersion = { ...initial, view: "immersion" };
  const resized = { ...immersion, viewport: [1100, 760] };
  const returned = { ...resized, view: "pdf" };
  const sameIdentity =
    returned.documentID === initial.documentID
    && returned.anchor.unit_id === initial.anchor.unit_id
    && returned.anchor.generation_id === initial.anchor.generation_id;
  return {
    page_index: page.record.page_index,
    unit_id: anchor.unit_id,
    generation_id: anchor.generation_id,
    state_trace: ["pdf/original", "immersion/original", "immersion/resized", "pdf/original"],
    identity: sameIdentity ? "preserved" : "lost",
    region: region ? (region.confidence >= 0.75 ? "reliable" : "unreliable") : "unavailable",
  };
}

export function verifyRoundTrips(document, cases) {
  const reports = cases.map((selection) => {
    const pages = document.pages.filter((page) => selection.pageIndexes.includes(page.record.page_index));
    const routes = new Set(pages.map((page) => page.record.route));
    let expectedRoute = selection.route === "mixed"
      ? routes.has("direct_text") && routes.has("ocr")
      : pages.length === selection.pageIndexes.length && [...routes].every((route) => route === selection.route);
    const candidates = pages.flatMap((page) =>
      page.anchors.map((anchor) => ({ page, anchor, unit: page.units.find((unit) => unit.unit_id === anchor.unit_id) })),
    ).filter(({ unit }) => unit);
    if (selection.type === "multi_column") {
      const x = candidates.flatMap(({ unit }) => unit.source_regions.map((region) => region.rect_pdf_points?.[0]));
      expectedRoute &&= x.length > 1 && Math.max(...x) - Math.min(...x) >= 200;
    }
    const anchors = candidates.slice(0, selection.count).map(({ page, anchor, unit }) =>
      reportAnchor(document.document_id, page, unit, anchor));
    const failures = anchors.filter((anchor) => anchor.identity !== "preserved" || anchor.region === "unavailable");
    return {
      type: selection.type,
      requested: selection.count,
      selected: anchors.length,
      route: expectedRoute ? "matched" : "mismatched",
      anchors,
      status: expectedRoute && anchors.length === selection.count && failures.length === 0 ? "passed" : "failed",
    };
  });
  return { document_id: document.document_id, cases: reports, passed: reports.every((report) => report.status === "passed") };
}

function args(argv) {
  const values = { cases: [] };
  for (let index = 2; index < argv.length; index += 2) {
    const key = argv[index];
    const value = argv[index + 1];
    if (!value || !key.startsWith("--")) throw new Error(usage);
    if (key === "--case") values.cases.push(parseCase(value));
    else values[key.slice(2)] = value;
  }
  if (!["input", "language", "lectura", "worker", "output"].every((key) => values[key]) || values.cases.length === 0) {
    throw new Error(usage);
  }
  if (!["es", "en", "pt"].includes(values.language)) throw new Error(usage);
  return values;
}

function atomicJSON(path, value) {
  mkdirSync(dirname(path), { recursive: true });
  const temporary = `${path}.tmp-${process.pid}`;
  writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
  renameSync(temporary, path);
}

function main() {
  const options = args(process.argv);
  const result = spawnSync(
    options.lectura,
    ["pdf", "process", "--input", options.input, "--language", options.language, "--unit", "sentence", "--json"],
    {
      encoding: "utf8",
      maxBuffer: 32 * 1024 * 1024,
      env: { ...process.env, LECTURA_MACOS_WORKER: options.worker },
    },
  );
  if (result.status !== 0 || result.stderr || result.stdout.split("\n").filter(Boolean).length !== 1) {
    throw new Error("worker did not return one completed LF event");
  }
  const event = JSON.parse(result.stdout);
  if (event.kind !== "completed" || !event.result) throw new Error("document processing failed");
  const report = verifyRoundTrips(event.result, options.cases);
  atomicJSON(resolve(options.output), {
    schema_version: 1,
    corpus_sha256: createHash("sha256").update(readFileSync(options.input)).digest("hex"),
    ...report,
  });
  if (!report.passed) process.exitCode = 4;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try { main(); } catch (error) { process.stderr.write(`anchor-roundtrip: ${error.message}\n`); process.exitCode = 64; }
}
