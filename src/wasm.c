/* Compile with the module and call runtime. This bridge exports a stable wasm32
 * memory interface. Supported WASM execution is MANUAL, on the calling thread
 * or inside a Worker that owns its non-shared instance. WASM pthread/shared-
 * memory execution is unsupported; native C runtime workers are independent.
 * No native function pointer or JS object crosses a worker. */
#include "synurang/call.h"
#include <stdlib.h>
#include <math.h>
#if defined(__wasm__)
#define EXPORT(name) __attribute__((export_name(#name)))
#else
#define EXPORT(name) SYNURANG_C_RUNTIME_API
#endif

extern const SynurangApi* Synurang_GetApi(void);
#if defined(__wasm__)
__attribute__((import_module("synurang"), import_name("wakeup")))
extern void synurang_wasm_wakeup(uint32_t token);
#else
static void synurang_wasm_wakeup(uint32_t token) { (void)token; }
#endif
static void wakeup(void* token) { synurang_wasm_wakeup((uint32_t)(uintptr_t)token); }

EXPORT(synurang_module_abi_version) uint32_t synurang_module_abi_version(void) {
    return SYNURANG_CALL_ABI_VERSION;
}

EXPORT(synurang_module_create) SynurangInstance* synurang_module_create(uint32_t capacity, uint32_t token) {
    SynurangRuntimeOptions options = SYNURANG_RUNTIME_OPTIONS_INIT;
    const SynurangApi* api = Synurang_GetApi();
    if (api == NULL || api->abi_version != SYNURANG_CALL_ABI_VERSION ||
        api->struct_size != sizeof(SynurangApi)) return NULL;
    options.execution_mode = SYNURANG_EXECUTION_MANUAL;
    options.wakeup = wakeup;
    options.wakeup_user_data = (void*)(uintptr_t)token;
    if (capacity != 0u) {
        options.inbound_queue_capacity = capacity;
        options.outbound_queue_capacity = capacity;
    }
    return api->create(&options);
}
EXPORT(synurang_module_destroy) int synurang_module_destroy(SynurangInstance* instance) {
    return Synurang_GetApi()->destroy(instance);
}
EXPORT(synurang_module_open) uint64_t synurang_module_open(SynurangInstance* instance,
    const char* method, uint32_t request_stream, uint32_t response_stream,
    double timeout_ms) {
    SynurangCallOptions options = {
        sizeof(SynurangCallOptions), request_stream, response_stream, 0u, UINT64_MAX
    };
    if (timeout_ms >= 0.0 && isfinite(timeout_ms) && timeout_ms <= 9007199254740991.0)
        options.timeout_ms = (uint64_t)timeout_ms;
    else if (timeout_ms != -1.0) return 0u;
    return Synurang_GetApi()->open(instance, method, &options);
}
EXPORT(synurang_module_send) int synurang_module_send(SynurangInstance* instance, uint64_t call,
    const uint8_t* data, uint32_t size) {
    return Synurang_GetApi()->send(instance, call, data, size);
}
EXPORT(synurang_module_half_close) int synurang_module_half_close(SynurangInstance* instance, uint64_t call) {
    return Synurang_GetApi()->half_close(instance, call);
}
/* This result uses the native SynurangReadResult layout. The wasm32 host knows
 * the 16-byte layout; other targets use their FFI struct layout. */
EXPORT(synurang_module_receive) int synurang_module_receive(SynurangInstance* instance, uint64_t call,
    SynurangReadResult* result) {
    return Synurang_GetApi()->receive(instance, call, result);
}
EXPORT(synurang_module_cancel) int synurang_module_cancel(SynurangInstance* instance, uint64_t call, int32_t code) {
    return Synurang_GetApi()->cancel(instance, call, code);
}
EXPORT(synurang_module_release) void synurang_module_release(SynurangInstance* instance, uint64_t call) {
    Synurang_GetApi()->release(instance, call);
}
EXPORT(synurang_module_poll) uint32_t synurang_module_poll(SynurangInstance* instance, uint32_t budget) {
    return Synurang_GetApi()->poll(instance, budget);
}
EXPORT(synurang_module_has_work) int synurang_module_has_work(SynurangInstance* instance) {
    return Synurang_GetApi()->has_work(instance);
}
EXPORT(synurang_module_free) void synurang_module_free(void* data) {
    Synurang_GetApi()->free_buffer(data);
}
EXPORT(synurang_module_alloc) void* synurang_module_alloc(uint32_t size) {
    return malloc(size == 0u ? 1u : size);
}
