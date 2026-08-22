//! C ABI v1 para el host macOS.

use std::collections::{BTreeMap, HashMap};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::ptr;
use std::slice;
use std::str;
use std::sync::Mutex;

use lectura_core::{ErrorScope, EventEnvelope, LfError, RequestError};

pub const LF_ABI_OK: i32 = 0;
pub const LF_ABI_TIMEOUT: i32 = 1;
pub const LF_ABI_INVALID_ARGUMENT: i32 = -1;
pub const LF_ABI_VERSION_MISMATCH: i32 = -2;
pub const LF_ABI_INVALID_UTF8: i32 = -3;
pub const LF_ABI_INVALID_JSON: i32 = -4;
pub const LF_ABI_MESSAGE_TOO_LARGE: i32 = -5;
pub const LF_ABI_ALLOCATION_FAILED: i32 = -6;
pub const LF_ABI_ENGINE_UNAVAILABLE: i32 = -7;
pub const LF_ABI_INTERNAL: i32 = -8;

const LF_MAX_MESSAGE_BYTES: usize = 16 * 1024 * 1024;

#[repr(C)]
pub struct LFInputBytes {
    pub ptr: *const u8,
    pub len: usize,
}

#[repr(C)]
pub struct LFOwnedBytes {
    pub ptr: *mut u8,
    pub len: usize,
}

#[repr(C)]
pub struct LFEngine {
    pending: Mutex<HashMap<String, EventEnvelope>>,
}

fn boundary(operation: impl FnOnce() -> i32) -> i32 {
    match catch_unwind(AssertUnwindSafe(operation)) {
        Ok(code) => code,
        Err(_) => LF_ABI_INTERNAL,
    }
}

unsafe fn read_input<'a>(input: LFInputBytes, allow_empty: bool) -> Result<&'a [u8], i32> {
    if input.len > LF_MAX_MESSAGE_BYTES {
        return Err(LF_ABI_MESSAGE_TOO_LARGE);
    }
    if input.len == 0 {
        return if allow_empty {
            Ok(&[])
        } else {
            Err(LF_ABI_INVALID_ARGUMENT)
        };
    }
    if input.ptr.is_null() {
        return Err(LF_ABI_INVALID_ARGUMENT);
    }

    // SAFETY: the caller promises `ptr` references `len` readable bytes for this call. The slice
    // is never retained, and null/zero/maximum-length combinations were checked above.
    Ok(unsafe { slice::from_raw_parts(input.ptr, input.len) })
}

unsafe fn prepare_output(output: *mut LFOwnedBytes) -> Result<(), i32> {
    if output.is_null() {
        return Err(LF_ABI_INVALID_ARGUMENT);
    }
    // SAFETY: the caller supplied a writable `LFOwnedBytes` slot for the duration of the call.
    unsafe {
        (*output).ptr = ptr::null_mut();
        (*output).len = 0;
    }
    Ok(())
}

unsafe fn write_owned(output: *mut LFOwnedBytes, bytes: Vec<u8>) -> Result<(), i32> {
    if output.is_null() {
        return Err(LF_ABI_INVALID_ARGUMENT);
    }
    let boxed = bytes.into_boxed_slice();
    let len = boxed.len();
    let data = Box::into_raw(boxed) as *mut u8;

    // SAFETY: `output` was validated above and receives the exact allocation returned by Rust.
    unsafe {
        (*output).ptr = data;
        (*output).len = len;
    }
    Ok(())
}

unsafe fn engine_ref<'a>(engine: *mut LFEngine) -> Result<&'a LFEngine, i32> {
    if engine.is_null() {
        return Err(LF_ABI_INVALID_ARGUMENT);
    }
    // SAFETY: the ABI requires a live engine created by `lf_engine_create`; no pointer is retained
    // beyond the current call.
    Ok(unsafe { &*engine })
}

fn input_error(code: &str, message_key: &str) -> LfError {
    LfError {
        code: code.into(),
        message_key: message_key.into(),
        scope: ErrorScope::default(),
        details: BTreeMap::new(),
    }
}

unsafe fn write_error(output: *mut LFOwnedBytes, error: &LfError, transport_code: i32) -> i32 {
    let serialized = match serde_json::to_vec(error) {
        Ok(serialized) => serialized,
        Err(_) => return LF_ABI_INTERNAL,
    };
    // SAFETY: the exported caller supplied and this function validated the output slot.
    match unsafe { write_owned(output, serialized) } {
        Ok(()) => transport_code,
        Err(code) => code,
    }
}

