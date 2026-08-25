use std::collections::BTreeMap;
use std::env;
use std::ffi::OsStr;
use std::fs;
use std::io::{Read, Write};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use lectura_core::{
    DistributionStatus, DocumentProcessingResult, EventEnvelope, EventResult, ExtractedBlock,
    GateAMetric, GateAMetricName, GateAMetricUnit, GateAResult, GateARunRequest, GateAThermalState,
    PageExtraction, PageMetric, ProcessingRoute, RequestedUnit, ResourceSample, SpokenPart,
    TranslationRequest, TranslationResult, TtsSynthesisRequest, TtsSynthesisResult, TtsUnit,
    ValidationArtifacts, ValidationEnvironment, ValidationRun, ValidationRunStatus,
    character_error_rate, espeak_stdin, fingerprint_file, measure_digital_block_order,
    normalize_digital_document, select_processing_route, sha256_hex, spoken_plan,
    validate_model_manifest, validate_model_package, validate_model_package_for_runtime,
};
use serde_json::{Value, json};

fn main() -> ExitCode {
    let arguments: Vec<_> = env::args_os().skip(1).collect();
    if arguments.len() == 2
        && arguments[0] == OsStr::new("canary")
        && arguments[1] == OsStr::new("--json")
    {
        return canary();
    }
    if arguments.len() == 7
        && arguments[0] == OsStr::new("session")
        && arguments[1] == OsStr::new("plan")
        && arguments[2] == OsStr::new("--pages")
        && arguments[4] == OsStr::new("--visible")
        && arguments[6] == OsStr::new("--json")
    {
        return plan_session(&arguments[3], &arguments[5]);
    }
    if arguments.len() == 5
        && arguments[0] == OsStr::new("spoken")
        && arguments[1] == OsStr::new("plan")
        && arguments[2] == OsStr::new("--language")
        && arguments[4] == OsStr::new("--json")
    {
        return plan_spoken_text(&arguments[3]);
    }
    if arguments.len() == 7
        && arguments[0] == OsStr::new("gate-a")
        && arguments[1] == OsStr::new("run")
        && arguments[2] == OsStr::new("--manifest")
        && arguments[4] == OsStr::new("--output")
        && arguments[6] == OsStr::new("--json")
    {
        return gate_a_run(&arguments[3], &arguments[5]);
    }
    if arguments.len() == 5
        && arguments[0] == OsStr::new("corpus")
        && arguments[1] == OsStr::new("validate")
        && arguments[2] == OsStr::new("--manifest")
        && arguments[4] == OsStr::new("--json")
    {
        return validate_corpus(&arguments[3]);
    }
    if arguments.len() == 7
        && arguments[0] == OsStr::new("model")
        && arguments[1] == OsStr::new("verify")
        && arguments[2] == OsStr::new("--manifest")
        && arguments[4] == OsStr::new("--package")
        && arguments[6] == OsStr::new("--json")
    {
        return verify_model(&arguments[3], &arguments[5]);
    }
    if arguments.len() == 5
        && arguments[0] == OsStr::new("tts")
        && arguments[1] == OsStr::new("synthesize")
        && arguments[2] == OsStr::new("--request")
        && arguments[4] == OsStr::new("--json")
    {
        return synthesize_tts(&arguments[3]);
    }
    if arguments.len() == 4
        && arguments[0] == OsStr::new("translate")
        && arguments[1] == OsStr::new("--request")
        && arguments[3] == OsStr::new("--json")
    {
        return translate(&arguments[2]);
    }
    if matches!(arguments.len(), 9 | 11 | 13)
        && arguments[0] == OsStr::new("pdf")
        && arguments[1] == OsStr::new("process")
        && arguments[2] == OsStr::new("--input")
        && arguments[4] == OsStr::new("--language")
        && arguments[6] == OsStr::new("--unit")
        && arguments[8] == OsStr::new("--json")
    {
        let force_page = option_u32(&arguments[9..], "--force-ocr-page");
        let page_limit = option_u32(&arguments[9..], "--page-limit");
        if arguments[9..].chunks_exact(2).any(|pair| {
            !matches!(pair[0].to_str(), Some("--force-ocr-page" | "--page-limit"))
                || pair[1]
                    .to_str()
                    .and_then(|value| value.parse::<u32>().ok())
                    .is_none()
        }) || page_limit == Some(0)
        {
            return process_failure("LF_PAGE_INDEX_INVALID", 64);
        }
        return process_pdf(
            &arguments[3],
            &arguments[5],
            &arguments[7],
            force_page,
            page_limit,
        );
    }
    eprintln!(
        "usage: lectura canary --json | lectura session plan --pages <count> --visible <index> --json | lectura spoken plan --language <es|en|pt> --json | lectura corpus validate --manifest <file> --json | lectura model verify --manifest <file> --package <dir> --json | lectura pdf process --input <pdf> --language <tag> --unit <paragraph|sentence> --json [--force-ocr-page <index>] [--page-limit <count>] | lectura tts synthesize --request <file|-> --json | lectura translate --request <file|-> --json | lectura gate-a run --manifest <file> --output <dir> --json"
    );
    ExitCode::from(2)
}

const MAX_GATE_A_MANIFEST_BYTES: u64 = 1_048_576;

#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct GateAManifest {
    schema_version: u32,
    request: GateARunRequest,
    document: GateADocument,
    tts: GateATts,
}

#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct GateADocument {
    input: PathBuf,
    language: String,
    unit: RequestedUnit,
    #[serde(default)]
    force_ocr_page: Option<u32>,
    /// Measurement-only ceiling; only narration stops after this many ordered units.
    #[serde(default)]
    narration_unit_limit: Option<u32>,
    /// Measurement-only ceiling for time-to-first-content runs.
    #[serde(default)]
    page_limit: Option<u32>,
}

#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct GateATts {
    model_id: String,
    model_revision: String,
    runtime_id: String,
    runtime_version: String,
    voice_id: String,
}

fn gate_a_run(manifest: &OsStr, output: &OsStr) -> ExitCode {
    let manifest = Path::new(manifest);
    let bytes = match fs::metadata(manifest) {
        Ok(metadata) if metadata.is_file() && metadata.len() <= MAX_GATE_A_MANIFEST_BYTES => {
            match fs::read(manifest) {
                Ok(bytes) => bytes,
                Err(_) => return gate_a_failure("LF_FILE_NOT_FOUND", 66),
            }
        }
        Ok(_) => return gate_a_failure("LF_CONTRACT_PAYLOAD_INVALID", 65),
        Err(_) => return gate_a_failure("LF_FILE_NOT_FOUND", 66),
    };
    let manifest: GateAManifest = match serde_json::from_slice(&bytes) {
        Ok(manifest) => manifest,
        Err(_) => return gate_a_failure("LF_CONTRACT_PAYLOAD_INVALID", 65),
    };
    if manifest.schema_version != lectura_core::SCHEMA_VERSION
        || manifest.request.validate().is_err()
        || manifest
            .document
            .narration_unit_limit
            .is_some_and(|limit| limit == 0)
        || manifest.document.page_limit == Some(0)
        || !matches!(manifest.document.language.as_str(), "es" | "en" | "pt")
        || manifest.tts.model_id != "kokoro-82m-4bit"
        || manifest.tts.model_revision != "e4468a460f6f70b9125a003e0adb1ab7d4904bbd"
        || manifest.request.revisions.runtime
            != format!(
                "{}-{}",
                manifest.tts.runtime_id, manifest.tts.runtime_version
            )
        || manifest.request.revisions.model
            != manifest
                .tts
                .model_revision
                .get(..8)
                .map(|revision| format!("{}-{revision}", manifest.tts.model_id))
                .unwrap_or_default()
    {
        return gate_a_failure("LF_CONTRACT_PAYLOAD_INVALID", 65);
    }
    TTS_CANCELLED.store(false, Ordering::Relaxed);
    // SAFETY: the handler only performs an atomic store, which is signal-safe.
    let previous = unsafe {
        libc::signal(
            libc::SIGINT,
            handle_tts_sigint as *const () as libc::sighandler_t,
        )
    };
    let _signal_guard = SignalGuard(previous);
    match execute_gate_a(&manifest, Path::new(output)) {
        Ok(result) => write_event(
            EventEnvelope {
                schema_version: lectura_core::SCHEMA_VERSION,
                request_id: "req_cli_gate_a_run".into(),
                job_id: "job_cli_gate_a_run".into(),
                sequence: 0,
                kind: "completed".into(),
                progress: None,
                result: Some(EventResult::GateACompleted(Box::new(result))),
                error: None,
                recovery: None,
            },
            ExitCode::SUCCESS,
        ),
        Err(code) if code == "LF_CANCELLED" => {
            match write_incomplete_gate_a_artifacts(Path::new(output), &manifest.request, &code) {
                Ok(()) => gate_a_cancelled(),
                Err(code) => gate_a_failure(&code, 70),
            }
        }
        Err(code) => gate_a_failure(&code, if code == "LF_FILE_NOT_FOUND" { 66 } else { 70 }),
    }
}

