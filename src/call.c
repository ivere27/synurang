#include "synurang/call.h"

#include <limits.h>
#include <stdlib.h>
#include <string.h>

typedef struct Method {
    struct Method* next;
    char* path;
    uint32_t request_stream;
    uint32_t response_stream;
    SynurangOpenCallFn open;
    void* user_data;
    SynurangDestroyFn destroy;
} Method;

typedef struct Call {
    struct Call* next;
    uint64_t id;
    uint64_t stream;
    uint32_t request_stream;
    uint32_t response_stream;
    uint64_t sent;
    uint64_t received;
    int half_closed;
    int finished;
    int32_t code;
    uint8_t* error;
    size_t error_size;
} Call;

struct SynurangInstance {
    SynurangRuntime* runtime;
    Method* methods;
    Call* calls;
    uint64_t next_call;
    int started;
    int closing;
};

static Call* find_call(SynurangInstance* instance, uint64_t id) {
    Call* call;
    if (instance == NULL) return NULL;
    for (call = instance->calls; call != NULL; call = call->next) {
        if (call->id == id) return call;
    }
    return NULL;
}

static void stop_stream(Call* call) {
    if (call->stream != 0u) {
        Synurang_Stream_Close(call->stream);
        call->stream = 0u;
    }
}

static void fail_call(Call* call, int32_t code, const char* message) {
    if (call->finished) return;
    call->finished = 1;
    call->code = code;
    call->error = synurang_error_response_copy(
        0, message, strlen(message), code, &call->error_size);
    stop_stream(call);
}

/* Only the status field of core.v1.Error is needed at the ABI boundary.
 * Leave the entire payload intact for the language-level decoder. */
static int read_varint(const uint8_t* data, size_t size,
                       size_t* position, uint64_t* value) {
    unsigned shift;
    *value = 0u;
    for (shift = 0u; shift < 64u && *position < size; shift += 7u) {
        uint8_t byte = data[(*position)++];
        if (shift == 63u && byte > 1u) return 0;
        *value |= (uint64_t)(byte & 127u) << shift;
        if ((byte & 128u) == 0u) return 1;
    }
    return 0;
}

static int32_t error_code(const uint8_t* data, size_t size) {
    size_t pos = 0u;
    while (pos < size) {
        uint64_t tag;
        uint64_t value;
        if (!read_varint(data, size, &pos, &tag) || tag == 0u) break;
        if ((tag & 7u) == 0u) {
            if (!read_varint(data, size, &pos, &value)) break;
            if ((tag >> 3u) == 3u) {
                return value > 0u && value <= 16u ? (int32_t)value : 2;
            }
        } else if ((tag & 7u) == 2u) {
            if (!read_varint(data, size, &pos, &value) || value > size - pos) break;
            pos += (size_t)value;
        } else if ((tag & 7u) == 1u && size - pos >= 8u) {
            pos += 8u;
        } else if ((tag & 7u) == 5u && size - pos >= 4u) {
            pos += 4u;
        } else {
            break;
        }
    }
    return 2;
}

SynurangInstance* synurang_instance_create(const SynurangRuntimeOptions* options) {
    SynurangInstance* instance = (SynurangInstance*)calloc(1u, sizeof(*instance));
    if (instance == NULL) return NULL;
    instance->runtime = synurang_runtime_create(options);
    if (instance->runtime == NULL) {
        free(instance);
        return NULL;
    }
    instance->next_call = 1u;
    synurang_runtime_enable_call_notifications(instance->runtime);
    return instance;
}

