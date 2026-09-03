use lectura_core::{CORE_VERSION, RequestError, handle_request};
use serde_json::json;

const FINGERPRINT_A: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const FINGERPRINT_B: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbc";

const VALID_REQUEST: &[u8] =
    br#"{"schema_version":1,"request_id":"req_opaque","command":"canary","payload":{}}"#;

#[test]
fn canary_returns_one_structured_terminal_event() {
    let event = handle_request(VALID_REQUEST).expect("the literal LF v1 request must be valid");

    assert_eq!(event.schema_version, 1);
    assert_eq!(event.request_id, "req_opaque");
    assert!(event.job_id.starts_with("job_"));
    assert_eq!(event.sequence, 0);
    assert_eq!(event.kind, "completed");
    assert_eq!(event.progress, None);
    assert_eq!(
        serde_json::to_value(event.result).expect("result must serialize"),
        json!({"core_version":"0.1.0","message":"lectura-core ready"})
    );
    assert_eq!(event.error, None);
    assert_eq!(event.recovery, None);
    assert_eq!(CORE_VERSION, "0.1.0");
}

#[test]
fn spoken_plan_is_available_through_the_shared_contract() {
    let event = handle_request(
        r#"{"schema_version":1,"request_id":"req_spoken","command":"plan_spoken_text","payload":{"text":"Una frase, con pausa — y cierre.","language":"es"}}"#
            .as_bytes(),
    )
    .expect("the app and CLI must consume the same spoken plan");
    let result = serde_json::to_value(event.result).expect("result must serialize");

    assert_eq!(result["frontend_voice"], "es");
    assert_eq!(
        result["normalized_text"],
        "Una frase, con pausa — y cierre."
    );
    assert_eq!(
        result["parts"][1],
        json!({"kind":"punctuation","value":","})
    );
    assert!(
        result["parts"]
            .as_array()
            .is_some_and(|parts| parts.contains(&json!({"kind":"punctuation","value":"—"})))
    );
}

#[test]
fn unknown_schema_version_is_rejected_before_work_starts() {
    let request =
        br#"{"schema_version":2,"request_id":"req_version","command":"canary","payload":{}}"#;

    let error = handle_request(request).expect_err("LF v2 is not supported");

    assert_eq!(
        error,
        RequestError::UnsupportedSchemaVersion { observed: 2 }
    );
    assert_eq!(error.as_lf_error().code, "LF_CONTRACT_VERSION_UNSUPPORTED");
}

#[test]
fn unknown_command_is_rejected_before_work_starts() {
    let request =
        br#"{"schema_version":1,"request_id":"req_command","command":"future","payload":{}}"#;

    let error = handle_request(request).expect_err("future commands must not be guessed");

    assert_eq!(error, RequestError::UnknownCommand);
    assert_eq!(error.as_lf_error().code, "LF_CONTRACT_COMMAND_UNKNOWN");
}

