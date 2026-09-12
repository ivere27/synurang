//go:build cgo && !js

#define _GNU_SOURCE
#include "_cgo_export.h"
#if defined(_WIN32)
#include <windows.h>
#else
#include <dlfcn.h>
#include <pthread.h>
#endif
static SynurangInstance* create(const SynurangRuntimeOptions* options) { return SynurangGo_Create((SynurangRuntimeOptions*)options); }
static int destroy(SynurangInstance* instance) { return SynurangGo_Destroy(instance); }
static uint64_t open_call(SynurangInstance* instance, const char* path, const SynurangCallOptions* options) {
    return SynurangGo_Open(instance, (char*)path, (SynurangCallOptions*)options);
}
static int send_call(SynurangInstance* instance, uint64_t call, const uint8_t* data, uint32_t size) { return SynurangGo_Send(instance, call, (uint8_t*)data, size); }
static int half_close(SynurangInstance* instance, uint64_t call) { return SynurangGo_HalfClose(instance, call); }
static int receive_call(SynurangInstance* instance, uint64_t call, SynurangReadResult* result) { return SynurangGo_Receive(instance, call, result); }
static int cancel_call(SynurangInstance* instance, uint64_t call, int32_t code) { return SynurangGo_Cancel(instance, call, code); }
static void release_call(SynurangInstance* instance, uint64_t call) { SynurangGo_Release(instance, call); }
static uint32_t poll_instance(SynurangInstance* instance, uint32_t budget) { return SynurangGo_Poll(instance, budget); }
static int has_work(SynurangInstance* instance) { (void)instance; return 0; }
SYNURANG_C_RUNTIME_API const SynurangApi* Synurang_GetApi(void);

/* A Go DSO contains a process-wide Go runtime with its own threads. Instances
 * are disposable, but unmapping that runtime is unsafe even after handlers
 * stop. Pin once at the OS loader so Node worker teardown is also safe. */
#if !defined(_WIN32)
static pthread_once_t pinned = PTHREAD_ONCE_INIT;
static void pin_runtime(void) {
    Dl_info info;
    if (dladdr((const void*)&Synurang_GetApi, &info) != 0) {
#ifdef RTLD_NODELETE
        (void)dlopen(info.dli_fname, RTLD_NOW | RTLD_NODELETE);
#else
        (void)dlopen(info.dli_fname, RTLD_NOW);
#endif
    }
}
#endif
const SynurangApi* Synurang_GetApi(void) {
    static const SynurangApi api = {
        SYNURANG_CALL_ABI_VERSION, sizeof(SynurangApi), create, destroy, open_call,
        send_call, half_close, receive_call, cancel_call, release_call,
        poll_instance, has_work, free
    };
#if defined(_WIN32)
    HMODULE module;
    GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_PIN | GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,
                      (LPCWSTR)&Synurang_GetApi, &module);
#else
    pthread_once(&pinned, pin_runtime);
#endif
    return &api;
}