fn execute_gate_a(manifest: &GateAManifest, output: &Path) -> Result<GateAResult, String> {
    let started = Instant::now();
    let fingerprint =
        fingerprint_file(&manifest.document.input).map_err(|_| "LF_FILE_NOT_FOUND".to_owned())?;
    let document_id = format!("doc_{}", &fingerprint[..16]);
    let mut page_metrics = Vec::new();
    let mut metrics = Vec::new();
    let mut resources = Vec::new();

    for repetition in 1..=manifest.request.expected_repetitions {
        let opened = Instant::now();
        let document = run_pdf_service(&manifest.document)?;
        let open_elapsed_ms = elapsed_ms(opened);
        let unit_limit = manifest
            .document
            .narration_unit_limit
            .map_or(usize::MAX, |limit| limit as usize);
        let units: Vec<_> = document
            .pages
            .iter()
            .flat_map(|page| page.units.iter())
            .take(unit_limit)
            .map(|unit| {
                let plan = spoken_plan(&unit.spoken_text, &manifest.document.language)
                    .map_err(|_| "LF_TTS_LANGUAGE_UNSUPPORTED".to_owned())?;
                let text = phonemize_plan(&plan.parts, &plan.frontend_voice)?;
                Ok(TtsUnit {
                    unit_id: unit.unit_id.clone(),
                    text,
                })
            })
            .collect::<Result<_, String>>()?;
        if units.is_empty() {
            return Err("LF_PDF_EXTRACTION_FAILED".into());
        }
        let first_unit_ms = elapsed_ms(opened);
        let synthesis_started = Instant::now();
        let mut audio_ms = 0_u64;
        for batch in units.chunks(64) {
            if TTS_CANCELLED.load(Ordering::Relaxed) {
                return Err("LF_CANCELLED".into());
            }
            let synthesis =
                run_tts_service(&manifest.tts, &manifest.document.language, batch.to_vec())?;
            audio_ms = audio_ms.saturating_add(
                synthesis
                    .segments
                    .iter()
                    .map(|segment| {
                        segment.sample_count.saturating_mul(1_000)
                            / u64::from(segment.sample_rate_hz)
                    })
                    .sum::<u64>(),
            );
            discard_gate_a_audio(&synthesis.audio_path);
        }
        let synthesis_elapsed_ms = elapsed_ms(synthesis_started);
        let elapsed = elapsed_ms(started);
        metrics.extend([
            gate_metric(
                GateAMetricName::OpenToFirstFrame,
                GateAMetricUnit::Milliseconds,
                repetition,
                elapsed,
                open_elapsed_ms,
                1,
            ),
            gate_metric(
                GateAMetricName::OpenToFirstUnit,
                GateAMetricUnit::Milliseconds,
                repetition,
                elapsed,
                first_unit_ms,
                1,
            ),
            gate_metric(
                GateAMetricName::TransportAck,
                GateAMetricUnit::Milliseconds,
                repetition,
                elapsed,
                synthesis_elapsed_ms,
                1,
            ),
            gate_metric(
                GateAMetricName::RealTimeFactor,
                GateAMetricUnit::Ratio,
                repetition,
                elapsed,
                synthesis_elapsed_ms,
                audio_ms.max(1),
            ),
        ]);
        let rss_bytes = current_rss_bytes().max(1);
        resources.push(ResourceSample {
            monotonic_elapsed_ms: elapsed,
            phys_footprint_bytes: rss_bytes,
            rss_bytes,
            swap_bytes: 0,
            boundary_elapsed_ms: synthesis_elapsed_ms.max(1),
            thermal_state: GateAThermalState::Nominal,
        });
        page_metrics.extend(page_metrics_for(&document));
    }

    let duration_ms = elapsed_ms(started);
    if duration_ms > manifest.request.expected_duration_ms {
        return Err("LF_GATE_A_DURATION_EXCEEDED".into());
    }
    let confidence_values: Vec<_> = page_metrics.iter().map(|metric| metric.value).collect();
    let confidence = if confidence_values.is_empty() {
        1.0
    } else {
        confidence_values.iter().sum::<f64>() / confidence_values.len() as f64
    };
    let run_id = format!(
        "gate_a_{}",
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|_| "LF_INTERNAL_INVARIANT".to_owned())?
            .as_nanos()
    );
    let request = manifest.request.clone();
    let app_revision = request.revisions.app.clone();
    let processor_revision = request.revisions.runtime.clone();
    let corpus_id = request.corpus_id.clone();
    let mut result = GateAResult {
        request,
        validation_run: ValidationRun {
            schema_version: lectura_core::SCHEMA_VERSION,
            validation_run_id: run_id,
            corpus_id,
            corpus_hashes: BTreeMap::from([(document_id, fingerprint)]),
            environment: ValidationEnvironment {
                hardware: env::consts::ARCH.into(),
                operating_system: env::consts::OS.into(),
                rust: lectura_core::CORE_VERSION.into(),
                app_revision,
                processor_revision,
            },
            processing_route: "macos_worker_rust_cli".into(),
            confidence,
            duration_ms,
            errors: vec![],
            page_metrics,
            status: ValidationRunStatus::Complete,
            artifacts: ValidationArtifacts {
                environment_sha256: String::new(),
                metrics_sha256: String::new(),
                summary_sha256: String::new(),
            },
        },
        metrics,
        resources,
    };
    write_gate_a_artifacts(output, &mut result)?;
    result
        .validate()
        .map_err(|_| "LF_INTERNAL_INVARIANT".to_owned())?;
    Ok(result)
}

fn write_incomplete_gate_a_artifacts(
    output: &Path,
    request: &GateARunRequest,
    error: &str,
) -> Result<(), String> {
    let mut result = GateAResult {
        request: request.clone(),
        validation_run: ValidationRun {
            schema_version: lectura_core::SCHEMA_VERSION,
            validation_run_id: format!("gate_a_incomplete_{}", std::process::id()),
            corpus_id: request.corpus_id.clone(),
            corpus_hashes: BTreeMap::new(),
            environment: ValidationEnvironment {
                hardware: env::consts::ARCH.into(),
                operating_system: env::consts::OS.into(),
                rust: lectura_core::CORE_VERSION.into(),
                app_revision: request.revisions.app.clone(),
                processor_revision: request.revisions.runtime.clone(),
            },
            processing_route: "not_completed".into(),
            confidence: 0.0,
            duration_ms: 0,
            errors: vec![error.into()],
            page_metrics: vec![],
            status: ValidationRunStatus::Incomplete,
            artifacts: ValidationArtifacts {
                environment_sha256: String::new(),
                metrics_sha256: String::new(),
                summary_sha256: String::new(),
            },
        },
        metrics: vec![],
        resources: vec![],
    };
    write_gate_a_artifacts(output, &mut result)
}