int synurang_instance_register(
    SynurangInstance* instance, const char* path, uint32_t request_stream,
    uint32_t response_stream, SynurangOpenCallFn open, void* user_data,
    SynurangDestroyFn destroy) {
    Method* method;
    size_t size;
    if (instance == NULL || path == NULL || path[0] != '/' || open == NULL ||
        request_stream > 1u || response_stream > 1u) return SYNURANG_INVALID_ARGUMENT;
    if (instance->started || instance->closing) return SYNURANG_CLOSED;
    for (method = instance->methods; method != NULL; method = method->next) {
        if (strcmp(method->path, path) == 0) return SYNURANG_INVALID_ARGUMENT;
    }
    method = (Method*)calloc(1u, sizeof(*method));
    if (method == NULL) return SYNURANG_OUT_OF_MEMORY;
    size = strlen(path) + 1u;
    method->path = (char*)malloc(size);
    if (method->path == NULL) {
        free(method);
        return SYNURANG_OUT_OF_MEMORY;
    }
    memcpy(method->path, path, size);
    method->request_stream = request_stream;
    method->response_stream = response_stream;
    method->open = open;
    method->user_data = user_data;
    method->destroy = destroy;
    method->next = instance->methods;
    instance->methods = method;
    return SYNURANG_OK;
}

uint64_t synurang_call_open(SynurangInstance* instance, const char* path,
                           const SynurangCallOptions* options) {
    Method* method;
    Call* call;
    SynurangCallOptions resolved = {
        sizeof(SynurangCallOptions), 0u, 0u, 0u, UINT64_MAX
    };
    if (instance == NULL || instance->closing || path == NULL ||
        instance->next_call == 0u) return 0u;
    if (options != NULL) {
        if (options->struct_size != sizeof(SynurangCallOptions) ||
            options->request_stream > 1u || options->response_stream > 1u ||
            options->reserved != 0u) return 0u;
        resolved = *options;
    }
    instance->started = 1;
    call = (Call*)calloc(1u, sizeof(*call));
    if (call == NULL) return 0u;
    call->id = instance->next_call++;
    call->next = instance->calls;
    instance->calls = call;
    for (method = instance->methods; method != NULL; method = method->next) {
        if (strcmp(method->path, path) == 0) break;
    }
    if (method == NULL) {
        fail_call(call, 12, "Unknown RPC method");
        return call->id;
    }
    call->request_stream = method->request_stream;
    call->response_stream = method->response_stream;
    if (options != NULL && (resolved.request_stream != method->request_stream ||
                            resolved.response_stream != method->response_stream)) {
        fail_call(call, 3, "RPC cardinality does not match the service");
        return call->id;
    }
    resolved.request_stream = method->request_stream;
    resolved.response_stream = method->response_stream;
    if (resolved.timeout_ms == 0u) {
        fail_call(call, 4, "Deadline exceeded");
        return call->id;
    }
    call->stream = method->open(instance->runtime, &resolved, method->user_data);
    if (call->stream == 0u) fail_call(call, 13, "Could not open RPC handler");
    return call->id;
}

int synurang_call_send(SynurangInstance* instance, uint64_t id,
                       const uint8_t* data, uint32_t size) {
    Call* call = find_call(instance, id);
    int status;
    if (call == NULL) return SYNURANG_NOT_FOUND;
    if (size > INT_MAX || (data == NULL && size != 0u)) return SYNURANG_INVALID_ARGUMENT;
    if (call->finished || call->half_closed) return SYNURANG_CLOSED;
    if (!call->request_stream && call->sent != 0u) {
        if (synurang_stream_cancel_pending(call->stream))
            fail_call(call, 3, "RPC accepts exactly one request");
        return SYNURANG_CLOSED;
    }
    status = Synurang_Stream_TrySend(call->stream, (const char*)data, (int)size);
    if (status == SYNURANG_OK) ++call->sent;
    return status;
}

int synurang_call_half_close(SynurangInstance* instance, uint64_t id) {
    Call* call = find_call(instance, id);
    if (call == NULL) return SYNURANG_NOT_FOUND;
    if (call->finished) return SYNURANG_OK;
    if (call->half_closed) return SYNURANG_OK;
    if (!call->request_stream && call->sent != 1u) {
        if (!synurang_stream_cancel_pending(call->stream)) return SYNURANG_OK;
        fail_call(call, 3, "RPC requires one request");
        return SYNURANG_CLOSED;
    }
    call->half_closed = 1;
    Synurang_Stream_CloseSend(call->stream);
    return SYNURANG_OK;
}

