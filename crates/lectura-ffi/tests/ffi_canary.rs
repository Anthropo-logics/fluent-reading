use std::process::Command;
use std::ptr;
use std::slice;

use lectura_ffi::{
    LF_ABI_INVALID_ARGUMENT, LF_ABI_INVALID_JSON, LF_ABI_INVALID_UTF8, LF_ABI_OK, LFEngine,
    LFInputBytes, LFOwnedBytes, lf_abi_version, lf_engine_cancel, lf_engine_create,
    lf_engine_destroy, lf_engine_next_event, lf_engine_submit, lf_owned_bytes_free,
};
use serde_json::Value;

const REQUEST: &[u8] =
    br#"{"schema_version":1,"request_id":"req_ffi","command":"canary","payload":{}}"#;
const MAX_MESSAGE_BYTES: usize = 16 * 1024 * 1024;

fn input(bytes: &[u8]) -> LFInputBytes {
    LFInputBytes {
        ptr: bytes.as_ptr(),
        len: bytes.len(),
    }
}

fn empty_owned() -> LFOwnedBytes {
    LFOwnedBytes {
        ptr: ptr::null_mut(),
        len: 0,
    }
}

fn take_json(bytes: LFOwnedBytes) -> Value {
    assert!(!bytes.ptr.is_null());
    // SAFETY: the ABI returned a live allocation of exactly `len` bytes; it is copied before
    // ownership is returned exactly once with `lf_owned_bytes_free`.
    let copied = unsafe { slice::from_raw_parts(bytes.ptr, bytes.len) }.to_vec();
    // SAFETY: this is the exact, not-yet-freed pair returned by the ABI.
    unsafe { lf_owned_bytes_free(bytes) };
    serde_json::from_slice(&copied).expect("ABI output must be valid JSON")
}

fn create_engine() -> *mut LFEngine {
    let mut engine = ptr::null_mut();
    let mut error = empty_owned();
    // SAFETY: both output slots and the configuration bytes remain live for this call.
    let code = unsafe { lf_engine_create(input(b"{}"), &mut engine, &mut error) };
    assert_eq!(code, LF_ABI_OK);
    assert!(!engine.is_null());
    assert!(error.ptr.is_null());
    engine
}

fn resident_bytes() -> Option<u64> {
    let output = Command::new("/bin/ps")
        .args(["-o", "rss=", "-p", &std::process::id().to_string()])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let kib = String::from_utf8(output.stdout)
        .ok()?
        .trim()
        .parse::<u64>()
        .ok()?;
    Some(kib * 1024)
}

fn submit_and_take(engine: *mut LFEngine) -> Vec<u8> {
    let mut acceptance = empty_owned();
    // SAFETY: the test owns the engine/output and REQUEST is live for this call.
    assert_eq!(
        unsafe { lf_engine_submit(engine, input(REQUEST), &mut acceptance) },
        LF_ABI_OK
    );
    let acceptance = take_json(acceptance);
    acceptance["job_id"]
        .as_str()
        .expect("accepted event must expose job_id")
        .as_bytes()
        .to_vec()
}