fn run_pdf_service(document: &GateADocument) -> Result<DocumentProcessingResult, String> {
    let executable = env::current_exe().map_err(|_| "LF_INTERNAL_INVARIANT".to_owned())?;
    let unit = match document.unit {
        RequestedUnit::Paragraph => "paragraph",
        RequestedUnit::Sentence => "sentence",
    };
    let mut arguments = vec![
        "pdf".into(),
        "process".into(),
        "--input".into(),
        document.input.as_os_str().into(),
        "--language".into(),
        document.language.clone().into(),
        "--unit".into(),
        unit.into(),
        "--json".into(),
    ];
    if let Some(page) = document.force_ocr_page {
        arguments.push("--force-ocr-page".into());
        arguments.push(page.to_string().into());
    }
    if let Some(limit) = document.page_limit {
        arguments.push("--page-limit".into());
        arguments.push(limit.to_string().into());
    }
    let event = run_service(&executable, arguments)?;
    serde_json::from_value(event["result"].clone())
        .map_err(|_| "LF_WORKER_PROTOCOL_INVALID".to_owned())
}

fn run_tts_service(
    tts: &GateATts,
    language: &str,
    units: Vec<TtsUnit>,
) -> Result<TtsSynthesisResult, String> {
    let executable = env::current_exe().map_err(|_| "LF_INTERNAL_INVARIANT".to_owned())?;
    let request = TtsSynthesisRequest {
        model_id: tts.model_id.clone(),
        model_revision: tts.model_revision.clone(),
        runtime_id: tts.runtime_id.clone(),
        runtime_version: tts.runtime_version.clone(),
        voice_id: tts.voice_id.clone(),
        language: language.into(),
        raw_ipa: true,
        units,
    };
    request
        .validate()
        .map_err(|error| error.as_lf_error().code)?;
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| "LF_INTERNAL_INVARIANT".to_owned())?
        .as_nanos();
    let request_path = env::temp_dir().join(format!(
        "lectura-gate-a-request-{}-{nonce}.json",
        std::process::id()
    ));
    fs::write(
        &request_path,
        serde_json::to_vec(&request).map_err(|_| "LF_INTERNAL_INVARIANT")?,
    )
    .map_err(|_| "LF_FILE_IO_FAILED".to_owned())?;
    let event = run_service(
        &executable,
        vec![
            "tts".into(),
            "synthesize".into(),
            "--request".into(),
            request_path.as_os_str().into(),
            "--json".into(),
        ],
    );
    let _ = fs::remove_file(request_path);
    let event = event?;
    serde_json::from_value(event["result"].clone())
        .map_err(|_| "LF_WORKER_PROTOCOL_INVALID".to_owned())
}

fn run_service(executable: &Path, arguments: Vec<std::ffi::OsString>) -> Result<Value, String> {
    let mut command = Command::new(executable);
    command
        .args(arguments)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    // SAFETY: the child creates its own process group before executing the same local CLI,
    // so cancellation can terminate its worker descendants without touching the caller group.
    unsafe {
        command.pre_exec(|| {
            if libc::setpgid(0, 0) == 0 {
                Ok(())
            } else {
                Err(std::io::Error::last_os_error())
            }
        });
    }
    let mut child = command
        .spawn()
        .map_err(|_| "LF_WORKER_START_FAILED".to_owned())?;
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| "LF_WORKER_PROTOCOL_INVALID".to_owned())?;
    let reader = std::thread::spawn(move || {
        let mut bytes = Vec::new();
        let _ = std::io::BufReader::new(stdout).read_to_end(&mut bytes);
        bytes
    });
    let status = loop {
        if TTS_CANCELLED.load(Ordering::Relaxed) {
            terminate_service_group(child.id());
            let _ = child.wait();
            let _ = reader.join();
            return Err("LF_CANCELLED".into());
        }
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) => std::thread::sleep(Duration::from_millis(10)),
            Err(_) => {
                terminate_service_group(child.id());
                let _ = child.wait();
                let _ = reader.join();
                return Err("LF_WORKER_IO_FAILED".into());
            }
        }
    };
    let stdout = reader
        .join()
        .map_err(|_| "LF_WORKER_PROTOCOL_INVALID".to_owned())?;
    let event: Value =
        serde_json::from_slice(&stdout).map_err(|_| "LF_WORKER_PROTOCOL_INVALID".to_owned())?;
    if event["kind"] == "cancelled" || TTS_CANCELLED.load(Ordering::Relaxed) {
        return Err("LF_CANCELLED".into());
    }
    if !status.success() || event["kind"] != "completed" {
        return Err(event["error"]["code"]
            .as_str()
            .filter(|code| code.starts_with("LF_"))
            .unwrap_or("LF_WORKER_PROTOCOL_INVALID")
            .to_owned());
    }
    Ok(event)
}

fn terminate_service_group(pid: u32) {
    let pid = i32::try_from(pid).unwrap_or_default();
    if pid > 0 {
        // SAFETY: negative pid targets only the isolated process group created in `run_service`.
        unsafe { libc::kill(-pid, libc::SIGKILL) };
    }
}

fn phonemize_plan(parts: &[SpokenPart], voice: &str) -> Result<String, String> {
    let executable = env::var_os("LECTURA_ESPEAK")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/opt/homebrew/bin/espeak-ng"));
    let mut phonemes = Vec::with_capacity(parts.len());
    for part in parts {
        match part {
            SpokenPart::Punctuation(value) => phonemes.push(value.clone()),
            SpokenPart::Text(value) => {
                let mut child = Command::new(&executable)
                    .args(["-q", "--ipa=3", "-v", voice, "--stdin"])
                    .stdin(Stdio::piped())
                    .stdout(Stdio::piped())
                    .stderr(Stdio::null())
                    .spawn()
                    .map_err(|_| "LF_TTS_SYNTHESIS_FAILED".to_owned())?;
                if let Some(mut stdin) = child.stdin.take() {
                    stdin
                        .write_all(espeak_stdin(value).as_bytes())
                        .map_err(|_| "LF_TTS_SYNTHESIS_FAILED".to_owned())?;
                }
                let output = child
                    .wait_with_output()
                    .map_err(|_| "LF_TTS_SYNTHESIS_FAILED".to_owned())?;
                if !output.status.success() {
                    return Err("LF_TTS_SYNTHESIS_FAILED".into());
                }
                let value = String::from_utf8(output.stdout)
                    .map_err(|_| "LF_TTS_SYNTHESIS_FAILED".to_owned())?;
                phonemes.push(value.trim().into());
            }
        }
    }
    Ok(phonemes
        .join(" ")
        .replace(" ,", ",")
        .replace(" .", ".")
        .replace(" ;", ";")
        .replace(" :", ":")
        .replace(" !", "!")
        .replace(" ?", "?")
        .replace(" —", "—"))
}

fn gate_metric(
    name: GateAMetricName,
    unit: GateAMetricUnit,
    repetition: u32,
    monotonic_elapsed_ms: u64,
    numerator: u64,
    denominator: u64,
) -> GateAMetric {
    GateAMetric {
        name,
        unit,
        repetition,
        monotonic_elapsed_ms,
        numerator,
        denominator,
    }
}

