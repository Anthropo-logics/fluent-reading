use serde::{Deserialize, Serialize};

use crate::{SCHEMA_VERSION, ValidationRun};

const MAX_REPETITIONS: u32 = 10_000;
const MAX_DURATION_MS: u64 = 7_200_000;

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum GateAScenario {
    IntegratedChain,
    BoundaryCycle,
    AnchorRoundTrip,
    PauseResume,
    SustainedSession,
    OfflinePrivacy,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum GateACondition {
    Cold,
    Hot,
    Stress,
    Sustained,
    Offline,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct GateARevisionSet {
    pub app: String,
    pub corpus: String,
    pub runtime: String,
    pub model: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct GateARunRequest {
    pub scenario: GateAScenario,
    pub condition: GateACondition,
    pub corpus_id: String,
    pub revisions: GateARevisionSet,
    pub expected_repetitions: u32,
    pub expected_duration_ms: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct GateAProgress {
    pub completed: u32,
    pub total: u32,
    pub monotonic_elapsed_ms: u64,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum GateAMetricName {
    OpenToFirstFrame,
    OpenToFirstUnit,
    PauseResume,
    RealTimeFactor,
    PhysFootprint,
    Rss,
    Swap,
    TransportAck,
    BoundaryCycle,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum GateAMetricUnit {
    Milliseconds,
    Bytes,
    Ratio,
    Count,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct GateAMetric {
    pub name: GateAMetricName,
    pub unit: GateAMetricUnit,
    pub repetition: u32,
    pub monotonic_elapsed_ms: u64,
    pub numerator: u64,
    pub denominator: u64,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum GateAThermalState {
    Nominal,
    Fair,
    Serious,
    Critical,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ResourceSample {
    pub monotonic_elapsed_ms: u64,
    pub phys_footprint_bytes: u64,
    pub rss_bytes: u64,
    pub swap_bytes: u64,
    pub boundary_elapsed_ms: u64,
    pub thermal_state: GateAThermalState,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct GateAResult {
    pub request: GateARunRequest,
    pub validation_run: ValidationRun,
    pub metrics: Vec<GateAMetric>,
    pub resources: Vec<ResourceSample>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GateAValidationError {
    InvalidIdentifier,
    InvalidLimit,
    InvalidProgress,
    InvalidMetric,
    InvalidResource,
    NonMonotonic,
    InconsistentRun,
}

impl GateARunRequest {
    pub fn validate(&self) -> Result<(), GateAValidationError> {
        if !safe_identifier(&self.corpus_id)
            || [
                &self.revisions.app,
                &self.revisions.corpus,
                &self.revisions.runtime,
                &self.revisions.model,
            ]
            .into_iter()
            .any(|value| !safe_identifier(value))
        {
            return Err(GateAValidationError::InvalidIdentifier);
        }
        if !(1..=MAX_REPETITIONS).contains(&self.expected_repetitions)
            || !(1..=MAX_DURATION_MS).contains(&self.expected_duration_ms)
        {
            return Err(GateAValidationError::InvalidLimit);
        }
        Ok(())
    }
}

impl GateAProgress {
    pub fn validate(&self) -> Result<(), GateAValidationError> {
        if self.total == 0 || self.completed > self.total {
            return Err(GateAValidationError::InvalidProgress);
        }
        Ok(())
    }
}

impl GateAResult {
    pub fn validate(&self) -> Result<(), GateAValidationError> {
        self.request.validate()?;
        if self.validation_run.schema_version != SCHEMA_VERSION
            || self.validation_run.corpus_id != self.request.corpus_id
            || self.validation_run.environment.app_revision != self.request.revisions.app
            || self.validation_run.duration_ms > self.request.expected_duration_ms
        {
            return Err(GateAValidationError::InconsistentRun);
        }

        let mut previous = 0;
        for metric in &self.metrics {
            let unit_matches = matches!(
                (metric.name, metric.unit),
                (
                    GateAMetricName::OpenToFirstFrame
                        | GateAMetricName::OpenToFirstUnit
                        | GateAMetricName::PauseResume
                        | GateAMetricName::TransportAck,
                    GateAMetricUnit::Milliseconds
                ) | (GateAMetricName::RealTimeFactor, GateAMetricUnit::Ratio)
                    | (
                        GateAMetricName::PhysFootprint
                            | GateAMetricName::Rss
                            | GateAMetricName::Swap,
                        GateAMetricUnit::Bytes
                    )
                    | (GateAMetricName::BoundaryCycle, GateAMetricUnit::Count)
            );
            if !unit_matches
                || metric.repetition == 0
                || metric.repetition > self.request.expected_repetitions
                || metric.denominator == 0
                || metric.monotonic_elapsed_ms > self.request.expected_duration_ms
            {
                return Err(GateAValidationError::InvalidMetric);
            }
            if metric.monotonic_elapsed_ms < previous {
                return Err(GateAValidationError::NonMonotonic);
            }
            previous = metric.monotonic_elapsed_ms;
        }

        previous = 0;
        for sample in &self.resources {
            if (sample.phys_footprint_bytes == 0 && sample.rss_bytes == 0)
                || sample.boundary_elapsed_ms == 0
                || sample.monotonic_elapsed_ms > self.request.expected_duration_ms
            {
                return Err(GateAValidationError::InvalidResource);
            }
            if sample.monotonic_elapsed_ms < previous {
                return Err(GateAValidationError::NonMonotonic);
            }
            previous = sample.monotonic_elapsed_ms;
        }
        Ok(())
    }
}

fn safe_identifier(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-' | b'.'))
}
