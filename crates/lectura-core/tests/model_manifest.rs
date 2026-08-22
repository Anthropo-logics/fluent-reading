use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use lectura_core::{
    DistributionStatus, ModelInstallationSession, ModelInstallationState,
    ModelInstallationTransitionError, ModelManifestError, ModelPurpose, validate_model_manifest,
    validate_model_package, validate_model_package_for_runtime,
};
use serde_json::json;

#[test]
fn voice_selection_rejects_silent_language_fallbacks() {
    assert!(lectura_core::VoiceSelection::kokoro("es", "ef_dora").is_some());
    assert!(lectura_core::VoiceSelection::kokoro("es", "af_heart").is_none());
    assert!(lectura_core::VoiceSelection::kokoro("fr", "ef_dora").is_none());
    assert_eq!(
        lectura_core::VoiceSelection::resolve_kokoro(None, None),
        Err(lectura_core::VoiceSelectionError::ModelRequired)
    );
    assert_eq!(
        lectura_core::VoiceSelection::resolve_kokoro(Some("es"), Some("af_heart")),
        Err(lectura_core::VoiceSelectionError::Unsupported)
    );
}

fn root(label: &str) -> PathBuf {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let path = std::env::temp_dir().join(format!(
        "lectura-model-{label}-{}-{nonce}",
        std::process::id()
    ));
    fs::create_dir_all(path.join("package/data")).unwrap();
    path
}

fn write_manifest(root: &Path, name: &str, artifacts: serde_json::Value) -> PathBuf {
    let manifest = root.join(name);
    fs::write(
        &manifest,
        serde_json::to_vec_pretty(&json!({
            "schema_version": 1,
            "id": "kokoro-int8",
            "model_revision": "a70f0e45c1cc0df9abdfbfa0f6dee9073579ee99",
            "artifact_revision": "a70f0e45c1cc0df9abdfbfa0f6dee9073579ee99",
            "purpose": "tts",
            "authors": ["hexgrad", "onnx-community"],
            "license_id": "Apache-2.0",
            "usage_restrictions": ["commercial_review_pending"],
            "languages": ["es", "en", "pt-BR"],
            "voices": ["ef_dora"],
            "runtime_id": "runtime-test",
            "runtime_version": "1.0.0",
            "distribution_status": "pending_review",
            "artifacts": artifacts
        }))
        .unwrap(),
    )
    .unwrap();
    manifest
}

fn model_artifact() -> serde_json::Value {
    json!([{
        "relative_path": "data/model_quantized.onnx",
        "role": "model_weights",
        "source_url": "https://example.invalid/models/a70f0e45c1cc0df9abdfbfa0f6dee9073579ee99/model_quantized.onnx",
        "publisher": "onnx-community",
        "format": "onnx",
        "quantization": "int8",
        "size_bytes": 5,
        "sha256_hex": "9372c470eeadd5ecd9c3c74c2b3cb633f8e2f2fad799250a0f70d652b6b825e4"
    }])
}

#[test]
fn installation_state_requires_monotonic_progress_and_verification_before_publish() {
    let mut session = ModelInstallationSession::new("kokoro".into(), 10).unwrap();
    assert_eq!(session.state, ModelInstallationState::Available);
    session.begin().unwrap();
    session.report_progress(6).unwrap();
    assert_eq!(
        session.publish_verified(),
        Err(ModelInstallationTransitionError::VerificationRequired)
    );
    assert_eq!(
        session.report_progress(5),
        Err(ModelInstallationTransitionError::InvalidProgress)
    );
    session.cancel().unwrap();
    session.begin().unwrap();
    session.report_progress(10).unwrap();
    session.publish_verified().unwrap();
    assert_eq!(session.state, ModelInstallationState::Installed);
    assert_eq!(
        session.begin(),
        Err(ModelInstallationTransitionError::InvalidTransition)
    );
}

