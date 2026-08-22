use lectura_core::{
    ContentClass, ExtractedBlock, PageExtraction, PageProcessingStatus, ProcessingRoute,
    RequestedUnit, SourceRegion, character_error_rate, measure_digital_block_order,
    normalize_digital_document, normalize_digital_page, select_processing_route,
};

/// An upright page. The rotation used to say 90 here while every rectangle below was laid out as
/// an upright page would lay them out — wide, short lines stacked down the Y axis — because the
/// field was inert and nothing read it. Now that the ordering honours it, saying 90 would describe
/// a page whose `/Rotate` and whose content disagree, which is a different fixture entirely (see
/// `a_page_tagged_ninety_degrees_is_read_along_its_own_axis`).
fn region(y: f64) -> SourceRegion {
    SourceRegion {
        page_index: 2,
        rect_pdf_points: [10.0, y, 200.0, 20.0],
        page_rotation_degrees: 0,
        source_to_page_transform: [1.0, 0.0, 0.0, 1.0, 0.0, 0.0],
        confidence: 1.0,
    }
}

#[test]
fn block_order_metric_reports_failures_instead_of_hiding_them() {
    let expected = vec!["a".into(), "b".into(), "c".into()];
    let perfect = measure_digital_block_order(&expected, &expected);
    assert_eq!((perfect.numerator, perfect.denominator), (3, 3));
    assert!(perfect.passed);

    let wrong = measure_digital_block_order(&["b".into(), "a".into()], &expected);
    assert_eq!((wrong.numerator, wrong.denominator), (1, 3));
    assert!(!wrong.passed);
    assert!((wrong.ratio - (1.0 / 3.0)).abs() < f64::EPSILON);

    let duplicate = measure_digital_block_order(&["a".into(), "a".into()], &["a".into()]);
    assert_eq!((duplicate.numerator, duplicate.denominator), (1, 2));
    assert!(!duplicate.passed);
}

#[test]
fn paragraph_and_sentence_units_have_stable_ids_and_round_trip_regions() {
    let page = PageExtraction {
        document_fingerprint: "sha256:fixture".into(),
        generation_id: "generation-1".into(),
        page_index: 2,
        blocks: vec![
            // Indented first line: this is what marks the start of a second paragraph. Without the
            // indent the two lines are, geometrically, one paragraph and are read as one.
            ExtractedBlock {
                block_id: "block-b".into(),
                text: "Segunda frase.".into(),
                region: SourceRegion {
                    rect_pdf_points: [30.0, 10.0, 180.0, 20.0],
                    ..region(10.0)
                },
                confidence: 0.98,
            },
            ExtractedBlock {
                block_id: "block-a".into(),
                text: "Primera frase. Otra oración.".into(),
                region: region(40.0),
                confidence: 0.99,
            },
        ],
    };

    let paragraphs = normalize_digital_page(&page, "es", RequestedUnit::Paragraph);
    assert_eq!(paragraphs.record.status, PageProcessingStatus::Completed);
    assert!(paragraphs.record.page_id.starts_with("page_"));
    assert_eq!(paragraphs.units.len(), 2);
    assert_eq!(paragraphs.units[0].text, "Primera frase. Otra oración.");
    assert_eq!(paragraphs.units[0].source_regions[0], region(40.0));
    assert_eq!(paragraphs.units[0].source_block_ids, ["block-a"]);
    assert_eq!(paragraphs.anchors[0].unit_id, paragraphs.units[0].unit_id);

    let repeated = normalize_digital_page(&page, "es", RequestedUnit::Paragraph);
    assert_eq!(repeated.units, paragraphs.units);

    let sentences = normalize_digital_page(&page, "es", RequestedUnit::Sentence);
    assert_eq!(sentences.units.len(), 3);
    assert!(
        sentences
            .units
            .iter()
            .all(|unit| unit.parent_unit_id.is_some())
    );
    assert_eq!(sentences.units[0].text, "Primera frase.");
}