fn page_metrics_for(document: &DocumentProcessingResult) -> Vec<PageMetric> {
    let mut metrics = Vec::new();
    if let Some(metric) = &document.nfr6 {
        metrics.push(PageMetric {
            document_id: document.document_id.clone(),
            page_index: 0,
            metric: "block_order".into(),
            numerator: u64::from(metric.numerator),
            denominator: u64::from(metric.denominator),
            value: metric.ratio,
        });
    }
    if let Some(metric) = &document.cer {
        metrics.push(PageMetric {
            document_id: document.document_id.clone(),
            page_index: 0,
            metric: "character_error_rate".into(),
            numerator: u64::from(metric.distance),
            denominator: u64::from(metric.reference_characters.max(1)),
            value: metric.ratio,
        });
    }
    metrics
}

fn current_rss_bytes() -> u64 {
    Command::new("ps")
        .args(["-o", "rss=", "-p", &std::process::id().to_string()])
        .output()
        .ok()
        .and_then(|output| String::from_utf8(output.stdout).ok())
        .and_then(|value| value.trim().parse::<u64>().ok())
        .map(|kilobytes| kilobytes.saturating_mul(1024))
        .unwrap_or(0)
}

fn discard_gate_a_audio(audio_path: &str) {
    let Some(parent) = Path::new(audio_path).parent() else {
        return;
    };
    let Some(name) = parent.file_name().and_then(OsStr::to_str) else {
        return;
    };
    if name.starts_with("lectura-tts-cli-") {
        let _ = fs::remove_dir_all(parent);
    }
}

fn write_gate_a_artifacts(output: &Path, result: &mut GateAResult) -> Result<(), String> {
    fs::create_dir_all(output).map_err(|_| "LF_FILE_IO_FAILED".to_owned())?;
    let environment = serde_json::to_vec_pretty(&result.validation_run.environment)
        .map_err(|_| "LF_INTERNAL_INVARIANT".to_owned())?;
    let metrics = serde_json::to_vec(&json!({
        "page_metrics": result.validation_run.page_metrics,
        "metrics": result.metrics,
        "resources": result.resources,
    }))
    .map_err(|_| "LF_INTERNAL_INVARIANT".to_owned())?;
    let metrics = [metrics, vec![b'\n']].concat();
    result.validation_run.artifacts.environment_sha256 = sha256_hex(&environment);
    result.validation_run.artifacts.metrics_sha256 = sha256_hex(&metrics);
    // The summary hashes its canonical pretty representation with this field zeroed.
    // This avoids a self-referential hash while allowing byte-for-byte verification.
    result.validation_run.artifacts.summary_sha256 = "0".repeat(64);
    let summary_basis =
        serde_json::to_vec_pretty(result).map_err(|_| "LF_INTERNAL_INVARIANT".to_owned())?;
    result.validation_run.artifacts.summary_sha256 = sha256_hex(&summary_basis);
    let summary =
        serde_json::to_vec_pretty(result).map_err(|_| "LF_INTERNAL_INVARIANT".to_owned())?;
    atomic_write(&output.join("environment.json"), &environment)?;
    atomic_write(&output.join("metrics.jsonl"), &metrics)?;
    atomic_write(&output.join("summary.json"), &summary)?;
    Ok(())
}

fn atomic_write(path: &Path, bytes: &[u8]) -> Result<(), String> {
    let temporary = path.with_extension(format!("tmp-{}", std::process::id()));
    fs::write(&temporary, bytes).map_err(|_| "LF_FILE_IO_FAILED".to_owned())?;
    fs::rename(&temporary, path).map_err(|_| "LF_FILE_IO_FAILED".to_owned())
}

fn elapsed_ms(started: Instant) -> u64 {
    u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX)
}

/// Sobre de evento terminal de un subcomando: los identificadores siguen la convención
/// `req_cli_<comando>`/`job_cli_<comando>` ya establecida por el resto del CLI.
fn cli_event(command: &str, kind: &str, error: Option<lectura_core::LfError>) -> EventEnvelope {
    EventEnvelope {
        schema_version: lectura_core::SCHEMA_VERSION,
        request_id: format!("req_cli_{command}"),
        job_id: format!("job_cli_{command}"),
        sequence: 0,
        kind: kind.into(),
        progress: None,
        result: None,
        error,
        recovery: None,
    }
}

fn gate_a_failure(code: &str, exit: u8) -> ExitCode {
    let mut error = lectura_core::RequestError::InvalidPayload.as_lf_error();
    error.code = code.into();
    error.message_key = "gate_a.run_failed".into();
    write_event(
        cli_event("gate_a_run", "failed", Some(error)),
        ExitCode::from(exit),
    )
}

fn gate_a_cancelled() -> ExitCode {
    write_event(
        cli_event("gate_a_run", "cancelled", None),
        ExitCode::from(130),
    )
}

const MAX_SPOKEN_TEXT_BYTES: u64 = 512 * 1024;

fn plan_spoken_text(language: &OsStr) -> ExitCode {
    let Some(language) = language.to_str() else {
        return spoken_failure("LF_TTS_LANGUAGE_UNSUPPORTED");
    };
    let mut bytes = Vec::new();
    if std::io::stdin()
        .take(MAX_SPOKEN_TEXT_BYTES + 1)
        .read_to_end(&mut bytes)
        .is_err()
        || bytes.len() as u64 > MAX_SPOKEN_TEXT_BYTES
    {
        return spoken_failure("LF_CONTRACT_PAYLOAD_INVALID");
    }
    let Ok(text) = std::str::from_utf8(&bytes) else {
        return spoken_failure("LF_CONTRACT_PAYLOAD_INVALID");
    };
    let Ok(plan) = spoken_plan(text, language) else {
        return spoken_failure("LF_TTS_LANGUAGE_UNSUPPORTED");
    };
    match serde_json::to_writer(std::io::stdout(), &plan) {
        Ok(()) => {
            println!();
            ExitCode::SUCCESS
        }
        Err(_) => ExitCode::from(74),
    }
}

fn spoken_failure(code: &str) -> ExitCode {
    println!("{}", json!({"error": {"code": code}}));
    ExitCode::from(65)
}

const MAX_TTS_REQUEST_BYTES: u64 = 34 * 1024 * 1024;
static TTS_CANCELLED: AtomicBool = AtomicBool::new(false);

extern "C" fn handle_tts_sigint(_: libc::c_int) {
    TTS_CANCELLED.store(true, Ordering::Relaxed);
}

struct SignalGuard(libc::sighandler_t);

impl Drop for SignalGuard {
    fn drop(&mut self) {
        // SAFETY: restores the process handler returned by `signal` for SIGINT.
        unsafe { libc::signal(libc::SIGINT, self.0) };
    }
}

struct OwnedWorkRoot {
    path: PathBuf,
    keep: bool,
}

impl Drop for OwnedWorkRoot {
    fn drop(&mut self) {
        if !self.keep {
            let _ = fs::remove_dir_all(&self.path);
        }
    }
}

