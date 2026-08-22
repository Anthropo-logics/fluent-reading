use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use lectura_core::{CorpusValidationError, ValidationRun, validate_corpus_manifest};
use serde_json::json;

fn temp_root(label: &str) -> PathBuf {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("clock must follow the Unix epoch")
        .as_nanos();
    let root = std::env::temp_dir().join(format!("lectura-{label}-{nonce}"));
    fs::create_dir_all(&root).expect("temporary corpus root must be creatable");
    root
}

fn copy_canonical_corpus(destination: &Path) {
    let source = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../tests/corpus");
    for directory in ["documents", "expected"] {
        fs::create_dir_all(destination.join(directory)).unwrap();
        for entry in fs::read_dir(source.join(directory)).unwrap() {
            let entry = entry.unwrap();
            fs::copy(
                entry.path(),
                destination.join(directory).join(entry.file_name()),
            )
            .unwrap();
        }
    }
    fs::copy(
        source.join("manifest.json"),
        destination.join("manifest.json"),
    )
    .unwrap();
}

#[test]
fn canonical_manifest_is_complete_and_machine_readable() {
    let result = validate_corpus_manifest(
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../tests/corpus/manifest.json"),
    )
    .expect("the canonical distributable corpus must validate");

    assert!(result.complete);
    assert_eq!(result.document_count, 14);
    assert_eq!(result.matrix_document_count, 12);
    assert_eq!(result.page_count, 1_013);
    assert_eq!(result.checked_hashes, 14);
}

#[test]
fn missing_source_fails_without_disclosing_its_path() {
    let root = temp_root("missing");
    let manifest = root.join("manifest.json");
    fs::write(
        &manifest,
        serde_json::to_vec(&json!({
            "schema_version": 1,
            "corpus_id": "corpus_missing",
            "entries": [{
                "id": "document_missing",
                "role": "matrix",
                "file": "private-name.pdf",
                "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                "byte_size": 1,
                "provenance": {"source": "synthetic", "permission": "owned", "evidence": "generator-v1"},
                "classification": {"layout": "single_column", "content": "digital"},
                "language": "es",
                "required": true,
                "distributable": true,
                "page_count": 1,
                "pages_evaluated": [0],
                "ground_truth": "expected/missing.json"
            }]
        }))
        .expect("manifest fixture must serialize"),
    )
    .expect("manifest fixture must be writable");

    let error = validate_corpus_manifest(&manifest).expect_err("missing source must fail closed");

    assert_eq!(error, CorpusValidationError::SourceMissing);
    assert!(!format!("{error:?}").contains("private-name"));
    fs::remove_dir_all(root).expect("temporary corpus must be removable");
}

#[test]
fn validation_never_changes_source_or_ground_truth_hashes() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../tests/corpus");
    let source = root.join("documents/es-single-digital.pdf");
    let truth = root.join("expected/es-single-digital.json");
    let before = (fs::read(&source).unwrap(), fs::read(&truth).unwrap());

    validate_corpus_manifest(root.join("manifest.json")).unwrap();
    validate_corpus_manifest(root.join("manifest.json")).unwrap();

    assert_eq!(fs::read(source).unwrap(), before.0);
    assert_eq!(fs::read(truth).unwrap(), before.1);
}

#[test]
fn wrong_hash_and_missing_annotation_fail_closed() {
    let hash_root = temp_root("hash");
    copy_canonical_corpus(&hash_root);
    let mut manifest: serde_json::Value =
        serde_json::from_slice(&fs::read(hash_root.join("manifest.json")).unwrap()).unwrap();
    manifest["entries"][0]["sha256"] = json!("0".repeat(64));
    fs::write(
        hash_root.join("manifest.json"),
        serde_json::to_vec(&manifest).unwrap(),
    )
    .unwrap();
    assert_eq!(
        validate_corpus_manifest(hash_root.join("manifest.json")).unwrap_err(),
        CorpusValidationError::HashMismatch
    );
    fs::remove_dir_all(hash_root).unwrap();

    let truth_root = temp_root("truth");
    copy_canonical_corpus(&truth_root);
    let truth_path = truth_root.join("expected/es-single-digital.json");
    let mut truth: serde_json::Value =
        serde_json::from_slice(&fs::read(&truth_path).unwrap()).unwrap();
    truth["pages"][0]["blocks"][0]["paragraphs"][0]
        .as_object_mut()
        .unwrap()
        .remove("paragraph_id");
    fs::write(&truth_path, serde_json::to_vec(&truth).unwrap()).unwrap();
    assert_eq!(
        validate_corpus_manifest(truth_root.join("manifest.json")).unwrap_err(),
        CorpusValidationError::GroundTruthInvalid
    );
    fs::remove_dir_all(truth_root).unwrap();
}