#[test]
fn abi_canary_completes_one_hundred_owned_lifecycles() {
    assert_eq!(lf_abi_version(), 1);
    let mut tail_rss = Vec::new();

    for cycle in 0..100 {
        let engine = create_engine();
        let job_id = submit_and_take(engine);
        match cycle % 4 {
            0 => {
                let mut terminal = empty_owned();
                // SAFETY: engine/output and job ID remain live for the call.
                assert_eq!(
                    unsafe { lf_engine_next_event(engine, input(&job_id), 0, &mut terminal) },
                    LF_ABI_OK
                );
                let terminal = take_json(terminal);
                assert_eq!(terminal["kind"], "completed");
                assert_eq!(terminal["result"]["core_version"], "0.1.0");
            }
            1 => {
                // SAFETY: engine and job ID remain live for the call.
                assert_eq!(
                    unsafe { lf_engine_cancel(engine, input(&job_id)) },
                    LF_ABI_OK
                );
                let mut terminal = empty_owned();
                // SAFETY: engine/output and job ID remain live for the call.
                assert_eq!(
                    unsafe { lf_engine_next_event(engine, input(&job_id), 0, &mut terminal) },
                    LF_ABI_OK
                );
                assert_eq!(take_json(terminal)["kind"], "cancelled");
            }
            2 => {
                let mut error = empty_owned();
                // SAFETY: engine/output and malformed request remain live for the call.
                assert_eq!(
                    unsafe {
                        lf_engine_submit(engine, input(br#"{"schema_version":1"#), &mut error)
                    },
                    LF_ABI_INVALID_JSON
                );
                assert_eq!(take_json(error)["code"], "LF_CONTRACT_INVALID_JSON");
            }
            _ => {
                // Closing before the next pull models a close during poll; the caller must not
                // dereference the opaque pointer afterwards.
            }
        }

        // SAFETY: the engine is live, no call is in flight, and this is its only owner.
        unsafe { lf_engine_destroy(engine) };
        if cycle >= 80
            && let Some(rss) = resident_bytes()
        {
            tail_rss.push(rss);
        }
    }

    // A warmed allocator/cache may retain pages. A sustained ten-sample rise above 2 MiB is a
    // leak signal; a stable high-water mark is not.
    if tail_rss.len() == 20 {
        assert!(
            !(tail_rss.windows(2).all(|pair| pair[1] >= pair[0])
                && tail_rss.last().unwrap() > &(tail_rss[0] + 2 * 1024 * 1024)),
            "sustained RSS growth across the warmed boundary cycles: {tail_rss:?}"
        );
        eprintln!("boundary RSS tail bytes: {tail_rss:?}");
    } else {
        assert_ne!(
            std::env::var("LECTURA_BOUNDARY_RSS_REQUIRED")
                .ok()
                .as_deref(),
            Some("1"),
            "the reference-host boundary run requires 20 RSS samples"
        );
    }
}

#[test]
fn abi_rejects_null_utf8_and_json_at_the_boundary() {
    let mut output = empty_owned();
    // SAFETY: null is a supported rejected engine value; input/output are live.
    let code = unsafe { lf_engine_submit(ptr::null_mut(), input(REQUEST), &mut output) };
    assert_eq!(code, LF_ABI_INVALID_ARGUMENT);

    let engine = create_engine();
    // The ABI owns result buffers, so a caller-supplied output slot is mandatory and there is no
    // capacity protocol that could truncate JSON silently.
    assert_eq!(
        unsafe { lf_engine_submit(engine, input(REQUEST), ptr::null_mut()) },
        LF_ABI_INVALID_ARGUMENT
    );
    assert_eq!(
        unsafe {
            lf_engine_submit(
                engine,
                LFInputBytes {
                    ptr: ptr::null(),
                    len: 0,
                },
                &mut output,
            )
        },
        LF_ABI_INVALID_ARGUMENT
    );
    let maximum = vec![b' '; MAX_MESSAGE_BYTES];
    assert_eq!(
        unsafe { lf_engine_submit(engine, input(&maximum), &mut output) },
        LF_ABI_INVALID_JSON
    );
    take_json(output);
    let mut output = empty_owned();
    assert_eq!(
        unsafe {
            lf_engine_submit(
                engine,
                LFInputBytes {
                    ptr: maximum.as_ptr(),
                    len: MAX_MESSAGE_BYTES + 1,
                },
                &mut output,
            )
        },
        lectura_ffi::LF_ABI_MESSAGE_TOO_LARGE
    );
    // SAFETY: the engine/output and one-byte input remain live for this call.
    let code = unsafe { lf_engine_submit(engine, input(&[0xff]), &mut output) };
    assert_eq!(code, LF_ABI_INVALID_UTF8);
    assert!(output.ptr.is_null());
    // SAFETY: the engine/output and malformed literal remain live for this call.
    let code = unsafe { lf_engine_submit(engine, input(br#"{"schema_version":1"#), &mut output) };
    assert_eq!(code, LF_ABI_INVALID_JSON);
    let error = take_json(output);
    assert_eq!(error["code"], "LF_CONTRACT_INVALID_JSON");

    // SAFETY: the engine is live, no call is in flight, and this is its only owner.
    unsafe { lf_engine_destroy(engine) };
    // `destroy(NULL)` is explicitly idempotent. Passing an already-freed non-null opaque pointer
    // is a C ABI contract violation and is intentionally never dereferenced by this test.
    unsafe { lf_engine_destroy(ptr::null_mut()) };
    unsafe { lf_engine_destroy(ptr::null_mut()) };
    // SAFETY: a null/zero owned buffer is explicitly valid.
    unsafe { lf_owned_bytes_free(empty_owned()) };
}

#[test]
fn cancellation_replaces_the_pending_terminal_event() {
    let engine = create_engine();
    let mut acceptance = empty_owned();
    // SAFETY: the test owns the engine/output and REQUEST is live for this call.
    let code = unsafe { lf_engine_submit(engine, input(REQUEST), &mut acceptance) };
    assert_eq!(code, LF_ABI_OK);
    let acceptance = take_json(acceptance);
    let job_id = acceptance["job_id"]
        .as_str()
        .expect("accepted event must expose job_id")
        .as_bytes();

    // SAFETY: the engine and borrowed job ID remain live for this call.
    let code = unsafe { lf_engine_cancel(engine, input(job_id)) };
    assert_eq!(code, LF_ABI_OK);
    let mut terminal = empty_owned();
    // SAFETY: the engine/output and borrowed job ID remain live for this call.
    let code = unsafe { lf_engine_next_event(engine, input(job_id), 0, &mut terminal) };
    assert_eq!(code, LF_ABI_OK);
    assert_eq!(take_json(terminal)["kind"], "cancelled");

    // SAFETY: the engine is live, no call is in flight, and this is its only owner.
    unsafe { lf_engine_destroy(engine) };
}