#[test]
fn a_paragraph_survives_the_sentences_that_end_on_a_line_break() {
    // Six justified lines of one paragraph, as a reflowed page delivers them: three of them end
    // exactly where a sentence ends, which is where the line break fell. The printer's slug line
    // at the foot of the page sits far outside the text block, as it does in a real book.
    let line = |id: &str, text: &str, y: f64, left: f64, width: f64| ExtractedBlock {
        block_id: id.into(),
        text: text.into(),
        region: SourceRegion {
            rect_pdf_points: [left, y, width, 15.0],
            ..region(y)
        },
        confidence: 1.0,
    };
    let page = PageExtraction {
        document_fingerprint: "sha256:reflow".into(),
        generation_id: "generation-1".into(),
        page_index: 2,
        blocks: vec![
            line(
                "l1",
                "Omama fugiu na direção do sol nascente.",
                600.0,
                75.0,
                340.0,
            ),
            line(
                "l2",
                "Além disso, para não ser seguido, cuidou",
                585.0,
                75.0,
                340.0,
            ),
            line(
                "l3",
                "de apagar suas pegadas com folhas.",
                570.0,
                75.0,
                340.0,
            ),
            line(
                "l4",
                "Foram essas palmas que se transformaram",
                555.0,
                75.0,
                340.0,
            ),
            line(
                "l5",
                "em picos rochosos espalhados pela terra.",
                540.0,
                75.0,
                340.0,
            ),
            line("l6", "Assim ele deixou nossa floresta.", 525.0, 75.0, 200.0),
            line("slug", "12959 - A queda do céu.indd 119", 30.0, 31.0, 92.0),
        ],
    };

    let normalized = normalize_digital_page(&page, "pt", RequestedUnit::Paragraph);
    let prose: Vec<&str> = normalized
        .units
        .iter()
        .filter(|unit| unit.source_block_ids.iter().any(|id| id.starts_with('l')))
        .map(|unit| unit.text.as_str())
        .collect();
    assert_eq!(
        prose.len(),
        1,
        "el párrafo debe leerse entero, no frase a frase: {prose:?}"
    );
    assert!(prose[0].starts_with("Omama fugiu"));
    assert!(prose[0].ends_with("deixou nossa floresta."));
}

#[test]
fn an_indented_first_line_and_a_wider_gap_still_open_a_new_paragraph() {
    let line = |id: &str, text: &str, y: f64, left: f64, width: f64| ExtractedBlock {
        block_id: id.into(),
        text: text.into(),
        region: SourceRegion {
            rect_pdf_points: [left, y, width, 15.0],
            ..region(y)
        },
        confidence: 1.0,
    };
    let page = PageExtraction {
        document_fingerprint: "sha256:breaks".into(),
        generation_id: "generation-1".into(),
        page_index: 2,
        blocks: vec![
            line(
                "a1",
                "Primera línea de un párrafo largo que",
                600.0,
                75.0,
                340.0,
            ),
            line(
                "a2",
                "continúa hasta el margen derecho igual.",
                585.0,
                75.0,
                340.0,
            ),
            // Indented: opens the second paragraph even though the line above is full width.
            line(
                "b1",
                "Segundo párrafo que empieza con sangría",
                570.0,
                96.0,
                319.0,
            ),
            line(
                "b2",
                "y sigue hasta el margen derecho también.",
                555.0,
                75.0,
                340.0,
            ),
            // No indent, but separated by more than normal leading: a third paragraph.
            line(
                "c1",
                "Tercer párrafo separado por una línea en",
                510.0,
                75.0,
                340.0,
            ),
            line(
                "c2",
                "blanco en lugar de por una sangría clara.",
                495.0,
                75.0,
                340.0,
            ),
        ],
    };

    let normalized = normalize_digital_page(&page, "es", RequestedUnit::Paragraph);
    let texts: Vec<&str> = normalized
        .units
        .iter()
        .map(|unit| unit.text.as_str())
        .collect();
    assert_eq!(texts.len(), 3, "{texts:?}");
    assert!(texts[0].starts_with("Primera línea"));
    assert!(texts[1].starts_with("Segundo párrafo"));
    assert!(texts[2].starts_with("Tercer párrafo"));
}

#[test]
fn repeated_headers_and_footers_are_removed_with_explicit_trace() {
    let pages: Vec<_> = (0..2)
        .map(|page_index| PageExtraction {
            document_fingerprint: "sha256:fixture".into(),
            generation_id: "generation-1".into(),
            page_index,
            blocks: vec![
                ExtractedBlock {
                    block_id: format!("header-{page_index}"),
                    text: "Título repetido".into(),
                    region: SourceRegion {
                        page_index,
                        ..region(90.0)
                    },
                    confidence: 1.0,
                },
                ExtractedBlock {
                    block_id: format!("body-{page_index}"),
                    text: format!("Contenido {page_index}."),
                    region: SourceRegion {
                        page_index,
                        ..region(50.0)
                    },
                    confidence: 1.0,
                },
                ExtractedBlock {
                    block_id: format!("footer-{page_index}"),
                    text: "Pie repetido".into(),
                    region: SourceRegion {
                        page_index,
                        ..region(10.0)
                    },
                    confidence: 1.0,
                },
            ],
        })
        .collect();

    let normalized = normalize_digital_document(&pages, "es", RequestedUnit::Paragraph);
    assert_eq!(normalized[0].units.len(), 1);
    assert_eq!(normalized[0].units[0].text, "Contenido 0.");
    assert_eq!(normalized[0].omissions.len(), 2);
    assert_eq!(normalized[0].omissions[0].rule, "remove_repeated_header");
    assert_eq!(normalized[0].omissions[1].rule, "remove_repeated_footer");
}