#[test]
fn invalid_permission_classification_language_and_required_entry_fail_closed() {
    let root = temp_root("metadata");
    copy_canonical_corpus(&root);
    let manifest_path = root.join("manifest.json");
    let original: serde_json::Value =
        serde_json::from_slice(&fs::read(&manifest_path).unwrap()).unwrap();

    for (pointer, invalid_value, expected) in [
        (
            "/entries/0/provenance/permission",
            json!("uncertain"),
            CorpusValidationError::ManifestInvalid,
        ),
        (
            "/entries/0/classification/layout",
            json!("unknown_layout"),
            CorpusValidationError::ManifestInvalid,
        ),
        (
            "/entries/0/language",
            json!("fr"),
            CorpusValidationError::ManifestInvalid,
        ),
        (
            "/entries/0/required",
            json!(false),
            CorpusValidationError::CoverageIncomplete,
        ),
    ] {
        let mut changed = original.clone();
        *changed.pointer_mut(pointer).unwrap() = invalid_value;
        fs::write(&manifest_path, serde_json::to_vec(&changed).unwrap()).unwrap();
        assert_eq!(
            validate_corpus_manifest(&manifest_path).unwrap_err(),
            expected
        );
    }
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn invalid_sentence_anchor_and_region_fail_closed() {
    let root = temp_root("anchors");
    copy_canonical_corpus(&root);
    let truth_path = root.join("expected/es-single-digital.json");
    let original: serde_json::Value =
        serde_json::from_slice(&fs::read(&truth_path).unwrap()).unwrap();

    let mut missing_anchor = original.clone();
    missing_anchor["pages"][0]["blocks"][0]["paragraphs"][0]["sentences"][0]
        .as_object_mut()
        .unwrap()
        .remove("sentence_id");
    fs::write(&truth_path, serde_json::to_vec(&missing_anchor).unwrap()).unwrap();
    assert_eq!(
        validate_corpus_manifest(root.join("manifest.json")).unwrap_err(),
        CorpusValidationError::GroundTruthInvalid
    );

    let mut invalid_region = original;
    invalid_region["pages"][0]["blocks"][0]["region"] = json!([0.9, 0.1, 0.2, 0.2]);
    fs::write(&truth_path, serde_json::to_vec(&invalid_region).unwrap()).unwrap();
    assert_eq!(
        validate_corpus_manifest(root.join("manifest.json")).unwrap_err(),
        CorpusValidationError::GroundTruthInvalid
    );
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn duplicate_paths_and_oversized_manifests_fail_before_processing() {
    let duplicate_root = temp_root("duplicate");
    copy_canonical_corpus(&duplicate_root);
    let mut manifest: serde_json::Value =
        serde_json::from_slice(&fs::read(duplicate_root.join("manifest.json")).unwrap()).unwrap();
    manifest["entries"][1]["file"] = manifest["entries"][0]["file"].clone();
    fs::write(
        duplicate_root.join("manifest.json"),
        serde_json::to_vec(&manifest).unwrap(),
    )
    .unwrap();
    assert_eq!(
        validate_corpus_manifest(duplicate_root.join("manifest.json")).unwrap_err(),
        CorpusValidationError::EntryInvalid
    );
    fs::remove_dir_all(duplicate_root).unwrap();

    let oversized_root = temp_root("oversized");
    let oversized = oversized_root.join("manifest.json");
    fs::write(&oversized, vec![b' '; 1_048_577]).unwrap();
    assert_eq!(
        validate_corpus_manifest(&oversized).unwrap_err(),
        CorpusValidationError::InputTooLarge
    );
    fs::remove_dir_all(oversized_root).unwrap();
}

#[test]
fn validation_run_contract_round_trips_machine_readable_metrics() {
    let value: serde_json::Value = serde_json::from_str(include_str!(
        "../../../contracts/lf-v1/fixtures/validation-run-complete.json"
    ))
    .unwrap();

    let run: ValidationRun = serde_json::from_value(value.clone()).unwrap();
    assert_eq!(serde_json::to_value(run).unwrap(), value);
}
