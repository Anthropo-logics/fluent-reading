use lectura_core::{
    TranslatedUnit, TranslationError, TranslationRequest, TranslationResult, TranslationUnit,
};

fn request(source: &str, target: &str, units: Vec<TranslationUnit>) -> TranslationRequest {
    TranslationRequest {
        model_id: "translation-candidate".into(),
        model_revision: "revision123".into(),
        runtime_id: "runtime-test".into(),
        runtime_version: "1.0.0".into(),
        source_language: source.into(),
        target_language: target.into(),
        units,
    }
}

fn unit(id: &str, text: &str) -> TranslationUnit {
    TranslationUnit {
        unit_id: id.into(),
        text: text.into(),
    }
}

fn translated(id: &str, sources: &[&str], order: u32, text: &str) -> TranslatedUnit {
    TranslatedUnit {
        translated_unit_id: id.into(),
        source_unit_ids: sources.iter().map(|s| s.to_string()).collect(),
        order_key: order,
        translated_text: text.into(),
    }
}

#[test]
fn request_accepts_only_the_six_supported_directions() {
    for (source, target) in [
        ("es", "en"),
        ("es", "pt"),
        ("en", "es"),
        ("en", "pt"),
        ("pt", "es"),
        ("pt", "en"),
    ] {
        let request = request(source, target, vec![unit("u1", "texto")]);
        assert_eq!(request.validate(), Ok(()));
    }

    assert_eq!(
        request("es", "es", vec![unit("u1", "texto")]).validate(),
        Err(TranslationError::DirectionUnsupported)
    );
    assert_eq!(
        request("es", "fr", vec![unit("u1", "texto")]).validate(),
        Err(TranslationError::DirectionUnsupported)
    );
}

#[test]
fn request_rejects_empty_or_duplicate_units() {
    assert_eq!(
        request("es", "en", vec![]).validate(),
        Err(TranslationError::DirectionUnsupported)
    );
    assert_eq!(
        request(
            "es",
            "en",
            vec![unit("u1", "texto"), unit("u1", "otro texto")]
        )
        .validate(),
        Err(TranslationError::OutputInvalid)
    );
}

#[test]
fn result_accepts_one_to_many_and_many_to_one_correspondence_without_loss_or_duplication() {
    let request = request(
        "es",
        "en",
        vec![
            unit("u1", "Una oración"),
            unit("u2", "larga que cruza."),
            unit("u3", "Independiente."),
        ],
    );

    // many-to-one: u1+u2 -> t1 ; one-to-one: u3 -> t2
    let result = TranslationResult {
        model_id: request.model_id.clone(),
        model_revision: request.model_revision.clone(),
        runtime_id: request.runtime_id.clone(),
        runtime_version: request.runtime_version.clone(),
        source_language: request.source_language.clone(),
        target_language: request.target_language.clone(),
        translated_units: vec![
            translated("t1", &["u1", "u2"], 0, "A long sentence that crosses."),
            translated("t2", &["u3"], 1, "Independent."),
        ],
        failed_unit_ids: vec![],
    };
    assert_eq!(result.validate_against(&request), Ok(()));
}

#[test]
fn result_rejects_lost_duplicated_or_misordered_source_units() {
    let request = request("es", "en", vec![unit("u1", "uno"), unit("u2", "dos")]);

    let lost = TranslationResult {
        model_id: request.model_id.clone(),
        model_revision: request.model_revision.clone(),
        runtime_id: request.runtime_id.clone(),
        runtime_version: request.runtime_version.clone(),
        source_language: request.source_language.clone(),
        target_language: request.target_language.clone(),
        translated_units: vec![translated("t1", &["u1"], 0, "one")],
        failed_unit_ids: vec![],
    };
    assert_eq!(
        lost.validate_against(&request),
        Err(TranslationError::MappingInvalid)
    );

    let duplicated = TranslationResult {
        translated_units: vec![
            translated("t1", &["u1"], 0, "one"),
            translated("t2", &["u1", "u2"], 1, "one two"),
        ],
        ..lost.clone()
    };
    assert_eq!(
        duplicated.validate_against(&request),
        Err(TranslationError::MappingInvalid)
    );

    let both_translated_and_failed = TranslationResult {
        translated_units: vec![translated("t1", &["u1"], 0, "one")],
        failed_unit_ids: vec!["u1".into()],
        ..lost.clone()
    };
    assert_eq!(
        both_translated_and_failed.validate_against(&request),
        Err(TranslationError::MappingInvalid)
    );

    let out_of_order = TranslationResult {
        translated_units: vec![
            translated("t1", &["u1"], 1, "one"),
            translated("t2", &["u2"], 0, "two"),
        ],
        failed_unit_ids: vec![],
        ..lost
    };
    assert_eq!(
        out_of_order.validate_against(&request),
        Err(TranslationError::MappingInvalid)
    );
}

#[test]
fn result_accepts_explicit_failed_units_without_losing_the_rest() {
    let request = request("pt", "es", vec![unit("u1", "um"), unit("u2", "dois")]);
    let partial = TranslationResult {
        model_id: request.model_id.clone(),
        model_revision: request.model_revision.clone(),
        runtime_id: request.runtime_id.clone(),
        runtime_version: request.runtime_version.clone(),
        source_language: request.source_language.clone(),
        target_language: request.target_language.clone(),
        translated_units: vec![translated("t1", &["u1"], 0, "uno")],
        failed_unit_ids: vec!["u2".into()],
    };
    assert_eq!(partial.validate_against(&request), Ok(()));
}
