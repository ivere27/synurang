/* Generic Node-API adapter for statically linked Synurang modules. Compile
 * this file into a .node addon and link the provider's .a (PIC on ELF).
 * The provider supplies Synurang_GetApi; no provider-specific JS is required. */
#include <node_api.h>
#include <uv.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include "synurang/call.h"
#ifdef SYNURANG_NODE_DYNAMIC
#include "synurang/module_host.h"
#endif

extern const SynurangApi* Synurang_GetApi(void);
typedef struct LinkedInstance {
#ifdef SYNURANG_NODE_DYNAMIC
    SynurangHost* instance;
#else
    const SynurangApi* api;
    SynurangInstance* instance;
#endif
    uv_loop_t* loop;
    uv_async_t notification;
    napi_env env;
    napi_ref callback;
    napi_async_cleanup_hook_handle cleanup_hook;
    unsigned references;
    int retiring;
} LinkedInstance;

#ifdef SYNURANG_NODE_DYNAMIC
#define ENTRY(ctx, name, ...) synurang_host_##name((ctx)->instance, __VA_ARGS__)
#define DESTROY(ctx) synurang_host_destroy((ctx)->instance)
#define HAS_WORK(ctx) synurang_host_has_work((ctx)->instance)
#define FREE_BUFFER(ctx, data) synurang_host_free((ctx)->instance, (data))
#else
#define ENTRY(ctx, name, ...) (ctx)->api->name((ctx)->instance, __VA_ARGS__)
#define DESTROY(ctx) (ctx)->api->destroy((ctx)->instance)
#define HAS_WORK(ctx) (ctx)->api->has_work((ctx)->instance)
#define FREE_BUFFER(ctx, data) (ctx)->api->free_buffer(data)
#endif

static void release_context(LinkedInstance* context) {
    if (--context->references == 0) free(context);
}
static void notification_closed(uv_handle_t* handle) {
    LinkedInstance* context = (LinkedInstance*)handle->data;
    if (context->cleanup_hook != NULL) {
        napi_remove_async_cleanup_hook(context->cleanup_hook);
        context->cleanup_hook = NULL;
    }
    release_context(context);
}
static void close_notification(LinkedInstance* context) {
    if (uv_is_closing((uv_handle_t*)&context->notification)) return;
    if (context->env != NULL && context->callback != NULL) napi_delete_reference(context->env, context->callback);
    context->callback = NULL;
    uv_close((uv_handle_t*)&context->notification, notification_closed);
}
static void wakeup(void* data) {
    LinkedInstance* context = (LinkedInstance*)data;
    /* Any producer thread; libuv coalesces sends and never waits for JS. */
    uv_async_send(&context->notification);
}
static void notification_ready(uv_async_t* handle) {
    LinkedInstance* context = (LinkedInstance*)handle->data;
    if (context->instance == NULL) return;
    if (context->retiring) {
        ENTRY(context, poll, 64);
        if (DESTROY(context) == 0) {
            context->instance = NULL;
            close_notification(context);
        } else if (HAS_WORK(context)) wakeup(context);
    } else if (context->env != NULL && context->callback != NULL) {
        napi_handle_scope scope;
        napi_value callback, receiver, result;
        napi_open_handle_scope(context->env, &scope);
        napi_get_reference_value(context->env, context->callback, &callback);
        napi_get_global(context->env, &receiver);
        napi_make_callback(context->env, NULL, receiver, callback, 0, NULL, &result);
        napi_close_handle_scope(context->env, scope);
    }
}
static void cleanup_environment(napi_async_cleanup_hook_handle hook, void* data) {
    LinkedInstance* context = (LinkedInstance*)data;
    (void)hook;
    context->env = NULL;
    context->retiring = 1;
    if (context->instance == NULL) close_notification(context);
    else notification_ready(&context->notification);
}

