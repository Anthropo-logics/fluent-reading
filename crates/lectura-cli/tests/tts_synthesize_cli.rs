use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

fn request() -> Value {
    json!({
        "model_id": "kokoro-82m-4bit",
        "model_revision": "e4468a460f6f70b9125a003e0adb1ab7d4904bbd",
        "runtime_id": "mlx-audio-swift",
        "runtime_version": "v0.1.3",
        "voice_id": "ef_dora",
        "language": "es",
        "units": [{"unit_id": "unit-1", "text": "Texto verificable."}]
    })
}

fn write_verified_model(
    root: &std::path::Path,
) -> (
    std::path::PathBuf,
    std::path::PathBuf,
    std::path::PathBuf,
    std::path::PathBuf,
) {
    let package = root.join("package");
    fs::create_dir_all(package.join("data")).unwrap();
    fs::write(package.join("data/model.safetensors"), b"model").unwrap();
    let manifest = root.join("manifest.json");
    fs::write(
        &manifest,
        serde_json::to_vec(&json!({
            "schema_version": 1,
            "id": "kokoro-82m-4bit",
            "model_revision": "e4468a460f6f70b9125a003e0adb1ab7d4904bbd",
            "artifact_revision": "e4468a460f6f70b9125a003e0adb1ab7d4904bbd",
            "purpose": "tts",
            "authors": ["publisher"],
            "license_id": "Apache-2.0",
            "usage_restrictions": ["review_pending"],
            "languages": ["es", "en", "pt"],
            "voices": ["ef_dora", "af_heart", "pf_dora"],
            "runtime_id": "mlx-audio-swift",
            "runtime_version": "v0.1.3",
            "distribution_status": "pending_review",
            "artifacts": [{
                "relative_path": "data/model.safetensors",
                "role": "model_weights",
                "source_url": "https://example.invalid/e4468a460f6f70b9125a003e0adb1ab7d4904bbd/model.safetensors",
                "publisher": "publisher",
                "format": "safetensors",
                "quantization": "int4",
                "size_bytes": 5,
                "sha256_hex": "9372c470eeadd5ecd9c3c74c2b3cb633f8e2f2fad799250a0f70d652b6b825e4"
            }]
        }))
        .unwrap(),
    )
    .unwrap();
    let aux_package = root.join("aux-package");
    fs::create_dir_all(aux_package.join("data")).unwrap();
    fs::write(aux_package.join("data/lexicon.tsv"), b"lexicon").unwrap();
    let aux_manifest = root.join("aux-manifest.json");
    fs::write(
        &aux_manifest,
        serde_json::to_vec(&json!({
            "schema_version": 1,
            "id": "kokoro-ipa-lexicons-es-pt",
            "model_revision": "a3d069caea9a2b63daed40834514431f73a2f11e",
            "artifact_revision": "a3d069caea9a2b63daed40834514431f73a2f11e",
            "purpose": "tts",
            "authors": ["publisher"],
            "license_id": "NOASSERTION",
            "usage_restrictions": ["review_pending"],
            "languages": ["es", "pt"],
            "voices": ["ef_dora", "pf_dora"],
            "runtime_id": "mlx-audio-swift",
            "runtime_version": "v0.1.3",
            "distribution_status": "pending_review",
            "artifacts": [{
                "relative_path": "data/lexicon.tsv",
                "role": "pronunciation_lexicon",
                "source_url": "https://example.invalid/a3d069caea9a2b63daed40834514431f73a2f11e/lexicon.tsv",
                "publisher": "publisher",
                "format": "tsv",
                "quantization": "not_applicable",
                "size_bytes": 7,
                "sha256_hex": "239aec50c94b6ea398dadb908b531bbe124c08fbbe756ce60cd59c37cfd719f2"
            }]
        }))
        .unwrap(),
    )
    .unwrap();
    (manifest, package, aux_manifest, aux_package)
}

