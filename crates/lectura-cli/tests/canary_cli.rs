use std::process::Command;

use serde_json::Value;

#[test]
fn canary_json_prints_only_the_lf_terminal_event() {
    let output = Command::new(env!("CARGO_BIN_EXE_lectura"))
        .args(["canary", "--json"])
        .output()
        .expect("the test binary must launch");

    assert!(output.status.success());
    assert!(output.stderr.is_empty());

    let event: Value =
        serde_json::from_slice(&output.stdout).expect("stdout must be one JSON value");
    assert_eq!(event["schema_version"], 1);
    assert_eq!(event["request_id"], "req_cli_canary");
    assert_eq!(event["kind"], "completed");
    assert_eq!(event["result"]["core_version"], "0.1.0");
    assert_eq!(event["result"]["message"], "lectura-core ready");
    assert!(event["error"].is_null());
}

#[test]
fn unsupported_invocation_exits_two_without_payload_leakage() {
    let output = Command::new(env!("CARGO_BIN_EXE_lectura"))
        .args(["future", "--json"])
        .output()
        .expect("the test binary must launch");

    assert_eq!(output.status.code(), Some(2));
    assert!(output.stdout.is_empty());
    assert_eq!(
        String::from_utf8(output.stderr).expect("diagnostic must be UTF-8"),
        "usage: lectura canary --json | lectura session plan --pages <count> --visible <index> --json | lectura spoken plan --language <es|en|pt> --json | lectura corpus validate --manifest <file> --json | lectura model verify --manifest <file> --package <dir> --json | lectura pdf process --input <pdf> --language <tag> --unit <paragraph|sentence> --json [--force-ocr-page <index>] [--page-limit <count>] | lectura tts synthesize --request <file|-> --json | lectura translate --request <file|-> --json | lectura gate-a run --manifest <file> --output <dir> --json\n"
    );
}
