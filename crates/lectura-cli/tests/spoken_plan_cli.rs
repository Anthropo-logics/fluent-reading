use std::io::Write;
use std::process::{Command, Stdio};

use serde_json::Value;

#[test]
fn spoken_plan_reads_stdin_and_returns_the_rust_authority() {
    let mut child = Command::new(env!("CARGO_BIN_EXE_lectura"))
        .args(["spoken", "plan", "--language", "pt", "--json"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(b"Tambem era rapido; naquelle lugar.")
        .unwrap();
    let output = child.wait_with_output().unwrap();

    assert!(output.status.success());
    assert!(output.stderr.is_empty());
    let plan: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(
        plan["normalized_text"],
        "Tambem era rapido; naquelle lugar."
    );
    assert_eq!(plan["frontend_voice"], "pt-br");
    assert_eq!(plan["parts"][1]["kind"], "punctuation");
    assert_eq!(plan["parts"][1]["value"], ";");
}

#[test]
fn spoken_plan_rejects_unsupported_language_without_echoing_input() {
    let sentinel = "SECRET spoken text";
    let mut child = Command::new(env!("CARGO_BIN_EXE_lectura"))
        .args(["spoken", "plan", "--language", "fr", "--json"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(sentinel.as_bytes())
        .unwrap();
    let output = child.wait_with_output().unwrap();

    assert_eq!(output.status.code(), Some(65));
    assert!(!String::from_utf8_lossy(&output.stdout).contains(sentinel));
    assert!(!String::from_utf8_lossy(&output.stderr).contains(sentinel));
}
