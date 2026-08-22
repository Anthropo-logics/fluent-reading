use std::process::Command;

use serde_json::Value;

#[test]
fn corpus_validate_emits_one_completed_lf_event() {
    let manifest = format!(
        "{}/../../tests/corpus/manifest.json",
        env!("CARGO_MANIFEST_DIR")
    );
    let output = Command::new(env!("CARGO_BIN_EXE_lectura"))
        .args(["corpus", "validate", "--manifest", &manifest, "--json"])
        .output()
        .expect("the test binary must launch");

    assert!(output.status.success());
    assert!(output.stderr.is_empty());
    assert_eq!(
        output.stdout.iter().filter(|byte| **byte == b'\n').count(),
        1
    );

    let event: Value = serde_json::from_slice(&output.stdout).expect("stdout must be LF JSON");
    assert_eq!(event["kind"], "completed");
    assert_eq!(event["result"]["document_count"], 14);
    assert_eq!(event["result"]["matrix_document_count"], 12);
    assert_eq!(event["result"]["page_count"], 1_013);
}

#[test]
fn missing_manifest_emits_safe_failed_lf_event() {
    let sentinel = "SECRET-document-name.pdf";
    let output = Command::new(env!("CARGO_BIN_EXE_lectura"))
        .args(["corpus", "validate", "--manifest", sentinel, "--json"])
        .output()
        .expect("the test binary must launch");

    assert_eq!(output.status.code(), Some(66));
    let event: Value = serde_json::from_slice(&output.stdout).expect("stdout must be LF JSON");
    assert_eq!(event["kind"], "failed");
    assert_eq!(event["error"]["code"], "LF_FILE_NOT_FOUND");
    assert!(!String::from_utf8_lossy(&output.stdout).contains(sentinel));
    assert!(!String::from_utf8_lossy(&output.stderr).contains(sentinel));
}
