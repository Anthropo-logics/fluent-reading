use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use unicode_normalization::UnicodeNormalization;

use crate::hash::hex_lower;
use crate::spoken::is_prosodic_punctuation;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SourceRegion {
    pub page_index: u32,
    pub rect_pdf_points: [f64; 4],
    pub page_rotation_degrees: i16,
    pub source_to_page_transform: [f64; 6],
    pub confidence: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ExtractedBlock {
    pub block_id: String,
    pub text: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub spoken_text: Option<String>,
    pub region: SourceRegion,
    pub confidence: f64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub layout_role: Option<LayoutRole>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub layout_confidence: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub layout_order: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub narration_disposition: Option<NarrationDisposition>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub physical_page_index: Option<u8>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, PartialOrd, Ord)]
#[serde(rename_all = "snake_case")]
pub enum LayoutRole {
    Abstract,
    Algorithm,
    AsideText,
    Chart,
    Content,
    Formula,
    #[serde(rename = "doc_title")]
    DocumentTitle,
    #[serde(rename = "figure_title")]
    FigureTitle,
    Footer,
    Footnote,
    FormulaNumber,
    Header,
    Image,
    Number,
    #[serde(rename = "paragraph_title")]
    ParagraphTitle,
    Reference,
    ReferenceContent,
    Seal,
    Table,
    Text,
    VisionFootnote,
    Unknown,
}

