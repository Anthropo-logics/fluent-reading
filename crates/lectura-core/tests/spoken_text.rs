use lectura_core::{
    ContentClass, ReadingUnit, ReadingUnitKind, SpokenPart, UnitOrderKey, espeak_stdin, spoken_plan,
};

#[test]
fn normalizes_only_universal_forms_without_mutating_the_reading_unit() {
    let cases = [
        (
            "pt",
            "  Tambem era rapido; NAQUELLE lugar.  ",
            "Tambem era rapido; NAQUELLE lugar.",
            "pt-br",
        ),
        (
            "es",
            "Puso en efeto\nlo que debía emendar.",
            "Puso en efeto lo que debía emendar.",
            "es",
        ),
        (
            "en",
            "CHAPTER I. Alice waited.",
            "Chapter one. Alice waited.",
            "en-us",
        ),
    ];

    for (language, source, expected, voice) in cases {
        let unit = ReadingUnit {
            unit_id: "unit-1".into(),
            kind: ReadingUnitKind::Paragraph,
            content_class: ContentClass::Prose,
            processing_route: lectura_core::ProcessingRoute::DirectText,
            order_key: UnitOrderKey {
                primary_page_index: 0,
                local_index: 0,
            },
            text: source.into(),
            spoken_text: source.into(),
            source_regions: vec![],
            source_block_ids: vec![],
            parent_unit_id: None,
            confidence: 1.0,
            decision_trace: vec![],
        };
        let original = unit.clone();
        let plan = spoken_plan(&unit.text, language).unwrap();

        assert_eq!(plan.normalized_text, expected);
        assert_eq!(plan.frontend_voice, voice);
        assert_eq!(unit, original);
    }
}

#[test]
fn preserves_prosodic_punctuation_and_final_phoneme_input_contract() {
    let plan = spoken_plan("Hechas, pues: adelante.", "es").unwrap();
    assert_eq!(
        plan.parts,
        vec![
            SpokenPart::Text("Hechas".into()),
            SpokenPart::Punctuation(",".into()),
            SpokenPart::Text("pues".into()),
            SpokenPart::Punctuation(":".into()),
            SpokenPart::Text("adelante".into()),
            SpokenPart::Punctuation(".".into()),
        ]
    );
    assert_eq!(espeak_stdin("adelante"), "adelante\n");
}

#[test]
fn decimals_and_abbreviations_stay_inside_the_phonetic_span() {
    let plan = spoken_plan("Dr. Pérez citó el art. 59.1 en 2011; eran 20,5%.", "es").unwrap();
    assert_eq!(
        plan.parts,
        vec![
            SpokenPart::Text("Dr. Pérez citó el art. 59.1 en 2011".into()),
            SpokenPart::Punctuation(";".into()),
            SpokenPart::Text("eran 20,5%".into()),
            SpokenPart::Punctuation(".".into()),
        ]
    );
}

#[test]
fn rejects_languages_outside_the_validated_set() {
    let error = spoken_plan("Salut", "fr").unwrap_err();
    assert_eq!(error.code(), "LF_TTS_LANGUAGE_UNSUPPORTED");
}

#[test]
fn leaves_historical_and_general_unicode_text_for_the_pinned_phonetic_dictionary() {
    let plan = spoken_plan("İstanbul déjà-vu; efeto.", "es").unwrap();
    assert_eq!(plan.normalized_text, "İstanbul déjà-vu; efeto.");
}
