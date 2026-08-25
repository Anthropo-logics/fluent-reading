//! Dominio local y contratos LF compartidos por CLI y macOS.

use std::collections::BTreeMap;
use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};

use serde::{Deserialize, Serialize};
use serde_json::Value;

mod corpus;
mod extraction;
mod gate_a;
mod hash;
mod incremental;
mod models;
mod narration;
mod spoken;

pub use corpus::{
    CorpusValidationError, CorpusValidationResult, PageMetric, ValidationArtifacts,
    ValidationEnvironment, ValidationRun, ValidationRunStatus, validate_corpus_manifest,
};
pub use extraction::{
    BlockOrderMetric, CharacterErrorMetric, ContentClass, ExtractedBlock, FurnitureEvidence,
    LayoutRole, NarrationDisposition, NormalizationDecision, NormalizedPage, PageExtraction,
    PageProcessingRecord, PageProcessingStatus, ProcessingRoute, ReadingAnchor, ReadingUnit,
    ReadingUnitKind, RequestedUnit, SourceRegion, UnitOrderKey, character_error_rate,
    measure_digital_block_order, normalize_digital_document, normalize_digital_page,
    select_processing_route,
};
pub use gate_a::{
    GateACondition, GateAMetric, GateAMetricName, GateAMetricUnit, GateAProgress, GateAResult,
    GateARevisionSet, GateARunRequest, GateAScenario, GateAThermalState, GateAValidationError,
    ResourceSample,
};
pub use hash::{fingerprint_file, sha256_hex};
pub use incremental::{IncrementalPage, IncrementalPageState, IncrementalSession};
pub use models::{
    DistributionStatus, ModelArtifact, ModelInstallationSession, ModelInstallationState,
    ModelInstallationTransitionError, ModelManifest, ModelManifestError, ModelPurpose,
    ModelVerificationResult, NarrationSegment, TranslatedUnit, TranslationError,
    TranslationRequest, TranslationResult, TranslationUnit, TtsError, TtsSynthesisRequest,
    TtsSynthesisResult, TtsUnit, VoiceSelection, VoiceSelectionError, validate_model_manifest,
    validate_model_package, validate_model_package_for_runtime,
};
pub use narration::{NarrationQueue, NarrationQueueState};
pub use spoken::{SpokenPart, SpokenPlan, SpokenTextError, espeak_stdin, spoken_plan};

pub const SCHEMA_VERSION: u32 = 1;
pub const CORE_VERSION: &str = env!("CARGO_PKG_VERSION");

static NEXT_JOB_ID: AtomicU64 = AtomicU64::new(1);
const REMEMBERED_FURNITURE_DOCUMENTS: usize = 4;
static FURNITURE_DOCUMENTS: Mutex<Vec<(String, FurnitureEvidence)>> = Mutex::new(Vec::new());

