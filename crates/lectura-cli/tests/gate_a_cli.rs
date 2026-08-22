use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

#[test]
fn gate_a_run_rejects_a_missing_manifest_with_one_safe_terminal_event() {
    let missing = "/private/tmp/lectura-gate-a-no-such-manifest.json";
    let output = Command::new(env!("CARGO_BIN_EXE_lectura"))
        .args([
            "gate-a",
            "run",
            "--manifest",
            missing,
            "--output",
            "/private/tmp/lectura-gate-a-no-output",
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
    assert_eq!(event["error"]["code"], "LF_FILE_NOT_FOUND");
    assert!(!String::from_utf8_lossy(&output.stdout).contains(missing));
    assert!(!String::from_utf8_lossy(&output.stderr).contains(missing));
}

#[test]
fn gate_a_run_rejects_a_manifest_with_no_document_payload_leakage() {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let root = std::env::temp_dir().join(format!("lectura-gate-a-invalid-{nonce}"));
    fs::create_dir_all(&root).unwrap();
    let manifest = root.join("manifest.json");
    let sentinel = "SECRET PDF TEXT";
    fs::write(&manifest, format!("{{\"sentinel\":\"{sentinel}\"}}")).unwrap();
    let output = Command::new(env!("CARGO_BIN_EXE_lectura"))
        .args(["gate-a", "run", "--manifest"])
        .arg(&manifest)
        .args(["--output"])
        .arg(root.join("output"))
        .arg("--json")
        .output()
        .unwrap();

    assert_eq!(output.status.code(), Some(65));
    assert!(!String::from_utf8_lossy(&output.stdout).contains(sentinel));
    assert!(!String::from_utf8_lossy(&output.stderr).contains(sentinel));
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn gate_a_run_composes_existing_pdf_and_tts_services_one_hundred_times_without_persisting_text() {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let root = std::env::temp_dir().join(format!("lectura-gate-a-complete-{nonce}"));
    fs::create_dir_all(&root).unwrap();
    let document = root.join("document.pdf");
    fs::write(&document, b"fixture").unwrap();
    let package = root.join("package");
    fs::create_dir_all(package.join("data")).unwrap();
    fs::write(package.join("data/model.safetensors"), b"model").unwrap();
    let model_manifest = root.join("model.json");
    fs::write(
        &model_manifest,
        serde_json::to_vec(&json!({
            "schema_version": 1, "id": "kokoro-82m-4bit",
            "model_revision": "e4468a460f6f70b9125a003e0adb1ab7d4904bbd",
            "artifact_revision": "e4468a460f6f70b9125a003e0adb1ab7d4904bbd",
            "purpose": "tts", "authors": ["publisher"], "license_id": "Apache-2.0",
            "usage_restrictions": ["review_pending"], "languages": ["es", "en", "pt"],
            "voices": ["ef_dora"], "runtime_id": "mlx-audio-swift", "runtime_version": "v0.1.3",
            "distribution_status": "pending_review", "artifacts": [{
                "relative_path": "data/model.safetensors", "role": "model_weights",
            "source_url": "https://example.invalid/e4468a460f6f70b9125a003e0adb1ab7d4904bbd/model.safetensors", "publisher": "publisher",
                "format": "safetensors", "quantization": "int4", "size_bytes": 5,
                "sha256_hex": "9372c470eeadd5ecd9c3c74c2b3cb633f8e2f2fad799250a0f70d652b6b825e4"
            }]
        }))
        .unwrap(),
    )
    .unwrap();
    let worker = root.join("worker");
    fs::write(&worker, r#"#!/bin/sh
read -r line
case "$line" in
  *extract_document*)
    printf '%s\n' '{"schema_version":1,"request_id":"req_cli_worker","kind":"completed","result":{"pages":[{"page_index":0,"direct_blocks":[{"block_id":"block-1","text":"Puso en efeto.","region":{"page_index":0,"rect_pdf_points":[0.0,0.0,1.0,1.0],"page_rotation_degrees":0,"source_to_page_transform":[1.0,0.0,0.0,1.0,0.0,0.0],"confidence":1.0},"confidence":1.0}],"ocr_blocks":[],"ocr_status":null,"ocr_error_code":null,"ocr_elapsed_ms":0}]},"error":null}'
    ;;
  *tts_synthesize*)
    unit_id=$(printf '%s' "$line" | sed -n 's/.*"unit_id":"\([^"]*\)".*/\1/p')
    audio="$LECTURA_TTS_WORK_ROOT/audio.wav"
    printf wave > "$audio"
    printf '{"schema_version":1,"request_id":"req_cli_tts_worker","kind":"completed","result":{"pages":null,"tts":{"model_id":"kokoro-82m-4bit","model_revision":"e4468a460f6f70b9125a003e0adb1ab7d4904bbd","runtime_id":"mlx-audio-swift","runtime_version":"v0.1.3","voice_id":"ef_dora","language":"es","audio_path":"%s","segments":[{"unit_id":"%s","segment_index":0,"unit_sample_offset":0,"sample_count":24000,"sample_rate_hz":24000,"elapsed_ms":1,"artifact_hash":null,"model_revision":"e4468a460f6f70b9125a003e0adb1ab7d4904bbd","voice_id":"ef_dora"}],"omitted_unit_ids":[]}},"error":null}\n' "$audio" "$unit_id"
    ;;
esac
"#).unwrap();
    let mut permissions = fs::metadata(&worker).unwrap().permissions();
    permissions.set_mode(0o700);
    fs::set_permissions(&worker, permissions).unwrap();
    let espeak = root.join("espeak");
    fs::write(&espeak, "#!/bin/sh\ncat\n").unwrap();
    let mut permissions = fs::metadata(&espeak).unwrap().permissions();
    permissions.set_mode(0o700);
    fs::set_permissions(&espeak, permissions).unwrap();
    let gate_manifest = root.join("gate-a.json");
    fs::write(&gate_manifest, serde_json::to_vec(&json!({
        "schema_version": 1,
        "request": {
            "scenario": "integrated_chain", "condition": "cold", "corpus_id": "gate-a-corpus-v1",
            "revisions": {"app": "app-rev", "corpus": "corpus-rev", "runtime": "mlx-audio-swift-v0.1.3", "model": "kokoro-82m-4bit-e4468a46"},
            "expected_repetitions": 1, "expected_duration_ms": 60000
        },
        "document": {"input": document, "language": "es", "unit": "paragraph"},
        "tts": {"model_id": "kokoro-82m-4bit", "model_revision": "e4468a460f6f70b9125a003e0adb1ab7d4904bbd", "runtime_id": "mlx-audio-swift", "runtime_version": "v0.1.3", "voice_id": "ef_dora"}
    })).unwrap()).unwrap();
    for repetition in 0..100 {
        let output_dir = root.join(format!("output-{repetition}"));
        let output = Command::new(env!("CARGO_BIN_EXE_lectura"))
            .args(["gate-a", "run", "--manifest"])
            .arg(&gate_manifest)
            .args(["--output"])
            .arg(&output_dir)
            .arg("--json")
            .env("LECTURA_MACOS_WORKER", &worker)
            .env("LECTURA_ESPEAK", &espeak)
            .env("LECTURA_TTS_MANIFEST", &model_manifest)
            .env("LECTURA_TTS_PACKAGE", &package)
            .env("LECTURA_TTS_MODEL", package.join("data"))
            .env("LECTURA_TTS_RUNTIME", &espeak)
            .output()
            .unwrap();

        assert!(
            output.status.success(),
            "run {repetition}: stdout={} stderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        let event: Value = serde_json::from_slice(&output.stdout).unwrap();
        assert_eq!(event["kind"], "completed");
        assert_eq!(event["result"]["request"]["corpus_id"], "gate-a-corpus-v1");
        assert_eq!(event["result"]["metrics"].as_array().unwrap().len(), 4);
        let terminal = String::from_utf8_lossy(&output.stdout);
        for forbidden in ["Puso en efeto", "audio_path", "document.pdf", "raw_ipa"] {
            assert!(!terminal.contains(forbidden));
        }
        for name in ["environment.json", "metrics.jsonl", "summary.json"] {
            let artifact = fs::read_to_string(output_dir.join(name)).unwrap();
            for forbidden in ["Puso en efeto", "audio_path", "document.pdf", "raw_ipa"] {
                assert!(!artifact.contains(forbidden));
            }
        }
        assert!(output_dir.join("environment.json").is_file());
        assert!(output_dir.join("metrics.jsonl").is_file());
    }
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn gate_a_sigint_cancels_the_nested_worker_and_marks_the_run_incomplete() {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let root = std::env::temp_dir().join(format!("lectura-gate-a-cancel-{nonce}"));
    fs::create_dir_all(&root).unwrap();
    let document = root.join("document.pdf");
    fs::write(&document, b"fixture").unwrap();
    let worker_pid = root.join("worker.pid");
    let worker = root.join("worker");
    fs::write(
        &worker,
        format!(
            "#!/bin/sh\necho $$ > '{}'\nread -r ignored\nsleep 5\n",
            worker_pid.display()
        ),
    )
    .unwrap();
    let mut permissions = fs::metadata(&worker).unwrap().permissions();
    permissions.set_mode(0o700);
    fs::set_permissions(&worker, permissions).unwrap();
    let gate_manifest = root.join("gate-a.json");
    fs::write(&gate_manifest, serde_json::to_vec(&json!({
        "schema_version": 1,
        "request": {
            "scenario": "integrated_chain", "condition": "cold", "corpus_id": "gate-a-corpus-v1",
            "revisions": {"app": "app-rev", "corpus": "corpus-rev", "runtime": "mlx-audio-swift-v0.1.3", "model": "kokoro-82m-4bit-e4468a46"},
            "expected_repetitions": 1, "expected_duration_ms": 60000
        },
        "document": {"input": document, "language": "es", "unit": "paragraph"},
        "tts": {"model_id": "kokoro-82m-4bit", "model_revision": "e4468a460f6f70b9125a003e0adb1ab7d4904bbd", "runtime_id": "mlx-audio-swift", "runtime_version": "v0.1.3", "voice_id": "ef_dora"}
    })).unwrap()).unwrap();
    let output_dir = root.join("output");
    let child = Command::new(env!("CARGO_BIN_EXE_lectura"))
        .args(["gate-a", "run", "--manifest"])
        .arg(&gate_manifest)
        .args(["--output"])
        .arg(&output_dir)
        .arg("--json")
        .env("LECTURA_MACOS_WORKER", &worker)
        .stdout(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    for _ in 0..100 {
        if worker_pid.is_file() {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    assert!(worker_pid.is_file());
    let pid = child.id().to_string();
    assert!(
        Command::new("/bin/kill")
            .args(["-INT", &pid])
            .status()
            .unwrap()
            .success()
    );
    let output = child.wait_with_output().unwrap();

    assert_eq!(output.status.code(), Some(130));
    let event: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(event["kind"], "cancelled");
    let summary: Value =
        serde_json::from_slice(&fs::read(output_dir.join("summary.json")).unwrap()).unwrap();
    assert_eq!(summary["validation_run"]["status"], "incomplete");
    assert_eq!(summary["validation_run"]["errors"], json!(["LF_CANCELLED"]));
    let worker_pid = fs::read_to_string(worker_pid).unwrap().trim().to_owned();
    assert!(
        !Command::new("/bin/kill")
            .args(["-0", &worker_pid])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .unwrap()
            .success()
    );
    fs::remove_dir_all(root).unwrap();
}
