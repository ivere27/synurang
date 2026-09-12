#include "synurang/module_host.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#ifdef _WIN32
#include <windows.h>
#define THREAD_LOCAL __declspec(thread)
#else
#include <dlfcn.h>
#include <pthread.h>
#define THREAD_LOCAL _Thread_local
#endif
struct SynurangHost {
    const SynurangApi* api;
    SynurangInstance* instance;
    void* library;
    SynurangWakeupFn wakeup;
    void* wakeup_data;
#ifdef _WIN32
    CRITICAL_SECTION wakeup_mutex;
#else
    pthread_mutex_t wakeup_mutex;
#endif
};
static void wakeup_lock(SynurangHost* host) {
#ifdef _WIN32
    EnterCriticalSection(&host->wakeup_mutex);
#else
    pthread_mutex_lock(&host->wakeup_mutex);
#endif
}
static void wakeup_unlock(SynurangHost* host) {
#ifdef _WIN32
    LeaveCriticalSection(&host->wakeup_mutex);
#else
    pthread_mutex_unlock(&host->wakeup_mutex);
#endif
}
static void wakeup_destroy(SynurangHost* host) {
#ifdef _WIN32
    DeleteCriticalSection(&host->wakeup_mutex);
#else
    pthread_mutex_destroy(&host->wakeup_mutex);
#endif
}
static void host_wakeup(void* data) {
    SynurangHost* host = (SynurangHost*)data;
    wakeup_lock(host);
    if (host->wakeup != NULL) host->wakeup(host->wakeup_data);
    wakeup_unlock(host);
}
void synurang_host_set_wakeup(SynurangHost* host, SynurangWakeupFn wakeup, void* data) {
    wakeup_lock(host);
    host->wakeup = wakeup;
    host->wakeup_data = data;
    if (wakeup != NULL) wakeup(data);
    wakeup_unlock(host);
}
static THREAD_LOCAL char last_error[512];
static void set_error(const char* message) { snprintf(last_error, sizeof(last_error), "%s", message); }
const char* synurang_host_error(void) { return last_error; }
static void unload(void* library) {
    if (library == NULL) return;
#ifdef _WIN32
    FreeLibrary((HMODULE)library);
#else
    dlclose(library);
#endif
}
SynurangHost* synurang_host_linked(const SynurangApi* api, const SynurangRuntimeOptions* options) {
    SynurangHost* host;
    SynurangRuntimeOptions defaults = SYNURANG_RUNTIME_OPTIONS_INIT;
    defaults.execution_mode = SYNURANG_EXECUTION_MANUAL;
    defaults.worker_count = 0;
    if (options != NULL) {
        if (options->struct_size != sizeof(*options)) {
            set_error("Unsupported runtime options size"); return NULL;
        }
        defaults = *options;
    }
    if (api == NULL || api->abi_version != SYNURANG_CALL_ABI_VERSION || api->struct_size != sizeof(*api)) {
        set_error("Unsupported Synurang module ABI"); return NULL;
    }
    if (api->create == NULL || api->destroy == NULL || api->open == NULL || api->send == NULL ||
        api->half_close == NULL || api->receive == NULL || api->cancel == NULL || api->release == NULL ||
        api->poll == NULL || api->has_work == NULL || api->free_buffer == NULL) {
        set_error("Incomplete Synurang module API"); return NULL;
    }
    host = (SynurangHost*)calloc(1u, sizeof(*host));
    if (host == NULL) { set_error("Out of memory"); return NULL; }
    host->api = api;
#ifdef _WIN32
    InitializeCriticalSection(&host->wakeup_mutex);
#else
    pthread_mutex_init(&host->wakeup_mutex, NULL);
#endif
    host->wakeup = defaults.wakeup;
    host->wakeup_data = defaults.wakeup_user_data;
    defaults.wakeup = host_wakeup;
    defaults.wakeup_user_data = host;
    host->instance = api->create(&defaults);
    if (host->instance == NULL) { wakeup_destroy(host); free(host); set_error("Module could not create an instance"); return NULL; }
    return host;
}
SynurangHost* synurang_host_load(const char* path, const char* symbol, const SynurangRuntimeOptions* options) {
    void* library;
    SynurangGetApiFn get_api;
    SynurangHost* host;
    if (path == NULL) { set_error("Missing module path"); return NULL; }
    if (symbol == NULL) symbol = "Synurang_GetApi";
#ifdef _WIN32
    {
        int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, NULL, 0);
        wchar_t* wide;
        if (length == 0) { set_error("Invalid UTF-8 module path"); return NULL; }
        wide = (wchar_t*)malloc((size_t)length * sizeof(wchar_t));
        if (wide == NULL) { set_error("Out of memory"); return NULL; }
        MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, wide, length);
        library = LoadLibraryW(wide);
        free(wide);
    }
    if (library == NULL) { set_error("Could not load module DLL"); return NULL; }
    get_api = (SynurangGetApiFn)GetProcAddress((HMODULE)library, symbol);
#else
    library = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (library == NULL) { set_error(dlerror()); return NULL; }
    {
        void* address = dlsym(library, symbol);
        /* POSIX specifies conversion of dlsym's result to a function pointer. */
        memcpy(&get_api, &address, sizeof(get_api));
    }
#endif
    if (get_api == NULL) { unload(library); set_error("Missing module API accessor"); return NULL; }
    host = synurang_host_linked(get_api(), options);
    if (host == NULL) { unload(library); return NULL; }
    host->library = library;
    return host;
}
uint64_t synurang_host_open(SynurangHost* host, const char* path, const SynurangCallOptions* options) {
    return host == NULL ? 0 : host->api->open(host->instance, path, options);
}
int synurang_host_send(SynurangHost* host, uint64_t call, const uint8_t* data, uint32_t size) {
    return host == NULL ? SYNURANG_CLOSED : host->api->send(host->instance, call, data, size);
}
int synurang_host_half_close(SynurangHost* host, uint64_t call) {
    return host == NULL ? SYNURANG_CLOSED : host->api->half_close(host->instance, call);
}
int synurang_host_receive(SynurangHost* host, uint64_t call, SynurangReadResult* result) {
    if (result != NULL) memset(result, 0, sizeof(*result));
    return host == NULL ? SYNURANG_CLOSED : host->api->receive(host->instance, call, result);
}
int synurang_host_cancel(SynurangHost* host, uint64_t call, int32_t code) {
    return host == NULL ? SYNURANG_CLOSED : host->api->cancel(host->instance, call, code);
}
void synurang_host_release(SynurangHost* host, uint64_t call) {
    if (host != NULL) host->api->release(host->instance, call);
}
void synurang_host_free(SynurangHost* host, void* data) {
    if (host != NULL) host->api->free_buffer(data);
}
uint32_t synurang_host_poll(SynurangHost* host, uint32_t budget) {
    return host == NULL ? 0 : host->api->poll(host->instance, budget);
}
int synurang_host_has_work(SynurangHost* host) {
    return host != NULL && host->api->has_work(host->instance);
}
int synurang_host_destroy(SynurangHost* host) {
    int status;
    if (host == NULL) return 0;
    status = host->api->destroy(host->instance);
    if (status == 0) { unload(host->library); wakeup_destroy(host); free(host); }
    return status;
}
