import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import {
  chmodSync,
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import test from "node:test";

const project = resolve(import.meta.dirname, "..");
const verifier = join(project, "scripts/verify-runtime-manifest.sh");
const signer = join(project, "scripts/sign-release-app.sh");
const notaryGate = join(project, "scripts/verify-notarized-app.sh");

function sha256(data) {
  return createHash("sha256").update(data).digest("hex");
}

function runtimeFixture(root) {
  const roots = {
    models: join(root, "models"),
    espeak: join(root, "espeak"),
    pcaudio: join(root, "pcaudio"),
  };
  const runtime = Buffer.from("verified runtime");
  const voice = Buffer.from("verified dictionary");
  const audio = Buffer.from("verified audio library");
  const files = [
    [roots.models, "runtime/runtime-bin", runtime],
    [roots.espeak, "share/espeak-ng-data/es_dict", voice],
    [roots.pcaudio, "lib/libpcaudio.dylib", audio],
  ];
  for (const [base, relative, data] of files) {
    const destination = join(base, relative);
    mkdirSync(dirname(destination), { recursive: true });
    writeFileSync(destination, data);
  }
  const treeLine = `es_dict\t${voice.length}\t${sha256(voice)}\n`;
  const manifestData = {
    schema_version: 1,
    id: "lectura-embedded-runtimes-v1",
    components: [
      {
        id: "tts-runtime",
        kind: "file",
        source_root: "models",
        relative_path: "runtime/runtime-bin",
        bundled_path: "Helpers/runtime-bin",
        origin_url: "https://example.invalid/runtime",
        revision: "fixture-revision",
        file_count: 1,
        size_bytes: runtime.length,
        sha256_hex: sha256(runtime),
      },
      {
        id: "espeak-data",
        kind: "tree",
        source_root: "espeak",
        relative_path: "share/espeak-ng-data",
        bundled_path: "Resources/espeak-ng-data",
        origin_url: "https://example.invalid/espeak",
        revision: "fixture-revision",
        file_count: 1,
        size_bytes: voice.length,
        sha256_hex: sha256(treeLine),
      },
      {
        id: "pcaudio",
        kind: "file",
        source_root: "pcaudio",
        relative_path: "lib/libpcaudio.dylib",
        bundled_path: "Helpers/libpcaudio.dylib",
        origin_url: "https://example.invalid/pcaudio",
        revision: "fixture-revision",
        file_count: 1,
        size_bytes: audio.length,
        sha256_hex: sha256(audio),
      },
    ],
  };
  const manifest = join(root, "runtime-manifest.json");
  writeFileSync(manifest, `${JSON.stringify(manifestData, null, 2)}\n`);
  return { manifest, manifestData, roots, runtime };
}

function verify(fixture, stage, manifest = fixture.manifest) {
  return spawnSync(
    verifier,
    [manifest, fixture.roots.models, fixture.roots.espeak, fixture.roots.pcaudio, stage],
    { encoding: "utf8" },
  );
}

test("stages only runtimes whose path, size and SHA-256 match the manifest", () => {
  const root = mkdtempSync(join(tmpdir(), "lf-runtime-package-"));
  try {
    const fixture = runtimeFixture(root);
    const validStage = join(root, "valid-stage");
    const valid = verify(fixture, validStage);
    assert.equal(valid.status, 0, valid.stderr || valid.error?.message);
    assert.deepEqual(readFileSync(join(validStage, "Helpers/runtime-bin")), fixture.runtime);

    writeFileSync(join(fixture.roots.models, "runtime/runtime-bin"), "verifieD runtime");
    const corruptStage = join(root, "corrupt-stage");
    assert.notEqual(verify(fixture, corruptStage).status, 0);
    assert.equal(existsSync(corruptStage), false);
    writeFileSync(join(fixture.roots.models, "runtime/runtime-bin"), fixture.runtime);

    const badSize = structuredClone(fixture.manifestData);
    badSize.components[0].size_bytes += 1;
    const badSizeManifest = join(root, "bad-size.json");
    writeFileSync(badSizeManifest, JSON.stringify(badSize));
    assert.notEqual(verify(fixture, join(root, "bad-size-stage"), badSizeManifest).status, 0);

    const badPath = structuredClone(fixture.manifestData);
    badPath.components[0].relative_path = "../runtime-bin";
    const badPathManifest = join(root, "bad-path.json");
    writeFileSync(badPathManifest, JSON.stringify(badPath));
    assert.notEqual(verify(fixture, join(root, "bad-path-stage"), badPathManifest).status, 0);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

function appFixture(root, name) {
  const app = join(root, `${name}.app`);
  const executable = join(app, "Contents/MacOS/LecturaFluida");
  mkdirSync(dirname(executable), { recursive: true });
  copyFileSync("/usr/bin/true", executable);
  chmodSync(executable, 0o755);
  writeFileSync(
    join(app, "Contents/Info.plist"),
    `<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>LecturaFluida</string>
<key>CFBundleIdentifier</key><string>com.lecturafluida.fixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>\n`,
  );
  return app;
}

test("labels ad hoc honestly and fails developer-id closed without external authority", () => {
  const root = mkdtempSync(join(tmpdir(), "lf-runtime-signing-"));
  try {
    const missingChannel = spawnSync(signer, [appFixture(root, "missing-channel")], {
      encoding: "utf8",
    });
    assert.notEqual(missingChannel.status, 0);

    const app = appFixture(root, "adhoc");
    const adhoc = spawnSync(signer, [app], {
      encoding: "utf8",
      env: { ...process.env, LECTURA_RELEASE_CHANNEL: "adhoc" },
    });
    assert.equal(adhoc.status, 0, adhoc.stderr || adhoc.error?.message);
    assert.match(adhoc.stdout, /channel=adhoc hardened_runtime=false notarized=false/);
    assert.equal(statSync(app).isDirectory(), true);
    const falseNotarization = spawnSync(notaryGate, [app], {
      encoding: "utf8",
      env: {
        ...process.env,
        LECTURA_RELEASE_CHANNEL: "developer-id",
        LECTURA_CODESIGN_IDENTITY: "Developer ID Application: Fixture (TEAMID)",
      },
    });
    assert.equal(falseNotarization.error, undefined, falseNotarization.error?.message);
    assert.notEqual(falseNotarization.status, 0);
    assert.doesNotMatch(falseNotarization.stdout ?? "", /notarized=true/);

    const developerID = spawnSync(signer, [appFixture(root, "developer-id")], {
      encoding: "utf8",
      env: { ...process.env, LECTURA_RELEASE_CHANNEL: "developer-id" },
    });
    assert.notEqual(developerID.status, 0);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