fn synthesize_tts(request_path: &OsStr) -> ExitCode {
    let request_bytes = match read_tts_request(request_path) {
        Ok(bytes) => bytes,
        Err(code) => return tts_failure(code, 66),
    };
    let request: TtsSynthesisRequest = match serde_json::from_slice(&request_bytes) {
        Ok(request) => request,
        Err(_) => return tts_failure("LF_CONTRACT_PAYLOAD_INVALID", 65),
    };
    if let Err(error) = request.validate() {
        return tts_failure(error.as_lf_error().code.as_str(), 65);
    }
    if let Err(code) = verify_tts_installation(&request) {
        return tts_failure(&code, 65);
    }
    match synthesize_with_worker(&request) {
        Ok(result) => write_event(
            EventEnvelope {
                schema_version: lectura_core::SCHEMA_VERSION,
                request_id: "req_cli_tts_synthesize".into(),
                job_id: "job_cli_tts_synthesize".into(),
                sequence: 0,
                kind: "completed".into(),
                progress: None,
                result: Some(EventResult::TtsSynthesized(result)),
                error: None,
                recovery: None,
            },
            ExitCode::SUCCESS,
        ),
        Err(code) if code == "LF_CANCELLED" => tts_cancelled(),
        Err(code) => tts_failure(&code, 70),
    }
}

fn verify_tts_installation(request: &TtsSynthesisRequest) -> Result<(), String> {
    let manifest_path =
        env::var_os("LECTURA_TTS_MANIFEST").ok_or_else(|| "LF_MODEL_REQUIRED".to_owned())?;
    let package_path =
        env::var_os("LECTURA_TTS_PACKAGE").ok_or_else(|| "LF_MODEL_REQUIRED".to_owned())?;
    let manifest = validate_model_manifest(Path::new(&manifest_path))
        .map_err(|error| error.as_lf_error().code)?;
    validate_model_package_for_runtime(
        Path::new(&manifest_path),
        Path::new(&package_path),
        &request.runtime_id,
        &request.runtime_version,
    )
    .map_err(|error| error.as_lf_error().code)?;
    if manifest.id != request.model_id
        || manifest.model_revision != request.model_revision
        || !manifest.languages.contains(&request.language)
        || !manifest.voices.contains(&request.voice_id)
        || manifest.distribution_status == DistributionStatus::Laboratory
    {
        return Err("LF_MODEL_RUNTIME_INCOMPATIBLE".into());
    }
    if request.model_id == "kokoro-82m-4bit" && !request.raw_ipa {
        verify_kokoro_auxiliary(request)?;
    }
    Ok(())
}

fn verify_kokoro_auxiliary(request: &TtsSynthesisRequest) -> Result<(), String> {
    let manifest_path =
        env::var_os("LECTURA_TTS_AUX_MANIFEST").ok_or_else(|| "LF_MODEL_REQUIRED".to_owned())?;
    let package_path =
        env::var_os("LECTURA_TTS_AUX_PACKAGE").ok_or_else(|| "LF_MODEL_REQUIRED".to_owned())?;
    let manifest = validate_model_manifest(Path::new(&manifest_path))
        .map_err(|error| error.as_lf_error().code)?;
    validate_model_package_for_runtime(
        Path::new(&manifest_path),
        Path::new(&package_path),
        &request.runtime_id,
        &request.runtime_version,
    )
    .map_err(|error| error.as_lf_error().code)?;
    let expected_id = if request.language == "en" {
        "kokoro-kitten-tts-g2p"
    } else {
        "kokoro-ipa-lexicons-es-pt"
    };
    if manifest.id != expected_id
        || !manifest.languages.contains(&request.language)
        || !manifest.voices.contains(&request.voice_id)
        || manifest.distribution_status == DistributionStatus::Laboratory
    {
        return Err("LF_MODEL_RUNTIME_INCOMPATIBLE".into());
    }
    Ok(())
}

fn read_tts_request(path: &OsStr) -> Result<Vec<u8>, &'static str> {
    if path == OsStr::new("-") {
        let mut bytes = Vec::new();
        std::io::stdin()
            .take(MAX_TTS_REQUEST_BYTES + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| "LF_TTS_REQUEST_UNREADABLE")?;
        return (bytes.len() as u64 <= MAX_TTS_REQUEST_BYTES)
            .then_some(bytes)
            .ok_or("LF_CONTRACT_PAYLOAD_INVALID");
    }
    let path = Path::new(path);
    let metadata = fs::metadata(path).map_err(|_| "LF_TTS_REQUEST_UNREADABLE")?;
    if !metadata.is_file() || metadata.len() > MAX_TTS_REQUEST_BYTES {
        return Err("LF_CONTRACT_PAYLOAD_INVALID");
    }
    fs::read(path).map_err(|_| "LF_TTS_REQUEST_UNREADABLE")
}

fn synthesize_with_worker(request: &TtsSynthesisRequest) -> Result<TtsSynthesisResult, String> {
    let worker = worker_path().ok_or_else(|| "LF_WORKER_NOT_FOUND".to_owned())?;
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| "LF_TTS_SYNTHESIS_FAILED".to_owned())?
        .as_nanos();
    let path = env::temp_dir().join(format!("lectura-tts-cli-{}-{nonce}", std::process::id()));
    fs::create_dir(&path).map_err(|_| "LF_TTS_SYNTHESIS_FAILED".to_owned())?;
    let mut work_root = OwnedWorkRoot { path, keep: false };
    let envelope = json!({
        "schema_version": 1,
        "request_id": "req_cli_tts_worker",
        "command": "tts_synthesize",
        "payload": request
    });
    let mut child = Command::new(worker)
        .env("LECTURA_TTS_WORK_ROOT", &work_root.path)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| "LF_WORKER_START_FAILED".to_owned())?;
    if let Some(mut stdin) = child.stdin.take()
        && writeln!(stdin, "{envelope}").is_err()
    {
        let _ = child.kill();
        let _ = child.wait();
        return Err("LF_WORKER_IO_FAILED".into());
    }
    TTS_CANCELLED.store(false, Ordering::Relaxed);
    // SAFETY: the handler only performs an atomic store, which is signal-safe.
    let previous = unsafe {
        libc::signal(
            libc::SIGINT,
            handle_tts_sigint as *const () as libc::sighandler_t,
        )
    };
    let _signal_guard = SignalGuard(previous);
    let status = loop {
        if TTS_CANCELLED.load(Ordering::Relaxed) {
            let _ = child.kill();
            let _ = child.wait();
            return Err("LF_CANCELLED".into());
        }
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) => std::thread::sleep(Duration::from_millis(20)),
            Err(_) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err("LF_WORKER_IO_FAILED".into());
            }
        }
    };
    if TTS_CANCELLED.load(Ordering::Relaxed) {
        return Err("LF_CANCELLED".into());
    }
    let mut stdout = Vec::new();
    child
        .stdout
        .take()
        .ok_or_else(|| "LF_WORKER_PROTOCOL_INVALID".to_owned())?
        .read_to_end(&mut stdout)
        .map_err(|_| "LF_WORKER_PROTOCOL_INVALID".to_owned())?;
    if !status.success() && stdout.is_empty() {
        return Err("LF_TTS_SYNTHESIS_FAILED".into());
    }
    if stdout.iter().filter(|byte| **byte == b'\n').count() != 1 {
        return Err("LF_WORKER_PROTOCOL_INVALID".into());
    }
    let response: Value =
        serde_json::from_slice(&stdout).map_err(|_| "LF_WORKER_PROTOCOL_INVALID".to_owned())?;
    if !status.success() || response["kind"] != "completed" {
        return Err(response["error"]["code"]
            .as_str()
            .filter(|code| code.starts_with("LF_TTS_") || code.starts_with("LF_MODEL_"))
            .unwrap_or("LF_TTS_SYNTHESIS_FAILED")
            .to_owned());
    }
    let result: TtsSynthesisResult = serde_json::from_value(response["result"]["tts"].clone())
        .map_err(|_| "LF_WORKER_PROTOCOL_INVALID".to_owned())?;
    let audio_path = Path::new(&result.audio_path);
    let audio_valid = audio_path.is_absolute()
        && fs::symlink_metadata(audio_path)
            .is_ok_and(|metadata| metadata.file_type().is_file() && metadata.len() > 0);
    if result.validate_against(request).is_err() || !audio_valid {
        return Err("LF_TTS_OUTPUT_INVALID".into());
    }
    if !audio_path.starts_with(&work_root.path) {
        return Err("LF_TTS_OUTPUT_INVALID".into());
    }
    work_root.keep = true;
    Ok(result)
}

