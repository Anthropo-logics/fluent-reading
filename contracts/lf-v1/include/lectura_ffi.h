#ifndef LECTURA_FFI_H
#define LECTURA_FFI_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct LFEngine LFEngine;

typedef struct {
  const uint8_t *ptr;
  size_t len;
} LFInputBytes;

typedef struct {
  uint8_t *ptr;
  size_t len;
} LFOwnedBytes;

enum {
  LF_ABI_OK = 0,
  LF_ABI_TIMEOUT = 1,
  LF_ABI_INVALID_ARGUMENT = -1,
  LF_ABI_VERSION_MISMATCH = -2,
  LF_ABI_INVALID_UTF8 = -3,
  LF_ABI_INVALID_JSON = -4,
  LF_ABI_MESSAGE_TOO_LARGE = -5,
  LF_ABI_ALLOCATION_FAILED = -6,
  LF_ABI_ENGINE_UNAVAILABLE = -7,
  LF_ABI_INTERNAL = -8
};

uint32_t lf_abi_version(void);

int32_t lf_engine_create(
    LFInputBytes configuration_json,
    LFEngine **out_engine,
    LFOwnedBytes *out_error_json);

int32_t lf_engine_submit(
    LFEngine *engine,
    LFInputBytes request_json,
    LFOwnedBytes *out_acceptance_json);

int32_t lf_engine_next_event(
    LFEngine *engine,
    LFInputBytes job_id_utf8,
    uint32_t timeout_ms,
    LFOwnedBytes *out_event_json);

int32_t lf_engine_cancel(LFEngine *engine, LFInputBytes job_id_utf8);

void lf_owned_bytes_free(LFOwnedBytes bytes);
void lf_engine_destroy(LFEngine *engine);

#ifdef __cplusplus
}
#endif

#endif