#[test]
fn normalization_traces_hyphen_join_and_empty_pages_fail_locally() {
    let page = PageExtraction {
        document_fingerprint: "sha256:fixture".into(),
        generation_id: "generation-1".into(),
        page_index: 2,
        blocks: vec![ExtractedBlock {
            block_id: "block-a".into(),
            text: "lectu-\nra fluida".into(),
            region: region(10.0),
            confidence: 0.9,
        }],
    };
    let result = normalize_digital_page(&page, "es", RequestedUnit::Paragraph);
    assert_eq!(result.units[0].text, "lectura fluida");
    assert_eq!(
        result.units[0].decision_trace[0].rule,
        "join_line_end_hyphen"
    );
    assert_eq!(
        result.units[0].decision_trace[0].affected_segments,
        vec!["block-a"]
    );

    let empty = normalize_digital_page(
        &PageExtraction {
            blocks: vec![],
            ..page.clone()
        },
        "es",
        RequestedUnit::Paragraph,
    );
    assert_eq!(empty.record.status, PageProcessingStatus::Failed);
    assert_eq!(
        empty.record.error_code.as_deref(),
        Some("LF_PDF_PAGE_NO_TEXT")
    );
    assert!(empty.units.is_empty());

    let numeric = normalize_digital_page(
        &PageExtraction {
            blocks: vec![ExtractedBlock {
                block_id: "numeric".into(),
                text: "10-\n20".into(),
                region: region(10.0),
                confidence: 1.0,
            }],
            ..page
        },
        "es",
        RequestedUnit::Paragraph,
    );
    assert_eq!(numeric.units[0].text, "10- 20");
    assert!(numeric.units[0].decision_trace.is_empty());
}

#[test]
fn route_selection_is_explicit_and_forceable() {
    assert_eq!(
        select_processing_route(2, 1, false),
        ProcessingRoute::DirectText
    );
    assert_eq!(select_processing_route(0, 0, false), ProcessingRoute::Ocr);
    assert_eq!(select_processing_route(1, 2, false), ProcessingRoute::Ocr);
    assert_eq!(select_processing_route(2, 0, true), ProcessingRoute::Ocr);
}

#[test]
fn cer_counts_unicode_substitution_and_empty_reference() {
    let metric = character_error_rate("ação", "açao");
    assert_eq!(metric.distance, 1);
    assert_eq!(metric.reference_characters, 4);
    assert_eq!(metric.ratio, 0.25);
    assert!(!metric.passed);

    let empty = character_error_rate("texto", "");
    assert_eq!(empty.ratio, 1.0);
    assert!(!empty.passed);
}

#[test]
fn cer_compares_canonically_equivalent_text_after_nfc() {
    let metric = character_error_rate("ac\u{327}a\u{303}o", "ação");
    assert_eq!(metric.distance, 0);
    assert_eq!(metric.ratio, 0.0);
    assert!(metric.passed);
}

#[test]
fn complex_and_low_confidence_content_is_never_silent_prose() {
    let page = PageExtraction {
        document_fingerprint: "sha256:fixture".into(),
        generation_id: "generation-1".into(),
        page_index: 2,
        blocks: vec![
            ExtractedBlock {
                block_id: "formula".into(),
                text: "x = √y".into(),
                region: region(30.0),
                confidence: 1.0,
            },
            ExtractedBlock {
                block_id: "uncertain".into(),
                text: "trazo incierto".into(),
                region: region(10.0),
                confidence: 0.4,
            },
        ],
    };
    let result = normalize_digital_page(&page, "es", RequestedUnit::Paragraph);
    assert_eq!(result.record.status, PageProcessingStatus::Degraded);
    assert_eq!(result.units[0].content_class, ContentClass::Formula);
    assert_eq!(result.units[1].content_class, ContentClass::Unsupported);
    assert_eq!(
        result.units[1].decision_trace[0].rule,
        "preserve_uncertain_content"
    );
}

