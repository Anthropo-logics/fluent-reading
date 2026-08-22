use std::process::Command;

use serde_json::Value;

#[test]
fn pdf_process_uses_real_worker_and_reports_nfr6() {
    let root = format!("{}/../..", env!("CARGO_MANIFEST_DIR"));
    let pdf = format!("{root}/tests/corpus/documents/en-multi-digital.pdf");
    let worker = format!("{root}/target/lectura-macos-worker");
    let output = Command::new(env!("CARGO_BIN_EXE_lectura"))
        .env("LECTURA_MACOS_WORKER", worker)
        .args([
            "pdf",
            "process",
            "--input",
            &pdf,
            "--language",
            "en",
            "--unit",
            "paragraph",
            "--json",
        ])
        .output()
        .expect("the CLI must launch");

    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(
        output.stdout.iter().filter(|byte| **byte == b'\n').count(),
        1
    );
    let event: Value = serde_json::from_slice(&output.stdout).expect("stdout must be LF JSON");
    assert_eq!(event["kind"], "completed");
    assert_eq!(event["result"]["pages"][0]["record"]["status"], "completed");
    assert_eq!(
        event["result"]["pages"][0]["units"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
    assert_eq!(event["result"]["nfr6"]["numerator"], 2);
    assert_eq!(event["result"]["nfr6"]["denominator"], 2);
    assert_eq!(event["result"]["nfr6"]["passed"], true);
}

#[test]
fn pdf_process_rejects_language_without_disclosing_the_path() {
    let sentinel = "SECRET-document.pdf";
    let output = Command::new(env!("CARGO_BIN_EXE_lectura"))
        .args([
            "pdf",
            "process",
            "--input",
            sentinel,
            "--language",
            "fr",
            "--unit",
            "paragraph",
            "--json",
        ])
        .output()
        .expect("the CLI must launch");
    assert_eq!(output.status.code(), Some(64));
    assert!(!String::from_utf8_lossy(&output.stdout).contains(sentinel));
    assert!(!String::from_utf8_lossy(&output.stderr).contains(sentinel));
}

#[test]
fn pdf_process_routes_a_scanned_page_through_ocr_and_reports_cer() {
    let root = format!("{}/../..", env!("CARGO_MANIFEST_DIR"));
    let pdf = format!("{root}/tests/corpus/documents/en-single-scanned.pdf");
    let worker = format!("{root}/target/lectura-macos-worker");
    let output = Command::new(env!("CARGO_BIN_EXE_lectura"))
        .env("LECTURA_MACOS_WORKER", worker)
        .args([
            "pdf",
            "process",
            "--input",
            &pdf,
            "--language",
            "en",
            "--unit",
            "sentence",
            "--json",
        ])
        .output()
        .expect("the CLI must launch");

    assert!(output.status.success());
    let event: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(event["result"]["pages"][0]["record"]["status"], "degraded");
    assert_eq!(event["result"]["pages"][0]["record"]["route"], "ocr");
    assert_eq!(event["result"]["nfr6"]["numerator"], 1);
    assert_eq!(event["result"]["nfr6"]["denominator"], 1);
    assert_eq!(event["result"]["nfr6"]["passed"], true);
    assert_eq!(event["result"]["cer"]["ratio"], 0.0);
    assert_eq!(event["result"]["cer"]["passed"], true);
}

#[test]
fn pdf_process_can_force_ocr_for_one_page() {
    let root = format!("{}/../..", env!("CARGO_MANIFEST_DIR"));
    let pdf = format!("{root}/tests/corpus/documents/en-multi-digital.pdf");
    let worker = format!("{root}/target/lectura-macos-worker");
    let output = Command::new(env!("CARGO_BIN_EXE_lectura"))
        .env("LECTURA_MACOS_WORKER", worker)
        .args([
            "pdf",
            "process",
            "--input",
            &pdf,
            "--language",
            "en",
            "--unit",
            "paragraph",
            "--json",
            "--force-ocr-page",
            "0",
        ])
        .output()
        .expect("the CLI must launch");

    assert!(output.status.success());
    let event: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(event["result"]["pages"][0]["record"]["route"], "ocr");
    assert_eq!(
        event["result"]["pages"][0]["record"]["reason_code"],
        "ocr_forced"
    );
    assert_eq!(event["result"]["cer"]["passed"], true);
}
