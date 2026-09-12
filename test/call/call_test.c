#include "synurang/call.h"
#include "conformance_ffi.h"
#include <assert.h>
#include <stdio.h>
extern const SynurangApi* Synurang_GetApi(void);
static SynurangStream* retained;
static int destroyed;
static void retain_open(SynurangStream* stream, void* data) {
    (void)data;
    retained = synurang_stream_retain(stream);
}
static void count_destroy(void* data) { (void)data; ++destroyed; }
static uint64_t open_retained(SynurangRuntime* runtime,
    const SynurangCallOptions* options, void* data) {
    SynurangStreamCallbacks callbacks = SYNURANG_STREAM_CALLBACKS_INIT;
    (void)options; (void)data;
    callbacks.on_open = retain_open;
    return synurang_stream_open(runtime, &callbacks, NULL);
}
static SynurangReadResult read_call(const SynurangApi* api,
    SynurangInstance* instance, uint64_t call) {
    SynurangReadResult result;
    assert(api->receive(instance, call, &result) == 0);
    return result;
}
static void close_instance(const SynurangApi* api, SynurangInstance* instance) {
    unsigned limit = 1000;
    while (api->destroy(instance) == SYNURANG_PENDING) {
        assert(limit-- != 0);
        api->poll(instance, 64);
    }
}
static void unimplemented_methods(const SynurangApi* api,
    const SynurangRuntimeOptions* options) {
    const CallsHandlers handlers = {0};
    const char* methods[] = {"/synurang.test.Calls/Client", "/synurang.test.Calls/Bidi"};
    for (unsigned method = 0; method < 2; ++method) {
        for (int half_close = 0; half_close < 2; ++half_close) {
            SynurangInstance* instance = synurang_instance_create(options);
            assert(instance != NULL);
            assert(calls_register(instance, &handlers, NULL) == SYNURANG_OK);
            uint64_t call = api->open(instance, methods[method], NULL);
            assert(call != 0);
            if (half_close) assert(api->half_close(instance, call) == SYNURANG_OK);
            api->poll(instance, 64);
            SynurangReadResult result = read_call(api, instance, call);
            assert(result.kind == SYNURANG_READ_FINISHED && result.code == 12);
            api->free_buffer(result.data);
            api->release(instance, call);
            close_instance(api, instance);
        }
    }
}
int main(void) {
    const SynurangApi* api = Synurang_GetApi();
    SynurangRuntimeOptions options = SYNURANG_RUNTIME_OPTIONS_INIT;
    SynurangInstance *a, *b;
    SynurangReadResult result;
    uint64_t call, other;
    options.execution_mode = SYNURANG_EXECUTION_MANUAL;
    options.inbound_queue_capacity = options.outbound_queue_capacity = 1;
    unimplemented_methods(api, &options);
    a = api->create(&options);
    b = api->create(&options);
    assert(a != NULL && b != NULL && a != b);
    assert(api->abi_version == 1 && api->struct_size == sizeof(*api));
    call = api->open(a, "/synurang.test.Calls/Unary", NULL);
    other = api->open(b, "/synurang.test.Calls/Unary", NULL);
    result = read_call(api, a, call);
    assert(result.kind == SYNURANG_READ_PENDING);
    assert(api->send(a, call, NULL, 0) == 0); /* Empty protobuf != EOF. */
    assert(api->half_close(a, call) == 0);
    assert(api->poll(a, 64) > 0);
    /* Once the provider has finished, late cancellation or sending cannot
     * replace that terminal status or discard the queued unary response. */
    assert(api->cancel(a, call, 1) == SYNURANG_OK);
    assert(api->send(a, call, NULL, 0) == SYNURANG_CLOSED);
    result = read_call(api, a, call);
    assert(result.kind == SYNURANG_READ_MESSAGE && result.size == 0);
    api->free_buffer(result.data);
    result = read_call(api, a, call);
    assert(result.kind == SYNURANG_READ_FINISHED && result.code == 0);
    api->release(a, call);
    result = read_call(api, b, other);
    assert(result.kind == SYNURANG_READ_PENDING);
    api->cancel(b, other, 4);
    result = read_call(api, b, other);
    assert(result.kind == SYNURANG_READ_FINISHED && result.code == 4 && result.size > 0);
    api->free_buffer(result.data);
    api->release(b, other);
    call = api->open(a, "/missing.Service/Unknown", NULL);
    result = read_call(api, a, call);
    assert(result.kind == SYNURANG_READ_FINISHED && result.code == 12);
    api->free_buffer(result.data);
    api->release(a, call);
    call = api->open(a, "/synurang.test.Calls/Unary", NULL);
    assert(api->half_close(a, call) == SYNURANG_CLOSED);
    result = read_call(api, a, call);
    assert(result.kind == SYNURANG_READ_FINISHED && result.code == 3);
    api->free_buffer(result.data);
    api->release(a, call);
    call = api->open(a, "/synurang.test.Calls/Bidi", NULL);
    assert(api->send(a, call, NULL, 0) == 0);
    assert(api->send(a, call, NULL, 0) == SYNURANG_WOULD_BLOCK);
    api->poll(a, 64);
    result = read_call(api, a, call);
    assert(result.kind == SYNURANG_READ_MESSAGE); /* Before half-close. */
    api->free_buffer(result.data);
    api->release(a, call);
    /* A slow reader pauses callback input without losing messages or allowing
     * half-close to overtake the pending response. Both queues have capacity 1. */
    call = api->open(a, "/synurang.test.Calls/Bidi", NULL);
    assert(api->send(a, call, NULL, 0) == 0);
    api->poll(a, 64);
    assert(api->send(a, call, NULL, 0) == 0);
    api->poll(a, 64); /* The second response blocks and pauses input. */
    assert(api->send(a, call, NULL, 0) == 0);
    assert(api->send(a, call, NULL, 0) == SYNURANG_WOULD_BLOCK);
    assert(api->half_close(a, call) == 0);
    api->poll(a, 64);
    for (int n = 0; n < 3; ++n) {
        result = read_call(api, a, call);
        assert(result.kind == SYNURANG_READ_MESSAGE && result.size == 0);
        api->free_buffer(result.data);
        api->poll(a, 64);
    }
    result = read_call(api, a, call);
    assert(result.kind == SYNURANG_READ_FINISHED && result.code == 0);
    api->release(a, call);
    close_instance(api, a);
    close_instance(api, b);

    a = synurang_instance_create(&options);
    assert(synurang_instance_register(a, "/test/Retain", 0, 0,
        open_retained, NULL, count_destroy) == 0);
    call = synurang_call_open(a, "/test/Retain", NULL);
    assert(call != 0);
    synurang_instance_poll(a, 64);
    assert(retained != NULL);
    assert(synurang_instance_destroy(a) == SYNURANG_PENDING);
    synurang_instance_poll(a, 64);
    assert(synurang_instance_destroy(a) == SYNURANG_PENDING);
    assert(destroyed == 0); /* Service state lives through producer cleanup. */
    assert(synurang_call_open(a, "/test/Retain", NULL) == 0);
    synurang_stream_release(retained);
    assert(synurang_instance_destroy(a) == SYNURANG_OK);
    assert(destroyed == 1);
    puts("C call lifecycle conformance passed");
    return 0;
}
