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
      "--model-root", "/tmp",
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

test("the Epic 5 gate requires models and reports translated narration activity", () => {
  const source = readFileSync("scripts/measure-reader-sustained.mjs", "utf8");
  const project = readFileSync("apps/macos/LecturaFluida.xcodeproj/project.pbxproj", "utf8");
  assert.match(source, /--model-root/);
  assert.match(source, /LECTURA_STRESS_MODEL_ROOT/);
  assert.match(source, /translated_units_played/);
  assert.match(source, /narration_source_switches/);
  assert.match(source, /pause_resume_cycles/);
  assert.match(project, /Embed Stress Runtimes/);
  assert.match(project, /embed-runtimes\.sh/);
  assert.match(project, /LECTURA_RELEASE_CHANNEL=adhoc/);
  assert.match(project, /LECTURA_EMBED_OUTER_SIGNING=xcode/);
});

test("runs the sustained app session with outbound networking denied", () => {
  const source = readFileSync("scripts/measure-reader-sustained.mjs", "utf8");
  const project = readFileSync("apps/macos/LecturaFluida.xcodeproj/project.pbxproj", "utf8");
  const entitlements = readFileSync(
    "apps/macos/Config/LecturaFluidaOffline.entitlements", "utf8",
  );
  assert.match(source, /LECTURA_APP_ENTITLEMENTS=Config\/LecturaFluidaOffline\.entitlements/);
  assert.match(project, /CODE_SIGN_ENTITLEMENTS = "\$\(LECTURA_APP_ENTITLEMENTS\)"/);
  assert.doesNotMatch(entitlements, /com\.apple\.security\.network\.client/);
  assert.match(source, /outbound_network_blocked: true/);
});

test("maps every Epic 5 stress control into the XCTest environment", () => {
  const source = readFileSync("scripts/measure-reader-sustained.mjs", "utf8");
  const plan = readFileSync("apps/macos/TestPlans/CI-Fast.xctestplan", "utf8");
  assert.match(plan, /"key": "LECTURA_STRESS_MODEL_ROOT"/);
  assert.match(plan, /"value": "\$\(LECTURA_STRESS_MODEL_ROOT\)"/);
  assert.match(source, /stress XCTest completed without metrics/);
  assert.match(source, /-resultBundlePath/);
  assert.match(source, /xcresulttool", "export", "attachments/);
  assert.match(source, /reader-stress-metrics_/);
  assert.match(source, /flatMap\(\(\{ attachments = \[\] \}\) => attachments\)/);
});

test("removes transient result bundles when the sustained run fails or is interrupted", () => {
  const source = readFileSync("scripts/measure-reader-sustained.mjs", "utf8");
  assert.match(source, /process\.once\("exit", cleanTransientArtifacts\)/);
  assert.match(source, /\[\["SIGHUP", 129\], \["SIGINT", 130\], \["SIGTERM", 143\]\]/);
  assert.match(source, /active\?\.kill\(signal\)/);
  assert.match(source, /rmSync\(resultBundlePath, \{ recursive: true, force: true \}\)/);
  assert.match(source, /rmSync\(attachmentsPath, \{ recursive: true, force: true \}\)/);
});

test("grants the sustained UI test enough XCTest execution time", () => {
  const source = readFileSync("apps/macos/LecturaMacUITests/CanaryWindowUITests.swift", "utf8");
  assert.match(
    source,
    /name\.contains\("testLongDocumentLifecycleIterationWhenRequested"\)/,
  );
  assert.match(source, /LECTURA_STRESS_DURATION_SECONDS/);
});

test("waits for the surface selected by the stress build", () => {
  const source = readFileSync("apps/macos/LecturaMacUITests/CanaryWindowUITests.swift", "utf8");
  const viewModel = readFileSync("apps/macos/LecturaMacApp/Reader/ReaderViewModel.swift", "utf8");
  const stressTest = source.split("func testLongDocumentLifecycleIterationWhenRequested()", 2)[1]
    .split("func test", 1)[0];
  assert.match(stressTest, /openDocument[\s\S]{0,120}reader\.immersion/);
  assert.doesNotMatch(stressTest, /reader\.immersion[\s\S]{0,120}dismissTutorialIfShown/);
  assert.match(stressTest, /narration\.next/);
  assert.match(stressTest, /narration\.previous/);
  assert.doesNotMatch(stressTest, /typeKey\(forward \? \.rightArrow : \.leftArrow/);
  assert.match(stressTest, /XCTAssertEqual\([\s\S]{0,120}positionBeforeRetry/);
  assert.doesNotMatch(stressTest, /menuItems\["English"\]/);
  assert.match(stressTest, /app\.typeKey\(\.downArrow/);
  assert.match(stressTest, /translation\.request\.start[\s\S]{0,120}isEnabled/);
  assert.match(stressTest, /translation\.requested[\s\S]{0,120}waitForExistence/);
  assert.match(stressTest, /translationAnchor\.click\(\)/);
  assert.match(stressTest, /the long document produced no visible reading unit/);
  assert.match(stressTest, /recovery left no visible reading anchor/);
  assert.match(stressTest, /translation removed the visible reading unit/);
  assert.match(stressTest, /the installed narration model was not ready/);
  assert.match(stressTest, /translated narration did not reach playback/);
  assert.match(stressTest, /label == 'Reading aloud' AND value == 'Translation'/);
  assert.match(stressTest, /narration\.source\.translation/);
  assert.match(stressTest, /app\.buttons\["narration\.toggle"\]\.click\(\)/);
  assert.match(stressTest, /app\.scrollViews\["reader\.immersion"\]\.scroll/);
  assert.match(stressTest, /translation\.progress\.running/);
  assert.match(stressTest, /guard !translationFailed\.exists else/);
  assert.match(source, /reader\.view\.pdf\.option/);
  assert.match(source, /reader\.view\.immersion\.option/);
  assert.match(
    viewModel,
    /currentUnitID\.map\(\{ id in !normalized\.units\.contains \{ \$0\.unitID == id \} \}\) \?\? true/,
  );
  assert.match(viewModel, /failTranslationStart\("translation_window_empty"\)/);
  assert.match(viewModel, /failTranslationStart\("eligible_units_missing"\)/);
});

test("the long-document corpus does not repeat body text as page furniture", () => {
  const pdf = readFileSync("tests/corpus/documents/long-1000-pages.pdf", "latin1");
  const bodies = [...pdf.matchAll(/\(Este parrafo [^)]+\) Tj/g)].map(([text]) => text);
  assert.equal(bodies.length, 1_000);
  assert.equal(new Set(bodies).size, 1_000);
});
