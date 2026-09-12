#include "conformance_ffi.h"
#include <stdlib.h>
#include <string.h>

typedef struct State { int32_t total; int32_t next; int32_t remaining; int pending; } State;
static void* state_open(SynurangStream* stream, const SynurangCallOptions* options, void* service) {
    (void)stream; (void)options; (void)service;
    return calloc(1u, sizeof(State));
}
static void unary(SynurangStream* stream, const SynurangTestValue* request, void* state) {
    (void)state;
    (void)calls_unary_respond(stream, request);
    if (request->field_value == -1)
        (void)synurang_stream_fail_error(stream, 42, 7, "Error after response");
    else
        (void)synurang_stream_finish(stream);
}
static void server_writable(SynurangStream* stream, void* user_data) {
    State* state = (State*)user_data;
    SynurangTestValue response;
    synurang_test_value_init(&response);
    while (state->remaining > 0) {
        response.field_value = state->next;
        if (calls_server_respond(stream, &response) == SYNURANG_WOULD_BLOCK) return;
        ++state->next;
        --state->remaining;
    }
    (void)synurang_stream_finish(stream);
}
static void server(SynurangStream* stream, const SynurangTestValue* request, void* user_data) {
    State* state = (State*)user_data;
    state->remaining = request->field_value;
    server_writable(stream, state);
}
static void client(SynurangStream* stream, const SynurangTestValue* request, void* user_data) {
    State* state = (State*)user_data;
    if (request->field_value == -2) {
        SynurangTestValue response;
        synurang_test_value_init(&response);
        response.field_value = 42;
        (void)calls_client_respond(stream, &response);
        (void)synurang_stream_finish(stream);
        return;
    }
    state->total += request->field_value;
}
static void client_half(SynurangStream* stream, void* user_data) {
    State* state = (State*)user_data;
    SynurangTestValue response;
    synurang_test_value_init(&response);
    response.field_value = state->total;
    (void)calls_client_respond(stream, &response);
    (void)synurang_stream_finish(stream);
}
static void bidi_writable(SynurangStream* stream, void* user_data) {
    State* state = (State*)user_data;
    SynurangTestValue response;
    if (!state->pending) return;
    synurang_test_value_init(&response);
    response.field_value = state->next;
    if (calls_bidi_respond(stream, &response) == SYNURANG_WOULD_BLOCK) return;
    state->pending = 0;
    synurang_stream_resume_input(stream);
}
static void bidi(SynurangStream* stream, const SynurangTestValue* request, void* user_data) {
    State* state = (State*)user_data;
    if (calls_bidi_respond(stream, request) == SYNURANG_WOULD_BLOCK) {
        state->next = request->field_value;
        state->pending = 1;
        synurang_stream_pause_input(stream);
    }
}
static void half(SynurangStream* stream, void* state) {
    (void)state;
    (void)synurang_stream_finish(stream);
}
static void waiting(SynurangStream* stream, const SynurangTestValue* request, void* state) {
    (void)stream; (void)request; (void)state;
}
static void failing(SynurangStream* stream, const SynurangTestValue* request, void* state) {
    (void)request; (void)state;
    (void)synurang_stream_fail_error(stream, 42, 7, "Permission denied by provider");
}
static SynurangInstance* create(const SynurangRuntimeOptions* options) {
    SynurangInstance* instance = synurang_instance_create(options);
    CallsHandlers handlers;
    memset(&handlers, 0, sizeof(handlers));
    if (instance == NULL) return NULL;
    handlers.unary.message = unary;
    handlers.server.open = state_open;
    handlers.server.message = server;
    handlers.server.writable = server_writable;
    handlers.server.destroy = free;
    handlers.client.open = state_open;
    handlers.client.message = client;
    handlers.client.half_close = client_half;
    handlers.client.destroy = free;
    handlers.bidi.open = state_open;
    handlers.bidi.message = bidi;
    handlers.bidi.writable = bidi_writable;
    handlers.bidi.destroy = free;
    handlers.bidi.half_close = half;
    handlers.wait.message = waiting;
    handlers.fail.message = failing;
    if (calls_register(instance, &handlers, NULL) != SYNURANG_OK) {
        (void)synurang_instance_destroy(instance);
        return NULL;
    }
    return instance;
}
SYNURANG_DEFINE_MODULE(Synurang_GetApi, create)
