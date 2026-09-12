#ifndef SYNURANG_MODULE_HOST_H_
#define SYNURANG_MODULE_HOST_H_
#include "call.h"
#ifdef __cplusplus
extern "C" {
#endif
/* Optional portable loader for native language bindings. An application may
 * also load Synurang_GetApi directly without depending on this library. */
typedef struct SynurangHost SynurangHost;
SYNURANG_C_RUNTIME_API SynurangHost* synurang_host_load(const char* path,
    const char* symbol, const SynurangRuntimeOptions* options);
SYNURANG_C_RUNTIME_API SynurangHost* synurang_host_linked(const SynurangApi* api,
    const SynurangRuntimeOptions* options);
SYNURANG_C_RUNTIME_API const char* synurang_host_error(void);
/* Install/replace the host's notification sink. Calls wakeup once on install
 * so notifications from create cannot be lost. The sink only schedules work. */
SYNURANG_C_RUNTIME_API void synurang_host_set_wakeup(SynurangHost*, SynurangWakeupFn, void*);
SYNURANG_C_RUNTIME_API uint64_t synurang_host_open(SynurangHost*, const char*, const SynurangCallOptions*);
SYNURANG_C_RUNTIME_API int synurang_host_send(SynurangHost*, uint64_t, const uint8_t*, uint32_t);
SYNURANG_C_RUNTIME_API int synurang_host_half_close(SynurangHost*, uint64_t);
SYNURANG_C_RUNTIME_API int synurang_host_receive(SynurangHost*, uint64_t, SynurangReadResult*);
SYNURANG_C_RUNTIME_API int synurang_host_cancel(SynurangHost*, uint64_t, int32_t);
SYNURANG_C_RUNTIME_API void synurang_host_release(SynurangHost*, uint64_t);
SYNURANG_C_RUNTIME_API void synurang_host_free(SynurangHost*, void*);
SYNURANG_C_RUNTIME_API uint32_t synurang_host_poll(SynurangHost*, uint32_t);
SYNURANG_C_RUNTIME_API int synurang_host_has_work(SynurangHost*);
/* PENDING keeps the module loaded. Continue polling and retry. OK frees host. */
SYNURANG_C_RUNTIME_API int synurang_host_destroy(SynurangHost*);
#ifdef __cplusplus
}
#endif
#endif
