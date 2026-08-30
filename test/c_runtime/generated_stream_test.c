#include "api/c_ffi/service_ffi.h"

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define CHECK(condition)                                                     \
    do {                                                                     \
        if (!(condition)) {                                                  \
            fprintf(stderr, "CHECK failed at %s:%d: %s\n",                 \
                    __FILE__, __LINE__, #condition);                         \
            return 1;                                                        \
        }                                                                    \
    } while (0)

typedef struct GeneratedContext {
    int opens;
    int messages;
    int half_closes;
    int destroys;
    SynurangStatus send_status;
} GeneratedContext;

static void* bidi_open(SynurangStream* stream, void* service_user_data) {
    GeneratedContext* context = (GeneratedContext*)service_user_data;
    (void)stream;
    ++context->opens;
    return context;
}

static void bidi_message(SynurangStream* stream,
                         const CffiTestV1Request* request,
                         void* stream_user_data) {
    GeneratedContext* context = (GeneratedContext*)stream_user_data;
    CffiTestV1Response response;
    ++context->messages;
    cffi_test_v1_response_init(&response);
    if (synurang_lite_bytes_assign(
            response._allocator,
            &response.field_value,
            request->field_value.data,
            request->field_value.len) != SYNURANG_LITE_OK) {
        context->send_status = SYNURANG_OUT_OF_MEMORY;
    } else {
        context->send_status = test_bidi_stream_send(stream, &response);
    }
    cffi_test_v1_response_free(&response);
}

static void bidi_half_close(SynurangStream* stream, void* stream_user_data) {
    GeneratedContext* context = (GeneratedContext*)stream_user_data;
    ++context->half_closes;
    (void)test_bidi_stream_finish(stream);
}

static void bidi_destroy(void* stream_user_data) {
    GeneratedContext* context = (GeneratedContext*)stream_user_data;
    ++context->destroys;
}

/* A stream can be closed before the runtime ever dispatches its open event.
 * on_open then never runs, so there is no per-stream state -- and the adapter
 * must not hand the *service* state to on_cancel/on_destroy in its place, or
 * a handler that frees what on_open allocated would free the service. */
static char SERVICE_STATE[] = "service-state";
static int g_unopened_opens;
static int g_unopened_cancels;
static int g_unopened_destroys;
static void* g_unopened_cancel_arg = SERVICE_STATE;
static void* g_unopened_destroy_arg = SERVICE_STATE;

static void* unopened_open(SynurangStream* stream, void* service_user_data) {
    (void)stream;
    (void)service_user_data;
    ++g_unopened_opens;
    return SERVICE_STATE;
}

static void unopened_cancel(SynurangStream* stream, void* stream_user_data) {
    (void)stream;
    ++g_unopened_cancels;
    g_unopened_cancel_arg = stream_user_data;
}

static void unopened_destroy(void* stream_user_data) {
    ++g_unopened_destroys;
    g_unopened_destroy_arg = stream_user_data;
}

static int check_cancel_before_open(SynurangRuntime* runtime) {
    TestServiceHandlers handlers = {0};
    uint64_t handle;

    CHECK(test_unregister() == 0);
    handlers.bidi_stream.on_open = unopened_open;
    handlers.bidi_stream.on_cancel = unopened_cancel;
    handlers.bidi_stream.on_destroy = unopened_destroy;
    CHECK(test_register_with_runtime(runtime, &handlers, SERVICE_STATE) == 0);

    handle = Synurang_Stream_TestService_Open(
        "/cffi.test.v1.TestService/BidiStream");
    CHECK(handle != 0u);
    /* Closed while the open event is still queued. */
    Synurang_Stream_Close(handle);
    (void)synurang_runtime_poll(runtime, 0u);

    CHECK(g_unopened_opens == 0);
    CHECK(g_unopened_cancels == 1);
    CHECK(g_unopened_destroys == 1);
    CHECK(g_unopened_cancel_arg == NULL);
    CHECK(g_unopened_destroy_arg == NULL);
    return 0;
}

int main(void) {
    SynurangRuntimeOptions options = SYNURANG_RUNTIME_OPTIONS_INIT;
    SynurangRuntime* runtime;
    TestServiceHandlers handlers = {0};
    GeneratedContext context = {0};
    CffiTestV1Request request;
    CffiTestV1Response response;
    uint8_t* request_data = NULL;
    size_t request_len = 0u;
    const SynurangLiteAllocator* allocator;
    uint64_t handle;
    int response_len = -1;
    int status = SYNURANG_INTERNAL;
    char* response_data;

    options.execution_mode = SYNURANG_EXECUTION_MANUAL;
    runtime = synurang_runtime_create(&options);
    CHECK(runtime != NULL);

    context.send_status = SYNURANG_INTERNAL;
    handlers.bidi_stream.on_open = bidi_open;
    handlers.bidi_stream.on_message = bidi_message;
    handlers.bidi_stream.on_half_close = bidi_half_close;
    handlers.bidi_stream.on_destroy = bidi_destroy;
    CHECK(test_register_with_runtime(runtime, &handlers, &context) == 0);

    handle = Synurang_Stream_TestService_Open(
        "/cffi.test.v1.TestService/BidiStream");
    CHECK(handle != 0u);
    CHECK(synurang_runtime_poll(runtime, 0u) >= 1u);
    CHECK(context.opens == 1);

    response_data = Synurang_Stream_TryRecv(
        handle, &response_len, &status);
    CHECK(response_data == NULL);
    CHECK(status == SYNURANG_PENDING);

    cffi_test_v1_request_init(&request);
    CHECK(synurang_lite_bytes_assign(
              request._allocator,
              &request.field_value,
              "typed echo",
              10u) == SYNURANG_LITE_OK);
    CHECK(cffi_test_v1_request_encode(
              &request, &request_data, &request_len) == SYNURANG_LITE_OK);
    CHECK(request_len <= (size_t)INT32_MAX);
    CHECK(Synurang_Stream_TrySend(
              handle, (const char*)request_data, (int)request_len) ==
          SYNURANG_OK);
    allocator = request._allocator;
    allocator->deallocate(allocator->context, request_data);
    request_data = NULL;
    cffi_test_v1_request_free(&request);

    CHECK(synurang_runtime_poll(runtime, 0u) >= 1u);
    CHECK(context.messages == 1);
    CHECK(context.send_status == SYNURANG_OK);

    response_data = Synurang_Stream_TryRecv(
        handle, &response_len, &status);
    CHECK(status == SYNURANG_OK);
    CHECK(response_data != NULL);
    cffi_test_v1_response_init(&response);
    CHECK(cffi_test_v1_response_decode(
              &response,
              (const uint8_t*)response_data,
              (size_t)response_len) == SYNURANG_LITE_OK);
    CHECK(response.field_value.len == 10u);
    CHECK(memcmp(response.field_value.data, "typed echo", 10u) == 0);
    cffi_test_v1_response_free(&response);
    Synurang_Free(response_data);

    Synurang_Stream_CloseSend(handle);
    CHECK(synurang_runtime_poll(runtime, 0u) >= 1u);
    CHECK(context.half_closes == 1);
    response_data = Synurang_Stream_TryRecv(
        handle, &response_len, &status);
    CHECK(response_data == NULL);
    CHECK(status == SYNURANG_EOF);
    Synurang_Stream_Close(handle);

    CHECK(context.destroys == 1);
    CHECK(check_cancel_before_open(runtime) == 0);

    synurang_runtime_destroy(runtime);
    CHECK(test_unregister() == 0);
    puts("Generated C typed streaming test passed.");
    return 0;
}
