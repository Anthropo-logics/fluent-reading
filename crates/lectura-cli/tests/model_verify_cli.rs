use std::fs;
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

#[test]
fn model_verify_emits_one_safe_lf_result() {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let root = std::env::temp_dir().join(format!("lectura-cli-model-{nonce}"));
    fs::create_dir_all(root.join("package/data")).unwrap();
    fs::write(root.join("package/data/model.onnx"), b"model").unwrap();
    let manifest = root.join("manifest.json");
    fs::write(
        &manifest,
        serde_json::to_vec(&json!({
            "schema_version": 1,
            "id": "candidate",
            "model_revision": "revision-immutable",
            "artifact_revision": "artifact-immutable",
            "purpose": "tts",
            "authors": ["publisher"],
            "license_id": "Apache-2.0",
            "usage_restrictions": ["review_pending"],
            "languages": ["es", "en", "pt"],
            "voices": ["voice"],
            "runtime_id": "runtime",
            "runtime_version": "1.0.0",
            "distribution_status": "pending_review",
            "artifacts": [{
                "relative_path": "data/model.onnx",
                "role": "model_weights",
                "source_url": "https://example.invalid/revision-immutable/model.onnx",
                "publisher": "publisher",
                "format": "onnx",
                "quantization": "int8",
                "size_bytes": 5,
                "sha256_hex": "9372c470eeadd5ecd9c3c74c2b3cb633f8e2f2fad799250a0f70d652b6b825e4"
            }]
        }))
        .unwrap(),
    )
    .unwrap();

    let output = Command::new(env!("CARGO_BIN_EXE_lectura"))
        .args(["model", "verify", "--manifest"])
        .arg(&manifest)
        .arg("--package")
        .arg(root.join("package"))
        .arg("--json")
        .output()
        .unwrap();

    assert!(output.status.success());
    assert_eq!(
        output.stdout.iter().filter(|byte| **byte == b'\n').count(),
        1
    );
    let event: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(event["kind"], "completed");
    assert_eq!(event["result"]["model_id"], "candidate");
    assert_eq!(event["result"]["checked_artifacts"], 1);
    assert!(!String::from_utf8_lossy(&output.stderr).contains(root.to_str().unwrap()));
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn model_verify_failure_is_single_and_does_not_disclose_paths() {
    let sentinel = "SECRET-model-manifest.json";
    let output = Command::new(env!("CARGO_BIN_EXE_lectura"))
        .args([
            "model",
            "verify",
            "--manifest",
            sentinel,
            "--package",
            "SECRET-model-package",
            "--json",
        ])
        .output()
        .unwrap();

    assert_eq!(output.status.code(), Some(66));
    assert_eq!(
        output.stdout.iter().filter(|byte| **byte == b'\n').count(),
        1
    );
    let event: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(event["kind"], "failed");
    assert_eq!(event["error"]["code"], "LF_MODEL_MANIFEST_INVALID");
    assert!(!String::from_utf8_lossy(&output.stdout).contains(sentinel));
    assert!(!String::from_utf8_lossy(&output.stderr).contains(sentinel));
}
