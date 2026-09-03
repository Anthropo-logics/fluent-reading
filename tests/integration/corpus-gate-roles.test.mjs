import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

test("keeps matrix and long-form corpora in their explicit gates", () => {
  const quickGate = readFileSync("tests/integration/DigitalCorpusProcess.sh", "utf8");
  const sustainedGate = readFileSync("scripts/measure-reader-sustained.mjs", "utf8");
  const manifest = JSON.parse(readFileSync("tests/corpus/manifest.json", "utf8"));
  const scripts = JSON.parse(readFileSync("package.json", "utf8")).scripts;

  assert.match(quickGate, /\.role == "matrix"/);
  assert.doesNotMatch(quickGate, /select\(\.classification\.content == "digital"\)/);
  assert.ok(manifest.entries.some(({ role }) => role === "long_form"));
  assert.match(scripts["test:long-form"], /measure-reader-sustained\.mjs/);
  assert.match(scripts["test:long-form"], /--corpus-role long_form/);
  assert.match(sustainedGate, /-configuration", "Release"/);
  assert.match(sustainedGate, /manifestPdfs/);
});
