/* Cleanup is observable through a file, without another RPC polling the host. */
#include "synurang/call.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct State { char* path; } State;
static void mark(State* state, int event) {
    if (state->path == NULL) return;
    FILE* output = fopen(state->path, "ab");
    assert(output != NULL);
    assert(fputc(event, output) != EOF);
    assert(fclose(output) == 0);
}
static void message(SynurangStream* stream, const uint8_t* data, size_t size, void* context) {
    State* state = (State*)context;
    assert(state->path == NULL && size != 0 && memchr(data, 0, size) == NULL);
    state->path = (char*)malloc(size + 1);
    assert(state->path != NULL);
    memcpy(state->path, data, size);
    state->path[size] = '\0';
    assert(synurang_stream_write(stream, NULL, 0) == SYNURANG_OK);
}
static void cancel(SynurangStream* stream, void* context) {
    (void)stream;
    mark((State*)context, 'C');
}
static void destroy(void* context) {
    State* state = (State*)context;
    mark(state, 'D');
    free(state->path);
    free(state);
}
static uint64_t open_call(SynurangRuntime* runtime,
    const SynurangCallOptions* options, void* context) {
    SynurangStreamCallbacks callbacks = SYNURANG_STREAM_CALLBACKS_INIT;
    State* state = (State*)calloc(1, sizeof(*state));
    (void)options; (void)context;
    assert(state != NULL);
    callbacks.on_message = message;
    callbacks.on_cancel = cancel;
    callbacks.on_destroy = destroy;
    uint64_t call = synurang_stream_open(runtime, &callbacks, state);
    assert(call != 0);
    return call;
}
static SynurangInstance* create(const SynurangRuntimeOptions* options) {
    SynurangInstance* instance = synurang_instance_create(options);
    assert(instance != NULL);
    assert(synurang_instance_register(instance, "/test.Release/Watch", 0, 1,
        open_call, NULL, NULL) == SYNURANG_OK);
    return instance;
}
SYNURANG_DEFINE_MODULE(Synurang_GetApi, create)