#[test]
fn multicolumn_order_route_notes_and_unreliable_geometry_remain_explicit() {
    let block = |id: &str, text: &str, x: f64, y: f64| ExtractedBlock {
        block_id: id.into(),
        text: text.into(),
        region: SourceRegion {
            rect_pdf_points: [x, y, 100.0, 20.0],
            ..region(y)
        },
        confidence: 1.0,
    };
    let page = PageExtraction {
        document_fingerprint: "sha256:columns".into(),
        generation_id: "generation-1".into(),
        page_index: 2,
        // The vertical distance between the two lines of each column is wider than normal leading,
        // so each line is its own paragraph and the four of them expose the reading order.
        blocks: vec![
            block("right-bottom", "R2", 240.0, 20.0),
            block("left-bottom", "L2", 10.0, 20.0),
            block("right-top", "R1", 240.0, 80.0),
            block("left-top", "L1", 10.0, 80.0),
        ],
    };

    let first = normalize_digital_page(&page, "es", RequestedUnit::Paragraph);
    let second = normalize_digital_page(&page, "es", RequestedUnit::Paragraph);
    assert_eq!(first.units, second.units);
    assert_eq!(
        first
            .units
            .iter()
            .map(|unit| unit.text.as_str())
            .collect::<Vec<_>>(),
        ["L1", "L2", "R1", "R2"]
    );
    assert!(first.units.iter().all(|unit| {
        unit.processing_route == ProcessingRoute::DirectText
            && unit
                .decision_trace
                .iter()
                .any(|trace| trace.rule == "multi_column_order")
    }));

    let special = normalize_digital_page(
        &PageExtraction {
            blocks: vec![
                block("note", "Nota al pie: fuente", 10.0, 30.0),
                ExtractedBlock {
                    block_id: "bad-geometry".into(),
                    text: "contenido preservado".into(),
                    region: SourceRegion {
                        rect_pdf_points: [10.0, 10.0, -1.0, 20.0],
                        ..region(10.0)
                    },
                    confidence: 1.0,
                },
            ],
            ..page
        },
        "es",
        RequestedUnit::Paragraph,
    );
    assert_eq!(special.record.status, PageProcessingStatus::Degraded);
    assert_eq!(special.units[0].content_class, ContentClass::Note);
    assert_eq!(special.units[1].content_class, ContentClass::Unsupported);
    assert_eq!(special.units[1].source_regions[0].confidence, 0.0);
    assert!(
        special.units[1]
            .decision_trace
            .iter()
            .any(|trace| trace.rule == "geometry_unreliable")
    );
}

#[test]
fn printed_page_folio_is_dropped_with_an_auditable_trace_but_years_in_prose_survive() {
    let page = PageExtraction {
        document_fingerprint: "sha256:fixture".into(),
        generation_id: "generation-1".into(),
        page_index: 2,
        blocks: vec![
            ExtractedBlock {
                block_id: "b1".into(),
                text: "Entre 1500 y 1800 la producción material progresa.".into(),
                region: region(400.0),
                confidence: 0.95,
            },
            ExtractedBlock {
                block_id: "b2".into(),
                text: "8".into(),
                region: region(40.0),
                confidence: 0.95,
            },
        ],
    };

    let normalized = normalize_digital_page(&page, "es", RequestedUnit::Paragraph);

    let texts: Vec<&str> = normalized
        .units
        .iter()
        .map(|unit| unit.text.as_str())
        .collect();
    assert!(
        !texts.iter().any(|text| text.trim() == "8"),
        "el folio impreso no debe llegar a la lectura: {texts:?}"
    );
    // The year inside the sentence is prose, not a folio.
    assert!(texts.iter().any(|text| text.contains("1500")));
    assert!(
        normalized
            .omissions
            .iter()
            .any(|omission| omission.rule == "drop_running_folio"),
        "la omisión debe quedar registrada"
    );
}

/// Geometry for a page laid out like a printed book: a wide column of body text with a narrow line
/// of furniture at the foot.
fn placed(x: f64, y: f64, width: f64, height: f64) -> SourceRegion {
    SourceRegion {
        page_index: 0,
        rect_pdf_points: [x, y, width, height],
        page_rotation_degrees: 0,
        source_to_page_transform: [1.0, 0.0, 0.0, 1.0, 0.0, 0.0],
        confidence: 1.0,
    }
}

fn placed_block(id: &str, text: &str, region: SourceRegion) -> ExtractedBlock {
    ExtractedBlock {
        block_id: id.into(),
        text: text.into(),
        region,
        confidence: 1.0,
    }
}

