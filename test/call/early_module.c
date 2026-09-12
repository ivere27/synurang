#include "synurang/call.h"

static void message(SynurangStream* stream, const uint8_t* data, size_t size, void* context) {
    (void)synurang_stream_write(stream, data, size);
    if (context != NULL)
        (void)synurang_stream_fail_error(stream, 42, 7, "Early response then error");
    else
        (void)synurang_stream_finish(stream);
}

static uint64_t open_call(SynurangRuntime* runtime, const SynurangCallOptions* options, void* context) {
    SynurangStreamCallbacks callbacks = SYNURANG_STREAM_CALLBACKS_INIT;
    (void)options;
    callbacks.on_message = message;
    return synurang_stream_open(runtime, &callbacks, context);
}

static SynurangInstance* create(const SynurangRuntimeOptions* options) {
    SynurangRuntimeOptions threaded = *options;
    SynurangInstance* instance;
    static int fail;
    threaded.execution_mode = SYNURANG_EXECUTION_THREADED;
    threaded.worker_count = 1;
    instance = synurang_instance_create(&threaded);
    if (instance != NULL) {
        if (synurang_instance_register(instance, "/early.Service/Client", 1, 0, open_call, NULL, NULL) != 0 ||
            synurang_instance_register(instance, "/synurang.test.Calls/Client", 1, 0, open_call, NULL, NULL) != 0 ||
            synurang_instance_register(instance, "/early.Service/Fail", 1, 0, open_call, &fail, NULL) != 0) {
            while (synurang_instance_destroy(instance) == SYNURANG_PENDING)
                synurang_instance_poll(instance, 64);
            return NULL;
        }
    }
    return instance;
}
SYNURANG_DEFINE_MODULE(Synurang_GetApi, create)