static napi_value failure(napi_env env, const char* message) {
    napi_throw_error(env, NULL, message);
    return NULL;
}
static napi_value number(napi_env env, int32_t value) {
    napi_value result;
    napi_create_int32(env, value, &result);
    return result;
}
static napi_value undefined_value(napi_env env) {
    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}
static LinkedInstance* arguments(napi_env env, napi_callback_info info, size_t count, napi_value* args) {
    napi_value self;
    size_t actual = count;
    LinkedInstance* context = NULL;
    if (napi_get_cb_info(env, info, &actual, args, &self, NULL) != napi_ok || actual < count ||
        napi_unwrap(env, self, (void**)&context) != napi_ok || context == NULL || context->instance == NULL) {
        failure(env, "Invalid or closed linked instance");
        return NULL;
    }
    return context;
}
static int call_id(napi_env env, napi_value value, uint64_t* id) {
    bool lossless;
    if (napi_get_value_bigint_uint64(env, value, id, &lossless) != napi_ok || !lossless) {
        failure(env, "Call handle must be a uint64 BigInt");
        return 0;
    }
    return 1;
}
static napi_value open_call(napi_env env, napi_callback_info info) {
    napi_value args[2], path_value, flag;
    LinkedInstance* context = arguments(env, info, 1, args);
    SynurangCallOptions options = {sizeof(SynurangCallOptions), 0, 0, 0, UINT64_MAX};
    size_t size;
    char* path;
    bool boolean;
    uint64_t id;
    napi_value result, self;
    size_t count = 2;
    if (context == NULL) return NULL;
    napi_get_cb_info(env, info, &count, args, &self, NULL);
    if (napi_get_named_property(env, args[0], "path", &path_value) != napi_ok ||
        napi_get_value_string_utf8(env, path_value, NULL, 0, &size) != napi_ok)
        return failure(env, "Method must have a path");
    path = (char*)malloc(size + 1u);
    if (path == NULL) return failure(env, "Out of memory");
    napi_get_value_string_utf8(env, path_value, path, size + 1u, &size);
    if (strlen(path) != size) { free(path); return failure(env, "NUL in method path"); }
    napi_get_named_property(env, args[0], "requestStream", &flag);
    if (napi_get_value_bool(env, flag, &boolean) != napi_ok) { free(path); return failure(env, "Invalid requestStream"); }
    options.request_stream = boolean;
    napi_get_named_property(env, args[0], "responseStream", &flag);
    if (napi_get_value_bool(env, flag, &boolean) != napi_ok) { free(path); return failure(env, "Invalid responseStream"); }
    options.response_stream = boolean;
    if (count > 1) {
        napi_valuetype type;
        napi_typeof(env, args[1], &type);
        if (type != napi_undefined) {
            double timeout;
            if (napi_get_value_double(env, args[1], &timeout) != napi_ok || !isfinite(timeout) ||
                timeout < 0 || timeout > 9007199254740991.0 || floor(timeout) != timeout) {
                free(path); return failure(env, "Invalid timeout");
            }
            options.timeout_ms = (uint64_t)timeout;
        }
    }
    id = ENTRY(context, open, path, &options);
    free(path);
    napi_create_bigint_uint64(env, id, &result);
    return result;
}
static napi_value send_call(napi_env env, napi_callback_info info) {
    napi_value args[2], buffer;
    LinkedInstance* context = arguments(env, info, 2, args);
    uint64_t id;
    napi_typedarray_type type;
    size_t size, offset;
    void* data;
    if (context == NULL || !call_id(env, args[0], &id)) return NULL;
    if (napi_get_typedarray_info(env, args[1], &type, &size, &data, &buffer, &offset) != napi_ok ||
        type != napi_uint8_array || size > INT32_MAX) return failure(env, "Expected Uint8Array");
    return number(env, ENTRY(context, send, id, data, (uint32_t)size));
}
static napi_value receive_call(napi_env env, napi_callback_info info) {
    napi_value args[1], result, kind, data;
    LinkedInstance* context = arguments(env, info, 1, args);
    uint64_t id;
    SynurangReadResult read = {0};
    int status;
    if (context == NULL || !call_id(env, args[0], &id)) return NULL;
    status = ENTRY(context, receive, id, &read);
    if (status != 0 || read.kind > 2) {
        FREE_BUFFER(context, read.data);
        return failure(env, "Module receive failed");
    }
    napi_create_object(env, &result);
    napi_create_string_utf8(env, read.kind == 0 ? "pending" : read.kind == 1 ? "message" : "finished", NAPI_AUTO_LENGTH, &kind);
    napi_set_named_property(env, result, "kind", kind);
    if (read.kind != 0) {
        napi_create_buffer_copy(env, read.size, read.data, NULL, &data);
        napi_set_named_property(env, result, "data", data);
        napi_set_named_property(env, result, "code", number(env, read.code));
    }
    FREE_BUFFER(context, read.data);
    return result;
}
static napi_value half_close(napi_env env, napi_callback_info info) {
    napi_value args[1];
    LinkedInstance* context = arguments(env, info, 1, args);
    uint64_t id;
    if (context == NULL || !call_id(env, args[0], &id)) return NULL;
    return number(env, ENTRY(context, half_close, id));
}
static napi_value cancel_call(napi_env env, napi_callback_info info) {
    napi_value args[2];
    LinkedInstance* context = arguments(env, info, 2, args);
    uint64_t id;
    int32_t code;
    if (context == NULL || !call_id(env, args[0], &id)) return NULL;
    if (napi_get_value_int32(env, args[1], &code) != napi_ok) return failure(env, "Invalid status code");
    return number(env, ENTRY(context, cancel, id, code));
}
static napi_value release_call(napi_env env, napi_callback_info info) {
    napi_value args[1];
    LinkedInstance* context = arguments(env, info, 1, args);
    uint64_t id;
    if (context == NULL || !call_id(env, args[0], &id)) return NULL;
    ENTRY(context, release, id);
    return undefined_value(env);
}
static napi_value poll_instance(napi_env env, napi_callback_info info) {
    napi_value args[1];
    LinkedInstance* context = arguments(env, info, 1, args);
    uint32_t budget;
    if (context == NULL) return NULL;
    if (napi_get_value_uint32(env, args[0], &budget) != napi_ok) return failure(env, "Invalid budget");
    return number(env, (int32_t)ENTRY(context, poll, budget));
}
static napi_value has_work(napi_env env, napi_callback_info info) {
    LinkedInstance* context = arguments(env, info, 0, NULL);
    napi_value result;
    if (context == NULL) return NULL;
    napi_get_boolean(env, HAS_WORK(context) != 0, &result);
    return result;
}
static napi_value destroy_instance(napi_env env, napi_callback_info info) {
    LinkedInstance* context = arguments(env, info, 0, NULL);
    int status;
    if (context == NULL) return NULL;
    status = DESTROY(context);
    if (status == 0) { context->instance = NULL; close_notification(context); }
    return number(env, status);
}
static void finalize(napi_env env, void* data, void* hint) {
    LinkedInstance* context = (LinkedInstance*)data;
    (void)env; (void)hint;
    context->retiring = 1;
    if (context->instance == NULL) close_notification(context);
    else wakeup(context);
    release_context(context);
}
static napi_value set_wakeup(napi_env env, napi_callback_info info) {
    napi_value args[1];
    LinkedInstance* context = arguments(env, info, 1, args);
    if (context == NULL) return NULL;
    if (context->callback != NULL) napi_delete_reference(env, context->callback);
    napi_create_reference(env, args[0], 1, &context->callback);
    wakeup(context);
    return undefined_value(env);
}
static napi_value create_instance(napi_env env, napi_callback_info info) {
    napi_value args[3], object;
    size_t count = 3;
    uint32_t capacity = 16;
    SynurangRuntimeOptions options = SYNURANG_RUNTIME_OPTIONS_INIT;
    LinkedInstance* context;
#ifndef SYNURANG_NODE_DYNAMIC
    const SynurangApi* api = Synurang_GetApi();
#endif
    const napi_property_descriptor methods[] = {
        {"setWakeup", NULL, set_wakeup, NULL, NULL, NULL, napi_default, NULL},
        {"open", NULL, open_call, NULL, NULL, NULL, napi_default, NULL},
        {"send", NULL, send_call, NULL, NULL, NULL, napi_default, NULL},
        {"halfClose", NULL, half_close, NULL, NULL, NULL, napi_default, NULL},
        {"receive", NULL, receive_call, NULL, NULL, NULL, napi_default, NULL},
        {"cancel", NULL, cancel_call, NULL, NULL, NULL, napi_default, NULL},
        {"release", NULL, release_call, NULL, NULL, NULL, napi_default, NULL},
        {"poll", NULL, poll_instance, NULL, NULL, NULL, napi_default, NULL},
        {"hasWork", NULL, has_work, NULL, NULL, NULL, napi_default, NULL},
        {"destroy", NULL, destroy_instance, NULL, NULL, NULL, napi_default, NULL}
    };
    napi_get_cb_info(env, info, &count, args, NULL, NULL);
    if (count && napi_get_value_uint32(env, args[0], &capacity) != napi_ok) return failure(env, "Invalid capacity");
    if (capacity == 0 || capacity > 65536) return failure(env, "Invalid capacity");
#ifndef SYNURANG_NODE_DYNAMIC
    if (api == NULL || api->abi_version != 1 || api->struct_size != sizeof(*api)) return failure(env, "Unsupported module ABI");
#endif
    context = (LinkedInstance*)calloc(1u, sizeof(*context));
    if (context == NULL) return failure(env, "Out of memory");
    context->env = env;
    context->references = 1; /* libuv handle; JS ownership is added after create. */
    napi_get_uv_event_loop(env, &context->loop);
    if (uv_async_init(context->loop, &context->notification, notification_ready) != 0) {
        free(context); return failure(env, "Could not create notification handle");
    }
    context->notification.data = context;
#ifndef SYNURANG_NODE_DYNAMIC
    context->api = api;
#endif
    options.execution_mode = SYNURANG_EXECUTION_MANUAL;
    options.inbound_queue_capacity = options.outbound_queue_capacity = capacity;
    options.wakeup = wakeup;
    options.wakeup_user_data = context;
#ifdef SYNURANG_NODE_DYNAMIC
    {
        char* strings[2] = {NULL, NULL};
        size_t index, length;
        if (count != 3) { close_notification(context); return failure(env, "Expected capacity, path and symbol"); }
        for (index = 0; index < 2; ++index) {
            if (napi_get_value_string_utf8(env, args[index + 1], NULL, 0, &length) != napi_ok) break;
            strings[index] = malloc(length + 1);
            if (strings[index] == NULL) break;
            napi_get_value_string_utf8(env, args[index + 1], strings[index], length + 1, &length);
            if (strlen(strings[index]) != length) break;
        }
        if (index == 2) context->instance = synurang_host_load(strings[0], strings[1], &options);
        free(strings[0]); free(strings[1]);
    }
#else
    context->instance = api->create(&options);
#endif
    if (context->instance == NULL) { close_notification(context); return failure(env, "Module could not create an instance"); }
    napi_add_async_cleanup_hook(env, cleanup_environment, context, &context->cleanup_hook);
    ++context->references;
    napi_create_object(env, &object);
    napi_wrap(env, object, context, finalize, NULL, NULL);
    napi_define_properties(env, object, sizeof(methods) / sizeof(methods[0]), methods);
    return object;
}
static napi_value initialize(napi_env env, napi_value exports) {
    napi_value create;
    napi_create_function(env, "createInstance", NAPI_AUTO_LENGTH, create_instance, NULL, &create);
    napi_set_named_property(env, exports, "createInstance", create);
    return exports;
}
NAPI_MODULE(NODE_GYP_MODULE_NAME, initialize)