#[test]
fn page_furniture_carrying_a_number_or_a_date_is_removed_across_the_whole_book() {
    // The imprint line and the export stamp a printer leaves at the foot of every page change on
    // every page, so comparing the literal text never matched them and the voice read them aloud.
    let pages: Vec<_> = (0..8_u32)
        .map(|page_index| {
            let mut blocks = vec![];
            // Chapter openings drop the running head; the rule must survive that, not give up.
            if page_index != 3 {
                blocks.push(placed_block(
                    &format!("head-{page_index}"),
                    "a queda do céu",
                    placed(75.0, 700.0, 120.0, 12.0),
                ));
            }
            blocks.push(placed_block(
                &format!("body-a-{page_index}"),
                &format!("Comienzo del párrafo número {page_index} de esta página impresa,"),
                placed(75.0, 600.0, 380.0, 12.0),
            ));
            blocks.push(placed_block(
                &format!("body-b-{page_index}"),
                &format!("que continúa con un cierre distinto en la página {page_index}."),
                placed(75.0, 580.0, 380.0, 12.0),
            ));
            blocks.push(placed_block(
                &format!("imprint-{page_index}"),
                &format!("12959 - A queda do céu.indd {}", page_index + 100),
                placed(31.0, 3.0, 85.0, 10.0),
            ));
            blocks.push(placed_block(
                &format!("stamp-{page_index}"),
                &format!("8/10/15 12:{} PM", 20 + page_index),
                placed(415.0, 3.0, 51.0, 10.0),
            ));
            PageExtraction {
                document_fingerprint: "sha256:fixture".into(),
                generation_id: "generation-1".into(),
                page_index,
                blocks,
            }
        })
        .collect();

    let normalized = normalize_digital_document(&pages, "es", RequestedUnit::Paragraph);
    let texts: Vec<&str> = normalized
        .iter()
        .flat_map(|page| page.units.iter().map(|unit| unit.text.as_str()))
        .collect();
    assert!(
        !texts.iter().any(|text| text.contains(".indd")),
        "el pie de imprenta no debe llegar a la lectura: {texts:?}"
    );
    assert!(
        !texts.iter().any(|text| text.contains(" PM")),
        "la marca de fecha y hora no debe llegar a la lectura: {texts:?}"
    );
    assert!(
        !texts.iter().any(|text| text.contains("queda do céu")),
        "el encabezado repetido tampoco, aunque falte en una página: {texts:?}"
    );
    // Nothing disappears silently: every removal leaves its rule in the trace.
    assert_eq!(
        normalized[0]
            .omissions
            .iter()
            .filter(|omission| omission.rule == "remove_repeated_footer")
            .count(),
        2
    );
    assert!(
        normalized[0]
            .omissions
            .iter()
            .any(|omission| omission.rule == "remove_repeated_header")
    );
    // The body of every page survives, including the page that had no running head.
    assert!(texts.iter().any(|text| text.contains("página 3.")));
    assert_eq!(normalized[3].units.len(), 1);
}

#[test]
fn a_bottom_line_that_does_not_repeat_is_never_taken_for_furniture() {
    let pages: Vec<_> = (0..6_u32)
        .map(|page_index| PageExtraction {
            document_fingerprint: "sha256:fixture".into(),
            generation_id: "generation-1".into(),
            page_index,
            blocks: vec![
                placed_block(
                    &format!("body-{page_index}"),
                    match page_index {
                        0 => "El relator abrió la sesión con una advertencia larga.",
                        1 => "Los testigos entraron de uno en uno por la puerta lateral.",
                        2 => "La discusión se alargó hasta bien entrada la madrugada.",
                        3 => "Nadie tomó nota de lo que se dijo en ese tramo.",
                        4 => "El acta quedó incompleta por razones que nunca se aclararon.",
                        _ => "La sesión se levantó sin acuerdo y sin fecha nueva.",
                    },
                    placed(75.0, 600.0, 380.0, 12.0),
                ),
                placed_block(
                    &format!("close-{page_index}"),
                    match page_index {
                        0 => "Y así terminó la primera jornada.",
                        1 => "El testimonio siguió al día siguiente.",
                        2 => "Nadie volvió a hablar del asunto.",
                        3 => "La carta llegó tres semanas después.",
                        4 => "Se despidieron en la estación.",
                        _ => "El expediente sigue abierto.",
                    },
                    placed(75.0, 60.0, 200.0, 12.0),
                ),
            ],
        })
        .collect();

    let normalized = normalize_digital_document(&pages, "es", RequestedUnit::Paragraph);
    assert!(
        normalized
            .iter()
            .all(|page| page.omissions.is_empty() && page.units.len() == 2),
        "no hay plantilla repetida, así que no debe descartarse nada"
    );
}