fn translate(request_path: &OsStr) -> ExitCode {
    let request_bytes = match read_tts_request(request_path) {
        Ok(bytes) => bytes,
        Err(code) => return translate_failure(code, 66),
    };
    let request: TranslationRequest = match serde_json::from_slice(&request_bytes) {
        Ok(request) => request,
        Err(_) => return translate_failure("LF_CONTRACT_PAYLOAD_INVALID", 65),
    };
    if let Err(error) = request.validate() {
        return translate_failure(error.as_lf_error().code.as_str(), 65);
    }
    if let Err(code) = verify_translation_installation(&request) {
        return translate_failure(&code, 65);
    }
    match translate_with_worker(&request) {
        Ok(result) => write_event(
            EventEnvelope {
                schema_version: lectura_core::SCHEMA_VERSION,
                request_id: "req_cli_translate".into(),
                job_id: "job_cli_translate".into(),
                sequence: 0,
                kind: "completed".into(),
                progress: None,
                result: Some(EventResult::TranslationCompleted(result)),
                error: None,
                recovery: None,
            },
            ExitCode::SUCCESS,
        ),
        Err(code) if code == "LF_CANCELLED" => translate_cancelled(),
        Err(code) => translate_failure(&code, 70),
    }
}

fn verify_translation_installation(request: &TranslationRequest) -> Result<(), String> {
    let manifest_path =
        env::var_os("LECTURA_TRANSLATE_MANIFEST").ok_or_else(|| "LF_MODEL_REQUIRED".to_owned())?;
    let package_path =
        env::var_os("LECTURA_TRANSLATE_PACKAGE").ok_or_else(|| "LF_MODEL_REQUIRED".to_owned())?;
    let manifest = validate_model_manifest(Path::new(&manifest_path))
        .map_err(|error| error.as_lf_error().code)?;
    validate_model_package_for_runtime(
        Path::new(&manifest_path),
        Path::new(&package_path),
        &request.runtime_id,
        &request.runtime_version,
    )
    .map_err(|error| error.as_lf_error().code)?;
    if manifest.id != request.model_id
        || manifest.model_revision != request.model_revision
        || !manifest.languages.contains(&request.source_language)
        || !manifest.languages.contains(&request.target_language)
        || manifest.distribution_status == DistributionStatus::Laboratory
    {
        return Err("LF_MODEL_RUNTIME_INCOMPATIBLE".into());
    }
    Ok(())
}

fn translate_with_worker(request: &TranslationRequest) -> Result<TranslationResult, String> {
    let worker = worker_path().ok_or_else(|| "LF_WORKER_NOT_FOUND".to_owned())?;
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| "LF_TRANSLATION_FAILED".to_owned())?
        .as_nanos();
    let path = env::temp_dir().join(format!(
        "lectura-translate-cli-{}-{nonce}",
        std::process::id()
    ));
    fs::create_dir(&path).map_err(|_| "LF_TRANSLATION_FAILED".to_owned())?;
    let work_root = OwnedWorkRoot { path, keep: false };
    let envelope = json!({
        "schema_version": 1,
        "request_id": "req_cli_translate_worker",
        "command": "translate",
        "payload": {
            "model_id": request.model_id,
            "model_revision": request.model_revision,
            "runtime_id": request.runtime_id,
            "runtime_version": request.runtime_version,
            "source_language": request.source_language,
            "target_language": request.target_language,
            "translation_units": request.units,
        }
    });
    let mut child = Command::new(worker)
        .env("LECTURA_TRANSLATE_WORK_ROOT", &work_root.path)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| "LF_WORKER_START_FAILED".to_owned())?;
    if let Some(mut stdin) = child.stdin.take()
        && writeln!(stdin, "{envelope}").is_err()
    {
        let _ = child.kill();
        let _ = child.wait();
        return Err("LF_WORKER_IO_FAILED".into());
    }
    TTS_CANCELLED.store(false, Ordering::Relaxed);
    // SAFETY: the handler only performs an atomic store, which is signal-safe.
    let previous = unsafe {
        libc::signal(
            libc::SIGINT,
            handle_tts_sigint as *const () as libc::sighandler_t,
        )
    };
    let _signal_guard = SignalGuard(previous);
    let status = loop {
        if TTS_CANCELLED.load(Ordering::Relaxed) {
            let _ = child.kill();
            let _ = child.wait();
            return Err("LF_CANCELLED".into());
        }
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) => std::thread::sleep(Duration::from_millis(20)),
            Err(_) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err("LF_WORKER_IO_FAILED".into());
            }
        }
    };
    if TTS_CANCELLED.load(Ordering::Relaxed) {
        return Err("LF_CANCELLED".into());
    }
    let mut stdout = Vec::new();
    child
        .stdout
        .take()
        .ok_or_else(|| "LF_WORKER_PROTOCOL_INVALID".to_owned())?
        .read_to_end(&mut stdout)
        .map_err(|_| "LF_WORKER_PROTOCOL_INVALID".to_owned())?;
    if !status.success() && stdout.is_empty() {
        return Err("LF_TRANSLATION_FAILED".into());
    }
    if stdout.iter().filter(|byte| **byte == b'\n').count() != 1 {
        return Err("LF_WORKER_PROTOCOL_INVALID".into());
    }
    let response: Value =
        serde_json::from_slice(&stdout).map_err(|_| "LF_WORKER_PROTOCOL_INVALID".to_owned())?;
    if !status.success() || response["kind"] != "completed" {
        return Err(response["error"]["code"]
            .as_str()
            .filter(|code| code.starts_with("LF_TRANSLATION_") || code.starts_with("LF_MODEL_"))
            .unwrap_or("LF_TRANSLATION_FAILED")
            .to_owned());
    }
    let result: TranslationResult =
        serde_json::from_value(response["result"]["translation"].clone())
            .map_err(|_| "LF_WORKER_PROTOCOL_INVALID".to_owned())?;
    if result.validate_against(request).is_err() {
        return Err("LF_TRANSLATION_OUTPUT_INVALID".into());
    }
    Ok(result)
}

fn translate_cancelled() -> ExitCode {
    write_event(
        cli_event("translate", "cancelled", None),
        ExitCode::from(130),
    )
}

fn translate_failure(code: &str, exit: u8) -> ExitCode {
    eprintln!("lectura: translation failed ({code})");
    let mut error = lectura_core::TranslationError::TranslationFailed.as_lf_error();
    error.code = code.into();
    write_event(
        cli_event("translate", "failed", Some(error)),
        ExitCode::from(exit),
    )
}

fn tts_cancelled() -> ExitCode {
    write_event(
        cli_event("tts_synthesize", "cancelled", None),
        ExitCode::from(130),
    )
}

fn tts_failure(code: &str, exit: u8) -> ExitCode {
    eprintln!("lectura: TTS synthesis failed ({code})");
    let mut error = lectura_core::TtsError::SynthesisFailed.as_lf_error();
    error.code = code.into();
    write_event(
        cli_event("tts_synthesize", "failed", Some(error)),
        ExitCode::from(exit),
    )
}

