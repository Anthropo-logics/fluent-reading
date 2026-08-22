use std::collections::BTreeMap;

use lectura_core::{
    GateACondition, GateAMetric, GateAMetricName, GateAMetricUnit, GateAProgress, GateAResult,
    GateARevisionSet, GateARunRequest, GateAScenario, GateAThermalState, GateAValidationError,
    ResourceSample, ValidationArtifacts, ValidationEnvironment, ValidationRun, ValidationRunStatus,
};

fn request() -> GateARunRequest {
    GateARunRequest {
        scenario: GateAScenario::IntegratedChain,
        condition: GateACondition::Cold,
        corpus_id: "gate-a-corpus-v1".into(),
        revisions: GateARevisionSet {
            app: "app-rev".into(),
            corpus: "corpus-rev".into(),
            runtime: "mlx-audio-swift-v0.1.3".into(),
            model: "kokoro-e4468a".into(),
        },
        expected_repetitions: 5,
        expected_duration_ms: 60_000,
    }
}

fn validation_run() -> ValidationRun {
    ValidationRun {
        schema_version: 1,
        validation_run_id: "gate_a_run_1".into(),
        corpus_id: "gate-a-corpus-v1".into(),
        corpus_hashes: BTreeMap::from([("manifest".into(), "a".repeat(64))]),
        environment: ValidationEnvironment {
            hardware: "Mac16,12".into(),
            operating_system: "macOS".into(),
            rust: "1.97.1".into(),
            app_revision: "app-rev".into(),
            processor_revision: "Apple M4".into(),
        },
        processing_route: "pdfkit-rust-mlx".into(),
        confidence: 1.0,
        duration_ms: 60_000,
        errors: vec![],
        page_metrics: vec![],
        status: ValidationRunStatus::Complete,
        artifacts: ValidationArtifacts {
            environment_sha256: "b".repeat(64),
            metrics_sha256: "c".repeat(64),
            summary_sha256: "d".repeat(64),
        },
    }
}

#[test]
fn gate_a_contract_accepts_closed_safe_monotonic_metrics() {
    let request = request();
    request.validate().unwrap();

    let progress = GateAProgress {
        completed: 1,
        total: 5,
        monotonic_elapsed_ms: 12,
    };
    progress.validate().unwrap();

    let result = GateAResult {
        request,
        validation_run: validation_run(),
        metrics: vec![GateAMetric {
            name: GateAMetricName::OpenToFirstUnit,
            unit: GateAMetricUnit::Milliseconds,
            repetition: 1,
            monotonic_elapsed_ms: 8_000,
            numerator: 8_000,
            denominator: 1,
        }],
        resources: vec![ResourceSample {
            monotonic_elapsed_ms: 8_000,
            phys_footprint_bytes: 500_000_000,
            rss_bytes: 450_000_000,
            swap_bytes: 0,
            boundary_elapsed_ms: 12,
            thermal_state: GateAThermalState::Nominal,
        }],
    };

    result.validate().unwrap();
    let serialized = serde_json::to_string(&result).unwrap();
    for forbidden in [
        "document_text",
        "spoken_text",
        "ipa",
        "audio_path",
        "/Users/",
    ] {
        assert!(!serialized.contains(forbidden));
    }
}

#[test]
fn gate_a_contract_rejects_invalid_units_limits_and_time_order() {
    let mut invalid = request();
    invalid.expected_repetitions = 0;
    assert_eq!(invalid.validate(), Err(GateAValidationError::InvalidLimit));

    let mut result = GateAResult {
        request: request(),
        validation_run: validation_run(),
        metrics: vec![GateAMetric {
            name: GateAMetricName::RealTimeFactor,
            unit: GateAMetricUnit::Milliseconds,
            repetition: 1,
            monotonic_elapsed_ms: 10,
            numerator: 1,
            denominator: 0,
        }],
        resources: vec![],
    };
    assert_eq!(result.validate(), Err(GateAValidationError::InvalidMetric));

    result.metrics.clear();
    result.resources = vec![
        ResourceSample {
            monotonic_elapsed_ms: 20,
            phys_footprint_bytes: 1,
            rss_bytes: 1,
            swap_bytes: 0,
            boundary_elapsed_ms: 1,
            thermal_state: GateAThermalState::Nominal,
        },
        ResourceSample {
            monotonic_elapsed_ms: 19,
            phys_footprint_bytes: 1,
            rss_bytes: 1,
            swap_bytes: 0,
            boundary_elapsed_ms: 1,
            thermal_state: GateAThermalState::Nominal,
        },
    ];
    assert_eq!(result.validate(), Err(GateAValidationError::NonMonotonic));
}

#[test]
fn gate_a_schema_is_closed_and_contains_no_document_payload_fields() {
    let schema: serde_json::Value = serde_json::from_str(include_str!(
        "../../../contracts/lf-v1/gate-a-run.schema.json"
    ))
    .unwrap();
    assert_eq!(schema["additionalProperties"], false);
    let encoded = serde_json::to_string(&schema).unwrap();
    for forbidden in ["document_text", "spoken_text", "ipa", "audio_path"] {
        assert!(!encoded.contains(forbidden));
    }

    let commands = include_str!("../../../contracts/lf-v1/commands.schema.json");
    let events = include_str!("../../../contracts/lf-v1/events.schema.json");
    assert!(commands.contains("gate_a_run"));
    assert!(commands.contains("gate-a-run.schema.json#/$defs/request"));
    assert!(events.contains("gate-a-run.schema.json#/$defs/progress"));
    assert!(events.contains("gate-a-run.schema.json"));
}