#[test]
fn a_numbered_footnote_is_kept_on_the_page_but_left_out_of_the_narration() {
    let page = PageExtraction {
        document_fingerprint: "sha256:fixture".into(),
        generation_id: "generation-1".into(),
        page_index: 0,
        blocks: vec![
            placed_block(
                "body-a",
                "El relato de los ancianos sostiene que la casa se levantó sobre la ceniza,",
                placed(75.0, 700.0, 380.0, 12.0),
            ),
            placed_block(
                "body-b",
                "y que nadie volvió a nombrar a quienes la habían encendido.",
                placed(75.0, 400.0, 380.0, 12.0),
            ),
            placed_block(
                "note",
                "1. Centro de Investigaciones Populares (CIP), Caracas.",
                placed(75.0, 80.0, 220.0, 10.0),
            ),
        ],
    };

    let normalized = normalize_digital_page(&page, "es", RequestedUnit::Paragraph);
    let note = normalized
        .units
        .iter()
        .find(|unit| unit.text.starts_with("1. Centro"))
        .expect("la nota sigue en el texto y en la pantalla");
    assert_eq!(note.content_class, ContentClass::Note);

    // Kept, but the voice steps over it: what breaks the thread of listening is hearing the note.
    let queue = lectura_core::NarrationQueue::from_current(
        &normalized.units,
        &normalized.units[0].unit_id,
        10,
    )
    .expect("hay prosa que narrar");
    assert!(!queue.unit_ids.contains(&note.unit_id));
    assert_eq!(queue.unit_ids.len(), 2);
}

#[test]
fn a_numbered_line_in_the_body_of_the_page_stays_prose() {
    let page = PageExtraction {
        document_fingerprint: "sha256:fixture".into(),
        generation_id: "generation-1".into(),
        page_index: 0,
        blocks: vec![
            placed_block(
                "body-a",
                "La sentencia enumera los fundamentos del fallo en tres apartados:",
                placed(75.0, 700.0, 380.0, 12.0),
            ),
            placed_block(
                "list",
                "1. Primero viene el fundamento constitucional del derecho invocado.",
                placed(75.0, 500.0, 380.0, 12.0),
            ),
            placed_block(
                "body-b",
                "El tribunal cierra el razonamiento sin admitir la excepción alegada.",
                placed(75.0, 120.0, 380.0, 12.0),
            ),
        ],
    };

    let normalized = normalize_digital_page(&page, "es", RequestedUnit::Paragraph);
    let item = normalized
        .units
        .iter()
        .find(|unit| unit.text.starts_with("1. Primero"))
        .expect("el elemento numerado sigue presente");
    assert_eq!(
        item.content_class,
        ContentClass::Prose,
        "una lista numerada en mitad de la página no es una nota al pie"
    );
}

/// The reading order of a page the PDF itself tags `/Rotate 90`.
///
/// The geometry below is the real one: the first nine lines of page 5 of `Goldberg2002`, straight
/// out of `PDFSelection.bounds(for:)`, rounded to the hundredth of a point. On such a page the
/// lines of type run along the page's **Y** axis — every box is about 20 pt wide and 310 pt tall —
/// and advance along **X**. Ordering by `rect[1]`, which is what this file did while
/// `page_rotation_degrees` went unread, scattered them: the reader heard "ate — n On".
///
/// The expected order is the visual one, read off the page as it is displayed.
#[test]
fn a_page_tagged_ninety_degrees_is_read_along_its_own_axis() {
    let turned = |id: &str, text: &str, x: f64, y: f64, width: f64, height: f64| ExtractedBlock {
        block_id: id.into(),
        text: text.into(),
        region: SourceRegion {
            page_index: 5,
            rect_pdf_points: [x, y, width, height],
            page_rotation_degrees: 90,
            source_to_page_transform: [1.0, 0.0, 0.0, 1.0, 0.0, 0.0],
            confidence: 1.0,
        },
        confidence: 1.0,
    };
    // Deliberately handed over shuffled: what has to come out in reading order is the geometry,
    // not the order the blocks happened to arrive in.
    let page = PageExtraction {
        document_fingerprint: "sha256:goldberg".into(),
        generation_id: "generation-1".into(),
        page_index: 5,
        blocks: vec![
            turned(
                "page-5-block-3",
                "The productive possibilities of that turn seem to have run their course.",
                47.07,
                128.94,
                19.99,
                310.67,
            ),
            turned(
                "page-5-block-0",
                "decades has seductively prompted, for better and worse. Liberalism's",
                9.25,
                130.77,
                18.93,
                310.72,
            ),
            turned(
                "page-5-block-2",
                "infatuation with racial identities in the dying decades of the century.",
                34.08,
                129.65,
                20.16,
                310.19,
            ),
            turned(
                "page-5-block-1",
                "dance around race relations at mid-century has given way to the",
                21.84,
                130.38,
                19.54,
                310.24,
            ),
        ],
    };

    let normalized = normalize_digital_page(&page, "en", RequestedUnit::Paragraph);
    let read: Vec<&str> = normalized
        .units
        .iter()
        .flat_map(|unit| unit.text.split_whitespace().next())
        .collect();
    assert_eq!(
        read,
        ["decades"],
        "the four lines are one paragraph, opening on the line the reader sees first"
    );
    assert_eq!(
        normalized.units[0].text,
        "decades has seductively prompted, for better and worse. Liberalism's dance around race \
         relations at mid-century has given way to the infatuation with racial identities in the \
         dying decades of the century. The productive possibilities of that turn seem to have run \
         their course.",
        "the lines join in the order they are read on the rotated page"
    );
    // The regions that leave the engine stay in page space, untouched, or highlighting on the PDF
    // would land somewhere other than the words.
    assert_eq!(
        normalized.units[0].source_regions[0].rect_pdf_points,
        [9.25, 130.77, 18.93, 310.72]
    );
    assert_eq!(
        normalized.units[0].source_regions[0].page_rotation_degrees,
        90
    );
}