fn verify_model(manifest: &OsStr, package: &OsStr) -> ExitCode {
    match validate_model_package(Path::new(manifest), Path::new(package)) {
        Ok(result) => write_event(
            EventEnvelope {
                schema_version: lectura_core::SCHEMA_VERSION,
                request_id: "req_cli_model_verify".into(),
                job_id: "job_cli_model_verify".into(),
                sequence: 0,
                kind: "completed".into(),
                progress: None,
                result: Some(EventResult::ModelVerified(result)),
                error: None,
                recovery: None,
            },
            ExitCode::SUCCESS,
        ),
        Err(error) => {
            let lf_error = error.as_lf_error();
            let exit = if matches!(
                error,
                lectura_core::ModelManifestError::ManifestMissing
                    | lectura_core::ModelManifestError::PackageMissing
                    | lectura_core::ModelManifestError::ArtifactMissing
            ) {
                66
            } else {
                65
            };
            eprintln!("lectura: model verification failed ({})", lf_error.code);
            write_event(
                EventEnvelope {
                    schema_version: lectura_core::SCHEMA_VERSION,
                    request_id: "req_cli_model_verify".into(),
                    job_id: "job_cli_model_verify".into(),
                    sequence: 0,
                    kind: "failed".into(),
                    progress: None,
                    result: None,
                    error: Some(lf_error),
                    recovery: None,
                },
                ExitCode::from(exit),
            )
        }
    }
}

fn process_pdf(
    input: &OsStr,
    language: &OsStr,
    unit: &OsStr,
    force_ocr_page: Option<u32>,
    page_limit: Option<u32>,
) -> ExitCode {
    let Some(language) = language
        .to_str()
        .filter(|value| matches!(*value, "es" | "en" | "pt"))
    else {
        return process_failure("LF_LANGUAGE_UNSUPPORTED", 64);
    };
    let requested_unit = match unit.to_str() {
        Some("paragraph") => RequestedUnit::Paragraph,
        Some("sentence") => RequestedUnit::Sentence,
        _ => return process_failure("LF_UNIT_UNSUPPORTED", 64),
    };
    let input = Path::new(input);
    let fingerprint = match fingerprint_file(input) {
        Ok(value) => value,
        Err(_) => return process_failure("LF_FILE_NOT_FOUND", 66),
    };
    let worker_pages = match extract_with_worker(input, language, force_ocr_page, page_limit) {
        Ok(pages) => pages,
        Err(code) => return process_failure(&code, 70),
    };
    let generation_id = format!("generation_{}", &fingerprint[..16]);
    let expected = expected_block_texts(input);
    let selected_blocks: Vec<_> = worker_pages
        .iter()
        .map(|page| {
            let force = force_ocr_page == Some(page.page_index);
            let route =
                select_processing_route(page.direct_blocks.len(), page.ocr_blocks.len(), force);
            let blocks = if route == ProcessingRoute::Ocr && !page.ocr_blocks.is_empty() {
                page.ocr_blocks.clone()
            } else {
                page.direct_blocks.clone()
            };
            (page.page_index, route, blocks)
        })
        .collect();
    let nfr6 = expected.as_ref().map(|expected_pages| {
        let expected_texts: Vec<_> = expected_pages
            .iter()
            .flat_map(|page| page.texts.iter().cloned())
            .collect();
        let predicted: Vec<_> = expected_pages
            .iter()
            .flat_map(|expected_page| {
                selected_blocks
                    .iter()
                    .find(|page| page.0 == expected_page.page_index)
                    .into_iter()
                    .flat_map(|page| page.2.iter().map(|block| block.text.clone()))
            })
            .collect();
        let mut metric = measure_digital_block_order(&predicted, &expected_texts);
        if selected_blocks
            .iter()
            .any(|page| page.1 == ProcessingRoute::Ocr)
        {
            metric.threshold = 0.95;
            metric.passed = metric.denominator > 0 && metric.ratio >= metric.threshold;
        }
        metric
    });
    let cer = expected.as_ref().map(|expected_pages| {
        let expected_text = expected_pages
            .iter()
            .flat_map(|page| page.texts.iter().map(String::as_str))
            .collect::<Vec<_>>()
            .join("\n");
        let predicted_text = selected_blocks
            .iter()
            .flat_map(|page| page.2.iter().map(|block| block.text.as_str()))
            .collect::<Vec<_>>()
            .join("\n");
        character_error_rate(&predicted_text, &expected_text)
    });
    let extracted_pages: Vec<_> = selected_blocks
        .into_iter()
        .map(|(page_index, _, blocks)| PageExtraction {
            document_fingerprint: fingerprint.clone(),
            generation_id: generation_id.clone(),
            page_index,
            blocks,
        })
        .collect();
    let mut pages = normalize_digital_document(&extracted_pages, language, requested_unit);
    for page in &mut pages {
        if let Some(candidate) = worker_pages
            .iter()
            .find(|candidate| candidate.page_index == page.record.page_index)
        {
            let forced = force_ocr_page == Some(candidate.page_index);
            page.record.route = select_processing_route(
                candidate.direct_blocks.len(),
                candidate.ocr_blocks.len(),
                forced,
            );
            for unit in &mut page.units {
                unit.processing_route = page.record.route;
            }
            page.record.reason_code = if forced {
                "ocr_forced"
            } else if candidate.direct_blocks.is_empty() {
                "direct_text_empty"
            } else if candidate.ocr_blocks.len() > candidate.direct_blocks.len() {
                "raster_content_detected"
            } else {
                "direct_text_useful"
            }
            .into();
            if page.record.route == ProcessingRoute::Ocr {
                page.record.elapsed_ms = candidate.ocr_elapsed_ms;
                page.record.processor_revision = "vision-v1".into();
                if candidate.ocr_status.as_deref() == Some("degraded") {
                    page.record.status = lectura_core::PageProcessingStatus::Degraded;
                }
                if page.units.is_empty() {
                    page.record.error_code = candidate.ocr_error_code.clone();
                }
            }
        }
    }
    let result = DocumentProcessingResult {
        document_id: format!("doc_{}", &fingerprint[..16]),
        language: language.into(),
        requested_unit,
        pages,
        nfr6,
        cer,
    };
    write_event(
        EventEnvelope {
            schema_version: lectura_core::SCHEMA_VERSION,
            request_id: "req_cli_pdf_process".into(),
            job_id: "job_cli_pdf_process".into(),
            sequence: 0,
            kind: "completed".into(),
            progress: None,
            result: Some(EventResult::DocumentProcessed(result)),
            error: None,
            recovery: None,
        },
        ExitCode::SUCCESS,
    )
}

struct WorkerPage {
    page_index: u32,
    direct_blocks: Vec<ExtractedBlock>,
    ocr_blocks: Vec<ExtractedBlock>,
    ocr_status: Option<String>,
    ocr_error_code: Option<String>,
    ocr_elapsed_ms: u64,
}