fn request_transport_code(error: &RequestError) -> i32 {
    match error {
        RequestError::UnsupportedSchemaVersion { .. } => LF_ABI_VERSION_MISMATCH,
        RequestError::InvalidJson
        | RequestError::InvalidRequestId
        | RequestError::UnknownCommand
        | RequestError::InvalidPayload => LF_ABI_INVALID_JSON,
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn lf_abi_version() -> u32 {
    1
}

#[unsafe(no_mangle)]
/// Creates an LF engine and transfers its opaque pointer to the caller.
///
/// # Safety
///
/// Non-null input buffers must be readable for their declared length. Both output pointers must
/// reference writable slots for the duration of the call.
pub unsafe extern "C" fn lf_engine_create(
    configuration_json: LFInputBytes,
    out_engine: *mut *mut LFEngine,
    out_error_json: *mut LFOwnedBytes,
) -> i32 {
    boundary(|| {
        if out_engine.is_null() {
            return LF_ABI_INVALID_ARGUMENT;
        }
        // SAFETY: both output pointers are validated before being written.
        if let Err(code) = unsafe { prepare_output(out_error_json) } {
            return code;
        }
        // SAFETY: `out_engine` is non-null and writable by the ABI contract.
        unsafe { *out_engine = ptr::null_mut() };

        // SAFETY: the input is borrowed only for this call.
        let configuration = match unsafe { read_input(configuration_json, true) } {
            Ok(configuration) => configuration,
            Err(code) => return code,
        };
        if !configuration.is_empty() {
            if str::from_utf8(configuration).is_err() {
                let error = input_error("LF_INPUT_INVALID_UTF8", "input.invalid_utf8");
                // SAFETY: `out_error_json` was prepared above.
                return unsafe { write_error(out_error_json, &error, LF_ABI_INVALID_UTF8) };
            }
            let value: serde_json::Value = match serde_json::from_slice(configuration) {
                Ok(value) => value,
                Err(_) => {
                    let error = RequestError::InvalidJson.as_lf_error();
                    // SAFETY: `out_error_json` was prepared above.
                    return unsafe { write_error(out_error_json, &error, LF_ABI_INVALID_JSON) };
                }
            };
            if !value.is_object() {
                let error = input_error(
                    "LF_CONTRACT_CONFIGURATION_INVALID",
                    "contract.configuration_invalid",
                );
                // SAFETY: `out_error_json` was prepared above.
                return unsafe { write_error(out_error_json, &error, LF_ABI_INVALID_JSON) };
            }
        }

        let engine = Box::new(LFEngine {
            pending: Mutex::new(HashMap::new()),
        });
        // SAFETY: `out_engine` is writable and receives exclusive ownership of the Rust allocation.
        unsafe { *out_engine = Box::into_raw(engine) };
        LF_ABI_OK
    })
}

#[unsafe(no_mangle)]
/// Submits one LF request and returns a Rust-owned acceptance buffer.
///
/// # Safety
///
/// `engine` must be null or a live pointer returned by `lf_engine_create`; non-null input buffers
/// must be readable for their declared length, and the output pointer must be writable.
pub unsafe extern "C" fn lf_engine_submit(
    engine: *mut LFEngine,
    request_json: LFInputBytes,
    out_acceptance_json: *mut LFOwnedBytes,
) -> i32 {
    boundary(|| {
        // SAFETY: the output slot is borrowed only for this call.
        if let Err(code) = unsafe { prepare_output(out_acceptance_json) } {
            return code;
        }
        // SAFETY: the engine is borrowed only for this call.
        let engine = match unsafe { engine_ref(engine) } {
            Ok(engine) => engine,
            Err(code) => return code,
        };
        // SAFETY: the input is borrowed only for this call.
        let request = match unsafe { read_input(request_json, false) } {
            Ok(request) => request,
            Err(code) => return code,
        };
        if str::from_utf8(request).is_err() {
            return LF_ABI_INVALID_UTF8;
        }

        let terminal = match lectura_core::handle_request(request) {
            Ok(event) => event,
            Err(error) => {
                let code = request_transport_code(&error);
                // SAFETY: `out_acceptance_json` was prepared above.
                return unsafe { write_error(out_acceptance_json, &error.as_lf_error(), code) };
            }
        };
        let acceptance = match serde_json::to_vec(&terminal.acceptance()) {
            Ok(acceptance) => acceptance,
            Err(_) => return LF_ABI_INTERNAL,
        };
        let job_id = terminal.job_id.clone();
        let mut pending = match engine.pending.lock() {
            Ok(pending) => pending,
            Err(_) => return LF_ABI_ENGINE_UNAVAILABLE,
        };
        pending.insert(job_id, terminal);
        // SAFETY: `out_acceptance_json` was prepared above.
        match unsafe { write_owned(out_acceptance_json, acceptance) } {
            Ok(()) => LF_ABI_OK,
            Err(code) => code,
        }
    })
}

#[unsafe(no_mangle)]
/// Removes the next queued event for a job.
///
/// # Safety
///
/// `engine` must be null or live, the job buffer must be readable for its declared length, and the
/// output pointer must reference a writable slot.
pub unsafe extern "C" fn lf_engine_next_event(
    engine: *mut LFEngine,
    job_id_utf8: LFInputBytes,
    _timeout_ms: u32,
    out_event_json: *mut LFOwnedBytes,
) -> i32 {
    boundary(|| {
        // SAFETY: the output slot is borrowed only for this call.
        if let Err(code) = unsafe { prepare_output(out_event_json) } {
            return code;
        }
        // SAFETY: the engine and input are borrowed only for this call.
        let engine = match unsafe { engine_ref(engine) } {
            Ok(engine) => engine,
            Err(code) => return code,
        };
        // SAFETY: the input is borrowed only for this call.
        let job_bytes = match unsafe { read_input(job_id_utf8, false) } {
            Ok(job_bytes) => job_bytes,
            Err(code) => return code,
        };
        let job_id = match str::from_utf8(job_bytes) {
            Ok(job_id) => job_id,
            Err(_) => return LF_ABI_INVALID_UTF8,
        };

        let mut pending = match engine.pending.lock() {
            Ok(pending) => pending,
            Err(_) => return LF_ABI_ENGINE_UNAVAILABLE,
        };
        let event = match pending.remove(job_id) {
            Some(event) => event,
            None => return LF_ABI_TIMEOUT,
        };
        let serialized = match serde_json::to_vec(&event) {
            Ok(serialized) => serialized,
            Err(_) => return LF_ABI_INTERNAL,
        };
        // SAFETY: `out_event_json` was prepared above.
        match unsafe { write_owned(out_event_json, serialized) } {
            Ok(()) => LF_ABI_OK,
            Err(code) => code,
        }
    })
}

#[unsafe(no_mangle)]
/// Replaces a pending job event with `cancelled`.
///
/// # Safety
///
/// `engine` must be null or live and the job buffer must be readable for its declared length.
pub unsafe extern "C" fn lf_engine_cancel(engine: *mut LFEngine, job_id_utf8: LFInputBytes) -> i32 {
    boundary(|| {
        // SAFETY: the engine and input are borrowed only for this call.
        let engine = match unsafe { engine_ref(engine) } {
            Ok(engine) => engine,
            Err(code) => return code,
        };
        // SAFETY: the input is borrowed only for this call.
        let job_bytes = match unsafe { read_input(job_id_utf8, false) } {
            Ok(job_bytes) => job_bytes,
            Err(code) => return code,
        };
        let job_id = match str::from_utf8(job_bytes) {
            Ok(job_id) => job_id,
            Err(_) => return LF_ABI_INVALID_UTF8,
        };

        let mut pending = match engine.pending.lock() {
            Ok(pending) => pending,
            Err(_) => return LF_ABI_ENGINE_UNAVAILABLE,
        };
        match pending.get_mut(job_id) {
            Some(event) => {
                event.cancel();
                LF_ABI_OK
            }
            None => LF_ABI_INVALID_ARGUMENT,
        }
    })
}

#[unsafe(no_mangle)]
/// Releases one exact Rust-owned byte allocation.
///
/// # Safety
///
/// A non-null pointer/length pair must have been returned by this ABI and must not have been freed.
pub unsafe extern "C" fn lf_owned_bytes_free(bytes: LFOwnedBytes) {
    if bytes.ptr.is_null() || bytes.len == 0 {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        let allocation = ptr::slice_from_raw_parts_mut(bytes.ptr, bytes.len);
        // SAFETY: this exact pointer/length pair came from `write_owned` and is freed once.
        unsafe { drop(Box::from_raw(allocation)) };
    }));
}

#[unsafe(no_mangle)]
/// Destroys an engine after all concurrent calls have stopped.
///
/// # Safety
///
/// `engine` must be null or the sole live pointer returned by `lf_engine_create`.
pub unsafe extern "C" fn lf_engine_destroy(engine: *mut LFEngine) {
    if engine.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: the caller transfers the sole live engine allocation and has stopped all calls.
        unsafe { drop(Box::from_raw(engine)) };
    }));
}

#[cfg(test)]
mod tests {
    use super::{LF_ABI_INTERNAL, boundary};

    #[test]
    fn panic_never_crosses_the_ffi_boundary() {
        assert_eq!(boundary(|| panic!("test-only panic")), LF_ABI_INTERNAL);
    }
}
