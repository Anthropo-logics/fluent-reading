use std::fs;
use std::path::Path;

use lectura_core::{
    DistributionStatus, ModelPurpose, NarrationSegment, TtsError, TtsSynthesisRequest,
    TtsSynthesisResult, TtsUnit,
};
use serde_json::{Value, json};

fn contract(name: &str) -> Value {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../contracts/lf-v1")
        .join(name);
    serde_json::from_slice(&fs::read(path).unwrap()).unwrap()
}

#[test]
fn synthesis_result_preserves_unit_order_segments_and_offsets() {
    let request = TtsSynthesisRequest {
        model_id: "kokoro-82m-4bit".into(),
        model_revision: "e4468a460f6f70b9125a003e0adb1ab7d4904bbd".into(),
        runtime_id: "mlx-audio-swift".into(),
        runtime_version: "v0.1.3".into(),
        voice_id: "ef_dora".into(),
        language: "es".into(),
        raw_ipa: true,
        units: vec![TtsUnit {
            unit_id: "unit-1".into(),
            text: "Texto verificable.".into(),
        }],
    };
    let mut result = TtsSynthesisResult {
        model_id: request.model_id.clone(),
        model_revision: request.model_revision.clone(),
        runtime_id: request.runtime_id.clone(),
        runtime_version: request.runtime_version.clone(),
        voice_id: request.voice_id.clone(),
        language: request.language.clone(),
        audio_path: "/tmp/audio.wav".into(),
        segments: vec![NarrationSegment {
            unit_id: "unit-1".into(),
            segment_index: 0,
            unit_sample_offset: 0,
            sample_count: 24_000,
            sample_rate_hz: 24_000,
            elapsed_ms: 1_000,
            artifact_hash: Some("a".repeat(64)),
            model_revision: request.model_revision.clone(),
            voice_id: request.voice_id.clone(),
        }],
        omitted_unit_ids: vec![],
    };
    assert_eq!(result.validate_against(&request), Ok(()));
    result.segments[0].unit_sample_offset = 1;
    assert_eq!(
        result.validate_against(&request),
        Err(TtsError::OutputInvalid)
    );
}

#[test]
fn synthesis_request_accepts_only_fixed_pairs_and_unique_bounded_units() {
    let mut request = TtsSynthesisRequest {
        model_id: "kokoro-82m-4bit".into(),
        model_revision: "e4468a460f6f70b9125a003e0adb1ab7d4904bbd".into(),
        runtime_id: "mlx-audio-swift".into(),
        runtime_version: "v0.1.3".into(),
        voice_id: "ef_dora".into(),
        language: "es".into(),
        raw_ipa: false,
        units: vec![TtsUnit {
            unit_id: "unit-1".into(),
            text: "Texto verificable.".into(),
        }],
    };
    assert_eq!(request.validate(), Ok(()));

    request.units.push(request.units[0].clone());
    assert_eq!(request.validate(), Err(TtsError::OutputInvalid));
    request.units.pop();
    request.voice_id = "em_santa".into();
    assert_eq!(request.validate(), Err(TtsError::LanguageUnsupported));
    request.voice_id = "ef_dora".into();
    request.language = "pt".into();
    assert_eq!(request.validate(), Err(TtsError::LanguageUnsupported));
    request.language = "es".into();
    request.model_revision = "mutable".into();
    assert_eq!(request.validate(), Err(TtsError::LanguageUnsupported));
}

#[test]
fn tts_contract_is_closed_traceable_and_diagnostic_safe() {
    // `translation` purpose is valid from Story 5.1 (harness/spike only; the Swift M2 loader
    // in ModelServices.swift still hardcodes `purpose == "tts"` and never loads it).
    assert!(serde_json::from_value::<ModelPurpose>(json!("translation")).is_ok());
    assert!(serde_json::from_value::<ModelPurpose>(json!("unsupported")).is_err());
    assert!(serde_json::from_value::<DistributionStatus>(json!("approved")).is_err());

    let segment = NarrationSegment {
        unit_id: "unit_1".into(),
        segment_index: 0,
        unit_sample_offset: 0,
        sample_count: 24_000,
        sample_rate_hz: 24_000,
        elapsed_ms: 1_000,
        artifact_hash: None,
        model_revision: "revision-immutable".into(),
        voice_id: "voice".into(),
    };
    assert_eq!(
        serde_json::from_value::<NarrationSegment>(serde_json::to_value(&segment).unwrap())
            .unwrap(),
        segment
    );

    let command = contract("commands.schema.json");
    let event = contract("events.schema.json");
    let manifest = contract("model-manifest.schema.json");
    let synthesis = contract("tts-synthesis.schema.json");
    assert_eq!(
        synthesis["$defs"]["requestPayload"]["properties"]["raw_ipa"]["type"],
        "boolean"
    );
    assert!(
        command["oneOf"]
            .as_array()
            .unwrap()
            .iter()
            .any(|variant| { variant["properties"]["command"]["const"] == "tts_synthesize" })
    );
    assert!(
        event["properties"]["result"]["oneOf"][1]["oneOf"]
            .as_array()
            .unwrap()
            .iter()
            .any(|variant| variant["$ref"] == "tts-synthesis.schema.json#/$defs/result")
    );
    assert_eq!(manifest["properties"]["artifacts"]["maxItems"], 32);
    assert!(
        synthesis["$defs"]["result"]["properties"]
            .get("text")
            .is_none()
    );
    assert!(
        synthesis["$defs"]["result"]["properties"]
            .get("pcm")
            .is_none()
    );

    for error in [
        TtsError::LanguageUnsupported,
        TtsError::SynthesisFailed,
        TtsError::OutputInvalid,
    ] {
        let encoded = serde_json::to_string(&error.as_lf_error()).unwrap();
        assert!(!encoded.contains("document text"));
        assert!(!encoded.contains("pcm"));
        assert!(encoded.contains("LF_TTS_"));
    }
}