#[test]
fn tts_synthesize_emits_one_traced_result_from_command_scoped_worker() {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let root = std::env::temp_dir().join(format!("lectura-cli-tts-{nonce}"));
    fs::create_dir_all(&root).unwrap();
    let request_path = root.join("request.json");
    fs::write(&request_path, serde_json::to_vec(&request()).unwrap()).unwrap();
    let (manifest, package, aux_manifest, aux_package) = write_verified_model(&root);
    let worker_path = root.join("worker");
    let response = json!({
        "schema_version": 1,
        "request_id": "req_cli_tts_worker",
        "kind": "completed",
        "result": {"pages": null, "tts": {
            "model_id": "kokoro-82m-4bit",
            "model_revision": "e4468a460f6f70b9125a003e0adb1ab7d4904bbd",
            "runtime_id": "mlx-audio-swift",
            "runtime_version": "v0.1.3",
            "voice_id": "ef_dora",
            "language": "es",
            "audio_path": "__AUDIO_PATH__",
            "segments": [{
                "unit_id": "unit-1",
                "segment_index": 0,
                "unit_sample_offset": 0,
                "sample_count": 24000,
                "sample_rate_hz": 24000,
                "elapsed_ms": 1000,
                "artifact_hash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                "model_revision": "e4468a460f6f70b9125a003e0adb1ab7d4904bbd",
                "voice_id": "ef_dora"
            }],
            "omitted_unit_ids": []
        }},
        "error": null
    });
    fs::write(
        &worker_path,
        format!(
            "#!/bin/sh\nread -r ignored\naudio=\"$LECTURA_TTS_WORK_ROOT/audio.wav\"\nprintf wave > \"$audio\"\nprintf '%s\\n' '{}' | sed \"s|__AUDIO_PATH__|$audio|g\"\n",
            response
        ),
    )
    .unwrap();
    let mut permissions = fs::metadata(&worker_path).unwrap().permissions();
    permissions.set_mode(0o700);
    fs::set_permissions(&worker_path, permissions).unwrap();

    let rejected = Command::new(env!("CARGO_BIN_EXE_lectura"))
        .args(["tts", "synthesize", "--request"])
        .arg(&request_path)
        .arg("--json")
        .env("LECTURA_MACOS_WORKER", &worker_path)
        .env("LECTURA_TTS_MANIFEST", &manifest)
        .env("LECTURA_TTS_PACKAGE", &package)
        .output()
        .unwrap();
    assert_eq!(rejected.status.code(), Some(65));
    let rejected_event: Value = serde_json::from_slice(&rejected.stdout).unwrap();
    assert_eq!(rejected_event["error"]["code"], "LF_MODEL_REQUIRED");

    let output = Command::new(env!("CARGO_BIN_EXE_lectura"))
        .args(["tts", "synthesize", "--request"])
        .arg(&request_path)
        .arg("--json")
        .env("LECTURA_MACOS_WORKER", &worker_path)
        .env("LECTURA_TTS_MANIFEST", &manifest)
        .env("LECTURA_TTS_PACKAGE", &package)
        .env("LECTURA_TTS_AUX_MANIFEST", &aux_manifest)
        .env("LECTURA_TTS_AUX_PACKAGE", &aux_package)
        .output()
        .unwrap();

    assert!(output.status.success());
    assert_eq!(
        output.stdout.iter().filter(|byte| **byte == b'\n').count(),
        1
    );
    let event: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(event["kind"], "completed");
    assert_eq!(event["result"]["segments"][0]["unit_id"], "unit-1");
    assert!(output.stderr.is_empty());
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn tts_synthesize_rejects_duplicate_units_without_disclosing_text_or_path() {
    let sentinel = "SECRET narration text";
    let mut request = request();
    request["units"] = json!([
        {"unit_id": "duplicate", "text": sentinel},
        {"unit_id": "duplicate", "text": sentinel}
    ]);
    let mut child = Command::new(env!("CARGO_BIN_EXE_lectura"))
        .args(["tts", "synthesize", "--request", "-", "--json"])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    use std::io::Write;
    child
        .stdin
        .take()
        .unwrap()
        .write_all(&serde_json::to_vec(&request).unwrap())
        .unwrap();
    let output = child.wait_with_output().unwrap();

    assert_eq!(output.status.code(), Some(65));
    let event: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(event["kind"], "failed");
    assert_eq!(event["error"]["code"], "LF_TTS_OUTPUT_INVALID");
    assert!(!String::from_utf8_lossy(&output.stdout).contains(sentinel));
    assert!(!String::from_utf8_lossy(&output.stderr).contains(sentinel));
}

#[test]
fn tts_synthesize_sigint_cancels_worker_and_cleans_owned_temporaries() {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let root = std::env::temp_dir().join(format!("lectura-cli-tts-cancel-{nonce}"));
    fs::create_dir_all(&root).unwrap();
    let request_path = root.join("request.json");
    fs::write(&request_path, serde_json::to_vec(&request()).unwrap()).unwrap();
    let (manifest, package, aux_manifest, aux_package) = write_verified_model(&root);
    let worker_path = root.join("worker");
    fs::write(&worker_path, "#!/bin/sh\nread -r ignored\nsleep 10\n").unwrap();
    let mut permissions = fs::metadata(&worker_path).unwrap().permissions();
    permissions.set_mode(0o700);
    fs::set_permissions(&worker_path, permissions).unwrap();
    let child = Command::new(env!("CARGO_BIN_EXE_lectura"))
        .args(["tts", "synthesize", "--request"])
        .arg(&request_path)
        .arg("--json")
        .env("LECTURA_MACOS_WORKER", &worker_path)
        .env("LECTURA_TTS_MANIFEST", manifest)
        .env("LECTURA_TTS_PACKAGE", package)
        .env("LECTURA_TTS_AUX_MANIFEST", aux_manifest)
        .env("LECTURA_TTS_AUX_PACKAGE", aux_package)
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    let prefix = format!("lectura-tts-cli-{}-", child.id());
    for _ in 0..100 {
        if fs::read_dir(std::env::temp_dir()).unwrap().any(|entry| {
            entry
                .ok()
                .and_then(|entry| entry.file_name().into_string().ok())
                .is_some_and(|name| name.starts_with(&prefix))
        }) {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    // SAFETY: the PID belongs to the child spawned immediately above.
    assert_eq!(
        unsafe { libc::kill(child.id() as libc::pid_t, libc::SIGINT) },
        0
    );
    let output = child.wait_with_output().unwrap();

    assert_eq!(output.status.code(), Some(130));
    let event: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(event["kind"], "cancelled");
    assert!(!fs::read_dir(std::env::temp_dir()).unwrap().any(|entry| {
        entry
            .ok()
            .and_then(|entry| entry.file_name().into_string().ok())
            .is_some_and(|name| name.starts_with(&prefix))
    }));
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn tts_synthesize_worker_death_fails_closed_and_cleans_temporaries() {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let root = std::env::temp_dir().join(format!("lectura-cli-tts-death-{nonce}"));
    fs::create_dir_all(&root).unwrap();
    let request_path = root.join("request.json");
    fs::write(&request_path, serde_json::to_vec(&request()).unwrap()).unwrap();
    let (manifest, package, aux_manifest, aux_package) = write_verified_model(&root);
    let worker_path = root.join("worker");
    fs::write(&worker_path, "#!/bin/sh\nread -r ignored\nexit 9\n").unwrap();
    let mut permissions = fs::metadata(&worker_path).unwrap().permissions();
    permissions.set_mode(0o700);
    fs::set_permissions(&worker_path, permissions).unwrap();
    let child = Command::new(env!("CARGO_BIN_EXE_lectura"))
        .args(["tts", "synthesize", "--request"])
        .arg(&request_path)
        .arg("--json")
        .env("LECTURA_MACOS_WORKER", &worker_path)
        .env("LECTURA_TTS_MANIFEST", manifest)
        .env("LECTURA_TTS_PACKAGE", package)
        .env("LECTURA_TTS_AUX_MANIFEST", aux_manifest)
        .env("LECTURA_TTS_AUX_PACKAGE", aux_package)
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    let prefix = format!("lectura-tts-cli-{}-", child.id());
    let output = child.wait_with_output().unwrap();

    assert_eq!(output.status.code(), Some(70));
    let event: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(event["kind"], "failed");
    assert_eq!(event["error"]["code"], "LF_TTS_SYNTHESIS_FAILED");
    assert!(!fs::read_dir(std::env::temp_dir()).unwrap().any(|entry| {
        entry
            .ok()
            .and_then(|entry| entry.file_name().into_string().ok())
            .is_some_and(|name| name.starts_with(&prefix))
    }));
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn tts_synthesize_rejects_audio_outside_its_owned_work_root() {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let root = std::env::temp_dir().join(format!("lectura-cli-tts-output-{nonce}"));
    fs::create_dir_all(&root).unwrap();
    let request_path = root.join("request.json");
    fs::write(&request_path, serde_json::to_vec(&request()).unwrap()).unwrap();
    let (manifest, package, aux_manifest, aux_package) = write_verified_model(&root);
    let audio_path = root.join("outside.wav");
    fs::write(&audio_path, b"wave").unwrap();
    let worker_path = root.join("worker");
    let response = json!({
        "schema_version": 1,
        "request_id": "req_cli_tts_worker",
        "kind": "completed",
        "result": {"tts": {
            "model_id": "kokoro-82m-4bit",
            "model_revision": "e4468a460f6f70b9125a003e0adb1ab7d4904bbd",
            "runtime_id": "mlx-audio-swift",
            "runtime_version": "v0.1.3",
            "voice_id": "ef_dora",
            "language": "es",
            "audio_path": audio_path,
            "segments": [{
                "unit_id": "unit-1", "segment_index": 0, "unit_sample_offset": 0,
                "sample_count": 24000, "sample_rate_hz": 24000, "elapsed_ms": 1000,
                "artifact_hash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                "model_revision": "e4468a460f6f70b9125a003e0adb1ab7d4904bbd", "voice_id": "ef_dora"
            }],
            "omitted_unit_ids": []
        }},
        "error": null
    });
    fs::write(
        &worker_path,
        format!(
            "#!/bin/sh\nread -r ignored\nprintf '%s\\n' '{}'\n",
            response
        ),
    )
    .unwrap();
    let mut permissions = fs::metadata(&worker_path).unwrap().permissions();
    permissions.set_mode(0o700);
    fs::set_permissions(&worker_path, permissions).unwrap();

    let output = Command::new(env!("CARGO_BIN_EXE_lectura"))
        .args(["tts", "synthesize", "--request"])
        .arg(&request_path)
        .arg("--json")
        .env("LECTURA_MACOS_WORKER", &worker_path)
        .env("LECTURA_TTS_MANIFEST", manifest)
        .env("LECTURA_TTS_PACKAGE", package)
        .env("LECTURA_TTS_AUX_MANIFEST", aux_manifest)
        .env("LECTURA_TTS_AUX_PACKAGE", aux_package)
        .output()
        .unwrap();

    assert_eq!(output.status.code(), Some(70));
    let event: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(event["error"]["code"], "LF_TTS_OUTPUT_INVALID");
    fs::remove_dir_all(root).unwrap();
}
