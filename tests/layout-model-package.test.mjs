import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import {
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import test from "node:test";

const project = resolve(import.meta.dirname, "..");
const embedder = join(project, "scripts/embed-layout-model.sh");
const paths = [
  "analytics/coremldata.bin",
  "coremldata.bin",
  "model.mil",
  "weights/weight.bin",
];

function sha256(data) {
  return createHash("sha256").update(data).digest("hex");
}

function fixture(root) {
  const source = join(root, "PPDocLayoutV3-fp32.mlmodelc");
  const licenseText = Buffer.from("Apache License fixture\nVersion 2.0, January 2004\n");
  const license = join(root, "licenses/PPDocLayoutV3-Apache-2.0.txt");
  mkdirSync(dirname(license), { recursive: true });
  writeFileSync(license, licenseText);
  const contents = new Map([
    [paths[0], Buffer.from("analytics")],
    [paths[1], Buffer.from("metadata")],
    [paths[2], Buffer.from("model program")],
    [paths[3], Buffer.from("fixed weights")],
  ]);
  for (const [relativePath, data] of contents) {
    const destination = join(source, relativePath);
    mkdirSync(dirname(destination), { recursive: true });
    writeFileSync(destination, data);
  }
  const manifest = join(root, "manifests/pp-doclayout-v3-coreml.json");
  mkdirSync(dirname(manifest), { recursive: true });
  writeFileSync(
    manifest,
    `${JSON.stringify(
      {
        schema_version: 1,
        id: "pp-doclayout-v3-coreml",
        model_revision: "fixture-revision",
        source_model: "PaddlePaddle/PP-DocLayoutV3_safetensors",
        source_revision: "fixture-revision",
        source_weights_sha256: "0".repeat(64),
        purpose: "document_layout",
        authors: ["PaddlePaddle"],
        license_id: "Apache-2.0",
        license_text_path: "../licenses/PPDocLayoutV3-Apache-2.0.txt",
        license_text_resource: "PPDocLayoutV3-Apache-2.0.txt",
        license_text_sha256: sha256(licenseText),
        source_license_evidence_url:
          "https://huggingface.co/PaddlePaddle/PP-DocLayoutV3_safetensors/blob/fixture-revision/README.md",
        source_notice_present: false,
        usage_restrictions: [],
        runtime_id: "Core ML",
        runtime_version: "macOS 15+",
        quantization: "fp32",
        bundled_directory: "PPDocLayoutV3-fp32.mlmodelc",
        files: [...contents].map(([relative_path, data]) => ({
          relative_path,
          size_bytes: data.length,
          sha256_hex: sha256(data),
        })),
      },
      null,
      2,
    )}\n`,
  );
  return { contents, license, licenseText, manifest, source };
}

function invoke(source, app, manifest) {
  return spawnSync(embedder, [source, app, manifest], { encoding: "utf8" });
}

test("publishes only a byte-identical layout model verified by its manifest", () => {
  const root = mkdtempSync(join(tmpdir(), "lf-layout-package-"));
  try {
    const { contents, license, licenseText, manifest, source } = fixture(root);
    const app = join(root, "valid.app");
    const result = invoke(source, app, manifest);
    assert.equal(result.status, 0, result.stderr || result.error?.message);

    const resources = join(app, "Contents/Resources");
    const published = join(resources, "PPDocLayoutV3-fp32.mlmodelc");
    for (const [relativePath, data] of contents) {
      assert.deepEqual(readFileSync(join(published, relativePath)), data);
      assert.equal(lstatSync(join(published, relativePath)).isFile(), true);
    }
    assert.deepEqual(
      readFileSync(join(resources, "pp-doclayout-v3-coreml.json")),
      readFileSync(manifest),
    );
    assert.deepEqual(
      readFileSync(join(resources, "PPDocLayoutV3-Apache-2.0.txt")),
      licenseText,
    );

    writeFileSync(license, Buffer.from("tampered license"));
    const badLicenseApp = join(root, "bad-license.app");
    assert.notEqual(invoke(source, badLicenseApp, manifest).status, 0);
    assert.equal(
      existsSync(join(badLicenseApp, "Contents/Resources/PPDocLayoutV3-fp32.mlmodelc")),
      false,
    );
    writeFileSync(license, licenseText);

    writeFileSync(join(source, "model.mil"), Buffer.from("nodel program"));
    const corruptApp = join(root, "corrupt.app");
    assert.notEqual(invoke(source, corruptApp, manifest).status, 0);
    assert.equal(
      existsSync(join(corruptApp, "Contents/Resources/PPDocLayoutV3-fp32.mlmodelc")),
      false,
    );

    writeFileSync(join(source, "model.mil"), contents.get("model.mil"));
    writeFileSync(join(source, "unexpected.bin"), "extra");
    const extraApp = join(root, "extra.app");
    assert.notEqual(invoke(source, extraApp, manifest).status, 0);
    assert.equal(
      existsSync(join(extraApp, "Contents/Resources/PPDocLayoutV3-fp32.mlmodelc")),
      false,
    );

    rmSync(join(source, "unexpected.bin"));
    rmSync(join(source, "coremldata.bin"));
    symlinkSync("model.mil", join(source, "coremldata.bin"));
    const symlinkApp = join(root, "symlink.app");
    assert.notEqual(invoke(source, symlinkApp, manifest).status, 0);
    assert.equal(
      existsSync(join(symlinkApp, "Contents/Resources/PPDocLayoutV3-fp32.mlmodelc")),
      false,
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