#[derive(Debug, Deserialize)]
struct RequestEnvelope {
    schema_version: u32,
    request_id: String,
    command: String,
    payload: Value,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CanaryResult {
    pub core_version: String,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DocumentOpenedResult {
    pub document_id: String,
    pub access_grant_id: String,
    pub page_count: u32,
    pub first_page_ms: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct DocumentProcessingResult {
    pub document_id: String,
    pub language: String,
    pub requested_unit: RequestedUnit,
    pub pages: Vec<NormalizedPage>,
    pub nfr6: Option<BlockOrderMetric>,
    pub cer: Option<CharacterErrorMetric>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(untagged)]
pub enum EventResult {
    Canary(CanaryResult),
    DocumentOpened(DocumentOpenedResult),
    CorpusValidated(CorpusValidationResult),
    DocumentProcessed(DocumentProcessingResult),
    ModelVerified(ModelVerificationResult),
    TtsSynthesized(TtsSynthesisResult),
    TranslationCompleted(TranslationResult),
    GateACompleted(Box<GateAResult>),
    SpokenPlan(SpokenPlan),
    IncrementalSession(IncrementalSession),
    NormalizedPage(NormalizedPage),
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct EventEnvelope {
    pub schema_version: u32,
    pub request_id: String,
    pub job_id: String,
    pub sequence: u64,
    pub kind: String,
    pub progress: Option<Value>,
    pub result: Option<EventResult>,
    pub error: Option<LfError>,
    pub recovery: Option<Value>,
}

impl EventEnvelope {
    pub fn acceptance(&self) -> SubmissionAcceptance {
        SubmissionAcceptance {
            schema_version: self.schema_version,
            request_id: self.request_id.clone(),
            job_id: self.job_id.clone(),
        }
    }

    pub fn cancel(&mut self) {
        self.kind = "cancelled".into();
        self.progress = None;
        self.result = None;
        self.error = None;
        self.recovery = None;
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SubmissionAcceptance {
    pub schema_version: u32,
    pub request_id: String,
    pub job_id: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct ErrorScope {
    pub job_id: Option<String>,
    pub document_id: Option<String>,
    pub page_index: Option<u32>,
    pub unit_id: Option<String>,
    pub model_id: Option<String>,
    pub export_job_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct LfError {
    pub code: String,
    pub message_key: String,
    pub scope: ErrorScope,
    pub details: BTreeMap<String, Value>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RequestError {
    InvalidJson,
    UnsupportedSchemaVersion { observed: u32 },
    InvalidRequestId,
    UnknownCommand,
    InvalidPayload,
}

impl RequestError {
    /// Converts a rejected request into the safe, localizable LF error contract.
    pub fn as_lf_error(&self) -> LfError {
        let (code, message_key) = match self {
            Self::InvalidJson => ("LF_CONTRACT_INVALID_JSON", "contract.invalid_json"),
            Self::UnsupportedSchemaVersion { .. } => (
                "LF_CONTRACT_VERSION_UNSUPPORTED",
                "contract.version_unsupported",
            ),
            Self::InvalidRequestId => (
                "LF_CONTRACT_REQUEST_ID_INVALID",
                "contract.request_id_invalid",
            ),
            Self::UnknownCommand => ("LF_CONTRACT_COMMAND_UNKNOWN", "contract.command_unknown"),
            Self::InvalidPayload => ("LF_CONTRACT_PAYLOAD_INVALID", "contract.payload_invalid"),
        };

        let mut details = BTreeMap::new();
        if let Self::UnsupportedSchemaVersion { observed } = self {
            details.insert("observed_schema_version".into(), Value::from(*observed));
        }

        LfError {
            code: code.into(),
            message_key: message_key.into(),
            scope: ErrorScope::default(),
            details,
        }
    }
}

/// The letters Spanish and Portuguese prose carries and a broken character map loses first.
const DIACRITICS: &str = "áéíóúüñÁÉÍÓÚÜÑàâãêôõçÀÂÃÊÔÕÇ";
/// `y` is included because Spanish and Portuguese spell whole words with it and nothing else.
const VOWELS: &str = "aeiouyáéíóúàâãêôõäëïöüAEIOUYÁÉÍÓÚÀÂÃÊÔÕÄËÏÖÜ";

/// Below this many letters the page says too little to judge, so it is left alone.
///
/// The floor has a price and it has been paid deliberately: 20 of the 372 damaged pages of the
/// reference book fall under it, and so do 216 pages of a real book whose layer is pure noise but
/// only sixty-odd letters of it per page. Lowering it does not buy them back — at 100 letters that
/// book gains 86 pages of 232 — and it costs immediately: measured over 5,166 pages of real prose,
/// a floor of 400 gives 0 false positives, 300 gives 6, 200 gives 75 and 100 gives 1,557. What
/// answers for those pages is not a lower floor (Story 6.13).
const PROSE_FLOOR_LETTERS: usize = 400;

/// Reason codes. The contract takes any short string (`reading-page.schema.json`), and naming the
/// signal that fired is what makes a routing decision auditable after the fact — the page store
/// keeps it (`pages/N.json`), so "why did this page go to OCR" is answerable without re-running it.
const DEGRADED_UNREADABLE: &str = "direct_text_degraded_unreadable";
const DEGRADED_IMPOSSIBLE_WORDS: &str = "direct_text_degraded_impossible_words";
const DEGRADED_LETTERS_NOT_WORDS: &str = "direct_text_degraded_letters_not_words";
const DEGRADED_MISSING_DIACRITICS: &str = "direct_text_degraded_missing_diacritics";

/// A character that no reader can be given: the replacement character left behind by a mapping that
/// failed, a control code, or a code point in one of the private use areas, where a subsetted font
/// puts glyphs whose meaning only that font knows.
fn carries_no_reading(c: char) -> bool {
    let point = c as u32;
    c == '\u{FFFD}'
        || (point < 0x20 && c != '\n' && c != '\r' && c != '\t')
        || (0x7f..=0x9f).contains(&point)
        || (0xe000..=0xf8ff).contains(&point)
        || (0xf0000..=0xffffd).contains(&point)
}

/// Whether this page's own text layer is too damaged to read aloud, and which signal says so.
///
/// A scanned book often ships a text layer that classifies as ordinary prose — right block shapes,
/// full confidence — and still cannot spell: the reader got "Pie! negra, mascaras" for "Piel negra,
/// máscaras". Until Story 6.13 the only test applied was "a long Spanish or Portuguese page without
/// a single accent is broken", which failed in both directions: it said nothing at all about
/// English, and one stray accented word anywhere on a ruined page was enough to declare it sound.
/// Measured against the shipped engine: all 352 damaged pages of the reference book passed as
/// healthy once the word «café» was appended to them.
///
/// So the page is asked four independent questions instead. Three of them are about the shape of
/// the text itself and apply to Spanish, English and Portuguese alike; only the fourth consults the
/// language, because English has no repertoire of accents to lose and their absence there is a fact
/// about English, not evidence about the page.
///
/// Every threshold below was calibrated against real prose with a hard requirement of **zero** false
/// positives, never maximum recall — a false positive is not free. The caller throws the good layer
/// away, re-recognises the page, and by Stories 6.6/6.9 may go on to offer writing that recognition
/// into the reader's own file. Margins measured over ~5,000 real pages of Spanish, English and
/// Portuguese (Story 6.13):
///
/// - vowel-less words: real prose peaks at 5.4–6.2 %, the damaged channel starts at 12.5 % → 10 %.
/// - one-letter words: real prose peaks at 29.8 % (Portuguese) against 100 % in the channel → 50 %.
/// - unreadable characters: real prose gives exactly 0 in every page measured → 0.2 %.
/// - diacritics: the worst real Spanish page carries 1 accent per 400 letters and the worst
///   Portuguese 2 per 400; at 2 per 1000 neither is touched, while a page of ordinary size (median
///   2,315 letters) must show at least 5 — which is precisely where the old binary test was fragile.
///
/// Known limit (Story 6.13, AC9): a ClearScan-style corruption at realistic damage (~15 % word error)
/// is not detected here, and none of the nine candidates evaluated detected it while staying on this
/// side of OCR. It was first described as a limit of languages with no diacritics to lose, and the
/// owner's own library corrected that: a Spanish book of 1968 whose layer spells "Nariffo" for
/// "Nariño" and "espafiol" for "español" still carries eighteen accents per thousand letters, and
/// passes. The corruption that hides from this rule is not the one that picks a language without
/// accents, it is the one that leaves the accents alone. What would see it is a comparison against a
/// recognition of two or three pages of the same document — a paired signal, and a story of its own.
fn direct_text_degradation(page: &NormalizedPage, language: &str) -> Option<&'static str> {
    let prose: String = page
        .units
        .iter()
        .filter(|unit| unit.content_class == ContentClass::Prose)
        .map(|unit| unit.text.as_str())
        .collect::<Vec<_>>()
        .join(" ");

    let mut characters = 0usize;
    let mut letters = 0usize;
    let mut accented = 0usize;
    let mut unreadable_in_word = 0usize;
    let mut previous: Option<char> = None;
    let mut following = prose.chars();
    following.next();
    for c in prose.chars() {
        let next = following.next();
        characters += 1;
        if c.is_alphabetic() {
            letters += 1;
            if DIACRITICS.contains(c) {
                accented += 1;
            }
        }
        if carries_no_reading(c)
            && (previous.is_some_and(char::is_alphanumeric)
                || next.is_some_and(char::is_alphanumeric))
        {
            unreadable_in_word += 1;
        }
        previous = Some(c);
    }
    if letters < PROSE_FLOOR_LETTERS {
        return None;
    }

    // Characters that carry no reading at all: the replacement character a lost mapping leaves
    // behind, control codes, and the private use area a subsetted font maps into.
    //
    // Only the ones standing *inside a word* are counted, and that qualification was not a guess —
    // it is what the owner's own 818-document library taught. Word writes its bullets as U+F0B7, a
    // private-use code point from the Symbol font, and on 464 pages of that library a perfectly
    // legible Spanish page carries nothing worse than half a dozen of them. Counting every
    // private-use character condemned all 464; counting only those glued to a letter or a digit
    // condemns none of them and still catches every page whose *words* are unreadable — a digit
    // mapped to U+F731 inside "1 990", a "¿" left as U+FFFD against the "Q" that follows it.
    if unreadable_in_word * 500 > characters {
        return Some(DEGRADED_UNREADABLE);
    }

    let mut words = 0usize;
    let mut single_letter = 0usize;
    let mut vowelless = 0usize;
    for word in
        prose.split(|c: char| !(c.is_alphanumeric() || c == '\'' || c == '\u{2019}' || c == '-'))
    {
        if !word.chars().any(char::is_alphabetic) {
            continue;
        }
        words += 1;
        if word.chars().nth(1).is_none() {
            single_letter += 1;
        } else if !word.chars().any(char::is_numeric) && !word.chars().any(|c| VOWELS.contains(c)) {
            vowelless += 1;
        }
    }
    if words == 0 {
        return None;
    }

    // Words of two letters or more that contain no vowel. These are not rare spellings, they are
    // impossible ones: a shifted character map turns "the silver" into "Uif tjmwfs" and produces
    // them by the dozen, in every language at once.
    //
    // A token carrying a digit is skipped, and that too came from the owner's library rather than
    // from taste: an index prints "91n.35", a statistics table prints "R2" and "x1", and neither is
    // a word any font broke. Ignoring them stopped 136 index and table pages being condemned and
    // cost nothing at all — every page of every shifted-character-map channel is still caught
    // (4128/270/733 in Spanish, English and Portuguese), and so is every page of the one real
    // library document whose layer is genuine nonsense.
    if vowelless * 100 > words * 10 {
        return Some(DEGRADED_IMPOSSIBLE_WORDS);
    }

    // A layer that emits one letter per token is not spelling badly, it has lost word boundaries
    // altogether — "c o m p l e j o". Real prose is full of "a", "y", "o", "I", so the bar is high.
    if single_letter * 100 > words * 50 {
        return Some(DEGRADED_LETTERS_NOT_WORDS);
    }

    // Only this last question is asked of the language, and only of the two that answer it. English
    // prose is written without accents by design; scoring it here is what condemned every long
    // English page while the call site still claimed every document was Spanish (Story 6.11).
    if matches!(language, "es" | "pt") && accented * 1000 < letters * 2 {
        return Some(DEGRADED_MISSING_DIACRITICS);
    }

    None
}

/// Page furniture is only recognisable by repetition, and repetition is only visible across pages —
/// but the reader asks the engine for one page at a time. The evidence each document has produced
/// so far is therefore kept alongside its fingerprint for as long as the process lives.
///
/// ponytail: in-process memory of the last few documents; a document reopened in a new run relearns
/// its margins from scratch, and the first pages normalised before a template earns its majority
/// keep their furniture. Priming the evidence from a whole-document prescan (the pattern already
/// used for the chapter index) is the upgrade when that matters.
fn observe_page_furniture(
    fingerprint: &str,
    page: &PageExtraction,
) -> (PageExtraction, Vec<NormalizationDecision>) {
    let Ok(mut documents) = FURNITURE_DOCUMENTS.lock() else {
        return (page.clone(), Vec::new());
    };
    let evidence = remembered_furniture(&mut documents, fingerprint);
    evidence.observe(page);
    evidence.strip(page)
}

fn prime_page_furniture(fingerprint: &str, pages: &[PageExtraction]) {
    let Ok(mut documents) = FURNITURE_DOCUMENTS.lock() else {
        return;
    };
    let evidence = remembered_furniture(&mut documents, fingerprint);
    for page in pages {
        evidence.observe(page);
    }
}

fn remembered_furniture<'a>(
    documents: &'a mut Vec<(String, FurnitureEvidence)>,
    fingerprint: &str,
) -> &'a mut FurnitureEvidence {
    let position = match documents.iter().position(|(known, _)| known == fingerprint) {
        Some(position) => position,
        None => {
            if documents.len() == REMEMBERED_FURNITURE_DOCUMENTS {
                documents.remove(0);
            }
            documents.push((fingerprint.to_owned(), FurnitureEvidence::default()));
            documents.len() - 1
        }
    };
    &mut documents[position].1
}

/// The name a document's derived data is filed under, taken from the document itself.
///
/// This used to be `doc_{job_number:016x}`, a counter that starts at 1 with every launch. The name
/// is not decoration: the host keys `sessions/<document_id>/` by it, and the storage panel reports
/// and deletes exactly that directory. A counter gets it wrong in both directions, both measured on
/// a real container: the first document of every launch is handed the same name, so one document's
/// stored data is reported — and, on "delete processed data", erased — for another; and the same
/// document opened in two launches lands in two directories, half the stored bytes duplicated where
/// the panel, which only ever shows the open document's, can neither show nor remove them.
///
/// The fingerprint is the SHA-256 of the file's bytes, which the host already computes to key
/// resumable export jobs, so the same document answers with the same name in every launch and two
/// different documents never collide. Half of it (128 bits) is plenty to name a directory. It
/// stays an opaque platform fact: no path, no text, nothing about the content crosses this
/// boundary — the same rule `rejects_a_document_path_at_the_core_boundary` guards.
fn document_id_from_fingerprint(fingerprint: &str) -> Option<String> {
    const NAME_HEX_DIGITS: usize = 32;
    let is_sha256_hex = fingerprint.len() == 64
        && fingerprint
            .bytes()
            .all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'));
    is_sha256_hex.then(|| format!("doc_{}", &fingerprint[..NAME_HEX_DIGITS]))
}

/// Validates one LF request and returns its single terminal event.
pub fn handle_request(input: &[u8]) -> Result<EventEnvelope, RequestError> {
    let request: RequestEnvelope =
        serde_json::from_slice(input).map_err(|_| RequestError::InvalidJson)?;

    if request.schema_version != SCHEMA_VERSION {
        return Err(RequestError::UnsupportedSchemaVersion {
            observed: request.schema_version,
        });
    }
    if request.request_id.is_empty() || request.request_id.len() > 256 {
        return Err(RequestError::InvalidRequestId);
    }
    let job_number = NEXT_JOB_ID.fetch_add(1, Ordering::Relaxed);
    let result = match request.command.as_str() {
        "canary" => {
            if request
                .payload
                .as_object()
                .is_none_or(|payload| !payload.is_empty())
            {
                return Err(RequestError::InvalidPayload);
            }
            EventResult::Canary(CanaryResult {
                core_version: CORE_VERSION.into(),
                message: "lectura-core ready".into(),
            })
        }
        "plan_spoken_text" => {
            #[derive(Deserialize)]
            #[serde(deny_unknown_fields)]
            struct Payload {
                text: String,
                language: String,
            }

            let payload: Payload = serde_json::from_value(request.payload)
                .map_err(|_| RequestError::InvalidPayload)?;
            if payload.text.trim().is_empty() || payload.text.len() > 100_000 {
                return Err(RequestError::InvalidPayload);
            }
            EventResult::SpokenPlan(
                spoken_plan(&payload.text, &payload.language)
                    .map_err(|_| RequestError::InvalidPayload)?,
            )
        }
        "open_document" => {
            #[derive(Deserialize)]
            #[serde(deny_unknown_fields)]
            struct Payload {
                access_grant_id: String,
                document_fingerprint: String,
                page_count: u32,
                first_page_ms: u64,
                #[serde(default)]
                furniture_pages: Vec<PageExtraction>,
            }

            let payload: Payload = serde_json::from_value(request.payload)
                .map_err(|_| RequestError::InvalidPayload)?;
            if payload.access_grant_id.is_empty()
                || payload.access_grant_id.len() > 256
                || payload.page_count == 0
                || payload.furniture_pages.len() > 64
                || payload.furniture_pages.iter().any(|page| {
                    page.document_fingerprint != payload.document_fingerprint
                        || page.page_index >= payload.page_count
                        || page.generation_id.is_empty()
                        || page.generation_id.len() > 128
                        || page.blocks.len() > 10_000
                })
            {
                return Err(RequestError::InvalidPayload);
            }
            let Some(document_id) = document_id_from_fingerprint(&payload.document_fingerprint)
            else {
                return Err(RequestError::InvalidPayload);
            };
            prime_page_furniture(&payload.document_fingerprint, &payload.furniture_pages);
            EventResult::DocumentOpened(DocumentOpenedResult {
                document_id,
                access_grant_id: payload.access_grant_id,
                page_count: payload.page_count,
                first_page_ms: payload.first_page_ms,
            })
        }
        "plan_session" => {
            #[derive(Deserialize)]
            #[serde(deny_unknown_fields)]
            struct Payload {
                document_id: String,
                page_count: u32,
                visible_page_index: u32,
            }

            let payload: Payload = serde_json::from_value(request.payload)
                .map_err(|_| RequestError::InvalidPayload)?;
            let mut session = IncrementalSession::new(
                payload.document_id,
                payload.page_count,
                payload.visible_page_index,
            )
            .ok_or(RequestError::InvalidPayload)?;
            session.next_page();
            EventResult::IncrementalSession(session)
        }
        "mutate_session" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "snake_case")]
            enum Action {
                Reprioritize,
                Cancel,
                Resume,
                Retry,
                Reread,
                Skip,
                Complete,
                Fail,
            }
            #[derive(Deserialize)]
            #[serde(deny_unknown_fields)]
            struct Payload {
                session: IncrementalSession,
                action: Action,
                page_index: Option<u32>,
                error_code: Option<String>,
            }

            let mut payload: Payload = serde_json::from_value(request.payload)
                .map_err(|_| RequestError::InvalidPayload)?;
            if !payload.session.is_valid() {
                return Err(RequestError::InvalidPayload);
            }
            let changed = match (payload.action, payload.page_index) {
                (Action::Reprioritize, Some(page)) => payload.session.reprioritize(page),
                (Action::Cancel, None) => {
                    payload.session.cancel();
                    true
                }
                (Action::Resume, None) => payload.session.resume(),
                (Action::Retry, Some(page)) => payload.session.retry(page),
                (Action::Reread, Some(page)) => payload.session.reread(page),
                (Action::Skip, Some(page)) => payload.session.skip(page),
                (Action::Complete, Some(page)) if payload.error_code.is_none() => {
                    payload.session.complete(page)
                }
                (Action::Fail, Some(page)) => payload
                    .error_code
                    .take()
                    .is_some_and(|code| payload.session.fail(page, code)),
                _ => false,
            };
            if !changed {
                return Err(RequestError::InvalidPayload);
            }
            if !payload.session.cancelled {
                payload.session.next_page();
            }
            EventResult::IncrementalSession(payload.session)
        }
        "normalize_page" => {
            #[derive(Deserialize)]
            #[serde(deny_unknown_fields)]
            struct Payload {
                page: PageExtraction,
                language: String,
                requested_unit: RequestedUnit,
                route: ProcessingRoute,
                adapter_status: String,
            }

            let payload: Payload = serde_json::from_value(request.payload)
                .map_err(|_| RequestError::InvalidPayload)?;
            if !matches!(payload.language.as_str(), "es" | "en" | "pt")
                || payload.page.document_fingerprint.is_empty()
                || payload.page.document_fingerprint.len() > 128
                || payload.page.generation_id.is_empty()
                || payload.page.generation_id.len() > 128
                || payload.page.blocks.len() > 10_000
                || !matches!(
                    payload.adapter_status.as_str(),
                    "completed" | "degraded" | "failed"
                )
            {
                return Err(RequestError::InvalidPayload);
            }
            // The reader normalises one page at a time, so the document-wide furniture rule can
            // only work if the engine remembers what the previous pages of *this* document printed
            // in their margins. Without this the running head and the printer's imprint were read
            // aloud in the app while the command-line path, which sees the whole document at once,
            // removed them.
            let (page, furniture_omissions) =
                observe_page_furniture(&payload.page.document_fingerprint, &payload.page);
            let mut normalized =
                normalize_digital_page(&page, &payload.language, payload.requested_unit);
            let mut omissions = furniture_omissions;
            // A page that held nothing but its own margins is not a failure to read: it is a page
            // whose only content was furniture, and the trace already says so.
            if !omissions.is_empty() && normalized.record.status == PageProcessingStatus::Failed {
                normalized.record.status = PageProcessingStatus::Degraded;
                normalized.record.error_code = None;
            }
            omissions.append(&mut normalized.omissions);
            normalized.omissions = omissions;
            let has_trusted_prose = normalized
                .units
                .iter()
                .any(|unit| unit.content_class == ContentClass::Prose && unit.confidence >= 0.6);
            if payload.route == ProcessingRoute::Ocr {
                normalized.record.route = ProcessingRoute::Ocr;
                for unit in &mut normalized.units {
                    unit.processing_route = ProcessingRoute::Ocr;
                }
                normalized.record.reason_code = if has_trusted_prose {
                    "ocr_completed"
                } else {
                    "ocr_insufficient"
                }
                .into();
                normalized.record.processor_revision = "vision-v1".into();
                if payload.adapter_status != "completed" {
                    normalized.record.status = PageProcessingStatus::Degraded;
                }
            } else if !has_trusted_prose {
                normalized.record.route = ProcessingRoute::Ocr;
                normalized.record.reason_code = "direct_text_insufficient".into();
            } else if let Some(reason) = direct_text_degradation(&normalized, &payload.language) {
                // Scanned books often carry a poor embedded text layer. It classifies as ordinary
                // prose, so confidence alone accepted it and OCR was never attempted — the reader
                // got "Pie! negra, mascaras" instead of "Piel negra, máscaras". The reason code says
                // which of the four signals caught it.
                normalized.record.route = ProcessingRoute::Ocr;
                normalized.record.reason_code = reason.into();
            }
            EventResult::NormalizedPage(normalized)
        }
        _ => return Err(RequestError::UnknownCommand),
    };

    Ok(EventEnvelope {
        schema_version: SCHEMA_VERSION,
        request_id: request.request_id,
        job_id: format!("job_{job_number:016x}"),
        sequence: 0,
        kind: "completed".into(),
        progress: None,
        result: Some(result),
        error: None,
        recovery: None,
    })
}
