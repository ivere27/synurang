#ifndef SYNURANG_CALL_H_
#define SYNURANG_CALL_H_

#include "c_runtime.h"

#ifdef __cplusplus
extern "C" {
#endif

/* The module ABI is deliberately independent of C++/Rust/managed object layouts.
 * ABI versions detect mismatched builds; no old-ABI fallback is provided. */
#define SYNURANG_CALL_ABI_VERSION 1u

typedef struct SynurangInstance SynurangInstance;
typedef struct SynurangCallOptions {
    uint32_t struct_size;
    uint32_t request_stream;
    uint32_t response_stream;
    uint32_t reserved;
    /* Remaining timeout in milliseconds; UINT64_MAX means no deadline. The
     * host owns the monotonic timer and forwards expiry with call_cancel. */
    uint64_t timeout_ms;
} SynurangCallOptions;

typedef enum SynurangReadKind {
    SYNURANG_READ_PENDING = 0,
    SYNURANG_READ_MESSAGE = 1,
    SYNURANG_READ_FINISHED = 2
} SynurangReadKind;

typedef struct SynurangReadResult {
    uint32_t kind;
    int32_t code; /* RPC status, meaningful for FINISHED only. */
    /* Message or serialized core.v1.Error for non-OK FINISHED. Every non-NULL
     * pointer must be passed to free_buffer, even when size is zero. */
    uint8_t* data;
    uint32_t size;
} SynurangReadResult;

typedef uint64_t (*SynurangOpenCallFn)(
    SynurangRuntime* runtime, const SynurangCallOptions* options, void* user_data);
typedef void (*SynurangDestroyFn)(void* user_data);

/* Registration is allowed before the first call only. The instance owns a
 * registration after success and calls destroy once during instance teardown. */
SYNURANG_C_RUNTIME_API SynurangInstance* synurang_instance_create(
    const SynurangRuntimeOptions* options);
SYNURANG_C_RUNTIME_API int synurang_instance_register(
    SynurangInstance* instance, const char* method, uint32_t request_stream,
    uint32_t response_stream, SynurangOpenCallFn open, void* user_data,
    SynurangDestroyFn destroy);
SYNURANG_C_RUNTIME_API uint64_t synurang_call_open(
    SynurangInstance* instance, const char* method,
    const SynurangCallOptions* options);
SYNURANG_C_RUNTIME_API int synurang_call_send(
    SynurangInstance* instance, uint64_t call, const uint8_t* data, uint32_t size);
SYNURANG_C_RUNTIME_API int synurang_call_half_close(
    SynurangInstance* instance, uint64_t call);
SYNURANG_C_RUNTIME_API int synurang_call_receive(
    SynurangInstance* instance, uint64_t call, SynurangReadResult* result);
SYNURANG_C_RUNTIME_API int synurang_call_cancel(
    SynurangInstance* instance, uint64_t call, int32_t code);
SYNURANG_C_RUNTIME_API void synurang_call_release(
    SynurangInstance* instance, uint64_t call);
SYNURANG_C_RUNTIME_API uint32_t synurang_instance_poll(
    SynurangInstance* instance, uint32_t budget);
SYNURANG_C_RUNTIME_API int synurang_instance_has_work(SynurangInstance* instance);
/* Starts shutdown, cancelling every call. Returns PENDING while producer
 * references/callbacks remain; keep polling and retry later. OK frees the
 * instance. The module must remain loaded until OK. */
SYNURANG_C_RUNTIME_API int synurang_instance_destroy(SynurangInstance* instance);

/* Instances serialize foreign entry calls. Producers may complete work on
 * runtime workers. Wakeups only schedule the host's later drain; they must not
 * re-enter this table or run application callbacks inline. Providers
 * invoke options.wakeup when ready work, readable output/terminal, writable
 * input, or completed producer cleanup can unblock the host. Notifications
 * may coalesce; register before create and keep the callback/user data alive
 * until destroy returns OK. No callback is running or may begin after OK.
 * Hosts retain notifications arriving before they start waiting, drain bounded
 * polling turns while has_work is true, then sleep until a notification or a
 * host deadline. A release schedules this drain in the background, including
 * after the final call; it never waits for unrelated calls to become idle. */
/* Portable create options are non-NULL with the exact RuntimeOptions size,
 * MANUAL execution and input/output capacities in 1..65536. worker_count is
 * ignored in MANUAL mode. wakeup/user_data describe the host notification sink.
 * NULL/default capacities, prefix-sized options and THREADED execution have
 * backend-specific semantics. ABI v1 hosts require exact Api.struct_size too;
 * it is a layout check, not a promise of prefix-compatible table extensions. */
typedef struct SynurangApi {
    uint32_t abi_version;
    uint32_t struct_size;
    SynurangInstance* (*create)(const SynurangRuntimeOptions* options);
    int (*destroy)(SynurangInstance* instance);
    uint64_t (*open)(SynurangInstance*, const char*, const SynurangCallOptions*);
    int (*send)(SynurangInstance*, uint64_t, const uint8_t*, uint32_t);
    int (*half_close)(SynurangInstance*, uint64_t);
    int (*receive)(SynurangInstance*, uint64_t, SynurangReadResult*);
    int (*cancel)(SynurangInstance*, uint64_t, int32_t);
    void (*release)(SynurangInstance*, uint64_t);
    uint32_t (*poll)(SynurangInstance*, uint32_t);
    int (*has_work)(SynurangInstance*);
    void (*free_buffer)(void*);
} SynurangApi;

typedef const SynurangApi* (*SynurangGetApiFn)(void);

/* factory creates an instance and registers this module's services. This
 * named accessor also works when several modules are statically linked. */
#ifdef __cplusplus
#define SYNURANG_MODULE_LINKAGE extern "C"
#else
#define SYNURANG_MODULE_LINKAGE
#endif
#define SYNURANG_DEFINE_MODULE(name, factory) \
    SYNURANG_MODULE_LINKAGE SYNURANG_C_RUNTIME_API const SynurangApi* name(void) { \
        static const SynurangApi api = { \
            SYNURANG_CALL_ABI_VERSION, sizeof(SynurangApi), factory, \
            synurang_instance_destroy, synurang_call_open, synurang_call_send, \
            synurang_call_half_close, synurang_call_receive, synurang_call_cancel, \
            synurang_call_release, synurang_instance_poll, \
            synurang_instance_has_work, synurang_response_free \
        }; \
        return &api; \
    }

#ifdef __cplusplus
}
#endif
#endif