int synurang_call_receive(SynurangInstance* instance, uint64_t id,
                          SynurangReadResult* result) {
    Call* call = find_call(instance, id);
    if (result == NULL) return SYNURANG_INVALID_ARGUMENT;
    memset(result, 0, sizeof(*result));
    if (call == NULL) return SYNURANG_NOT_FOUND;
    if (!call->finished) {
        int size = 0;
        int status = 0;
        char* data = Synurang_Stream_TryRecv(call->stream, &size, &status);
        if (status == SYNURANG_PENDING) return SYNURANG_OK;
        if (status == SYNURANG_OK) {
            ++call->received;
            if (!call->response_stream && call->received > 1u) {
                Synurang_Free(data);
                fail_call(call, 13, "RPC produced more than one response");
            } else {
                result->kind = SYNURANG_READ_MESSAGE;
                result->data = (uint8_t*)data;
                result->size = (uint32_t)size;
                return SYNURANG_OK;
            }
        } else if (status == SYNURANG_EOF) {
            Synurang_Free(data);
            if (!call->response_stream && call->received != 1u) {
                fail_call(call, 13, "RPC completed without a response");
            } else {
                call->finished = 1;
                stop_stream(call);
            }
        } else {
            call->finished = 1;
            call->error = (uint8_t*)data;
            call->error_size = size > 0 ? (size_t)size : 0u;
            call->code = error_code(call->error, call->error_size);
            stop_stream(call);
        }
    }
    result->kind = SYNURANG_READ_FINISHED;
    result->code = call->code;
    if (call->error_size != 0u) {
        result->data = synurang_response_copy(call->error, call->error_size);
        if (result->data == NULL) return SYNURANG_OUT_OF_MEMORY;
        result->size = (uint32_t)call->error_size;
    }
    return SYNURANG_OK;
}

int synurang_call_cancel(SynurangInstance* instance, uint64_t id, int32_t code) {
    Call* call = find_call(instance, id);
    if (call == NULL) return SYNURANG_NOT_FOUND;
    if (code < 1 || code > 16) return SYNURANG_INVALID_ARGUMENT;
    if (!call->finished && synurang_stream_cancel_pending(call->stream))
        fail_call(call, code, code == 4 ? "Deadline exceeded" : "Call cancelled");
    return SYNURANG_OK;
}

void synurang_call_release(SynurangInstance* instance, uint64_t id) {
    Call** slot;
    if (instance == NULL) return;
    for (slot = &instance->calls; *slot != NULL; slot = &(*slot)->next) {
        Call* call = *slot;
        if (call->id == id) {
            *slot = call->next;
            stop_stream(call);
            synurang_response_free(call->error);
            free(call);
            return;
        }
    }
}

uint32_t synurang_instance_poll(SynurangInstance* instance, uint32_t budget) {
    if (instance == NULL) return 0u;
    /* Zero must not accidentally request an unbounded drain in the lower runtime. */
    if (budget == 0u) budget = 64u;
    return (uint32_t)synurang_runtime_poll(instance->runtime, budget);
}

int synurang_instance_has_work(SynurangInstance* instance) {
    return instance != NULL && synurang_runtime_has_pending(instance->runtime);
}

int synurang_instance_destroy(SynurangInstance* instance) {
    Method* method;
    if (instance == NULL) return SYNURANG_OK;
    instance->closing = 1;
    while (instance->calls != NULL) synurang_call_release(instance, instance->calls->id);
    if (!synurang_runtime_is_idle(instance->runtime)) return SYNURANG_PENDING;
    synurang_runtime_destroy(instance->runtime);
    while ((method = instance->methods) != NULL) {
        instance->methods = method->next;
        if (method->destroy != NULL) method->destroy(method->user_data);
        free(method->path);
        free(method);
    }
    free(instance);
    return SYNURANG_OK;
}