/// The same page turned the other way. `/Rotate 270` reverses both axes of the quarter turn: the
/// reader's first line is the one with the **largest** x, and a line runs from large y to small.
#[test]
fn a_page_tagged_two_hundred_and_seventy_degrees_reverses_both_axes() {
    let turned = |id: &str, text: &str, x: f64, y: f64| ExtractedBlock {
        block_id: id.into(),
        text: text.into(),
        region: SourceRegion {
            page_index: 0,
            rect_pdf_points: [x, y, 20.0, 300.0],
            page_rotation_degrees: 270,
            source_to_page_transform: [1.0, 0.0, 0.0, 1.0, 0.0, 0.0],
            confidence: 1.0,
        },
        confidence: 1.0,
    };
    let page = PageExtraction {
        document_fingerprint: "sha256:turned".into(),
        generation_id: "generation-1".into(),
        page_index: 0,
        blocks: vec![
            turned("block-c", "y la tercera cierra el párrafo.", 60.0, 100.0),
            turned("block-a", "Primera línea de la página girada", 100.0, 100.0),
            turned("block-b", "seguida de la segunda línea", 80.0, 100.0),
        ],
    };

    let normalized = normalize_digital_page(&page, "es", RequestedUnit::Paragraph);
    assert_eq!(
        normalized.units[0].text,
        "Primera línea de la página girada seguida de la segunda línea y la tercera cierra el \
         párrafo."
    );
}

/// A page whose `/Rotate` is not a quarter turn has no axis to swap. Leaving it exactly as it was
/// is the only safe answer: guessing an axis from a 45° tag would scatter a page that reads fine.
#[test]
fn a_rotation_that_is_not_a_quarter_turn_changes_nothing() {
    let skewed = |id: &str, text: &str, y: f64| ExtractedBlock {
        block_id: id.into(),
        text: text.into(),
        region: SourceRegion {
            page_index: 0,
            rect_pdf_points: [10.0, y, 200.0, 20.0],
            page_rotation_degrees: 45,
            source_to_page_transform: [1.0, 0.0, 0.0, 1.0, 0.0, 0.0],
            confidence: 1.0,
        },
        confidence: 1.0,
    };
    let page = PageExtraction {
        document_fingerprint: "sha256:skewed".into(),
        generation_id: "generation-1".into(),
        page_index: 0,
        blocks: vec![
            skewed("block-b", "y la segunda debajo.", 40.0),
            skewed("block-a", "Primera línea arriba", 60.0),
        ],
    };

    let normalized = normalize_digital_page(&page, "es", RequestedUnit::Paragraph);
    assert_eq!(
        normalized.units[0].text,
        "Primera línea arriba y la segunda debajo."
    );
}

/// A negative `/Rotate` is legal in PDF and means the same quarter turn as its positive twin:
/// `-90` is `270`. Producers do write it, and reading it as "not a quarter turn" would leave the
/// page scattered for the sake of a sign.
#[test]
fn a_negative_rotation_means_the_same_quarter_turn() {
    let turned = |id: &str, text: &str, x: f64, degrees: i16| ExtractedBlock {
        block_id: id.into(),
        text: text.into(),
        region: SourceRegion {
            page_index: 0,
            rect_pdf_points: [x, 100.0, 20.0, 300.0],
            page_rotation_degrees: degrees,
            source_to_page_transform: [1.0, 0.0, 0.0, 1.0, 0.0, 0.0],
            confidence: 1.0,
        },
        confidence: 1.0,
    };
    for degrees in [270_i16, -90_i16] {
        let page = PageExtraction {
            document_fingerprint: "sha256:negative".into(),
            generation_id: "generation-1".into(),
            page_index: 0,
            blocks: vec![
                turned("block-b", "y la segunda después.", 60.0, degrees),
                turned("block-a", "Primera línea de la página", 100.0, degrees),
            ],
        };
        let normalized = normalize_digital_page(&page, "es", RequestedUnit::Paragraph);
        assert_eq!(
            normalized.units[0].text, "Primera línea de la página y la segunda después.",
            "rotation {degrees} must be read as the same quarter turn as 270"
        );
    }
}

