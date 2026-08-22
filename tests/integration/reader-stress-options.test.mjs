import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import test from "node:test";

test("rejects an iteration watchdog shorter than a real large-PDF run", () => {
  const result = spawnSync(
    process.execPath,
    [
      "scripts/measure-reader-sustained.mjs",
      "--output", "/tmp/unused-reader-stress.json",
      "--input-root", "/tmp",
      "--duration-minutes", "1",
      "--iteration-timeout-seconds", "300",
    ],
    { encoding: "utf8" },
  );

  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /iteration-timeout-seconds must be at least 600/);
});

test("holds one XCTest session for the full sustained duration", () => {
  const source = readFileSync("scripts/measure-reader-sustained.mjs", "utf8");
  assert.match(source, /LECTURA_STRESS_DURATION_SECONDS/);
  assert.match(source, /try \{\s*await runIteration\(\);\s*\}/);
  assert.doesNotMatch(source, /while \(performance\.now\(\) - started < durationMs\)/);
});
