use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Component, Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::{ErrorScope, LfError, SCHEMA_VERSION};

const MAX_MANIFEST_BYTES: u64 = 1_048_576;
const MAX_GROUND_TRUTH_BYTES: u64 = 8_388_608;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CorpusValidationResult {
    pub corpus_id: String,
    pub complete: bool,
    pub document_count: u32,
    pub matrix_document_count: u32,
    pub page_count: u32,
    pub checked_hashes: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct ValidationRun {
    pub schema_version: u32,
    pub validation_run_id: String,
    pub corpus_id: String,
    pub corpus_hashes: BTreeMap<String, String>,
    pub environment: ValidationEnvironment,
    pub processing_route: String,
    pub confidence: f64,
    pub duration_ms: u64,
    pub errors: Vec<String>,
    pub page_metrics: Vec<PageMetric>,
    pub status: ValidationRunStatus,
    pub artifacts: ValidationArtifacts,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ValidationEnvironment {
    pub hardware: String,
    pub operating_system: String,
    pub rust: String,
    pub app_revision: String,
    pub processor_revision: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct PageMetric {
    pub document_id: String,
    pub page_index: u32,
    pub metric: String,
    pub numerator: u64,
    pub denominator: u64,
    pub value: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ValidationRunStatus {
    Complete,
    Incomplete,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ValidationArtifacts {
    pub environment_sha256: String,
    pub metrics_sha256: String,
    pub summary_sha256: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CorpusValidationError {
    ManifestMissing,
    ManifestNotRegular,
    ManifestInvalid,
    UnsupportedSchema,
    EntryInvalid,
    UnsafeRelativePath,
    SourceMissing,
    SourceNotRegular,
    SourceOutsideRoot,
    HashMismatch,
    SizeMismatch,
    InputTooLarge,
    GroundTruthMissing,
    GroundTruthInvalid,
    CoverageIncomplete,
}

impl CorpusValidationError {
    pub fn as_lf_error(self) -> LfError {
        let (code, message_key) = match self {
            Self::ManifestMissing | Self::SourceMissing | Self::GroundTruthMissing => {
                ("LF_FILE_NOT_FOUND", "file.not_found")
            }
            Self::ManifestNotRegular | Self::SourceNotRegular => {
                ("LF_FILE_TYPE_INVALID", "file.type_invalid")
            }
            Self::SourceOutsideRoot | Self::UnsafeRelativePath => {
                ("LF_FILE_SCOPE_INVALID", "file.scope_invalid")
            }
            Self::HashMismatch => ("LF_INPUT_HASH_MISMATCH", "input.hash_mismatch"),
            Self::SizeMismatch => ("LF_INPUT_SIZE_MISMATCH", "input.size_mismatch"),
            Self::InputTooLarge => ("LF_INPUT_SIZE_LIMIT", "input.size_limit"),
            Self::CoverageIncomplete => ("LF_INPUT_CORPUS_INCOMPLETE", "input.corpus_incomplete"),
            Self::UnsupportedSchema => ("LF_INPUT_SCHEMA_UNSUPPORTED", "input.schema_unsupported"),
            Self::ManifestInvalid | Self::EntryInvalid | Self::GroundTruthInvalid => {
                ("LF_INPUT_ANNOTATION_INVALID", "input.annotation_invalid")
            }
        };
        LfError {
            code: code.into(),
            message_key: message_key.into(),
            scope: ErrorScope::default(),
            details: BTreeMap::new(),
        }
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct CorpusManifest {
    schema_version: u32,
    corpus_id: String,
    entries: Vec<CorpusEntry>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct CorpusEntry {
    id: String,
    role: EntryRole,
    file: PathBuf,
    sha256: String,
    byte_size: u64,
    provenance: Provenance,
    classification: Classification,
    language: Language,
    required: bool,
    distributable: bool,
    page_count: u32,
    pages_evaluated: Vec<u32>,
    ground_truth: PathBuf,
}

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
enum EntryRole {
    Matrix,
    LongForm,
    Adversarial,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Provenance {
    source: String,
    permission: Permission,
    evidence: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
enum Permission {
    Owned,
    Generated,
    Cc0,
    CcBy,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Classification {
    layout: Layout,
    content: Content,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
enum Layout {
    SingleColumn,
    MultiColumn,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
enum Content {
    Digital,
    Scanned,
    Mixed,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "lowercase")]
enum Language {
    Es,
    En,
    Pt,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct GroundTruth {
    schema_version: u32,
    document_id: String,
    revision: u32,
    pages: Vec<TruthPage>,
    unsupported: Vec<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct TruthPage {
    page_index: u32,
    blocks: Vec<TruthBlock>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct TruthBlock {
    block_id: String,
    order: u32,
    text: String,
    region: Option<[f64; 4]>,
    paragraphs: Vec<TruthParagraph>,
    degradation: Option<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct TruthParagraph {
    paragraph_id: String,
    sentences: Vec<TruthSentence>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct TruthSentence {
    sentence_id: String,
    text: String,
}

pub fn validate_corpus_manifest(
    path: impl AsRef<Path>,
) -> Result<CorpusValidationResult, CorpusValidationError> {
    let path = path.as_ref();
    let metadata = fs::symlink_metadata(path).map_err(|error| {
        if error.kind() == std::io::ErrorKind::NotFound {
            CorpusValidationError::ManifestMissing
        } else {
            CorpusValidationError::ManifestInvalid
        }
    })?;
    if !metadata.file_type().is_file() {
        return Err(CorpusValidationError::ManifestNotRegular);
    }
    let root = path
        .parent()
        .ok_or(CorpusValidationError::ManifestInvalid)?;
    let canonical_root = root
        .canonicalize()
        .map_err(|_| CorpusValidationError::ManifestInvalid)?;
    let bytes = read_limited(
        path,
        MAX_MANIFEST_BYTES,
        CorpusValidationError::ManifestInvalid,
    )?;
    let manifest: CorpusManifest =
        serde_json::from_slice(&bytes).map_err(|_| CorpusValidationError::ManifestInvalid)?;
    if manifest.schema_version != SCHEMA_VERSION {
        return Err(CorpusValidationError::UnsupportedSchema);
    }
    if !valid_id(&manifest.corpus_id) || manifest.entries.is_empty() {
        return Err(CorpusValidationError::ManifestInvalid);
    }

    let mut ids = BTreeSet::new();
    let mut source_paths = BTreeSet::new();
    let mut truth_paths = BTreeSet::new();
    let mut matrix = BTreeSet::new();
    let mut matrix_count = 0_u32;
    let mut page_count = 0_u32;
    let mut checked_hashes = 0_u32;
    let mut has_long_form = false;
    let mut has_adversarial = false;
    let mut complete = true;

    for entry in &manifest.entries {
        validate_entry_metadata(entry, &mut ids)?;
        if !source_paths.insert(entry.file.clone())
            || !truth_paths.insert(entry.ground_truth.clone())
        {
            return Err(CorpusValidationError::EntryInvalid);
        }
        let source = resolve_regular_file(
            root,
            &canonical_root,
            &entry.file,
            CorpusValidationError::SourceMissing,
            CorpusValidationError::SourceNotRegular,
        )?;
        if fs::metadata(&source)
            .map_err(|_| CorpusValidationError::SourceMissing)?
            .len()
            != entry.byte_size
        {
            return Err(CorpusValidationError::SizeMismatch);
        }
        let observed = sha256_file(&source)?;
        if observed != entry.sha256 {
            return Err(CorpusValidationError::HashMismatch);
        }
        checked_hashes += 1;

        let truth_path = resolve_regular_file(
            root,
            &canonical_root,
            &entry.ground_truth,
            CorpusValidationError::GroundTruthMissing,
            CorpusValidationError::GroundTruthInvalid,
        )?;
        let truth: GroundTruth = serde_json::from_slice(&read_limited(
            &truth_path,
            MAX_GROUND_TRUTH_BYTES,
            CorpusValidationError::GroundTruthMissing,
        )?)
        .map_err(|_| CorpusValidationError::GroundTruthInvalid)?;
        validate_truth(entry, &truth)?;

        page_count = page_count
            .checked_add(entry.page_count)
            .ok_or(CorpusValidationError::EntryInvalid)?;
        complete &= entry.required;
        match entry.role {
            EntryRole::Matrix => {
                matrix_count += 1;
                matrix.insert(format!(
                    "{:?}:{:?}:{:?}",
                    entry.language, entry.classification.layout, entry.classification.content
                ));
            }
            EntryRole::LongForm => has_long_form |= entry.page_count >= 1_000,
            EntryRole::Adversarial => has_adversarial = true,
        }
    }

    let expected_matrix: BTreeSet<_> = [
        "Es:SingleColumn:Digital",
        "Es:MultiColumn:Digital",
        "Es:SingleColumn:Scanned",
        "Es:MultiColumn:Mixed",
        "En:SingleColumn:Digital",
        "En:MultiColumn:Digital",
        "En:SingleColumn:Scanned",
        "En:MultiColumn:Mixed",
        "Pt:SingleColumn:Digital",
        "Pt:MultiColumn:Digital",
        "Pt:SingleColumn:Scanned",
        "Pt:MultiColumn:Mixed",
    ]
    .into_iter()
    .map(String::from)
    .collect();
    if matrix_count != 12
        || matrix != expected_matrix
        || !has_long_form
        || !has_adversarial
        || !complete
    {
        return Err(CorpusValidationError::CoverageIncomplete);
    }

    Ok(CorpusValidationResult {
        corpus_id: manifest.corpus_id,
        complete,
        document_count: manifest.entries.len() as u32,
        matrix_document_count: matrix_count,
        page_count,
        checked_hashes,
    })
}

fn validate_entry_metadata(
    entry: &CorpusEntry,
    ids: &mut BTreeSet<String>,
) -> Result<(), CorpusValidationError> {
    if !valid_id(&entry.id)
        || !ids.insert(entry.id.clone())
        || !valid_relative_path(&entry.file)
        || !valid_relative_path(&entry.ground_truth)
        || entry.sha256.len() != 64
        || !entry
            .sha256
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
        || entry.byte_size == 0
        || entry.page_count == 0
        || entry.pages_evaluated.is_empty()
        || entry.pages_evaluated.iter().collect::<BTreeSet<_>>().len()
            != entry.pages_evaluated.len()
        || entry
            .pages_evaluated
            .iter()
            .any(|page| *page >= entry.page_count)
        || entry.provenance.source.trim().is_empty()
        || entry.provenance.evidence.trim().is_empty()
        || !entry.distributable
    {
        return Err(CorpusValidationError::EntryInvalid);
    }
    match entry.provenance.permission {
        Permission::Owned | Permission::Generated | Permission::Cc0 | Permission::CcBy => Ok(()),
    }
}

fn validate_truth(entry: &CorpusEntry, truth: &GroundTruth) -> Result<(), CorpusValidationError> {
    if truth.schema_version != SCHEMA_VERSION
        || truth.document_id != entry.id
        || truth.revision == 0
        || truth.pages.len() != entry.pages_evaluated.len()
        || truth
            .pages
            .iter()
            .map(|page| page.page_index)
            .collect::<Vec<_>>()
            != entry.pages_evaluated
        || truth
            .unsupported
            .iter()
            .any(|value| value.trim().is_empty())
    {
        return Err(CorpusValidationError::GroundTruthInvalid);
    }
    for page in &truth.pages {
        if page.blocks.is_empty() {
            return Err(CorpusValidationError::GroundTruthInvalid);
        }
        for (index, block) in page.blocks.iter().enumerate() {
            let region_valid = block.region.is_none_or(|region| {
                region[0] >= 0.0
                    && region[1] >= 0.0
                    && region[2] > 0.0
                    && region[3] > 0.0
                    && region[0] + region[2] <= 1.0
                    && region[1] + region[3] <= 1.0
            });
            if !valid_id(&block.block_id)
                || block.order != index as u32
                || block.text.trim().is_empty()
                || !region_valid
                || block.paragraphs.is_empty()
                || block
                    .degradation
                    .as_ref()
                    .is_some_and(|value| value.trim().is_empty())
            {
                return Err(CorpusValidationError::GroundTruthInvalid);
            }
            for paragraph in &block.paragraphs {
                if !valid_id(&paragraph.paragraph_id) || paragraph.sentences.is_empty() {
                    return Err(CorpusValidationError::GroundTruthInvalid);
                }
                if paragraph.sentences.iter().any(|sentence| {
                    !valid_id(&sentence.sentence_id) || sentence.text.trim().is_empty()
                }) {
                    return Err(CorpusValidationError::GroundTruthInvalid);
                }
            }
        }
    }
    Ok(())
}

fn resolve_regular_file(
    root: &Path,
    canonical_root: &Path,
    relative: &Path,
    missing: CorpusValidationError,
    invalid_type: CorpusValidationError,
) -> Result<PathBuf, CorpusValidationError> {
    if !valid_relative_path(relative) {
        return Err(CorpusValidationError::UnsafeRelativePath);
    }
    let candidate = root.join(relative);
    let metadata = fs::symlink_metadata(&candidate).map_err(|error| {
        if error.kind() == std::io::ErrorKind::NotFound {
            missing
        } else {
            invalid_type
        }
    })?;
    if !metadata.is_file() {
        return Err(invalid_type);
    }
    let canonical = candidate.canonicalize().map_err(|_| invalid_type)?;
    if !canonical.starts_with(canonical_root) {
        return Err(CorpusValidationError::SourceOutsideRoot);
    }
    Ok(canonical)
}

fn valid_relative_path(path: &Path) -> bool {
    !path.as_os_str().is_empty()
        && !path.is_absolute()
        && path
            .components()
            .all(|component| matches!(component, Component::Normal(_)))
}

fn valid_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'))
}

fn read_limited(
    path: &Path,
    max_bytes: u64,
    read_error: CorpusValidationError,
) -> Result<Vec<u8>, CorpusValidationError> {
    let metadata = fs::metadata(path).map_err(|_| read_error)?;
    if metadata.len() > max_bytes {
        return Err(CorpusValidationError::InputTooLarge);
    }
    fs::read(path).map_err(|_| read_error)
}

fn sha256_file(path: &Path) -> Result<String, CorpusValidationError> {
    crate::hash::fingerprint_file(path).map_err(|_| CorpusValidationError::SourceMissing)
}