/// A chapter opening, laid out the way `fanon-scanned.pdf` lays one out: the title set large over
/// two lines, the second of them opening in lower case because it is the same sentence carried on,
/// and the body underneath at body size.
fn chapter_opening(second_title_line: &str, second_line_height: f64) -> PageExtraction {
    let mut blocks = vec![
        placed_block(
            "title-a",
            "III El hombre de color",
            placed(150.0, 700.0, 200.0, 38.0),
        ),
        placed_block(
            "title-b",
            second_title_line,
            placed(180.0, 660.0, 170.0, second_line_height),
        ),
    ];
    for (index, y) in [600.0, 580.0, 560.0, 540.0, 520.0].into_iter().enumerate() {
        blocks.push(placed_block(
            &format!("body-{index}"),
            "Desde la parte más negra de mi alma me sube ese deseo de ser de pronto blanco",
            placed(75.0, y, 380.0, 12.0),
        ));
    }
    PageExtraction {
        document_fingerprint: "sha256:fixture".into(),
        generation_id: "generation-1".into(),
        page_index: 0,
        blocks,
    }
}

#[test]
fn a_chapter_title_set_on_two_lines_arrives_as_one_heading() {
    // The reader used to hear "y la blanca" appear out of nowhere at the opening of the chapter:
    // the page's geometry splits a centred title in two, the heading test promotes only the first
    // line — a continuation opens in lower case, which that test rejects on purpose — and the
    // narration filter then dropped the half that had been classed `heading`.
    let normalized = normalize_digital_page(
        &chapter_opening("y la blanca", 20.0),
        "es",
        RequestedUnit::Paragraph,
    );

    let headings: Vec<&lectura_core::ReadingUnit> = normalized
        .units
        .iter()
        .filter(|unit| unit.content_class == ContentClass::Heading)
        .collect();
    assert_eq!(headings.len(), 1, "el título es uno, no dos");
    assert_eq!(headings[0].text, "III El hombre de color y la blanca");

    // Both source lines still point back at the page, so the highlight keeps landing on the words.
    assert_eq!(headings[0].source_block_ids, vec!["title-a", "title-b"]);
    assert_eq!(headings[0].source_regions.len(), 2);
    assert!(
        headings[0]
            .decision_trace
            .iter()
            .any(|decision| decision.rule == "join_heading_continuation"),
        "la unión debe quedar registrada"
    );

    // And the body underneath is still its own passage, not part of the title.
    assert!(
        normalized
            .units
            .iter()
            .any(|unit| unit.content_class == ContentClass::Prose
                && unit.text.starts_with("Desde la parte")),
        "el cuerpo de la página no se absorbe en el título"
    );
}

#[test]
fn only_a_line_set_at_title_size_and_opening_in_lower_case_rejoins_a_title() {
    // Size alone would swallow the first entry under a "Bibliografía" heading, which is set large
    // and opens in capitals. Case alone would swallow the body paragraph under a title whenever it
    // happened to start mid-sentence. Both signals are required.
    let capitalised = normalize_digital_page(
        &chapter_opening("BALANDIER, G., Daily Life in the Kingdom", 20.0),
        "es",
        RequestedUnit::Paragraph,
    );
    assert!(
        capitalised
            .units
            .iter()
            .any(|unit| unit.text == "III El hombre de color"),
        "una entrada que abre en mayúsculas no continúa el título: {:?}",
        capitalised
            .units
            .iter()
            .map(|u| &u.text)
            .collect::<Vec<_>>()
    );

    let body_sized = normalize_digital_page(
        &chapter_opening("y la blanca", 12.0),
        "es",
        RequestedUnit::Paragraph,
    );
    assert!(
        body_sized
            .units
            .iter()
            .any(|unit| unit.text == "III El hombre de color"),
        "una línea al cuerpo de la página no continúa el título: {:?}",
        body_sized.units.iter().map(|u| &u.text).collect::<Vec<_>>()
    );
}

#[test]
fn the_voice_reads_the_chapter_title_it_reaches() {
    // `ContentClass::Heading` has always said headings are narratable content; the queue that
    // decides what the voice reads was the place that disagreed.
    let normalized = normalize_digital_page(
        &chapter_opening("y la blanca", 20.0),
        "es",
        RequestedUnit::Paragraph,
    );
    let title = normalized
        .units
        .iter()
        .find(|unit| unit.content_class == ContentClass::Heading)
        .expect("la página abre con un título");

    let queue = lectura_core::NarrationQueue::from_current(&normalized.units, &title.unit_id, 10)
        .expect("hay algo que narrar");
    assert!(
        queue.unit_ids.contains(&title.unit_id),
        "el lector debe oír el título del capítulo al llegar a él"
    );
}