impl LayoutRole {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Abstract => "abstract",
            Self::Algorithm => "algorithm",
            Self::AsideText => "aside_text",
            Self::Chart => "chart",
            Self::Content => "content",
            Self::Formula => "formula",
            Self::DocumentTitle => "doc_title",
            Self::FigureTitle => "figure_title",
            Self::Footer => "footer",
            Self::Footnote => "footnote",
            Self::FormulaNumber => "formula_number",
            Self::Header => "header",
            Self::Image => "image",
            Self::Number => "number",
            Self::ParagraphTitle => "paragraph_title",
            Self::Reference => "reference",
            Self::ReferenceContent => "reference_content",
            Self::Seal => "seal",
            Self::Table => "table",
            Self::Text => "text",
            Self::VisionFootnote => "vision_footnote",
            Self::Unknown => "unknown",
        }
    }

    fn narration_disposition(self) -> Option<NarrationDisposition> {
        match self {
            Self::Unknown => None,
            Self::Header
            | Self::Footer
            | Self::Footnote
            | Self::VisionFootnote
            | Self::Number
            | Self::FormulaNumber
            | Self::Seal => Some(NarrationDisposition::Never),
            Self::Algorithm
            | Self::Chart
            | Self::Formula
            | Self::Image
            | Self::Reference
            | Self::ReferenceContent
            | Self::Table => Some(NarrationDisposition::OnDemand),
            _ => Some(NarrationDisposition::Automatic),
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum NarrationDisposition {
    Automatic,
    OnDemand,
    Never,
}

impl NarrationDisposition {
    fn as_str(self) -> &'static str {
        match self {
            Self::Automatic => "automatic",
            Self::OnDemand => "on_demand",
            Self::Never => "never",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PageExtraction {
    pub document_fingerprint: String,
    pub generation_id: String,
    pub page_index: u32,
    pub blocks: Vec<ExtractedBlock>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum RequestedUnit {
    Paragraph,
    Sentence,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ProcessingRoute {
    DirectText,
    Ocr,
}

pub fn select_processing_route(
    direct_block_count: usize,
    ocr_block_count: usize,
    force_ocr: bool,
) -> ProcessingRoute {
    if force_ocr || direct_block_count == 0 || ocr_block_count > direct_block_count {
        ProcessingRoute::Ocr
    } else {
        ProcessingRoute::DirectText
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ReadingUnitKind {
    Paragraph,
    Sentence,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ContentClass {
    Prose,
    Table,
    Formula,
    Note,
    /// A structural title. Scanned books frequently ship an outline with meaningless labels
    /// ("f - 0002"), so headings recovered from the page are what makes chapter navigation
    /// possible. Headings are still narratable content, not something to skip.
    Heading,
    Unsupported,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, PartialOrd, Ord)]
pub struct UnitOrderKey {
    pub primary_page_index: u32,
    pub local_index: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct NormalizationDecision {
    pub rule: String,
    pub confidence: f64,
    pub affected_segments: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ReadingUnit {
    pub unit_id: String,
    pub kind: ReadingUnitKind,
    pub content_class: ContentClass,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub narration_disposition: Option<NarrationDisposition>,
    pub processing_route: ProcessingRoute,
    pub order_key: UnitOrderKey,
    pub text: String,
    pub spoken_text: String,
    pub source_regions: Vec<SourceRegion>,
    pub source_block_ids: Vec<String>,
    pub parent_unit_id: Option<String>,
    pub confidence: f64,
    pub decision_trace: Vec<NormalizationDecision>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ReadingAnchor {
    pub unit_id: String,
    pub unit_kind: ReadingUnitKind,
    pub source_region_index: u32,
    pub sample_offset: u64,
    pub generation_id: String,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum PageProcessingStatus {
    Completed,
    Degraded,
    Failed,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PageProcessingRecord {
    pub page_id: String,
    pub page_index: u32,
    pub route: ProcessingRoute,
    pub reason_code: String,
    pub status: PageProcessingStatus,
    pub confidence: f64,
    pub elapsed_ms: u64,
    pub processor_revision: String,
    pub error_code: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct NormalizedPage {
    pub record: PageProcessingRecord,
    pub units: Vec<ReadingUnit>,
    pub anchors: Vec<ReadingAnchor>,
    pub omissions: Vec<NormalizationDecision>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct BlockOrderMetric {
    pub numerator: u32,
    pub denominator: u32,
    pub ratio: f64,
    pub threshold: f64,
    pub passed: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct CharacterErrorMetric {
    pub distance: u32,
    pub reference_characters: u32,
    pub ratio: f64,
    pub threshold: f64,
    pub passed: bool,
}

pub fn character_error_rate(predicted: &str, expected: &str) -> CharacterErrorMetric {
    let predicted: Vec<_> = predicted.nfc().collect();
    let expected: Vec<_> = expected.nfc().collect();
    let mut distances: Vec<u32> = (0..=expected.len() as u32).collect();
    for (predicted_index, predicted_character) in predicted.iter().enumerate() {
        let mut diagonal = predicted_index as u32;
        distances[0] = predicted_index as u32 + 1;
        for (expected_index, expected_character) in expected.iter().enumerate() {
            let previous = distances[expected_index + 1];
            let substitution = diagonal + u32::from(predicted_character != expected_character);
            distances[expected_index + 1] = substitution
                .min(distances[expected_index] + 1)
                .min(previous + 1);
            diagonal = previous;
        }
    }
    let distance = distances[expected.len()];
    let reference_characters = expected.len() as u32;
    let ratio = if reference_characters == 0 {
        f64::from(!predicted.is_empty())
    } else {
        f64::from(distance) / f64::from(reference_characters)
    };
    CharacterErrorMetric {
        distance,
        reference_characters,
        ratio,
        threshold: 0.05,
        passed: reference_characters > 0 && ratio <= 0.05,
    }
}

pub fn measure_digital_block_order(predicted: &[String], expected: &[String]) -> BlockOrderMetric {
    let mut lengths = vec![0_u32; expected.len() + 1];
    for predicted_value in predicted {
        let mut diagonal = 0;
        for (index, expected_value) in expected.iter().enumerate() {
            let previous = lengths[index + 1];
            if predicted_value == expected_value {
                lengths[index + 1] = diagonal + 1;
            } else {
                lengths[index + 1] = lengths[index + 1].max(lengths[index]);
            }
            diagonal = previous;
        }
    }
    let numerator = lengths[expected.len()];
    let denominator = expected.len().max(predicted.len()) as u32;
    let ratio = if denominator == 0 {
        0.0
    } else {
        f64::from(numerator) / f64::from(denominator)
    };
    BlockOrderMetric {
        numerator,
        denominator,
        ratio,
        threshold: 0.98,
        passed: denominator > 0 && ratio >= 0.98,
    }
}

pub fn normalize_digital_page(
    page: &PageExtraction,
    language: &str,
    requested: RequestedUnit,
) -> NormalizedPage {
    let mut blocks = page.blocks.clone();
    let use_layout_order = layout_order_coverage(&blocks) >= 0.60;
    let column_boundary = if use_layout_order {
        let mut geometrically_ordered = blocks.clone();
        let boundary = order_blocks(&mut geometrically_ordered);
        order_blocks_by_layout(&mut blocks);
        boundary
    } else {
        order_blocks(&mut blocks)
    };
    let multi_column = column_boundary.is_some();

    if blocks.is_empty() {
        return NormalizedPage {
            record: PageProcessingRecord {
                page_id: stable_page_id(page),
                page_index: page.page_index,
                route: ProcessingRoute::DirectText,
                reason_code: "direct_text_empty".into(),
                status: PageProcessingStatus::Failed,
                confidence: 0.0,
                elapsed_ms: 0,
                processor_revision: "direct-v1".into(),
                error_code: Some("LF_PDF_PAGE_NO_TEXT".into()),
            },
            units: vec![],
            anchors: vec![],
            omissions: vec![],
        };
    }

    // Margins are measured per column. A two-column article has two text blocks with their own
    // margins, and measuring them together makes every line of the first column look short and
    // every line of the second look indented — which used to break the page into single lines.
    let in_second_column = |block: &ExtractedBlock| {
        column_boundary.is_some_and(|boundary| reading_rect(&block.region)[0] >= boundary)
    };
    let column_metrics = [
        page_metrics(blocks.iter().filter(|block| !in_second_column(block))),
        page_metrics(blocks.iter().filter(|block| in_second_column(block))),
    ];
    let metrics_for =
        |block: &ExtractedBlock| column_metrics[usize::from(in_second_column(block))].as_ref();

    // Group the extracted lines into paragraphs before turning them into reading units.
    let mut groups: Vec<Vec<ExtractedBlock>> = Vec::new();
    for block in blocks.into_iter() {
        let start_new = match (
            groups.last().and_then(|group| group.last()),
            metrics_for(&block),
        ) {
            (Some(previous), Some(metrics)) => {
                in_second_column(previous) != in_second_column(&block)
                    || starts_new_paragraph(previous, &block, metrics)
            }
            _ => true,
        };
        if start_new {
            groups.push(vec![block]);
        } else if let Some(group) = groups.last_mut() {
            group.push(block);
        }
    }

    // Once a numbered note begins, every following group in that column belongs to the same
    // apparatus, including a marker PDFKit split from its citation and "5. Id."-style short notes.
    let mut footnote_zone_start = [None, None];
    for index in 0..groups.len() {
        let Some(first) = groups[index].first() else {
            continue;
        };
        let column = usize::from(in_second_column(first));
        let Some(metrics) = metrics_for(first) else {
            continue;
        };
        let text = join_paragraph_text(
            &groups[index]
                .iter()
                .map(|block| block.text.clone())
                .collect::<Vec<_>>(),
        );
        if group_is_footnote(&groups, index, metrics, &text) {
            footnote_zone_start[column].get_or_insert(index);
        }
    }

    let mut paragraphs = Vec::with_capacity(groups.len());
    let mut folio_omissions: Vec<NormalizationDecision> = Vec::new();
    for index in 0..groups.len() {
        let group = groups[index].clone();
        let Some(first) = group.first() else { continue };
        let geometry_reliable = group.iter().all(|block| region_is_reliable(&block.region));
        let mut decision_trace = Vec::new();
        let mut line_texts = Vec::with_capacity(group.len());
        let mut spoken_line_texts = Vec::with_capacity(group.len());
        for block in &group {
            let (text, spoken_text, trace) = normalize_text(block);
            line_texts.push(text);
            spoken_line_texts.push(spoken_text);
            decision_trace.extend(trace);
        }
        let text = join_paragraph_text(&line_texts);
        let mut spoken_text = join_paragraph_text(&spoken_line_texts);
        if let Some(projection) = table_of_contents_spoken_text(&text) {
            spoken_text = projection;
            decision_trace.push(NormalizationDecision {
                rule: "omit_toc_leader_and_folio_from_narration".into(),
                confidence: 1.0,
                affected_segments: group.iter().map(|block| block.block_id.clone()).collect(),
            });
        }
        let affected: Vec<String> = group.iter().map(|block| block.block_id.clone()).collect();
        let selected_layout = select_layout_role(&group);
        // A passage that is nothing but a short number is the printed folio. Reading it aloud
        // interrupted the prose and, in the continuous immersion scroll, it sat stranded between
        // paragraphs. Dropping it is recorded so the omission stays auditable.
        if is_running_folio(&text) && selected_layout.is_none() {
            folio_omissions.push(NormalizationDecision {
                rule: "drop_running_folio".into(),
                confidence: 1.0,
                affected_segments: affected.clone(),
            });
            continue;
        }
        let confidence = group
            .iter()
            .map(|block| block.confidence.clamp(0.0, 1.0))
            .fold(1.0_f64, f64::min);
        if group.len() > 1 {
            decision_trace.push(NormalizationDecision {
                rule: "join_lines_into_paragraph".into(),
                confidence,
                affected_segments: affected.clone(),
            });
        }
        if multi_column {
            decision_trace.push(NormalizationDecision {
                rule: "multi_column_order".into(),
                confidence,
                affected_segments: affected.clone(),
            });
        }
        if use_layout_order && group.iter().any(has_layout_order) {
            decision_trace.push(NormalizationDecision {
                rule: "ml_layout_order".into(),
                confidence: group
                    .iter()
                    .filter_map(|block| block.layout_confidence)
                    .filter(|value| value.is_finite() && *value >= 0.30)
                    .fold(1.0_f64, f64::min),
                affected_segments: affected.clone(),
            });
        }
        if confidence < 0.6 {
            decision_trace.push(NormalizationDecision {
                rule: "preserve_uncertain_content".into(),
                confidence,
                affected_segments: affected.clone(),
            });
        }
        if !geometry_reliable {
            decision_trace.push(NormalizationDecision {
                rule: "geometry_unreliable".into(),
                confidence: 0.0,
                affected_segments: affected.clone(),
            });
        }
        // Every source line keeps its own region so highlighting on the PDF still maps back to the
        // exact place the words came from, even though the reader now hears a whole paragraph.
        let regions: Vec<SourceRegion> = group
            .iter()
            .map(|block| {
                let mut region = block.region.clone();
                if !region_is_reliable(&block.region) {
                    region.confidence = 0.0;
                }
                region
            })
            .collect();
        let column = usize::from(in_second_column(first));
        let inside_footnote_zone = footnote_zone_start[column].is_some_and(|start| index >= start);
        let heuristic_class = match metrics_for(first) {
            Some(_) if inside_footnote_zone => ContentClass::Note,
            Some(metrics) if group_is_heading(&groups, index, metrics, &text) => {
                ContentClass::Heading
            }
            _ => classify_content(&text, confidence, geometry_reliable),
        };
        let (content_class, narration_disposition) = selected_layout
            .and_then(|(role, layout_confidence)| {
                apply_layout_policy(role).map(|(class, disposition)| {
                    decision_trace.push(NormalizationDecision {
                        rule: format!("ml_layout_role_{}", role.as_str()),
                        confidence: layout_confidence,
                        affected_segments: affected.clone(),
                    });
                    decision_trace.push(NormalizationDecision {
                        rule: format!("layout_policy_{}", disposition.as_str()),
                        confidence: layout_confidence,
                        affected_segments: affected.clone(),
                    });
                    (class, Some(disposition))
                })
            })
            .unwrap_or((heuristic_class, None));
        let unit_id = stable_id(page, &first.block_id, "paragraph", 0);
        paragraphs.push(ReadingUnit {
            unit_id,
            kind: ReadingUnitKind::Paragraph,
            content_class,
            narration_disposition,
            processing_route: ProcessingRoute::DirectText,
            order_key: UnitOrderKey {
                primary_page_index: page.page_index,
                local_index: index as u32,
            },
            text,
            spoken_text,
            source_regions: regions,
            source_block_ids: affected,
            parent_unit_id: None,
            confidence: if geometry_reliable { confidence } else { 0.0 },
            decision_trace,
        });
    }

    join_heading_continuations(&mut paragraphs, &column_metrics, column_boundary);

    let units = match requested {
        RequestedUnit::Paragraph => paragraphs,
        RequestedUnit::Sentence => paragraphs
            .iter()
            .flat_map(|paragraph| split_sentences(page, language, paragraph))
            .enumerate()
            .map(|(index, mut unit)| {
                unit.order_key.local_index = index as u32;
                unit
            })
            .collect(),
    };
    let anchors = units
        .iter()
        .map(|unit| ReadingAnchor {
            unit_id: unit.unit_id.clone(),
            unit_kind: unit.kind,
            source_region_index: 0,
            sample_offset: 0,
            generation_id: page.generation_id.clone(),
        })
        .collect();
    let confidence = units
        .iter()
        .map(|unit| unit.confidence)
        .fold(1.0_f64, f64::min);

    let has_complex_content = units
        .iter()
        .any(|unit| unit.content_class != ContentClass::Prose);
    NormalizedPage {
        record: PageProcessingRecord {
            page_id: stable_page_id(page),
            page_index: page.page_index,
            route: ProcessingRoute::DirectText,
            reason_code: "direct_text_useful".into(),
            status: if has_complex_content {
                PageProcessingStatus::Degraded
            } else {
                PageProcessingStatus::Completed
            },
            confidence,
            elapsed_ms: 0,
            processor_revision: "direct-v1".into(),
            error_code: None,
        },
        units,
        anchors,
        omissions: folio_omissions,
    }
}

pub fn normalize_digital_document(
    pages: &[PageExtraction],
    language: &str,
    requested: RequestedUnit,
) -> Vec<NormalizedPage> {
    let mut evidence = FurnitureEvidence::default();
    for page in pages {
        evidence.observe(page);
    }

    pages
        .iter()
        .map(|page| {
            let (filtered, mut omissions) = evidence.strip(page);
            let mut normalized = normalize_digital_page(&filtered, language, requested);
            if !omissions.is_empty() && normalized.record.status == PageProcessingStatus::Failed {
                normalized.record.status = PageProcessingStatus::Degraded;
                normalized.record.error_code = None;
            }
            // The folio the page itself dropped stays in the trace behind the furniture: nothing
            // leaves the reading without a rule that explains it.
            omissions.append(&mut normalized.omissions);
            normalized.omissions = omissions;
            normalized
        })
        .collect()
}

/// Which margin of the page a repeated line was printed in. Only used to name the omission so the
/// trace says what the reader would have seen.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum PageEdge {
    Header,
    Footer,
}

/// The comparison key for page furniture. Runs of digits collapse to a single `#`, so the printer's
/// imprint "12959 - A queda do céu.indd 100" and the date stamp "8/10/15 12:30 PM" match themselves
/// from page to page even though the number and the time change on every one. Comparing the literal
/// text — what the previous rule did — never matched anything that carried a page number, which is
/// most of the furniture a book actually prints.
fn furniture_literal(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn furniture_template(text: &str) -> String {
    let collapsed = furniture_literal(text);
    let mut masked = String::with_capacity(collapsed.len());
    let mut inside_digits = false;
    for character in collapsed.chars() {
        if character.is_ascii_digit() {
            if !inside_digits {
                masked.push('#');
                inside_digits = true;
            }
        } else {
            inside_digits = false;
            masked.push(character);
        }
    }
    masked
}

/// The clusters printed at the very top and bottom of a page. Editorial furniture may span three
/// or four lines and a detached folio may leave one large gap inside the cluster; the second large
/// gap stops it before body text, while half-page/cap bounds keep both margins from claiming the
/// same line.
fn edge_blocks(page: &PageExtraction) -> Vec<(usize, PageEdge)> {
    let count = page.blocks.len();
    let max_depth = (count / 2).min(6);
    if max_depth == 0 {
        return Vec::new();
    }
    let mut order: Vec<usize> = (0..count).collect();
    order.sort_by(|left, right| {
        let left_rect = reading_rect(&page.blocks[*left].region);
        let right_rect = reading_rect(&page.blocks[*right].region);
        right_rect[1]
            .total_cmp(&left_rect[1])
            .then_with(|| left_rect[0].total_cmp(&right_rect[0]))
            .then_with(|| {
                page.blocks[*left]
                    .block_id
                    .cmp(&page.blocks[*right].block_id)
            })
    });
    let typical_height = percentile(
        page.blocks
            .iter()
            .map(|block| reading_rect(&block.region)[3])
            .collect(),
        0.5,
    )
    .unwrap_or(0.0);
    let gap_limit = typical_height * 3.0;
    let centre = |index: usize| {
        let rect = reading_rect(&page.blocks[index].region);
        rect[1] + rect[3] / 2.0
    };
    let mut edges = Vec::new();
    let mut gaps = 0;
    for slot in 0..max_depth {
        if slot > 0 && (centre(order[slot - 1]) - centre(order[slot])).abs() > gap_limit {
            gaps += 1;
            if gaps > 1 {
                break;
            }
        }
        edges.push((order[slot], PageEdge::Header));
    }
    gaps = 0;
    for slot in 0..max_depth {
        let index = count - 1 - slot;
        if slot > 0 && (centre(order[index + 1]) - centre(order[index])).abs() > gap_limit {
            gaps += 1;
            if gaps > 1 {
                break;
            }
        }
        edges.push((order[index], PageEdge::Footer));
    }
    edges
}

/// Horizontal reach of the page's text, used as the yardstick for "this line is far shorter than a
/// line of body text".
fn page_span(page: &PageExtraction) -> Option<f64> {
    let mut left = f64::INFINITY;
    let mut right = f64::NEG_INFINITY;
    for block in &page.blocks {
        let rect = reading_rect(&block.region);
        if !rect.iter().all(|value| value.is_finite()) || rect[2] <= 0.0 {
            continue;
        }
        left = left.min(rect[0]);
        right = right.max(rect[0] + rect[2]);
    }
    (left.is_finite() && right > left).then_some(right - left)
}

#[derive(Debug, Default, Clone)]
struct FurnitureTally {
    pages: BTreeSet<u32>,
    headers: usize,
    footers: usize,
    narrow: usize,
    wide: usize,
}

/// What a document has revealed, so far, about the lines it prints in its own margins.
///
/// Two things had to give for this to work on real books. Comparison happens through
/// [`furniture_template`], so a footer carrying the page number still matches itself; and unanimity
/// is no longer required, because books legitimately drop the running head on chapter openings,
/// half-titles and blank versos. A masked template — one that only matches because its digits were
/// hidden — has to clear stricter evidence than a line that repeats literally: at least three pages,
/// a short line well inside the text width, and a majority of the pages it could have appeared on.
/// Verso and recto are counted separately as well, because a running head that alternates sides
/// ("100 A QUEDA DO CÉU" / "A QUEDA DO CÉU 101") only ever reaches half the book.
///
/// The evidence is accumulated instead of computed in one shot because the reader normalises one
/// page at a time: the engine feeds it every page it sees and asks it to strip the same page.
/// Observing a page twice changes nothing, so a retried page cannot inflate the count.
#[derive(Debug, Default, Clone)]
pub struct FurnitureEvidence {
    tallies: BTreeMap<String, FurnitureTally>,
    exact_pages: BTreeMap<String, BTreeSet<u32>>,
    seen_pages: BTreeSet<u32>,
    eligible: [usize; 2],
}

impl FurnitureEvidence {
    pub fn observe(&mut self, page: &PageExtraction) {
        if !self.seen_pages.insert(page.page_index) {
            return;
        }
        let edges = edge_blocks(page);
        if edges.is_empty() {
            return;
        }
        self.eligible[(page.page_index % 2) as usize] += 1;
        let span = page_span(page);
        for (index, edge) in edges {
            let block = &page.blocks[index];
            let template = furniture_template(&block.text);
            if template.trim().is_empty() {
                continue;
            }
            self.exact_pages
                .entry(furniture_literal(&block.text))
                .or_default()
                .insert(page.page_index);
            let tally = self.tallies.entry(template).or_default();
            tally.pages.insert(page.page_index);
            match edge {
                PageEdge::Header => tally.headers += 1,
                PageEdge::Footer => tally.footers += 1,
            }
            let ratio = span.map_or(1.0, |span| reading_rect(&block.region)[2] / span);
            if ratio.is_finite() && ratio <= 0.75 {
                tally.narrow += 1;
            } else {
                tally.wide += 1;
            }
        }
    }

    fn qualified(&self) -> BTreeMap<&str, PageEdge> {
        let total = self.eligible[0] + self.eligible[1];
        let repeats = |pages: &BTreeSet<u32>| {
            let mut parity = [0_usize; 2];
            for page_index in pages {
                parity[(page_index % 2) as usize] += 1;
            }
            5 * pages.len() >= 3 * total
                || (0..2)
                    .any(|side| parity[side] >= 3 && 5 * parity[side] >= 3 * self.eligible[side])
        };
        self.tallies
            .iter()
            .filter_map(|(template, tally)| {
                let seen = tally.pages.len();
                let exact_repeat = self.exact_pages.iter().any(|(literal, pages)| {
                    furniture_template(literal) == *template && pages.len() >= 3 && repeats(pages)
                });
                let qualifies = if exact_repeat {
                    true
                } else if template.contains('#') {
                    seen >= 3
                        && repeats(&tally.pages)
                        && template.chars().count() <= 120
                        && tally.narrow >= tally.wide
                } else {
                    (seen >= 2 && seen == total) || (seen >= 3 && repeats(&tally.pages))
                };
                qualifies.then(|| {
                    let edge = if tally.footers >= tally.headers {
                        PageEdge::Footer
                    } else {
                        PageEdge::Header
                    };
                    (template.as_str(), edge)
                })
            })
            .collect()
    }

    /// Removes from the page the margin lines that the document has shown to be furniture, and
    /// returns the decisions that account for every one of them.
    pub fn strip(&self, page: &PageExtraction) -> (PageExtraction, Vec<NormalizationDecision>) {
        let furniture = self.qualified();
        if furniture.is_empty() {
            return (page.clone(), Vec::new());
        }
        let edges = edge_blocks(page);
        let mut filtered = page.clone();
        let mut omissions = Vec::new();
        filtered.blocks.retain(|block| {
            let at_edge = edges
                .iter()
                .any(|(index, _)| page.blocks[*index].block_id == block.block_id);
            let matched = at_edge
                .then(|| furniture.get(furniture_template(&block.text).as_str()))
                .flatten();
            if let Some(edge) = matched {
                omissions.push(NormalizationDecision {
                    rule: match edge {
                        PageEdge::Header => "remove_repeated_header".into(),
                        PageEdge::Footer => "remove_repeated_footer".into(),
                    },
                    confidence: 1.0,
                    affected_segments: vec![block.block_id.clone()],
                });
            }
            matched.is_none()
        });
        (filtered, omissions)
    }
}

fn normalize_text(block: &ExtractedBlock) -> (String, String, Vec<NormalizationDecision>) {
    let (mut text, changed_hyphen) = join_line_end_hyphens(&block.text);
    text = text.split_whitespace().collect::<Vec<_>>().join(" ");
    let (mut spoken_text, _) =
        join_line_end_hyphens(block.spoken_text.as_deref().unwrap_or(block.text.as_str()));
    spoken_text = spoken_text.split_whitespace().collect::<Vec<_>>().join(" ");
    let mut trace: Vec<_> = changed_hyphen
        .then(|| NormalizationDecision {
            rule: "join_line_end_hyphen".into(),
            confidence: block.confidence.clamp(0.0, 1.0),
            affected_segments: vec![block.block_id.clone()],
        })
        .into_iter()
        .collect();
    if spoken_text != text {
        trace.push(NormalizationDecision {
            rule: "omit_matched_footnote_callout_from_narration".into(),
            confidence: block.confidence.clamp(0.0, 1.0),
            affected_segments: vec![block.block_id.clone()],
        });
    }
    (text, spoken_text, trace)
}

/// Page-level typography derived from the extracted lines, used to decide where paragraphs break.
struct PageMetrics {
    median_height: f64,
    body_height: f64,
    min_left: f64,
    max_right: f64,
}

fn page_metrics<'a>(blocks: impl IntoIterator<Item = &'a ExtractedBlock>) -> Option<PageMetrics> {
    let reliable: Vec<&ExtractedBlock> = blocks
        .into_iter()
        .filter(|block| region_is_reliable(&block.region))
        .collect();
    if reliable.is_empty() {
        return None;
    }
    let median_height = median_line_height(&reliable)?;
    let body_height = percentile(
        reliable
            .iter()
            .map(|block| reading_rect(&block.region)[3])
            .collect(),
        0.75,
    )?;
    // The margins have to be the *typical* ones, not the extreme ones. Taking the outermost line
    // let a single stray element decide the whole page: the printer's slug line at the foot of a
    // book page sits far to the left of the text block, and once `min_left` came from it every
    // body line counted as indented, so every line became its own paragraph. A low and a high
    // percentile keep the body margins while ignoring folios, slug lines and marginal notes.
    let min_left = percentile(
        reliable
            .iter()
            .map(|block| reading_rect(&block.region)[0])
            .collect(),
        0.10,
    )?;
    let max_right = percentile(
        reliable
            .iter()
            .map(|block| {
                let rect = reading_rect(&block.region);
                rect[0] + rect[2]
            })
            .collect(),
        0.90,
    )?;
    (min_left.is_finite() && max_right.is_finite() && max_right > min_left).then_some(PageMetrics {
        median_height,
        body_height,
        min_left,
        max_right,
    })
}

fn percentile(mut values: Vec<f64>, fraction: f64) -> Option<f64> {
    values.retain(|value| value.is_finite());
    values.sort_by(|left, right| left.partial_cmp(right).unwrap_or(std::cmp::Ordering::Equal));
    let index = ((values.len().checked_sub(1)? as f64) * fraction).round() as usize;
    values.get(index).copied()
}

/// Extraction yields one block per visual line, which is why narration paused at every line break
/// and the immersion view showed sentences chopped mid-word. Lines are joined back into paragraphs
/// using the page's own geometry: a paragraph ends where the line stops short of the right margin,
/// where the vertical gap widens, or where the next line is indented.
fn starts_new_paragraph(
    previous: &ExtractedBlock,
    next: &ExtractedBlock,
    metrics: &PageMetrics,
) -> bool {
    if !region_is_reliable(&previous.region) || !region_is_reliable(&next.region) {
        return true;
    }
    // A confident non-automatic layout policy is a boundary, even when geometry says two boxes
    // share one visual line. Otherwise a folio beside the final line is absorbed into the prose
    // group; the automatic text role wins (or the mixed roles become ambiguous), and the source ID
    // of a `never` block leaks into an audible unit.
    let previous_disposition = block_layout_disposition(previous);
    let next_disposition = block_layout_disposition(next);
    if previous_disposition != next_disposition
        && [previous_disposition, next_disposition]
            .into_iter()
            .flatten()
            .any(|disposition| disposition == NarrationDisposition::Never)
    {
        return true;
    }
    // Only lines of the same nature and comparable certainty may merge: a formula, a table or a
    // barely-legible fragment must never be absorbed into a neighbouring prose paragraph.
    let previous_class = classify_content(&previous.text, previous.confidence, true);
    let next_class = classify_content(&next.text, next.confidence, true);
    if previous_class != next_class || previous_class != ContentClass::Prose {
        return true;
    }
    if (previous.confidence - next.confidence).abs() > 0.25 {
        return true;
    }
    // Punctuation is deliberately not consulted. A sentence is not a paragraph: in justified prose
    // most lines of a multi-sentence paragraph end exactly where a sentence ends, because that is
    // where the reflow chose to break. Cutting there turned every paragraph into a string of
    // one-line fragments, both on screen and in the narration. Only the page's own geometry says
    // where a paragraph begins.
    let span = metrics.max_right - metrics.min_left;
    let previous_rect = reading_rect(&previous.region);
    let next_rect = reading_rect(&next.region);
    let previous_centre = previous_rect[1] + previous_rect[3] / 2.0;
    let next_centre = next_rect[1] + next_rect[3] / 2.0;
    // Two boxes at the same height, separated by no more than a word space, are one visual line cut
    // in two — Vision splits a line wherever the type changes — and not a new paragraph. The gap is
    // checked as well: on a two-column page whose columns were not separated, the line beside this
    // one belongs to the other column and must never be appended to it.
    let previous_end = previous_rect[0] + previous_rect[2];
    let horizontal_gap = next_rect[0] - previous_end;
    if (previous_centre - next_centre).abs() < metrics.median_height * 0.5 {
        return !(-metrics.median_height * 0.5..=metrics.median_height).contains(&horizontal_gap);
    }
    if (previous_centre - next_centre).abs() > metrics.median_height * 2.1 {
        return true;
    }
    if previous_rect[0] + previous_rect[2] < metrics.max_right - span * 0.10 {
        return true;
    }
    // A first line set further right than the line above it opens a new paragraph. The indent is
    // measured against the previous line, not against the page margin: an indented block quote has
    // every line indented, yet none of them is indented *relative to the line above*, and measuring
    // against the margin turned each of those lines into its own paragraph.
    if next_rect[0] > previous_rect[0] + (span * 0.02).max(metrics.median_height * 0.4) {
        return true;
    }
    false
}

fn block_layout_disposition(block: &ExtractedBlock) -> Option<NarrationDisposition> {
    let (Some(role), Some(confidence)) = (block.layout_role, block.layout_confidence) else {
        return None;
    };
    (role != LayoutRole::Unknown && confidence.is_finite() && confidence >= 0.30)
        .then(|| role.narration_disposition())
        .flatten()
}

/// Joins the text of consecutive lines, healing the hyphenation the line break introduced.
fn join_paragraph_text(lines: &[String]) -> String {
    let mut joined = String::new();
    for line in lines {
        let piece = line.trim();
        if piece.is_empty() {
            continue;
        }
        if joined.is_empty() {
            joined.push_str(piece);
            continue;
        }
        if let Some(stem) = joined.strip_suffix('-') {
            let stem_owned = stem.to_owned();
            joined = stem_owned;
            joined.push_str(piece);
        } else {
            joined.push(' ');
            joined.push_str(piece);
        }
    }
    joined
}

/// Median glyph height of the page's reliable blocks, used as the body-text baseline a heading has
/// to stand out from. Returns None when the page has no usable geometry to compare against.
fn median_line_height(blocks: &[&ExtractedBlock]) -> Option<f64> {
    let mut heights: Vec<f64> = blocks
        .iter()
        .filter(|block| region_is_reliable(&block.region))
        .filter_map(|block| {
            let height = reading_rect(&block.region)[3];
            let lines = block.text.lines().count().max(1) as f64;
            let per_line = height / lines;
            (per_line.is_finite() && per_line > 0.0).then_some(per_line)
        })
        .collect();
    if heights.is_empty() {
        return None;
    }
    heights.sort_by(|left, right| left.partial_cmp(right).unwrap_or(std::cmp::Ordering::Equal));
    Some(heights[heights.len() / 2])
}

/// A heading is a short, title-like paragraph that stands apart from the body text: either set in a
/// larger face, or separated from its neighbours by more whitespace than normal leading. Judging it
/// against the surrounding groups is far more reliable than font size alone, because most books
/// typeset section titles at body size and rely on the surrounding space to mark them.
fn group_is_heading(
    groups: &[Vec<ExtractedBlock>],
    index: usize,
    metrics: &PageMetrics,
    text: &str,
) -> bool {
    let group = &groups[index];
    if group.len() > 2 {
        return false;
    }
    let trimmed = text.trim();
    let words = trimmed.split_whitespace().count();
    if !(1..=12).contains(&words) {
        return false;
    }
    if trimmed.ends_with(['.', ',', ';', ':']) {
        return false;
    }
    if !group.iter().all(|block| region_is_reliable(&block.region)) {
        return false;
    }
    // A title opens with a capital letter. This is what separates a real heading from the short
    // isolated lines a copyright page is made of: postal codes ("28760 Tres Cantos"), notices
    // opening with a symbol ("© Ediciones Akal"), and continuation lines that start lowercase.
    if !trimmed.chars().next().is_some_and(char::is_uppercase) {
        return false;
    }
    let height = group
        .iter()
        .map(|block| reading_rect(&block.region)[3])
        .fold(0.0_f64, f64::max);
    // OCR line boxes grow with capitals, digits and accents rather than with the type size, so a
    // modest ratio produces false titles on pages like the copyright notice. Only a clearly larger
    // line is trusted; a section title set at body size is missed on purpose rather than filling
    // the navigator with noise.
    if height >= metrics.median_height * 1.35 {
        return true;
    }

    // Same size as the body: rely on the whitespace that isolates a title from its neighbours. The
    // gap has to be measured against the nearest line of each neighbour — the previous paragraph's
    // *last* line and the next paragraph's *first* — not against whichever line comes first.
    let centre_of = |block: &ExtractedBlock| -> f64 {
        let rect = reading_rect(&block.region);
        rect[1] + rect[3] / 2.0
    };
    let Some(own) = group.first().map(centre_of) else {
        return false;
    };
    let gap_before = index
        .checked_sub(1)
        .and_then(|previous| groups[previous].last())
        .map(|block| (centre_of(block) - own).abs());
    let gap_after = groups
        .get(index + 1)
        .and_then(|next| next.first())
        .map(|block| (own - centre_of(block)).abs());
    // Whitespace alone is not enough: a credits page is full of short, isolated, centred lines
    // that are not titles. Isolation only promotes a line that is also set at least slightly
    // larger than the body, which keeps the navigator free of noise.
    let isolated = |gap: Option<f64>| gap.is_some_and(|value| value > metrics.median_height * 2.4);
    height >= metrics.median_height * 1.2 && isolated(gap_before) && isolated(gap_after)
}

/// Puts a title that runs over more than one line back together.
///
/// A chapter opening like "III El hombre de color / y la blanca" is one title set on two lines, but
/// the page's geometry makes them two paragraphs: a centred line stops well short of the right
/// margin, which is exactly the signal [`starts_new_paragraph`] reads as the end of a paragraph.
/// [`group_is_heading`] then promotes only the first of them, because a continuation line opens in
/// lower case and the heading test rejects lower-case openings on purpose — that guard is what
/// keeps a copyright page from filling the navigator with false titles.
///
/// The result was a title straddling two classes, and the reader heard the tail without the head:
/// on `fanon-scanned.pdf`, 9 of the 13 chapters the navigator lists arrived split this way, and only
/// 1 of the 13 was spoken whole.
///
/// What tells a continuation line apart from the body text underneath is the size it is set in, the
/// same signal the heading test already trusts. Measured over that book, every continuation line of
/// a real title stands at 1.52-4.08 times the page's median line height while the body paragraph
/// that follows sits at 1.00, and every one of them opens in lower case — which is what separates
/// them from the entries under a "Bibliografía" heading, set large but opening in capitals.
fn join_heading_continuations(
    paragraphs: &mut Vec<ReadingUnit>,
    column_metrics: &[Option<PageMetrics>; 2],
    column_boundary: Option<f64>,
) {
    // The words of a title, using the bound the prescan navigator already applies to one.
    const MAX_TITLE_WORDS: usize = 30;

    let metrics_for = |unit: &ReadingUnit| -> Option<&PageMetrics> {
        let left = unit
            .source_regions
            .iter()
            .map(|region| reading_rect(region)[0])
            .fold(f64::INFINITY, f64::min);
        let second = column_boundary.is_some_and(|boundary| left >= boundary);
        column_metrics[usize::from(second)].as_ref()
    };

    let continues_title = |unit: &ReadingUnit| -> bool {
        if unit.content_class != ContentClass::Prose {
            return false;
        }
        if !unit.source_regions.iter().all(region_is_reliable) {
            return false;
        }
        let trimmed = unit.text.trim();
        // A new sentence, a name in capitals or a numbered entry opens its own passage; only a line
        // that starts the way a line broken mid-title starts may be pulled back into the title.
        if !trimmed.chars().next().is_some_and(char::is_lowercase) {
            return false;
        }
        let Some(metrics) = metrics_for(unit) else {
            return false;
        };
        let height = unit
            .source_regions
            .iter()
            .map(|region| reading_rect(region)[3])
            .fold(0.0_f64, f64::max);
        height >= metrics.median_height * 1.35
    };

    let mut index = 0;
    while index < paragraphs.len() {
        if paragraphs[index].content_class != ContentClass::Heading {
            index += 1;
            continue;
        }
        while index + 1 < paragraphs.len() && continues_title(&paragraphs[index + 1]) {
            let joined = join_paragraph_text(&[
                paragraphs[index].text.clone(),
                paragraphs[index + 1].text.clone(),
            ]);
            if joined.split_whitespace().count() > MAX_TITLE_WORDS {
                break;
            }
            let tail = paragraphs.remove(index + 1);
            let head = &mut paragraphs[index];
            head.text = joined;
            head.spoken_text =
                join_paragraph_text(&[head.spoken_text.clone(), tail.spoken_text.clone()]);
            head.source_regions.extend(tail.source_regions);
            head.source_block_ids.extend(tail.source_block_ids.clone());
            head.confidence = head.confidence.min(tail.confidence);
            head.narration_disposition = head.narration_disposition.or(tail.narration_disposition);
            head.decision_trace.extend(tail.decision_trace);
            head.decision_trace.push(NormalizationDecision {
                rule: "join_heading_continuation".into(),
                confidence: head.confidence,
                affected_segments: tail.source_block_ids,
            });
        }
        index += 1;
    }
}

fn classify_content(text: &str, confidence: f64, geometry_reliable: bool) -> ContentClass {
    if confidence < 0.6 || !geometry_reliable {
        return ContentClass::Unsupported;
    }
    if text.contains('\t') || text.contains('|') {
        return ContentClass::Table;
    }
    if table_of_contents_spoken_text(text).is_some() {
        return ContentClass::Prose;
    }
    let non_text = text
        .chars()
        .filter(|character| !character.is_alphanumeric() && !character.is_whitespace())
        .count();
    if text
        .chars()
        .any(|character| matches!(character, '=' | '∑' | '√' | '÷' | '×'))
        || (!text.is_empty() && non_text * 3 > text.chars().count())
    {
        ContentClass::Formula
    } else if ["footnote", "nota al pie", "nota de rodapé"]
        .iter()
        .any(|prefix| text.to_lowercase().starts_with(prefix))
    {
        ContentClass::Note
    } else {
        ContentClass::Prose
    }
}

/// A numbered footnote printed at the foot of the page. It stays in the text and on screen — it is
/// real content, often a source the reader will want — but the voice does not read it: hearing a
/// bibliographic note in the middle of a paragraph is what breaks the thread of listening.
///
/// The literal prefixes [`classify_content`] looks for ("nota al pie", "footnote") never occur in a
/// real book, so the note has to be recognised the way a reader recognises it: a short numeral that
/// opens the line, down in the bottom band of the page, with body text still above it. For digital
/// text, a style-confirmed callout is also carried in `spoken_text`; line height remains the
/// conservative fallback for OCR and untagged layers.
///
/// Deliberately conservative: a note left unmarked is merely read aloud, while body prose marked as
/// a note would be silently skipped, and losing audible content is the worse failure.
fn group_is_footnote(
    groups: &[Vec<ExtractedBlock>],
    index: usize,
    metrics: &PageMetrics,
    text: &str,
) -> bool {
    let group = &groups[index];
    if !group
        .iter()
        .all(|block| region_is_reliable(&block.region) && block.confidence >= 0.6)
    {
        return false;
    }
    let trimmed = text.trim();
    if table_of_contents_spoken_text(trimmed).is_some() || !starts_with_note_numeral(trimmed) {
        return false;
    }
    let reliable = || {
        groups
            .iter()
            .flatten()
            .filter(|block| region_is_reliable(&block.region))
    };
    let floor = reliable()
        .map(|block| reading_rect(&block.region)[1])
        .fold(f64::INFINITY, f64::min);
    let ceiling = reliable()
        .map(|block| {
            let rect = reading_rect(&block.region);
            rect[1] + rect[3]
        })
        .fold(f64::NEG_INFINITY, f64::max);
    if !floor.is_finite() || !ceiling.is_finite() || ceiling <= floor {
        return false;
    }
    // A short apparatus lives in the bottom quarter. A dense one can rise above it, but only while
    // its smaller type continues down to a numbered note in that band and its numeral is actually
    // called from the body. Those extra signals keep a numbered list in the body audible.
    let band = floor + (ceiling - floor) * 0.25;
    let group_top = group
        .iter()
        .map(|block| {
            let rect = reading_rect(&block.region);
            rect[1] + rect[3]
        })
        .fold(f64::NEG_INFINITY, f64::max);
    let group_height = group
        .iter()
        .map(|block| reading_rect(&block.region)[3] / block.text.lines().count().max(1) as f64)
        .fold(0.0_f64, f64::max);
    if group_height > metrics.median_height * 1.25 {
        return false;
    }
    let Some(numeral) = opening_note_numeral(trimmed) else {
        return false;
    };
    let has_styled_callouts = groups
        .iter()
        .flatten()
        .any(|block| block.spoken_text.is_some());
    let called_from_styled_body = groups[..index].iter().flatten().any(|block| {
        contains_note_callout(&block.text, numeral)
            && block
                .spoken_text
                .as_deref()
                .is_some_and(|spoken| spoken != block.text)
    });
    if has_styled_callouts && !called_from_styled_body {
        return false;
    }
    if group_top > band {
        let called_from_body = called_from_styled_body
            || groups[..index]
                .iter()
                .flatten()
                .any(|block| contains_note_callout(&block.text, numeral));
        let smaller_type = group_height <= metrics.body_height * 0.9;
        let reaches_bottom_note = groups[index + 1..].iter().any(|candidate| {
            let candidate_text = join_paragraph_text(
                &candidate
                    .iter()
                    .map(|block| block.text.clone())
                    .collect::<Vec<_>>(),
            );
            let candidate_top = candidate
                .iter()
                .map(|block| {
                    let rect = reading_rect(&block.region);
                    rect[1] + rect[3]
                })
                .fold(f64::NEG_INFINITY, f64::max);
            candidate_top <= band && starts_with_note_numeral(candidate_text.trim())
        });
        if !called_from_body || !smaller_type || !reaches_bottom_note {
            return false;
        }
    }
    // Something has to be annotated. Without body text above it, the numbered line is the page's
    // own content — an index, a list of contents — and skipping it would lose the page entirely.
    groups.iter().enumerate().any(|(other, blocks)| {
        other != index
            && !blocks.is_empty()
            && blocks.iter().all(|block| {
                region_is_reliable(&block.region) && reading_rect(&block.region)[1] > band
            })
    })
}

/// The opening numeral of a footnote: one to three digits closed by a dot or a bracket, or followed
/// directly by a capitalised word. A four-digit year, a decimal figure and a date ("3 de mayo") are
/// all rejected on purpose.
fn starts_with_note_numeral(text: &str) -> bool {
    opening_note_numeral(text).is_some()
}

fn opening_note_numeral(text: &str) -> Option<&str> {
    let digits = text.chars().take_while(char::is_ascii_digit).count();
    if !(1..=3).contains(&digits) {
        return None;
    }
    let mut rest = text.chars().skip(digits);
    let valid = match rest.next() {
        Some('.') | Some(')') | Some(']') => rest.next().is_none_or(char::is_whitespace),
        Some(' ') => rest.next().is_some_and(char::is_uppercase),
        _ => false,
    };
    valid.then_some(&text[..digits])
}

fn contains_note_callout(text: &str, numeral: &str) -> bool {
    text.match_indices(numeral).any(|(start, matched)| {
        let before = text[..start].chars().next_back();
        let before_before = text[..start]
            .chars()
            .rev()
            .nth(1)
            .filter(|_| before == Some('.'));
        let after = text[start + matched.len()..].chars().next();
        let attached = before.is_some_and(|character| {
            character.is_alphabetic()
                || matches!(character, ')' | ']')
                || (character == '.' && before_before.is_some_and(|value| !value.is_ascii_digit()))
        });
        attached && after.is_none_or(|character| !character.is_ascii_digit())
    })
}

/// A table-of-contents title followed by a dotted leader and its destination page. The dots are
/// navigation furniture, not mathematical notation; the visible line remains unchanged.
fn table_of_contents_spoken_text(text: &str) -> Option<String> {
    let bytes = text.as_bytes();
    let mut output = String::with_capacity(text.len());
    let mut cursor = 0;
    let mut index = 0;
    let mut changed = false;
    while index < bytes.len() {
        if bytes[index] != b'.' {
            index += 1;
            continue;
        }
        let mut dots_end = index;
        while dots_end < bytes.len() && bytes[dots_end] == b'.' {
            dots_end += 1;
        }
        if dots_end - index >= 3 {
            let mut page_start = dots_end;
            while page_start < bytes.len() && bytes[page_start].is_ascii_whitespace() {
                page_start += 1;
            }
            let mut page_end = page_start;
            while page_end < bytes.len() && bytes[page_end].is_ascii_digit() {
                page_end += 1;
            }
            let title = &text[cursor..index];
            if page_end > page_start
                && title.contains(char::is_alphabetic)
                && (page_end == bytes.len() || bytes[page_end].is_ascii_whitespace())
            {
                output.push_str(title.trim_end());
                output.push(' ');
                cursor = page_end;
                index = page_end;
                changed = true;
                continue;
            }
        }
        index = dots_end;
    }
    if !changed {
        return None;
    }
    output.push_str(&text[cursor..]);
    Some(output.split_whitespace().collect::<Vec<_>>().join(" "))
}

/// A unit that is nothing but a short number is the printed page folio, not something to read
/// aloud: continuous scrolling shows it stranded between paragraphs and the voice announced it.
/// Only a whole unit counts — a year inside a sentence is part of the prose.
fn is_running_folio(text: &str) -> bool {
    let trimmed = text.trim();
    if trimmed.is_empty() || trimmed.chars().count() > 5 {
        return false;
    }
    trimmed.chars().all(|character| character.is_ascii_digit())
        || trimmed
            .chars()
            .all(|character| matches!(character, 'i' | 'v' | 'x' | 'l' | 'I' | 'V' | 'X' | 'L'))
}

/// The rectangle a block occupies **as the reader sees it**, with the page's own `/Rotate` already
/// applied.
///
/// `rect_pdf_points` is PDF user space, which ignores the rotation the viewer applies before
/// showing the page. On a page tagged `/Rotate 90` the lines of type run along the page's **Y**
/// axis and advance along **X** — so every rule in this file that reads `rect[1]` as "how far down
/// the page" and `rect[3]` as "how tall the line is" was reading the wrong axis. Measured on
/// `Goldberg2002` p5 (1,046 such pages across 16 documents of the reference corpus): extraction
/// hands over 111 lines in perfect reading order and the ordering here scattered them, so the
/// reader heard "ate — n On" instead of "decades has seductively prompted…".
///
/// The returned rectangle uses the same convention as an unrotated page — x grows to the right, y
/// grows towards the top of what is displayed — so every rule downstream keeps working unchanged.
/// The origin is not restored to the crop box, because nothing here compares against absolute page
/// coordinates: only differences, orders and spans, all of which survive the translation. The
/// emitted `SourceRegion`s keep the untouched page-space rectangle, so highlighting on the PDF
/// still lands on the words.
///
/// A rotation that is not a quarter turn is left alone: there is no axis to swap, and guessing
/// would be worse than the identity.
fn reading_rect(region: &SourceRegion) -> [f64; 4] {
    let [x, y, width, height] = region.rect_pdf_points;
    match region.page_rotation_degrees.rem_euclid(360) {
        90 => [y, -(x + width), height, width],
        180 => [-(x + width), -(y + height), width, height],
        270 => [-(y + height), x, height, width],
        _ => [x, y, width, height],
    }
}

fn region_is_reliable(region: &SourceRegion) -> bool {
    region.rect_pdf_points.iter().all(|value| value.is_finite())
        && region
            .source_to_page_transform
            .iter()
            .all(|value| value.is_finite())
        && region.rect_pdf_points[2] > 0.0
        && region.rect_pdf_points[3] > 0.0
        && region.confidence.is_finite()
        && region.confidence >= 0.6
}

/// Orders the lines for reading and reports the vertical boundary between columns, when the page
/// has two of them, so that each column can be measured against its own margins.
fn order_blocks(blocks: &mut [ExtractedBlock]) -> Option<f64> {
    if blocks.len() < 4 {
        blocks.sort_by(top_down_order);
        return None;
    }

    let mut by_x: Vec<_> = blocks.iter().collect();
    by_x.sort_by(|left, right| {
        reading_rect(&left.region)[0]
            .total_cmp(&reading_rect(&right.region)[0])
            .then_with(|| left.block_id.cmp(&right.block_id))
    });
    let split = (2..=by_x.len() - 2)
        .filter_map(|index| {
            let left_edge = by_x[..index]
                .iter()
                .map(|block| {
                    let rect = reading_rect(&block.region);
                    rect[0] + rect[2]
                })
                .fold(f64::NEG_INFINITY, f64::max);
            let right_edge = by_x[index..]
                .iter()
                .map(|block| reading_rect(&block.region)[0])
                .fold(f64::INFINITY, f64::min);
            let gap = right_edge - left_edge;
            (gap >= 12.0).then_some((gap, right_edge))
        })
        .max_by(|left, right| left.0.total_cmp(&right.0))
        .map(|(_, boundary)| boundary);

    if let Some(boundary) = split {
        blocks.sort_by(|left, right| {
            let left_column = reading_rect(&left.region)[0] >= boundary;
            let right_column = reading_rect(&right.region)[0] >= boundary;
            left_column
                .cmp(&right_column)
                .then_with(|| top_down_order(left, right))
        });
        Some(boundary)
    } else {
        blocks.sort_by(top_down_order);
        None
    }
}

fn top_down_order(left: &ExtractedBlock, right: &ExtractedBlock) -> std::cmp::Ordering {
    let left_rect = reading_rect(&left.region);
    let right_rect = reading_rect(&right.region);
    right_rect[1]
        .total_cmp(&left_rect[1])
        .then_with(|| left_rect[0].total_cmp(&right_rect[0]))
        .then_with(|| left.block_id.cmp(&right.block_id))
}

fn has_layout_order(block: &ExtractedBlock) -> bool {
    !block.text.trim().is_empty()
        && block.layout_order.is_some()
        && block
            .layout_confidence
            .is_some_and(|confidence| confidence.is_finite() && confidence >= 0.30)
}

fn layout_order_coverage(blocks: &[ExtractedBlock]) -> f64 {
    let non_empty = blocks
        .iter()
        .filter(|block| !block.text.trim().is_empty())
        .count();
    if non_empty == 0 {
        return 0.0;
    }
    blocks
        .iter()
        .filter(|block| has_layout_order(block))
        .count() as f64
        / non_empty as f64
}

fn order_blocks_by_layout(blocks: &mut [ExtractedBlock]) {
    blocks.sort_by(|left, right| {
        let left_key = (
            left.physical_page_index.unwrap_or(u8::MAX),
            has_layout_order(left)
                .then_some(left.layout_order)
                .flatten()
                .unwrap_or(u32::MAX),
        );
        let right_key = (
            right.physical_page_index.unwrap_or(u8::MAX),
            has_layout_order(right)
                .then_some(right.layout_order)
                .flatten()
                .unwrap_or(u32::MAX),
        );
        left_key
            .cmp(&right_key)
            .then_with(|| top_down_order(left, right))
    });
}

fn select_layout_role(group: &[ExtractedBlock]) -> Option<(LayoutRole, f64)> {
    let mut confidence_by_role = BTreeMap::<LayoutRole, f64>::new();
    for block in group {
        let (Some(role), Some(confidence)) = (block.layout_role, block.layout_confidence) else {
            continue;
        };
        if role == LayoutRole::Unknown || !confidence.is_finite() || confidence < 0.30 {
            continue;
        }
        confidence_by_role
            .entry(role)
            .and_modify(|current| *current = current.max(confidence))
            .or_insert(confidence);
    }
    let mut roles: Vec<_> = confidence_by_role.into_iter().collect();
    roles.sort_by(|left, right| {
        right
            .1
            .total_cmp(&left.1)
            .then_with(|| left.0.cmp(&right.0))
    });
    match roles.as_slice() {
        [] => None,
        [(role, confidence)] => Some((*role, *confidence)),
        [(role, confidence), (_, runner_up), ..] if *confidence >= runner_up + 0.10 => {
            Some((*role, *confidence))
        }
        _ => None,
    }
}

fn apply_layout_policy(role: LayoutRole) -> Option<(ContentClass, NarrationDisposition)> {
    let disposition = role.narration_disposition()?;
    let class = match disposition {
        NarrationDisposition::Automatic
            if matches!(
                role,
                LayoutRole::DocumentTitle | LayoutRole::FigureTitle | LayoutRole::ParagraphTitle
            ) =>
        {
            ContentClass::Heading
        }
        NarrationDisposition::Automatic => ContentClass::Prose,
        NarrationDisposition::OnDemand if role == LayoutRole::Table => ContentClass::Table,
        NarrationDisposition::OnDemand
            if matches!(role, LayoutRole::Formula | LayoutRole::Algorithm) =>
        {
            ContentClass::Formula
        }
        NarrationDisposition::Never
            if matches!(role, LayoutRole::Footnote | LayoutRole::VisionFootnote) =>
        {
            ContentClass::Note
        }
        NarrationDisposition::OnDemand | NarrationDisposition::Never => ContentClass::Unsupported,
    };
    Some((class, disposition))
}

fn join_line_end_hyphens(input: &str) -> (String, bool) {
    let normalized = input.replace("\r\n", "\n");
    let characters: Vec<_> = normalized.chars().collect();
    let mut output = String::with_capacity(normalized.len());
    let mut joined = false;
    let mut index = 0;
    while index < characters.len() {
        if characters[index] == '-'
            && characters.get(index + 1) == Some(&'\n')
            && index > 0
            && characters[index - 1].is_alphabetic()
            && characters
                .get(index + 2)
                .is_some_and(|value| value.is_alphabetic())
        {
            joined = true;
            index += 2;
        } else {
            output.push(characters[index]);
            index += 1;
        }
    }
    (output, joined)
}

fn split_sentences(
    page: &PageExtraction,
    language: &str,
    paragraph: &ReadingUnit,
) -> Vec<ReadingUnit> {
    if table_of_contents_spoken_text(&paragraph.text).is_some() {
        return vec![sentence_unit(
            page,
            language,
            paragraph,
            &paragraph.text,
            &paragraph.spoken_text,
            0,
        )];
    }
    let visible = sentence_texts(&paragraph.text);
    let spoken = sentence_texts(&paragraph.spoken_text);
    visible
        .into_iter()
        .enumerate()
        .map(|(ordinal, text)| {
            sentence_unit(
                page,
                language,
                paragraph,
                text,
                spoken.get(ordinal).copied().unwrap_or(text),
                ordinal as u32,
            )
        })
        .collect()
}

fn sentence_texts(text: &str) -> Vec<&str> {
    let mut start = 0;
    let mut sentences = Vec::new();
    for (index, character) in text.char_indices() {
        if matches!(character, '.' | '!' | '?') && is_prosodic_punctuation(text, index, character) {
            let end = index + character.len_utf8();
            let sentence = text[start..end].trim();
            if !sentence.is_empty() {
                sentences.push(sentence);
            }
            start = end;
        }
    }
    let remainder = text[start..].trim();
    if !remainder.is_empty() {
        sentences.push(remainder);
    }
    sentences
}

fn sentence_unit(
    page: &PageExtraction,
    language: &str,
    paragraph: &ReadingUnit,
    text: &str,
    spoken_text: &str,
    ordinal: u32,
) -> ReadingUnit {
    ReadingUnit {
        unit_id: stable_id(page, &paragraph.unit_id, language, ordinal),
        kind: ReadingUnitKind::Sentence,
        content_class: paragraph.content_class,
        narration_disposition: paragraph.narration_disposition,
        processing_route: paragraph.processing_route,
        order_key: paragraph.order_key.clone(),
        text: text.into(),
        spoken_text: spoken_text.into(),
        source_regions: paragraph.source_regions.clone(),
        source_block_ids: paragraph.source_block_ids.clone(),
        parent_unit_id: Some(paragraph.unit_id.clone()),
        confidence: paragraph.confidence,
        decision_trace: paragraph.decision_trace.clone(),
    }
}

fn stable_id(page: &PageExtraction, source_id: &str, kind: &str, ordinal: u32) -> String {
    let mut hash = Sha256::new();
    for value in [
        page.document_fingerprint.as_bytes(),
        page.generation_id.as_bytes(),
        page.page_index.to_string().as_bytes(),
        source_id.as_bytes(),
        kind.as_bytes(),
        ordinal.to_string().as_bytes(),
    ] {
        hash.update((value.len() as u64).to_le_bytes());
        hash.update(value);
    }
    let digest = hex_lower(&hash.finalize());
    format!("unit_{digest}")
}

fn stable_page_id(page: &PageExtraction) -> String {
    stable_id(page, "page", "page", page.page_index).replacen("unit_", "page_", 1)
}