#[test]
fn verified_package_preserves_declared_pair_and_bytes() {
    let root = root("valid");
    fs::write(root.join("package/data/model_quantized.onnx"), b"model").unwrap();
    let manifest = write_manifest(&root, "manifest.json", model_artifact());

    let result = validate_model_package(&manifest, root.join("package")).unwrap();

    assert_eq!(result.model_id, "kokoro-int8");
    assert_eq!(result.purpose, ModelPurpose::Tts);
    assert_eq!(
        result.distribution_status,
        DistributionStatus::PendingReview
    );
    assert_eq!(result.checked_artifacts, 1);
    assert_eq!(result.total_size_bytes, 5);
    assert_eq!(result.runtime_id, "runtime-test");
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn package_rejects_hash_size_extra_symlink_and_transformed_weights() {
    let root = root("adversarial");
    let package = root.join("package");
    let model = package.join("data/model_quantized.onnx");
    let sentinel = root.join("outside-package.txt");
    fs::write(&sentinel, b"unchanged").unwrap();
    fs::write(&model, b"four").unwrap();
    let manifest = write_manifest(&root, "manifest.json", model_artifact());
    assert_eq!(
        validate_model_package(&manifest, &package),
        Err(ModelManifestError::SizeMismatch)
    );

    fs::write(&model, b"wrong").unwrap();
    assert_eq!(
        validate_model_package(&manifest, &package),
        Err(ModelManifestError::HashMismatch)
    );

    fs::remove_file(&model).unwrap();
    assert_eq!(
        validate_model_package(&manifest, &package),
        Err(ModelManifestError::ArtifactMissing)
    );

    fs::write(&model, b"model").unwrap();
    fs::write(package.join("data/extra.bin"), b"extra").unwrap();
    assert_eq!(
        validate_model_package(&manifest, &package),
        Err(ModelManifestError::UnexpectedArtifact)
    );
    fs::remove_file(package.join("data/extra.bin")).unwrap();

    let unsafe_manifest = write_manifest(
        &root,
        "unsafe-manifest.json",
        json!([{
            "relative_path": "data/model.zip",
            "role": "model_weights",
            "source_url": "https://example.invalid/models/revision/model.zip",
            "publisher": "unknown",
            "format": "zip",
            "quantization": "converted",
            "size_bytes": 5,
            "sha256_hex": "9372c470eeadd5ecd9c3c74c2b3cb633f8e2f2fad799250a0f70d652b6b825e4"
        }]),
    );
    assert_eq!(
        validate_model_package(&unsafe_manifest, &package),
        Err(ModelManifestError::ArtifactInvalid)
    );

    #[cfg(unix)]
    {
        use std::os::unix::fs::symlink;
        fs::remove_file(&model).unwrap();
        symlink("/etc/hosts", &model).unwrap();
        assert_eq!(
            validate_model_package(&manifest, &package),
            Err(ModelManifestError::ArtifactNotRegular)
        );
    }
    assert_eq!(fs::read(&sentinel).unwrap(), b"unchanged");
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn manifest_rejects_mutable_urls_and_unsafe_paths() {
    let root = root("metadata");
    fs::write(root.join("package/data/model_quantized.onnx"), b"model").unwrap();
    let mutable = write_manifest(
        &root,
        "mutable-manifest.json",
        json!([{
            "relative_path": "../model_quantized.onnx",
            "role": "model_weights",
            "source_url": "https://example.invalid/models/main/model_quantized.onnx",
            "publisher": "onnx-community",
            "format": "onnx",
            "quantization": "int8",
            "size_bytes": 5,
            "sha256_hex": "9372c470eeadd5ecd9c3c74c2b3cb633f8e2f2fad799250a0f70d652b6b825e4"
        }]),
    );
    assert_eq!(
        validate_model_package(&mutable, root.join("package")),
        Err(ModelManifestError::ArtifactInvalid)
    );
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn package_rejects_runtime_mismatch_too_many_files_and_executable_data() {
    let root = root("runtime-limits");
    let package = root.join("package");
    let model = package.join("data/model_quantized.onnx");
    fs::write(&model, b"model").unwrap();
    let manifest = write_manifest(&root, "manifest.json", model_artifact());

    assert_eq!(
        validate_model_package_for_runtime(&manifest, &package, "runtime-test", "2.0.0"),
        Err(ModelManifestError::RuntimeMismatch)
    );

    let artifacts = (0..33)
        .map(|index| {
            json!({
                "relative_path": format!("data/model-{index}.onnx"),
                "role": "model_weights",
                "source_url": format!("https://example.invalid/models/a70f0e45c1cc0df9abdfbfa0f6dee9073579ee99/model-{index}.onnx"),
                "publisher": "onnx-community",
                "format": "onnx",
                "quantization": "int8",
                "size_bytes": 5,
                "sha256_hex": "9372c470eeadd5ecd9c3c74c2b3cb633f8e2f2fad799250a0f70d652b6b825e4"
            })
        })
        .collect::<Vec<_>>();
    let oversized = write_manifest(&root, "oversized-manifest.json", json!(artifacts));
    assert_eq!(
        validate_model_package(&oversized, &package),
        Err(ModelManifestError::ManifestInvalid)
    );

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&model, fs::Permissions::from_mode(0o755)).unwrap();
        assert_eq!(
            validate_model_package(&manifest, &package),
            Err(ModelManifestError::ArtifactNotRegular)
        );
    }
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn manifest_rejects_absolute_duplicate_undeclared_and_overflowing_artifacts() {
    let root = root("manifest-boundaries");
    let package = root.join("package");
    fs::write(package.join("data/model_quantized.onnx"), b"model").unwrap();

    let mut absolute = model_artifact();
    absolute[0]["relative_path"] = json!("/tmp/model.onnx");
    let absolute_manifest = write_manifest(&root, "absolute.json", absolute);
    assert_eq!(
        validate_model_package(&absolute_manifest, &package),
        Err(ModelManifestError::ArtifactInvalid)
    );

    let artifact = model_artifact()[0].clone();
    let duplicate_manifest = write_manifest(
        &root,
        "duplicate.json",
        json!([artifact.clone(), artifact.clone()]),
    );
    assert_eq!(
        validate_model_package(&duplicate_manifest, &package),
        Err(ModelManifestError::ArtifactInvalid)
    );

    let mut undeclared = artifact.clone();
    undeclared.as_object_mut().unwrap().remove("format");
    let undeclared_manifest = write_manifest(&root, "undeclared.json", json!([undeclared]));
    assert_eq!(
        validate_model_package(&undeclared_manifest, &package),
        Err(ModelManifestError::ManifestInvalid)
    );

    let mut overflowing = artifact;
    overflowing["size_bytes"] = json!(u64::MAX);
    let overflow_manifest = write_manifest(&root, "overflow.json", json!([overflowing]));
    assert_eq!(
        validate_model_package(&overflow_manifest, &package),
        Err(ModelManifestError::SizeLimit)
    );

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn translation_purpose_requires_empty_voices_and_tts_requires_nonempty_voices() {
    let root = root("translation-purpose");
    fs::write(root.join("package/data/model.safetensors"), b"model").unwrap();
    let artifacts = json!([{
        "relative_path": "data/model.safetensors",
        "role": "model_weights",
        "source_url": "https://example.invalid/models/a70f0e45c1cc0df9abdfbfa0f6dee9073579ee99/model.safetensors",
        "publisher": "example",
        "format": "safetensors",
        "quantization": "4bit",
        "size_bytes": 5,
        "sha256_hex": "9372c470eeadd5ecd9c3c74c2b3cb633f8e2f2fad799250a0f70d652b6b825e4"
    }]);

    let manifest = root.join("manifest.json");
    fs::write(
        &manifest,
        serde_json::to_vec_pretty(&json!({
            "schema_version": 1,
            "id": "translation-candidate",
            "model_revision": "a70f0e45c1cc0df9abdfbfa0f6dee9073579ee99",
            "artifact_revision": "a70f0e45c1cc0df9abdfbfa0f6dee9073579ee99",
            "purpose": "translation",
            "authors": ["example"],
            "license_id": "MIT",
            "usage_restrictions": ["commercial_review_pending"],
            "languages": ["es", "en", "pt"],
            "voices": [],
            "runtime_id": "runtime-test",
            "runtime_version": "1.0.0",
            "distribution_status": "pending_review",
            "artifacts": artifacts
        }))
        .unwrap(),
    )
    .unwrap();

    let result = validate_model_package(&manifest, root.join("package")).unwrap();
    assert_eq!(result.purpose, ModelPurpose::Translation);

    let mut with_voices = json!({
        "schema_version": 1,
        "id": "translation-candidate",
        "model_revision": "a70f0e45c1cc0df9abdfbfa0f6dee9073579ee99",
        "artifact_revision": "a70f0e45c1cc0df9abdfbfa0f6dee9073579ee99",
        "purpose": "translation",
        "authors": ["example"],
        "license_id": "MIT",
        "usage_restrictions": ["commercial_review_pending"],
        "languages": ["es", "en", "pt"],
        "voices": ["should-not-exist"],
        "runtime_id": "runtime-test",
        "runtime_version": "1.0.0",
        "distribution_status": "pending_review",
        "artifacts": artifacts
    });
    let invalid_manifest = root.join("invalid-voices.json");
    fs::write(
        &invalid_manifest,
        serde_json::to_vec_pretty(&with_voices).unwrap(),
    )
    .unwrap();
    assert_eq!(
        validate_model_package(&invalid_manifest, root.join("package")),
        Err(ModelManifestError::ManifestInvalid)
    );

    with_voices["purpose"] = json!("tts");
    with_voices["voices"] = json!([]);
    let tts_without_voices = root.join("tts-without-voices.json");
    fs::write(
        &tts_without_voices,
        serde_json::to_vec_pretty(&with_voices).unwrap(),
    )
    .unwrap();
    assert_eq!(
        validate_model_package(&tts_without_voices, root.join("package")),
        Err(ModelManifestError::ManifestInvalid)
    );

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn canonical_candidate_manifests_are_complete_before_weight_downloads() {
    let project = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let manifests = project.join("models/manifests");
    let kokoro =
        validate_model_manifest(manifests.join("kokoro-82m-onnx-int8-laboratory.json")).unwrap();
    let qwen_light =
        validate_model_manifest(manifests.join("qwen3-tts-0.6b-customvoice-4bit.json")).unwrap();
    let qwen_quality =
        validate_model_manifest(manifests.join("qwen3-tts-1.7b-customvoice-4bit.json")).unwrap();

    assert_eq!(kokoro.distribution_status, DistributionStatus::Laboratory);
    assert_eq!(kokoro.languages, ["es", "en", "pt"]);
    for qwen in [qwen_light, qwen_quality] {
        assert_eq!(qwen.distribution_status, DistributionStatus::PendingReview);
        assert_eq!(qwen.languages, ["es", "en", "pt"]);
        assert!(qwen.artifacts.iter().any(|artifact| {
            artifact.role == "model_weights" && artifact.quantization.contains("4bit")
        }));
        assert!(qwen.artifacts.iter().any(|artifact| {
            artifact.role == "audio_codec_weights"
                && artifact.quantization == "f32_published_auxiliary"
        }));
    }
}
