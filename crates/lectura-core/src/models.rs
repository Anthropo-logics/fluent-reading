use std::collections::BTreeSet;
use std::fs;
use std::path::{Component, Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::{ErrorScope, LfError, SCHEMA_VERSION};

const MAX_MANIFEST_BYTES: u64 = 1_048_576;
const MAX_MODEL_BYTES: u64 = 16 * 1024 * 1024 * 1024;
const MAX_MODEL_FILES: usize = 32;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ModelPurpose {
    Tts,
    Translation,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum DistributionStatus {
    Laboratory,
    PendingReview,
    Distributable,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ModelArtifact {
    pub relative_path: PathBuf,
    pub role: String,
    pub source_url: String,
    pub publisher: String,
    pub format: String,
    pub quantization: String,
    pub size_bytes: u64,
    pub sha256_hex: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ModelManifest {
    pub schema_version: u32,
    pub id: String,
    pub model_revision: String,
    pub artifact_revision: String,
    pub purpose: ModelPurpose,
    pub authors: Vec<String>,
    pub license_id: String,
    pub usage_restrictions: Vec<String>,
    pub languages: Vec<String>,
    pub voices: Vec<String>,
    pub runtime_id: String,
    pub runtime_version: String,
    pub distribution_status: DistributionStatus,
    pub artifacts: Vec<ModelArtifact>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ModelVerificationResult {
    pub model_id: String,
    pub model_revision: String,
    pub artifact_revision: String,
    pub purpose: ModelPurpose,
    pub runtime_id: String,
    pub runtime_version: String,
    pub distribution_status: DistributionStatus,
    pub checked_artifacts: u32,
    pub total_size_bytes: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ModelInstallationState {
    Available,
    Downloading,
    Cancelled,
    Failed,
    Installed,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ModelInstallationSession {
    pub model_id: String,
    pub state: ModelInstallationState,
    pub completed_bytes: u64,
    pub total_bytes: u64,
    pub error_code: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct VoiceSelection {
    pub language: String,
    pub voice_id: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VoiceSelectionError {
    ModelRequired,
    Unsupported,
}

impl VoiceSelection {
    pub fn kokoro(language: &str, voice_id: &str) -> Option<Self> {
        matches!(
            (language, voice_id),
            ("es", "ef_dora") | ("en", "af_heart") | ("pt", "pf_dora")
        )
        .then(|| Self {
            language: language.to_owned(),
            voice_id: voice_id.to_owned(),
        })
    }

    pub fn resolve_kokoro(
        language: Option<&str>,
        voice_id: Option<&str>,
    ) -> Result<Self, VoiceSelectionError> {
        match (language, voice_id) {
            (Some(language), Some(voice_id)) => {
                Self::kokoro(language, voice_id).ok_or(VoiceSelectionError::Unsupported)
            }
            _ => Err(VoiceSelectionError::ModelRequired),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ModelInstallationTransitionError {
    InvalidTransition,
    InvalidProgress,
    VerificationRequired,
}

impl ModelInstallationSession {
    pub fn new(model_id: String, total_bytes: u64) -> Option<Self> {
        (!model_id.is_empty() && total_bytes > 0).then_some(Self {
            model_id,
            state: ModelInstallationState::Available,
            completed_bytes: 0,
            total_bytes,
            error_code: None,
        })
    }

    pub fn begin(&mut self) -> Result<(), ModelInstallationTransitionError> {
        if !matches!(
            self.state,
            ModelInstallationState::Available
                | ModelInstallationState::Cancelled
                | ModelInstallationState::Failed
        ) {
            return Err(ModelInstallationTransitionError::InvalidTransition);
        }
        self.state = ModelInstallationState::Downloading;
        self.error_code = None;
        Ok(())
    }

    pub fn report_progress(
        &mut self,
        completed_bytes: u64,
    ) -> Result<(), ModelInstallationTransitionError> {
        if self.state != ModelInstallationState::Downloading
            || completed_bytes < self.completed_bytes
            || completed_bytes > self.total_bytes
        {
            return Err(ModelInstallationTransitionError::InvalidProgress);
        }
        self.completed_bytes = completed_bytes;
        Ok(())
    }

    pub fn cancel(&mut self) -> Result<(), ModelInstallationTransitionError> {
        if self.state != ModelInstallationState::Downloading {
            return Err(ModelInstallationTransitionError::InvalidTransition);
        }
        self.state = ModelInstallationState::Cancelled;
        Ok(())
    }

    pub fn fail(&mut self, error_code: String) -> Result<(), ModelInstallationTransitionError> {
        if self.state != ModelInstallationState::Downloading || error_code.is_empty() {
            return Err(ModelInstallationTransitionError::InvalidTransition);
        }
        self.state = ModelInstallationState::Failed;
        self.error_code = Some(error_code);
        Ok(())
    }

    pub fn publish_verified(&mut self) -> Result<(), ModelInstallationTransitionError> {
        if self.state != ModelInstallationState::Downloading
            || self.completed_bytes != self.total_bytes
        {
            return Err(ModelInstallationTransitionError::VerificationRequired);
        }
        self.state = ModelInstallationState::Installed;
        self.error_code = None;
        Ok(())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct NarrationSegment {
    pub unit_id: String,
    pub segment_index: u32,
    pub unit_sample_offset: u64,
    pub sample_count: u64,
    pub sample_rate_hz: u32,
    pub elapsed_ms: u64,
    pub artifact_hash: Option<String>,
    pub model_revision: String,
    pub voice_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct TtsUnit {
    pub unit_id: String,
    pub text: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct TtsSynthesisRequest {
    pub model_id: String,
    pub model_revision: String,
    pub runtime_id: String,
    pub runtime_version: String,
    pub voice_id: String,
    pub language: String,
    #[serde(default)]
    pub raw_ipa: bool,
    pub units: Vec<TtsUnit>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct TtsSynthesisResult {
    pub model_id: String,
    pub model_revision: String,
    pub runtime_id: String,
    pub runtime_version: String,
    pub voice_id: String,
    pub language: String,
    pub audio_path: String,
    pub segments: Vec<NarrationSegment>,
    pub omitted_unit_ids: Vec<String>,
}

impl TtsSynthesisRequest {
    pub fn validate(&self) -> Result<(), TtsError> {
        let pair_supported = self.runtime_id == "mlx-audio-swift"
            && self.runtime_version == "v0.1.3"
            && matches!(
                (self.model_id.as_str(), self.model_revision.as_str()),
                (
                    "kokoro-82m-4bit",
                    "e4468a460f6f70b9125a003e0adb1ab7d4904bbd"
                ) | (
                    "qwen3-tts-0.6b-customvoice-4bit",
                    "93076f032b285167cbb63aeba1e37ec918968bbb"
                ) | (
                    "qwen3-tts-1.7b-customvoice-4bit",
                    "f35faf19b0cc2160865af64ecf0f22f83d335135"
                )
            );
        let voice_supported = match self.model_id.as_str() {
            "kokoro-82m-4bit" => matches!(
                (self.language.as_str(), self.voice_id.as_str()),
                ("es", "ef_dora") | ("en", "af_heart") | ("pt", "pf_dora")
            ),
            "qwen3-tts-0.6b-customvoice-4bit" | "qwen3-tts-1.7b-customvoice-4bit" => {
                matches!(self.language.as_str(), "es" | "en" | "pt")
                    && self.voice_id.eq_ignore_ascii_case("ryan")
            }
            _ => false,
        };
        if !pair_supported
            || !voice_supported
            || (self.raw_ipa && self.model_id != "kokoro-82m-4bit")
            || self.units.is_empty()
            || self.units.len() > 64
        {
            return Err(TtsError::LanguageUnsupported);
        }
        let mut unit_ids = BTreeSet::new();
        if self.units.iter().any(|unit| {
            unit.unit_id.is_empty()
                || unit.unit_id.len() > 256
                || unit.text.trim().is_empty()
                || unit.text.len() > 524_288
                || !unit_ids.insert(unit.unit_id.as_str())
        }) {
            return Err(TtsError::OutputInvalid);
        }
        Ok(())
    }
}

impl TtsSynthesisResult {
    pub fn validate_against(&self, request: &TtsSynthesisRequest) -> Result<(), TtsError> {
        if self.model_id != request.model_id
            || self.model_revision != request.model_revision
            || self.runtime_id != request.runtime_id
            || self.runtime_version != request.runtime_version
            || self.voice_id != request.voice_id
            || self.language != request.language
            || self.audio_path.is_empty()
        {
            return Err(TtsError::OutputInvalid);
        }
        let omitted: BTreeSet<_> = self.omitted_unit_ids.iter().map(String::as_str).collect();
        if omitted.len() != self.omitted_unit_ids.len() {
            return Err(TtsError::OutputInvalid);
        }
        let mut position = 0;
        for unit in &request.units {
            let start = position;
            let mut offset = 0;
            while let Some(segment) = self.segments.get(position)
                && segment.unit_id == unit.unit_id
            {
                if segment.segment_index != (position - start) as u32
                    || segment.unit_sample_offset != offset
                    || segment.sample_count == 0
                    || !(8_000..=384_000).contains(&segment.sample_rate_hz)
                    || segment.elapsed_ms == 0
                    || segment.model_revision != request.model_revision
                    || segment.voice_id != request.voice_id
                    || segment
                        .artifact_hash
                        .as_deref()
                        .is_some_and(|hash| !valid_sha256(hash))
                {
                    return Err(TtsError::OutputInvalid);
                }
                offset = offset
                    .checked_add(segment.sample_count)
                    .ok_or(TtsError::OutputInvalid)?;
                position += 1;
            }
            let has_segments = position > start;
            if has_segments == omitted.contains(unit.unit_id.as_str()) {
                return Err(TtsError::OutputInvalid);
            }
        }
        if position != self.segments.len()
            || omitted
                .iter()
                .any(|id| !request.units.iter().any(|unit| unit.unit_id == *id))
        {
            return Err(TtsError::OutputInvalid);
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TtsError {
    LanguageUnsupported,
    SynthesisFailed,
    OutputInvalid,
}

impl TtsError {
    pub fn as_lf_error(self) -> LfError {
        let (code, message_key) = match self {
            Self::LanguageUnsupported => {
                ("LF_TTS_LANGUAGE_UNSUPPORTED", "tts.language_unsupported")
            }
            Self::SynthesisFailed => ("LF_TTS_SYNTHESIS_FAILED", "tts.synthesis_failed"),
            Self::OutputInvalid => ("LF_TTS_OUTPUT_INVALID", "tts.output_invalid"),
        };
        LfError {
            code: code.into(),
            message_key: message_key.into(),
            scope: ErrorScope::default(),
            details: Default::default(),
        }
    }
}

/// Las seis direcciones admitidas por NFR8/Story 5.1 entre español, inglés y portugués.
const SUPPORTED_TRANSLATION_DIRECTIONS: [(&str, &str); 6] = [
    ("es", "en"),
    ("es", "pt"),
    ("en", "es"),
    ("en", "pt"),
    ("pt", "es"),
    ("pt", "en"),
];

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct TranslationUnit {
    pub unit_id: String,
    pub text: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct TranslationRequest {
    pub model_id: String,
    pub model_revision: String,
    pub runtime_id: String,
    pub runtime_version: String,
    pub source_language: String,
    pub target_language: String,
    pub units: Vec<TranslationUnit>,
}

/// Una unidad traducida conserva `source_unit_ids` ordenados y no vacíos; admite
/// correspondencia uno-a-varios y varios-a-uno con la fuente (docs/architecture.md#L435).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct TranslatedUnit {
    pub translated_unit_id: String,
    pub source_unit_ids: Vec<String>,
    pub order_key: u32,
    pub translated_text: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct TranslationResult {
    pub model_id: String,
    pub model_revision: String,
    pub runtime_id: String,
    pub runtime_version: String,
    pub source_language: String,
    pub target_language: String,
    pub translated_units: Vec<TranslatedUnit>,
    pub failed_unit_ids: Vec<String>,
}

impl TranslationRequest {
    pub fn validate(&self) -> Result<(), TranslationError> {
        if self.source_language == self.target_language
            || !SUPPORTED_TRANSLATION_DIRECTIONS
                .contains(&(self.source_language.as_str(), self.target_language.as_str()))
            || self.model_id.trim().is_empty()
            || self.model_revision.trim().is_empty()
            || self.runtime_id.trim().is_empty()
            || self.runtime_version.trim().is_empty()
            || self.units.is_empty()
            || self.units.len() > 64
        {
            return Err(TranslationError::DirectionUnsupported);
        }
        let mut unit_ids = BTreeSet::new();
        if self.units.iter().any(|unit| {
            unit.unit_id.is_empty()
                || unit.unit_id.len() > 256
                || unit.text.trim().is_empty()
                || unit.text.len() > 524_288
                || !unit_ids.insert(unit.unit_id.as_str())
        }) {
            return Err(TranslationError::OutputInvalid);
        }
        Ok(())
    }
}

impl TranslationResult {
    /// Cero unidades fuente perdidas o duplicadas: cada `unit_id` de la solicitud aparece
    /// exactamente una vez, como traducida o como fallida, nunca en ambas ni en ninguna.
    pub fn validate_against(&self, request: &TranslationRequest) -> Result<(), TranslationError> {
        if self.model_id != request.model_id
            || self.model_revision != request.model_revision
            || self.runtime_id != request.runtime_id
            || self.runtime_version != request.runtime_version
            || self.source_language != request.source_language
            || self.target_language != request.target_language
        {
            return Err(TranslationError::OutputInvalid);
        }
        let request_ids: BTreeSet<_> = request
            .units
            .iter()
            .map(|unit| unit.unit_id.as_str())
            .collect();
        if request_ids.len() != request.units.len() {
            return Err(TranslationError::OutputInvalid);
        }
        let failed: BTreeSet<_> = self.failed_unit_ids.iter().map(String::as_str).collect();
        if failed.len() != self.failed_unit_ids.len()
            || !failed.iter().all(|id| request_ids.contains(id))
        {
            return Err(TranslationError::MappingInvalid);
        }

        let mut covered = BTreeSet::new();
        let mut previous_order = None;
        for translated in &self.translated_units {
            if translated.translated_unit_id.trim().is_empty()
                || translated.translated_text.trim().is_empty()
                || translated.source_unit_ids.is_empty()
            {
                return Err(TranslationError::OutputInvalid);
            }
            if previous_order.is_some_and(|previous| translated.order_key <= previous) {
                return Err(TranslationError::MappingInvalid);
            }
            previous_order = Some(translated.order_key);

            let mut seen_in_unit = BTreeSet::new();
            for source_id in &translated.source_unit_ids {
                if !request_ids.contains(source_id.as_str())
                    || failed.contains(source_id.as_str())
                    || !seen_in_unit.insert(source_id.as_str())
                    || !covered.insert(source_id.as_str())
                {
                    return Err(TranslationError::MappingInvalid);
                }
            }
        }

        if covered.len() + failed.len() != request_ids.len() {
            return Err(TranslationError::MappingInvalid);
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TranslationError {
    DirectionUnsupported,
    TranslationFailed,
    OutputInvalid,
    MappingInvalid,
}

impl TranslationError {
    pub fn as_lf_error(self) -> LfError {
        let (code, message_key) = match self {
            Self::DirectionUnsupported => (
                "LF_TRANSLATION_PAIR_UNSUPPORTED",
                "translation.pair_unsupported",
            ),
            Self::TranslationFailed => ("LF_TRANSLATION_FAILED", "translation.failed"),
            Self::OutputInvalid => (
                "LF_TRANSLATION_OUTPUT_INVALID",
                "translation.output_invalid",
            ),
            Self::MappingInvalid => (
                "LF_TRANSLATION_MAPPING_INVALID",
                "translation.mapping_invalid",
            ),
        };
        LfError {
            code: code.into(),
            message_key: message_key.into(),
            scope: ErrorScope::default(),
            details: Default::default(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ModelManifestError {
    ManifestMissing,
    ManifestNotRegular,
    ManifestInvalid,
    UnsupportedSchema,
    PackageMissing,
    PackageNotDirectory,
    ArtifactInvalid,
    ArtifactMissing,
    ArtifactNotRegular,
    UnexpectedArtifact,
    SizeMismatch,
    HashMismatch,
    RuntimeMismatch,
    SizeLimit,
}

impl ModelManifestError {
    pub fn as_lf_error(self) -> LfError {
        let (code, message_key) = match self {
            Self::ManifestMissing
            | Self::PackageMissing
            | Self::ArtifactMissing
            | Self::ManifestNotRegular
            | Self::PackageNotDirectory
            | Self::ArtifactNotRegular
            | Self::UnsupportedSchema
            | Self::UnexpectedArtifact
            | Self::ManifestInvalid
            | Self::ArtifactInvalid => ("LF_MODEL_MANIFEST_INVALID", "model.manifest_invalid"),
            Self::SizeMismatch => ("LF_MODEL_SIZE_MISMATCH", "model.size_mismatch"),
            Self::HashMismatch => ("LF_MODEL_HASH_MISMATCH", "model.hash_mismatch"),
            Self::RuntimeMismatch => (
                "LF_MODEL_RUNTIME_INCOMPATIBLE",
                "model.runtime_incompatible",
            ),
            Self::SizeLimit => ("LF_MODEL_SIZE_MISMATCH", "model.size_mismatch"),
        };
        LfError {
            code: code.into(),
            message_key: message_key.into(),
            scope: ErrorScope::default(),
            details: Default::default(),
        }
    }
}

pub fn validate_model_package(
    manifest_path: impl AsRef<Path>,
    package_root: impl AsRef<Path>,
) -> Result<ModelVerificationResult, ModelManifestError> {
    validate_model_package_inner(manifest_path.as_ref(), package_root.as_ref(), None)
}

pub fn validate_model_manifest(
    manifest_path: impl AsRef<Path>,
) -> Result<ModelManifest, ModelManifestError> {
    let manifest_path = manifest_path.as_ref();
    let manifest_metadata = fs::symlink_metadata(manifest_path).map_err(|error| {
        if error.kind() == std::io::ErrorKind::NotFound {
            ModelManifestError::ManifestMissing
        } else {
            ModelManifestError::ManifestInvalid
        }
    })?;
    if !manifest_metadata.file_type().is_file() {
        return Err(ModelManifestError::ManifestNotRegular);
    }
    if manifest_metadata.len() > MAX_MANIFEST_BYTES {
        return Err(ModelManifestError::SizeLimit);
    }
    let manifest: ModelManifest = serde_json::from_slice(
        &fs::read(manifest_path).map_err(|_| ModelManifestError::ManifestInvalid)?,
    )
    .map_err(|_| ModelManifestError::ManifestInvalid)?;
    validate_manifest(&manifest)?;
    Ok(manifest)
}

pub fn validate_model_package_for_runtime(
    manifest_path: impl AsRef<Path>,
    package_root: impl AsRef<Path>,
    runtime_id: &str,
    runtime_version: &str,
) -> Result<ModelVerificationResult, ModelManifestError> {
    validate_model_package_inner(
        manifest_path.as_ref(),
        package_root.as_ref(),
        Some((runtime_id, runtime_version)),
    )
}

fn validate_model_package_inner(
    manifest_path: &Path,
    package_root: &Path,
    runtime: Option<(&str, &str)>,
) -> Result<ModelVerificationResult, ModelManifestError> {
    let manifest = validate_model_manifest(manifest_path)?;
    if runtime.is_some_and(|runtime| {
        runtime.0 != manifest.runtime_id || runtime.1 != manifest.runtime_version
    }) {
        return Err(ModelManifestError::RuntimeMismatch);
    }

    let package_metadata = fs::symlink_metadata(package_root).map_err(|error| {
        if error.kind() == std::io::ErrorKind::NotFound {
            ModelManifestError::PackageMissing
        } else {
            ModelManifestError::PackageNotDirectory
        }
    })?;
    if !package_metadata.file_type().is_dir() {
        return Err(ModelManifestError::PackageNotDirectory);
    }
    let canonical_root = package_root
        .canonicalize()
        .map_err(|_| ModelManifestError::PackageNotDirectory)?;

    let expected: BTreeSet<_> = manifest
        .artifacts
        .iter()
        .map(|artifact| artifact.relative_path.clone())
        .collect();
    let mut observed = BTreeSet::new();
    collect_package_files(package_root, package_root, &mut observed)?;
    if observed.iter().any(|path| !expected.contains(path)) {
        return Err(ModelManifestError::UnexpectedArtifact);
    }

    let mut total_size_bytes = 0_u64;
    for artifact in &manifest.artifacts {
        let path = package_root.join(&artifact.relative_path);
        let metadata = fs::symlink_metadata(&path).map_err(|error| {
            if error.kind() == std::io::ErrorKind::NotFound {
                ModelManifestError::ArtifactMissing
            } else {
                ModelManifestError::ArtifactNotRegular
            }
        })?;
        if !is_safe_data_file(&metadata) {
            return Err(ModelManifestError::ArtifactNotRegular);
        }
        let canonical = path
            .canonicalize()
            .map_err(|_| ModelManifestError::ArtifactNotRegular)?;
        if !canonical.starts_with(&canonical_root) {
            return Err(ModelManifestError::ArtifactNotRegular);
        }
        if metadata.len() != artifact.size_bytes {
            return Err(ModelManifestError::SizeMismatch);
        }
        total_size_bytes = total_size_bytes
            .checked_add(metadata.len())
            .filter(|total| *total <= MAX_MODEL_BYTES)
            .ok_or(ModelManifestError::SizeLimit)?;
        if sha256_file(&canonical)? != artifact.sha256_hex {
            return Err(ModelManifestError::HashMismatch);
        }
    }

    Ok(ModelVerificationResult {
        model_id: manifest.id,
        model_revision: manifest.model_revision,
        artifact_revision: manifest.artifact_revision,
        purpose: manifest.purpose,
        runtime_id: manifest.runtime_id,
        runtime_version: manifest.runtime_version,
        distribution_status: manifest.distribution_status,
        checked_artifacts: manifest.artifacts.len() as u32,
        total_size_bytes,
    })
}

fn validate_manifest(manifest: &ModelManifest) -> Result<(), ModelManifestError> {
    if manifest.schema_version != SCHEMA_VERSION {
        return Err(ModelManifestError::UnsupportedSchema);
    }
    if !valid_id(&manifest.id)
        || !valid_revision(&manifest.model_revision)
        || !valid_revision(&manifest.artifact_revision)
        || !valid_id(&manifest.runtime_id)
        || manifest.runtime_version.trim().is_empty()
        || manifest.license_id.trim().is_empty()
        || !valid_unique_values(&manifest.authors)
        || !valid_unique_values(&manifest.usage_restrictions)
        || !valid_unique_values(&manifest.languages)
        || !valid_voices_for_purpose(&manifest.purpose, &manifest.voices)
        || manifest.artifacts.is_empty()
        || manifest.artifacts.len() > MAX_MODEL_FILES
    {
        return Err(ModelManifestError::ManifestInvalid);
    }
    let mut paths = BTreeSet::new();
    let mut total = 0_u64;
    for artifact in &manifest.artifacts {
        if !valid_artifact(artifact, manifest) || !paths.insert(artifact.relative_path.clone()) {
            return Err(ModelManifestError::ArtifactInvalid);
        }
        total = total
            .checked_add(artifact.size_bytes)
            .filter(|value| *value <= MAX_MODEL_BYTES)
            .ok_or(ModelManifestError::SizeLimit)?;
    }
    Ok(())
}

fn is_safe_data_file(metadata: &fs::Metadata) -> bool {
    if !metadata.file_type().is_file() {
        return false;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        metadata.permissions().mode() & 0o111 == 0
    }
    #[cfg(not(unix))]
    true
}

fn valid_artifact(artifact: &ModelArtifact, manifest: &ModelManifest) -> bool {
    let extension = artifact
        .relative_path
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or_default()
        .to_ascii_lowercase();
    let unsafe_extension = matches!(
        extension.as_str(),
        "zip" | "tar" | "gz" | "tgz" | "7z" | "dylib" | "so" | "dll" | "exe" | "sh" | "py"
    );
    valid_data_path(&artifact.relative_path)
        && !unsafe_extension
        && !artifact.role.trim().is_empty()
        && !artifact.publisher.trim().is_empty()
        && !artifact.format.trim().is_empty()
        && !artifact.quantization.trim().is_empty()
        && artifact.format != "zip"
        && artifact.quantization != "converted"
        && (artifact.role != "model_weights" || artifact.quantization != "not_applicable")
        && artifact.size_bytes > 0
        && valid_sha256(&artifact.sha256_hex)
        && artifact.source_url.starts_with("https://")
        && artifact.source_url.len() <= 2_048
        && !artifact.source_url.contains("/main/")
        && !artifact.source_url.contains("/latest/")
        && (artifact.source_url.contains(&manifest.artifact_revision)
            || artifact.source_url.contains(&manifest.model_revision))
}

fn valid_data_path(path: &Path) -> bool {
    let raw = path.to_string_lossy();
    !path.is_absolute()
        && !raw.contains("//")
        && !raw.ends_with('/')
        && matches!(path.components().next(), Some(Component::Normal(value)) if value == "data")
        && path
            .components()
            .all(|component| matches!(component, Component::Normal(_)))
        && path.components().count() > 1
}

fn valid_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-' | b'.'))
}

fn valid_revision(value: &str) -> bool {
    valid_id(value) && value != "main" && value != "latest"
}

fn valid_voices_for_purpose(purpose: &ModelPurpose, voices: &[String]) -> bool {
    match purpose {
        ModelPurpose::Tts => valid_unique_values(voices),
        ModelPurpose::Translation => voices.is_empty(),
    }
}

fn valid_unique_values(values: &[String]) -> bool {
    !values.is_empty()
        && values.iter().all(|value| !value.trim().is_empty())
        && values.iter().collect::<BTreeSet<_>>().len() == values.len()
}

fn valid_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
}

fn collect_package_files(
    root: &Path,
    directory: &Path,
    files: &mut BTreeSet<PathBuf>,
) -> Result<(), ModelManifestError> {
    for entry in fs::read_dir(directory).map_err(|_| ModelManifestError::PackageNotDirectory)? {
        let entry = entry.map_err(|_| ModelManifestError::PackageNotDirectory)?;
        let path = entry.path();
        let metadata =
            fs::symlink_metadata(&path).map_err(|_| ModelManifestError::ArtifactNotRegular)?;
        if metadata.file_type().is_dir() {
            collect_package_files(root, &path, files)?;
        } else if metadata.file_type().is_file() {
            files.insert(
                path.strip_prefix(root)
                    .map_err(|_| ModelManifestError::ArtifactNotRegular)?
                    .to_path_buf(),
            );
        } else {
            return Err(ModelManifestError::ArtifactNotRegular);
        }
    }
    Ok(())
}

fn sha256_file(path: &Path) -> Result<String, ModelManifestError> {
    crate::hash::fingerprint_file(path).map_err(|_| ModelManifestError::ArtifactMissing)
}