fn extract_with_worker(
    input: &Path,
    language: &str,
    force_ocr_page: Option<u32>,
    page_limit: Option<u32>,
) -> Result<Vec<WorkerPage>, String> {
    let worker = worker_path().ok_or_else(|| "LF_WORKER_NOT_FOUND".to_owned())?;
    let input = input
        .to_str()
        .ok_or_else(|| "LF_FILE_PATH_INVALID".to_owned())?;
    let request = json!({
        "schema_version": 1,
        "request_id": "req_cli_worker",
        "command": "extract_document",
        "payload": {
            "path": input,
            "language": language,
            "force_ocr_pages": force_ocr_page.into_iter().collect::<Vec<_>>(),
            "page_limit": page_limit
        }
    });
    let mut child = Command::new(worker)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| "LF_WORKER_START_FAILED".to_owned())?;
    if let Some(mut stdin) = child.stdin.take()
        && writeln!(stdin, "{request}").is_err()
    {
        let _ = child.kill();
        let _ = child.wait();
        return Err("LF_WORKER_IO_FAILED".into());
    }
    let output = child
        .wait_with_output()
        .map_err(|_| "LF_WORKER_IO_FAILED".to_owned())?;
    if !output.status.success() || output.stdout.iter().filter(|byte| **byte == b'\n').count() != 1
    {
        return Err("LF_WORKER_PROTOCOL_INVALID".into());
    }
    let response: Value = serde_json::from_slice(&output.stdout)
        .map_err(|_| "LF_WORKER_PROTOCOL_INVALID".to_owned())?;
    if response["kind"] != "completed" {
        return Err(match response["error"]["code"].as_str() {
            Some("LF_PDF_ENCRYPTED") => "LF_PDF_ENCRYPTED",
            Some("LF_PDF_UNREADABLE") => "LF_PDF_UNREADABLE",
            _ => "LF_PDF_PROCESSING_FAILED",
        }
        .into());
    }
    response["result"]["pages"]
        .as_array()
        .ok_or_else(|| "LF_WORKER_PROTOCOL_INVALID".to_owned())?
        .iter()
        .map(|page| {
            Ok(WorkerPage {
                page_index: page["page_index"]
                    .as_u64()
                    .and_then(|value| u32::try_from(value).ok())
                    .ok_or_else(|| "LF_WORKER_PROTOCOL_INVALID".to_owned())?,
                direct_blocks: serde_json::from_value(page["direct_blocks"].clone())
                    .map_err(|_| "LF_WORKER_PROTOCOL_INVALID".to_owned())?,
                ocr_blocks: serde_json::from_value(page["ocr_blocks"].clone())
                    .map_err(|_| "LF_WORKER_PROTOCOL_INVALID".to_owned())?,
                ocr_status: page["ocr_status"].as_str().map(str::to_owned),
                ocr_error_code: page["ocr_error_code"].as_str().map(str::to_owned),
                ocr_elapsed_ms: page["ocr_elapsed_ms"]
                    .as_u64()
                    .ok_or_else(|| "LF_WORKER_PROTOCOL_INVALID".to_owned())?,
            })
        })
        .collect()
}

fn option_u32(arguments: &[std::ffi::OsString], name: &str) -> Option<u32> {
    arguments.chunks_exact(2).find_map(|pair| {
        (pair[0] == OsStr::new(name))
            .then(|| pair[1].to_str()?.parse::<u32>().ok())
            .flatten()
    })
}

fn worker_path() -> Option<PathBuf> {
    env::var_os("LECTURA_MACOS_WORKER")
        .map(PathBuf::from)
        .or_else(|| {
            env::current_exe()
                .ok()
                .and_then(|path| {
                    path.parent()
                        .map(|parent| parent.join("lectura-macos-worker"))
                })
                .filter(|path| path.is_file())
        })
        .or_else(|| {
            let path = PathBuf::from("target/lectura-macos-worker");
            path.is_file().then_some(path)
        })
}

struct ExpectedPage {
    page_index: u32,
    texts: Vec<String>,
}

fn expected_block_texts(input: &Path) -> Option<Vec<ExpectedPage>> {
    let file_name = input.file_stem()?.to_str()?;
    let expected = input
        .parent()?
        .parent()?
        .join("expected")
        .join(format!("{file_name}.json"));
    let bytes = fs::read(expected).ok()?;
    let ground_truth: Value = serde_json::from_slice(&bytes).ok()?;
    ground_truth["pages"]
        .as_array()?
        .iter()
        .map(|page| {
            Some(ExpectedPage {
                page_index: u32::try_from(page["page_index"].as_u64()?).ok()?,
                texts: page["blocks"]
                    .as_array()?
                    .iter()
                    .filter_map(|block| block["text"].as_str().map(str::to_owned))
                    .collect(),
            })
        })
        .collect()
}

fn process_failure(code: &str, exit: u8) -> ExitCode {
    eprintln!("lectura: PDF processing failed ({code})");
    let mut error = lectura_core::RequestError::InvalidPayload.as_lf_error();
    error.code = code.into();
    error.message_key = "pdf.processing_failed".into();
    write_event(
        EventEnvelope {
            schema_version: lectura_core::SCHEMA_VERSION,
            request_id: "req_cli_pdf_process".into(),
            job_id: "job_cli_pdf_process".into(),
            sequence: 0,
            kind: "failed".into(),
            progress: None,
            result: None,
            error: Some(error),
            recovery: None,
        },
        ExitCode::from(exit),
    )
}

fn canary() -> ExitCode {
    let request =
        br#"{"schema_version":1,"request_id":"req_cli_canary","command":"canary","payload":{}}"#;
    let event = match lectura_core::handle_request(request) {
        Ok(event) => event,
        Err(_) => {
            eprintln!("lectura: canary request rejected");
            return ExitCode::from(70);
        }
    };
    let output = match serde_json::to_string(&event) {
        Ok(output) => output,
        Err(_) => {
            eprintln!("lectura: canary result serialization failed");
            return ExitCode::from(70);
        }
    };

    println!("{output}");
    ExitCode::SUCCESS
}

fn plan_session(page_count: &OsStr, visible_page_index: &OsStr) -> ExitCode {
    let Some(page_count) = page_count
        .to_str()
        .and_then(|value| value.parse::<u32>().ok())
    else {
        return process_failure("LF_PAGE_COUNT_INVALID", 64);
    };
    let Some(visible_page_index) = visible_page_index
        .to_str()
        .and_then(|value| value.parse::<u32>().ok())
    else {
        return process_failure("LF_PAGE_INDEX_INVALID", 64);
    };
    let request = json!({
        "schema_version": lectura_core::SCHEMA_VERSION,
        "request_id": "req_cli_session_plan",
        "command": "plan_session",
        "payload": {
            "document_id": "doc_cli_session",
            "page_count": page_count,
            "visible_page_index": visible_page_index,
        }
    });
    match lectura_core::handle_request(
        &serde_json::to_vec(&request).expect("JSON value serializes"),
    ) {
        Ok(event) => write_event(event, ExitCode::SUCCESS),
        Err(_) => process_failure("LF_SESSION_PLAN_INVALID", 65),
    }
}

fn validate_corpus(manifest: &OsStr) -> ExitCode {
    match lectura_core::validate_corpus_manifest(manifest) {
        Ok(result) => write_event(
            EventEnvelope {
                schema_version: lectura_core::SCHEMA_VERSION,
                request_id: "req_cli_corpus_validate".into(),
                job_id: "job_cli_corpus_validate".into(),
                sequence: 0,
                kind: "completed".into(),
                progress: None,
                result: Some(EventResult::CorpusValidated(result)),
                error: None,
                recovery: None,
            },
            ExitCode::SUCCESS,
        ),
        Err(error) => {
            let lf_error = error.as_lf_error();
            let exit = if lf_error.code == "LF_FILE_NOT_FOUND" {
                66
            } else {
                65
            };
            eprintln!("lectura: corpus validation failed ({})", lf_error.code);
            write_event(
                EventEnvelope {
                    schema_version: lectura_core::SCHEMA_VERSION,
                    request_id: "req_cli_corpus_validate".into(),
                    job_id: "job_cli_corpus_validate".into(),
                    sequence: 0,
                    kind: "failed".into(),
                    progress: None,
                    result: None,
                    error: Some(lf_error),
                    recovery: None,
                },
                ExitCode::from(exit),
            )
        }
    }
}

fn write_event(event: EventEnvelope, exit: ExitCode) -> ExitCode {
    match serde_json::to_string(&event) {
        Ok(output) => {
            println!("{output}");
            exit
        }
        Err(_) => {
            eprintln!("lectura: result serialization failed");
            ExitCode::from(70)
        }
    }
}