#[test]
fn malformed_json_becomes_a_safe_contract_error() {
    let error =
        handle_request(br#"{"schema_version":1"#).expect_err("truncated JSON must not create work");

    assert_eq!(error, RequestError::InvalidJson);
    let lf_error = error.as_lf_error();
    assert_eq!(lf_error.code, "LF_CONTRACT_INVALID_JSON");
    assert_eq!(lf_error.message_key, "contract.invalid_json");
    assert!(lf_error.details.is_empty());
}

fn open_document_request(fingerprint: &str) -> Vec<u8> {
    format!(
        r#"{{"schema_version":1,"request_id":"req_open","command":"open_document","payload":{{"access_grant_id":"grant_opaque","document_fingerprint":"{fingerprint}","page_count":2,"first_page_ms":125}}}}"#
    )
    .into_bytes()
}

fn opened_document_id(fingerprint: &str) -> String {
    let event = handle_request(&open_document_request(fingerprint))
        .expect("valid document facts should be accepted");
    serde_json::to_value(event.result).expect("result must serialize")["document_id"]
        .as_str()
        .expect("an opened document must be named")
        .to_owned()
}

#[test]
fn opens_document_with_only_opaque_and_numeric_platform_facts() {
    let event = handle_request(&open_document_request(FINGERPRINT_A))
        .expect("valid document facts should be accepted");

    assert_eq!(event.kind, "completed");
    let result = serde_json::to_value(event.result).expect("result must serialize");
    assert!(
        result["document_id"]
            .as_str()
            .is_some_and(|id| id.starts_with("doc_"))
    );
    assert_eq!(result["access_grant_id"], "grant_opaque");
    assert_eq!(result["page_count"], 2);
    assert_eq!(result["first_page_ms"], 125);
}

#[test]
fn opening_primes_repeated_furniture_before_the_first_page_is_normalized() {
    let fingerprint = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
    let pages: Vec<_> = (0..6_u32)
        .map(|page_index| {
            json!({
                "document_fingerprint": fingerprint,
                "generation_id": "generation_c",
                "page_index": page_index,
                "blocks": [
                    {
                        "block_id": format!("body-{page_index}"),
                        "text": format!("Contenido distinto y legible de la página {page_index}."),
                        "region": {
                            "page_index": page_index,
                            "rect_pdf_points": [60.0, 600.0, 380.0, 12.0],
                            "page_rotation_degrees": 0,
                            "source_to_page_transform": [1.0, 0.0, 0.0, 1.0, 0.0, 0.0],
                            "confidence": 1.0
                        },
                        "confidence": 1.0
                    },
                    {
                        "block_id": format!("footer-{page_index}"),
                        "text": "Published by Digital Commons, 2011",
                        "region": {
                            "page_index": page_index,
                            "rect_pdf_points": [60.0, 5.0, 220.0, 10.0],
                            "page_rotation_degrees": 0,
                            "source_to_page_transform": [1.0, 0.0, 0.0, 1.0, 0.0, 0.0],
                            "confidence": 1.0
                        },
                        "confidence": 1.0
                    }
                ]
            })
        })
        .collect();
    let opened = json!({
        "schema_version": 1,
        "request_id": "req_open_primed",
        "command": "open_document",
        "payload": {
            "access_grant_id": "grant_opaque",
            "document_fingerprint": fingerprint,
            "page_count": 6,
            "first_page_ms": 125,
            "furniture_pages": pages
        }
    });
    handle_request(opened.to_string().as_bytes()).expect("opening should accept its margin sample");

    let normalized = json!({
        "schema_version": 1,
        "request_id": "req_normalize_primed",
        "command": "normalize_page",
        "payload": {
            "page": pages[0],
            "language": "en",
            "requested_unit": "paragraph",
            "route": "direct_text",
            "adapter_status": "completed"
        }
    });
    let event = handle_request(normalized.to_string().as_bytes()).expect("page should normalize");
    let result = serde_json::to_value(event.result).expect("result must serialize");

    assert_eq!(result["units"].as_array().map(Vec::len), Some(1));
    assert_eq!(
        result["units"][0]["text"],
        "Contenido distinto y legible de la página 0."
    );
    assert_eq!(result["omissions"][0]["rule"], "remove_repeated_footer");
}

/// The document, not the run, names the derived data (Story 6.25).
///
/// A launch counter gave the first document of every launch the same name, so a second document
/// inherited — and on "delete processed data" destroyed — the first one's session directory. Two
/// opens of the same file must agree, and two different files must not, in the same process and
/// across processes alike; deriving the name from the file's own bytes is what makes both true.
#[test]
fn names_a_document_after_its_contents_not_after_the_order_it_was_opened() {
    let first = opened_document_id(FINGERPRINT_A);
    let second = opened_document_id(FINGERPRINT_B);
    let first_again = opened_document_id(FINGERPRINT_A);

    assert_eq!(first, first_again, "the same document must keep its name");
    assert_ne!(first, second, "two documents must never share a name");
    assert_eq!(first, format!("doc_{}", &FINGERPRINT_A[..32]));
}

#[test]
fn rejects_a_fingerprint_that_is_not_one() {
    for fingerprint in [
        "",
        "not-hex",
        &"a".repeat(63),
        &"A".repeat(64),
        &"a".repeat(65),
    ] {
        assert_eq!(
            handle_request(&open_document_request(fingerprint))
                .expect_err("a name that is not a fingerprint must be refused"),
            RequestError::InvalidPayload,
            "accepted {fingerprint:?}"
        );
    }
}

#[test]
fn rejects_a_document_path_at_the_core_boundary() {
    let error = handle_request(
        br#"{"schema_version":1,"request_id":"req_open","command":"open_document","payload":{"access_grant_id":"grant_opaque","document_fingerprint":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","page_count":2,"first_page_ms":125,"path":"/private/document.pdf"}}"#,
    )
    .expect_err("paths must never cross into the core");

    assert_eq!(error, RequestError::InvalidPayload);
}

#[test]
fn plans_visible_page_first_without_document_content() {
    let event = handle_request(
        br#"{"schema_version":1,"request_id":"req_plan","command":"plan_session","payload":{"document_id":"doc_opaque","page_count":4,"visible_page_index":2}}"#,
    )
    .expect("valid session facts should be accepted");
    let result = serde_json::to_value(event.result).expect("result must serialize");
    assert_eq!(result["visible_page_index"], 2);
    assert_eq!(result["pages"][2]["state"], "processing");
    assert!(result.to_string().find("text").is_none());
}

#[test]
fn mutates_session_only_through_the_core_contract() {
    let event = handle_request(
        br#"{"schema_version":1,"request_id":"req_cancel","command":"mutate_session","payload":{"session":{"document_id":"doc_opaque","visible_page_index":1,"cancelled":false,"pages":[{"page_index":0,"state":"completed","error_code":null},{"page_index":1,"state":"processing","error_code":null}]},"action":"cancel","page_index":null}}"#,
    )
    .expect("valid cancellation should be accepted");
    let result = serde_json::to_value(event.result).expect("result must serialize");
    assert_eq!(result["cancelled"], true);
    assert_eq!(result["pages"][0]["state"], "completed");
    assert_eq!(result["pages"][1]["state"], "pending");
}

#[test]
fn completes_or_fails_one_processing_page_and_selects_the_next() {
    let completed = handle_request(
        br#"{"schema_version":1,"request_id":"req_complete","command":"mutate_session","payload":{"session":{"document_id":"doc_opaque","visible_page_index":1,"cancelled":false,"pages":[{"page_index":0,"state":"pending","error_code":null},{"page_index":1,"state":"processing","error_code":null}]},"action":"complete","page_index":1,"error_code":null}}"#,
    )
    .expect("a completed adapter result should advance the session");
    let result = serde_json::to_value(completed.result).expect("result must serialize");
    assert_eq!(result["pages"][1]["state"], "completed");
    assert_eq!(result["pages"][0]["state"], "processing");

    let failed = handle_request(
        br#"{"schema_version":1,"request_id":"req_fail","command":"mutate_session","payload":{"session":{"document_id":"doc_opaque","visible_page_index":0,"cancelled":false,"pages":[{"page_index":0,"state":"processing","error_code":null}]},"action":"fail","page_index":0,"error_code":"LF_PDF_PAGE_NO_TEXT"}}"#,
    )
    .expect("a failed adapter result should remain recoverable");
    let result = serde_json::to_value(failed.result).expect("result must serialize");
    assert_eq!(result["pages"][0]["state"], "failed");
    assert_eq!(result["pages"][0]["error_code"], "LF_PDF_PAGE_NO_TEXT");
}

#[test]
fn normalizes_adapter_blocks_into_stable_units_at_the_core_boundary() {
    let request = br#"{"schema_version":1,"request_id":"req_normalize","command":"normalize_page","payload":{"page":{"document_fingerprint":"abc123","generation_id":"generation_abc123","page_index":0,"blocks":[{"block_id":"page-0-block-0","text":"Lectu-\nra fluida.","region":{"page_index":0,"rect_pdf_points":[0.0,0.0,100.0,20.0],"page_rotation_degrees":0,"source_to_page_transform":[1.0,0.0,0.0,1.0,0.0,0.0],"confidence":1.0},"confidence":1.0}]},"language":"es","requested_unit":"paragraph","route":"direct_text","adapter_status":"completed"}}"#;

    let first = handle_request(request).expect("valid adapter blocks should normalize");
    let second = handle_request(request).expect("normalization should be deterministic");
    let first = serde_json::to_value(first.result).expect("result must serialize");
    let second = serde_json::to_value(second.result).expect("result must serialize");

    assert_eq!(first["units"][0]["text"], "Lectura fluida.");
    assert_eq!(first["units"][0]["unit_id"], second["units"][0]["unit_id"]);
    assert_eq!(
        first["units"][0]["decision_trace"][0]["rule"],
        "join_line_end_hyphen"
    );
    assert_eq!(first["record"]["route"], "direct_text");
    assert!(first["units"][0].get("narration_disposition").is_none());
}

#[test]
fn layout_contract_fields_are_optional_and_narration_disposition_round_trips() {
    let commands: serde_json::Value = serde_json::from_str(include_str!(
        "../../../contracts/lf-v1/commands.schema.json"
    ))
    .expect("commands schema must be JSON");
    let block = &commands["$defs"]["extracted_block"];
    assert_eq!(block["additionalProperties"], false);
    assert_eq!(block["properties"]["layout_role"]["type"], "string");
    assert_eq!(block["properties"]["layout_confidence"]["type"], "number");
    assert_eq!(block["properties"]["layout_order"]["type"], "integer");
    assert_eq!(
        block["properties"]["narration_disposition"]["enum"],
        json!(["automatic", "on_demand", "never"])
    );
    assert_eq!(
        block["properties"]["physical_page_index"]["type"],
        "integer"
    );
    let required = block["required"].as_array().expect("required block fields");
    assert!(!required.contains(&json!("layout_role")));
    assert!(!required.contains(&json!("narration_disposition")));

    let reading: serde_json::Value = serde_json::from_str(include_str!(
        "../../../contracts/lf-v1/reading-page.schema.json"
    ))
    .expect("reading schema must be JSON");
    assert_eq!(
        reading["properties"]["units"]["items"]["properties"]["narration_disposition"]["enum"],
        json!(["automatic", "on_demand", "never"])
    );
    assert!(
        !reading["properties"]["units"]["items"]["required"]
            .as_array()
            .expect("required reading unit fields")
            .contains(&json!("narration_disposition"))
    );

    let request = json!({
        "schema_version": 1,
        "request_id": "req_layout_contract",
        "command": "normalize_page",
        "payload": {
            "page": {
                "document_fingerprint": "abc123",
                "generation_id": "generation_abc123",
                "page_index": 0,
                "blocks": [{
                    "block_id": "image",
                    "text": "Figure content",
                    "region": {
                        "page_index": 0,
                        "rect_pdf_points": [0.0, 0.0, 100.0, 20.0],
                        "page_rotation_degrees": 0,
                        "source_to_page_transform": [1.0, 0.0, 0.0, 1.0, 0.0, 0.0],
                        "confidence": 1.0
                    },
                    "confidence": 1.0,
                    "layout_role": "image",
                    "layout_confidence": 0.9,
                    "layout_order": 0,
                    "narration_disposition": "automatic",
                    "physical_page_index": 0
                }]
            },
            "language": "en",
            "requested_unit": "paragraph",
            "route": "direct_text",
            "adapter_status": "completed"
        }
    });
    let event = handle_request(request.to_string().as_bytes()).expect("layout fields are valid");
    let result = serde_json::to_value(event.result).expect("result must serialize");
    assert_eq!(result["units"][0]["content_class"], "unsupported");
    assert_eq!(result["units"][0]["narration_disposition"], "on_demand");
}

#[test]
fn legacy_reading_unit_satisfies_the_closed_lf_v1_schema_without_spoken_or_layout_fields() {
    let schema: serde_json::Value = serde_json::from_str(include_str!(
        "../../../contracts/lf-v1/reading-page.schema.json"
    ))
    .expect("reading schema must be JSON");
    let unit_schema = &schema["properties"]["units"]["items"];
    let legacy = json!({
        "unit_id": "unit_legacy",
        "kind": "paragraph",
        "content_class": "prose",
        "processing_route": "direct_text",
        "order_key": {"primary_page_index": 0, "local_index": 0},
        "text": "Legacy visible text.",
        "source_regions": [{
            "page_index": 0,
            "rect_pdf_points": [0.0, 0.0, 100.0, 20.0],
            "page_rotation_degrees": 0,
            "source_to_page_transform": [1.0, 0.0, 0.0, 1.0, 0.0, 0.0],
            "confidence": 1.0
        }],
        "source_block_ids": ["block_legacy"],
        "parent_unit_id": null,
        "confidence": 1.0,
        "decision_trace": []
    });

    for field in unit_schema["required"]
        .as_array()
        .expect("unit required fields")
    {
        let field = field.as_str().expect("required field name");
        assert!(
            legacy.get(field).is_some(),
            "legacy unit lacks required {field}"
        );
    }
    for field in legacy.as_object().expect("legacy unit object").keys() {
        assert!(
            unit_schema["properties"].get(field).is_some(),
            "closed unit schema rejects {field}"
        );
    }
}

#[test]
fn routes_empty_direct_extraction_to_ocr_without_trusted_units() {
    let event = handle_request(br#"{"schema_version":1,"request_id":"req_ocr_route","command":"normalize_page","payload":{"page":{"document_fingerprint":"abc123","generation_id":"generation_abc123","page_index":0,"blocks":[]},"language":"es","requested_unit":"paragraph","route":"direct_text","adapter_status":"failed"}}"#)
        .expect("an empty direct result should produce an explicit OCR handoff");
    let result = serde_json::to_value(event.result).expect("result must serialize");

    assert_eq!(result["record"]["route"], "ocr");
    assert_eq!(result["record"]["reason_code"], "direct_text_insufficient");
    assert_eq!(result["units"], serde_json::json!([]));
}

#[test]
fn routes_detected_raster_content_to_ocr_even_when_direct_text_is_useful() {
    let event = handle_request(br#"{"schema_version":1,"request_id":"req_mixed_route","command":"normalize_page","payload":{"page":{"document_fingerprint":"abc123","generation_id":"generation_abc123","page_index":0,"blocks":[{"block_id":"page-0-block-0","text":"Texto digital util.","region":{"page_index":0,"rect_pdf_points":[0.0,0.0,100.0,20.0],"page_rotation_degrees":0,"source_to_page_transform":[1.0,0.0,0.0,1.0,0.0,0.0],"confidence":1.0},"confidence":1.0}]},"language":"es","requested_unit":"paragraph","route":"direct_text","adapter_status":"completed","raster_content_detected":true}}"#)
        .expect("mixed digital and raster content should request OCR");
    let result = serde_json::to_value(event.result).expect("result must serialize");

    assert_eq!(result["record"]["route"], "ocr");
    assert_eq!(result["record"]["reason_code"], "raster_content_detected");
}

#[test]
fn preserves_low_confidence_content_but_routes_it_to_ocr() {
    let event = handle_request(br#"{"schema_version":1,"request_id":"req_low_confidence","command":"normalize_page","payload":{"page":{"document_fingerprint":"abc123","generation_id":"generation_abc123","page_index":0,"blocks":[{"block_id":"page-0-block-0","text":"trazo incierto","region":{"page_index":0,"rect_pdf_points":[0.0,0.0,100.0,20.0],"page_rotation_degrees":0,"source_to_page_transform":[1.0,0.0,0.0,1.0,0.0,0.0],"confidence":0.4},"confidence":0.4}]},"language":"es","requested_unit":"paragraph","route":"direct_text","adapter_status":"completed"}}"#)
        .expect("uncertain content should remain represented");
    let result = serde_json::to_value(event.result).expect("result must serialize");

    assert_eq!(result["record"]["route"], "ocr");
    assert_eq!(result["units"][0]["text"], "trazo incierto");
    assert_eq!(result["units"][0]["content_class"], "unsupported");
}

#[test]
fn records_ocr_route_revision_and_degraded_adapter_status() {
    let event = handle_request(br#"{"schema_version":1,"request_id":"req_ocr","command":"normalize_page","payload":{"page":{"document_fingerprint":"abc123","generation_id":"generation_abc123","page_index":0,"blocks":[{"block_id":"page-0-ocr-0","text":"Texto reconocido.","region":{"page_index":0,"rect_pdf_points":[0.0,0.0,100.0,20.0],"page_rotation_degrees":0,"source_to_page_transform":[1.0,0.0,0.0,1.0,0.0,0.0],"confidence":0.95},"confidence":0.95}]},"language":"es","requested_unit":"paragraph","route":"ocr","adapter_status":"degraded"}}"#)
        .expect("OCR observations should use the shared unit model");
    let result = serde_json::to_value(event.result).expect("result must serialize");

    assert_eq!(result["record"]["route"], "ocr");
    assert_eq!(result["record"]["reason_code"], "ocr_completed");
    assert_eq!(result["record"]["processor_revision"], "vision-v1");
    assert_eq!(result["record"]["status"], "degraded");
    assert_eq!(result["units"][0]["text"], "Texto reconocido.");
}

/// Asks the engine — the shipped `normalize_page` path, not a reimplementation — where one page of
/// text ends up, and why.
fn route_of(prose: &str, language: &str) -> (String, String) {
    let request = json!({
        "schema_version": 1,
        "request_id": "req_language_route",
        "command": "normalize_page",
        "payload": {
            "page": {
                "document_fingerprint": "abc123",
                "generation_id": "generation_abc123",
                "page_index": 0,
                "blocks": [{
                    "block_id": "page-0-block-0",
                    "text": prose,
                    "region": {
                        "page_index": 0,
                        "rect_pdf_points": [0.0, 0.0, 400.0, 200.0],
                        "page_rotation_degrees": 0,
                        "source_to_page_transform": [1.0, 0.0, 0.0, 1.0, 0.0, 0.0],
                        "confidence": 1.0
                    },
                    "confidence": 1.0
                }]
            },
            "language": language,
            "requested_unit": "paragraph",
            "route": "direct_text",
            "adapter_status": "completed"
        }
    });
    let event =
        handle_request(request.to_string().as_bytes()).expect("a well-formed page must normalize");
    let record = serde_json::to_value(event.result).expect("result must serialize");
    (
        record["record"]["route"]
            .as_str()
            .unwrap_or_default()
            .into(),
        record["record"]["reason_code"]
            .as_str()
            .unwrap_or_default()
            .into(),
    )
}

/// Ordinary English prose with a perfectly good text layer.
const ENGLISH_PROSE: &str = "Reading aloud changes the pace of a book. The listener cannot glance backwards \
     over a sentence, so every line has to stand on its own, and whoever narrates learns \
     quickly to respect the pauses the author wrote down. For years that habit was practised \
     in the kitchen, while somebody made dinner and the rest of the household listened without \
     looking at the page. Nobody called it a technique, but a technique is what it was: the \
     passage was chosen, the voice was measured, and the story was allowed to fill the whole \
     room until the last page had been spoken.";

/// One real page of `fanon-scanned.pdf` (page 46), copied verbatim out of the layer the reading path
/// extracts. Every accent the printed page shows is gone from it — "incomprension", "vertigo",
/// "corazon", "mitico" — which is the damage this rule exists to catch.
const REAL_DEGRADED_PAGE: &str = "0 que el ya no la comprende. Entonces se felicita y, desarrollando esa diferencia, esa \
     incomprension, esa disar monia, encuentra el sentido de su verdadera humanidad. 0, mas \
     raramente, quiere ser de su pueblo. Y con la rabia en los labios y vertigo en el corazon se \
     adentra en el gran agujero negro. Veremos que esa actitud tan absolutamente bella rechaza la \
     ac tualidad y el porvenir en nombre de un pasado mitico. Siendo yo de origen antillano, mis \
     observaciones y conclusiones solo son validas para las Antillas, al menos en lo que concierne \
     al negro en su tierra. Se tendria que dedicar un estudio a la explicacion de las divergencias \
     que existen entre los antilla nos y los africanos. Puede que lo hagamos un dia. Tambien puede \
     ser que se vuelva inutil, algo de lo que solo podriamos congratularnos. 47";

/// AC8. This test used to assert that the very page below — sound English prose — was sent to OCR
/// when the engine was told it was Spanish, and it called that the expected result. It was not: it
/// was the defect of Story 6.11 written down as if it were a contract. A good page is a good page in
/// any language, and the only reason the old rule condemned it was that English carries no accents.
///
/// What the engine owes the reader is the pair below: prose that reads keeps its layer, and prose
/// that does not read goes to OCR — in English too, where until Story 6.13 nothing was ever caught.
#[test]
fn english_prose_keeps_its_text_layer_and_only_broken_english_goes_to_ocr() {
    assert!(ENGLISH_PROSE.chars().filter(|c| c.is_alphabetic()).count() >= 400);

    // Told what the document actually is, the engine keeps the layer (Story 6.11).
    assert_eq!(route_of(ENGLISH_PROSE, "en").0, "direct_text");

    // Told it is Spanish, it still sends the page to OCR — and this is a known limit, written down
    // rather than asserted away: an English bibliography inside a Spanish book falls here, exactly
    // as it did under the old rule. It is not a regression, and the fix for it is knowing the
    // language of the page, which no pre-OCR text signal can supply (Story 6.13, Dev Notes).
    assert_eq!(
        route_of(ENGLISH_PROSE, "es"),
        (
            "ocr".into(),
            "direct_text_degraded_missing_diacritics".into()
        )
    );

    // The same page with its character map shifted by one — "Uif mjtufofs" — reads as nothing at
    // all. Today's rule sees no difference between this and the page above.
    let shifted: String = ENGLISH_PROSE
        .chars()
        .map(|c| match c {
            'a'..='z' => char::from(((c as u8 - b'a' + 1) % 26) + b'a'),
            'A'..='Z' => char::from(((c as u8 - b'A' + 1) % 26) + b'A'),
            other => other,
        })
        .collect();
    assert_eq!(
        route_of(&shifted, "en"),
        ("ocr".into(), "direct_text_degraded_impossible_words".into())
    );

    // And the same page with its word boundaries lost — "R e a d i n g".
    let spaced: String = ENGLISH_PROSE.chars().flat_map(|c| [c, ' ']).collect();
    assert_eq!(
        route_of(&spaced, "en"),
        (
            "ocr".into(),
            "direct_text_degraded_letters_not_words".into()
        )
    );
}

/// AC3. The two channels that no language detected before Story 6.13, now caught in all three.
#[test]
fn broken_word_boundaries_and_shifted_character_maps_reach_ocr_in_every_language() {
    let pages = [
        (
            "es",
            "El hombre no es solamente posibilidad de recuperación, de negación. Si bien es \
                cierto que la conciencia es actividad de trascendencia, hay que saber también que \
                esa trascendencia está obsesionada por el problema del amor y de la comprensión. \
                Desgarrado, disperso, confundido, condenado a ver disolverse una tras otra las \
                verdades que ha elaborado, tiene que dejar de proyectar sobre el mundo una \
                antinomia que le es coexistente. Yo hablo de millones de hombres a quienes \
                sabiamente se les ha inculcado el miedo, el temblor y la desesperación.",
        ),
        ("en", ENGLISH_PROSE),
        (
            "pt",
            "A leitura em voz alta muda o ritmo de um livro inteiro. Quem escuta não pode voltar \
                atrás sobre uma frase já dita, de modo que cada linha precisa sustentar-se sozinha, \
                e quem narra aprende depressa a respeitar as pausas que o autor deixou escritas na \
                página. Durante anos esse hábito foi praticado na cozinha, enquanto alguém fazia o \
                jantar e o resto da casa ouvia sem olhar para o papel. Ninguém chamava aquilo de \
                técnica, mas técnica era: escolhia-se a passagem, media-se a voz, e a história \
                enchia a sala inteira até a última página ser dita em voz alta.",
        ),
    ];

    for (language, prose) in pages {
        assert_eq!(
            route_of(prose, language).0,
            "direct_text",
            "sound {language} prose must keep its own text layer"
        );

        let shifted: String = prose
            .chars()
            .map(|c| match c {
                'a'..='z' => char::from(((c as u8 - b'a' + 1) % 26) + b'a'),
                'A'..='Z' => char::from(((c as u8 - b'A' + 1) % 26) + b'A'),
                other => other,
            })
            .collect();
        assert_eq!(
            route_of(&shifted, language),
            ("ocr".into(), "direct_text_degraded_impossible_words".into()),
            "a shifted character map must reach OCR in {language}"
        );

        let spaced: String = prose.chars().flat_map(|c| [c, ' ']).collect();
        assert_eq!(
            route_of(&spaced, language),
            (
                "ocr".into(),
                "direct_text_degraded_letters_not_words".into()
            ),
            "a page of loose letters must reach OCR in {language}"
        );
    }
}

/// AC1 and AC4. The complaint that opened Story 6.13: a page can carry an accent and still be
/// unreadable. Measured against this very engine, appending one accented word to each of the 352
/// damaged pages of `fanon-scanned.pdf` made every one of them pass as sound.
#[test]
fn one_stray_accent_no_longer_rescues_a_page_that_cannot_spell() {
    assert_eq!(
        route_of(REAL_DEGRADED_PAGE, "es"),
        (
            "ocr".into(),
            "direct_text_degraded_missing_diacritics".into()
        )
    );

    // One accented word — not even a rare event on a damaged page, since a single surviving glyph
    // does it — and the old rule declared the whole page healthy.
    let with_one_accent = format!("{REAL_DEGRADED_PAGE} café");
    assert!(with_one_accent.contains('é'));
    assert_eq!(
        route_of(&with_one_accent, "es"),
        (
            "ocr".into(),
            "direct_text_degraded_missing_diacritics".into()
        )
    );

    // The threshold is a rate, not a presence test. Two accents are enough to clear a page of 650
    // letters — that is the calibrated margin, since the worst real Spanish page measured carries
    // one accent per 400 letters — but the same two accents on a page of ordinary size do not.
    let short_page_with_two_accents = format!("{REAL_DEGRADED_PAGE} café canción");
    assert_eq!(
        route_of(&short_page_with_two_accents, "es").0,
        "direct_text"
    );

    let full_page = [REAL_DEGRADED_PAGE; 4].join(" ");
    assert!(full_page.chars().filter(|c| c.is_alphabetic()).count() > 2_000);
    assert_eq!(
        route_of(&format!("{full_page} café canción"), "es"),
        (
            "ocr".into(),
            "direct_text_degraded_missing_diacritics".into()
        )
    );
}

/// AC1. Characters that carry no reading — the replacement character a lost mapping leaves behind,
/// and the private use area a subsetted font maps into — are their own signal, ahead of everything
/// else, because a page full of them says nothing about words at all.
#[test]
fn characters_that_carry_no_reading_are_their_own_reason() {
    let unreadable: String = ENGLISH_PROSE
        .chars()
        .enumerate()
        .map(|(index, c)| if index % 50 == 0 { '\u{FFFD}' } else { c })
        .collect();
    assert_eq!(
        route_of(&unreadable, "en"),
        ("ocr".into(), "direct_text_degraded_unreadable".into())
    );

    // A handful of stray replacement characters is not a broken page, and the threshold is a rate:
    // the reference book carries three of them on a page of three thousand characters — a tenth of
    // what it takes to fire — and it is its missing accents that condemn it, not those three.
    let occasional = format!("{ENGLISH_PROSE} {ENGLISH_PROSE} \u{FFFD}\u{FFFD}");
    assert_eq!(route_of(&occasional, "en").0, "direct_text");

    // A digit the font failed to map — U+F731 is "1" in the Symbol encoding — sits inside the
    // number it ruins, and the number is unreadable. This is the case the signal is for.
    let broken_numbers: String = ENGLISH_PROSE
        .chars()
        .enumerate()
        .map(|(index, c)| if index % 40 == 0 { '\u{F731}' } else { c })
        .collect();
    assert_eq!(
        route_of(&broken_numbers, "en"),
        ("ocr".into(), "direct_text_degraded_unreadable".into())
    );
}

/// AC5. An index page is not a broken page. "91n.35", "380n45", "R2", "x1" all read as words with
/// no vowel in them, and a name index or a statistics table is made of little else — 136 pages of
/// the owner's library were condemned for it. A token carrying a digit is a citation, a table cell
/// or a footnote marker, never a word a font broke, so it is not counted; every page of every
/// shifted-character-map channel is still caught without it.
#[test]
fn a_page_of_citations_is_not_a_page_of_impossible_words() {
    // Copied verbatim from page 328 of one of the owner's own books, which the rule condemned.
    let index = "Name Index Abbott, Andrew, 242 Abrams, Philip, 16, 91n.35 Accardo, Alain, 2n.1 \
        Adair, Philippe, 115n.67 Addelson, Katharine Pyne, 157 Alexander, Jeffrey C., 3n.3, 31, \
        31n.53, 32, 162, 224, 224n.11 Althusser, Louis, 8, 19, 155n.111, 156, 164, 251n.49 \
        Anderson, Bob, 40, 144 Ansart, Pierre, 2n.1, 11n.21, 132n.85 Apel, Otto, 139 Arendt, \
        Hannah, 102n.55 Aristotle, 128, 183 Aron, Raymond, 46, 46n.83 Aronowitz, Stanley, 79 \
        Ashrnore, Malcolm, 36n.63, 43n.77 Atkinson, Paul, 41n.72 Auerbach, Erich, 124 Augstein, \
        Rudof, 154n.109 Austin, I. L., 147—48, 148n.100, 169 Bachelard, Gaston, 5n.7, 35, 35n.60, \
        45n.82, 73, 74, 95n.43, 161n.115, 174, 177n.132, 181, 194, 195n.155, 233, 251n.49 Bakhtin, \
        Mikhail, 141 Baldwin, John B., 122n.77 Bancaud, Alain, 243n.39 Barnard, Henri, 41, 4111.73, \
        42n.75, 66n.8 Barthes, Roland, 154, 156 Baudrillard, Jean, 154 Becker, Gary S., 25n.45, \
        115n.67, 118 Becker, Howard, 110n.63 Beeghley, Leonard, 241n.37 Beisel, Nicola, 4n.4 Bell, \
        Daniel, 77n.17 Bellah, Robert, 49, 50n.90 Benveniste, Emile, 147 Benzécri, Jean-Pierre, \
        96n.47 Berelson, Bernard, 96 Berger, Bennett, 36n.63, 37, 38, 38n.68, 43n.77, 63ni2, \
        80n.24, 205n.166 Berger, Peter, 9n.17 Best, Joel, 239n.30 Bidet, Jacques, 79, 135—36";
    assert!(index.chars().filter(|c| c.is_alphabetic()).count() >= 400);
    assert_eq!(route_of(index, "en").0, "direct_text");
}

/// AC5, the constraint that outranks recall. Word writes a bulleted list with U+F0B7, a private use
/// character from the Symbol font, and a page of ordinary prose can carry a dozen of them. Counting
/// every private use character as unreadable condemned 464 perfectly legible Spanish pages of the
/// owner's own 818-document library; counting only the ones standing inside a word condemns none of
/// them, and costs nothing on any page whose words are genuinely broken.
#[test]
fn a_bullet_glyph_is_not_a_broken_text_layer() {
    let spanish = "El hombre no es solamente posibilidad de recuperación, de negación. Si bien es \
        cierto que la conciencia es actividad de trascendencia, hay que saber también que esa \
        trascendencia está obsesionada por el problema del amor y de la comprensión. Desgarrado, \
        disperso, confundido, condenado a ver disolverse una tras otra las verdades que ha \
        elaborado, tiene que dejar de proyectar sobre el mundo una antinomia que le es coexistente. \
        Yo hablo de millones de hombres a quienes sabiamente se les ha inculcado el miedo.";
    assert_eq!(route_of(spanish, "es").0, "direct_text");

    // Twelve bullets on one page, each standing alone the way a list item begins.
    let bulleted = format!("{spanish} {}", "\u{F0B7} Un punto de la lista. ".repeat(12));
    assert!(bulleted.matches('\u{F0B7}').count() == 12);
    assert!(
        (bulleted.chars().filter(|c| *c == '\u{F0B7}').count() as f64 * 100.0)
            / bulleted.chars().count() as f64
            > 0.2,
        "the page must be over the 0.2 % threshold, or the test proves nothing"
    );
    assert_eq!(route_of(&bulleted, "es").0, "direct_text");
}
