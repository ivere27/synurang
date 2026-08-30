#include "synurang/c_runtime.h"

#include <limits.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#if defined(__EMSCRIPTEN__) && !defined(__EMSCRIPTEN_PTHREADS__) && \
    !defined(SYNURANG_RUNTIME_NO_THREADS)
#define SYNURANG_RUNTIME_NO_THREADS 1
#endif

#if !defined(SYNURANG_RUNTIME_NO_THREADS) && defined(_WIN32)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#if !defined(_WIN32_WINNT) || _WIN32_WINNT < 0x0600
#undef _WIN32_WINNT
#define _WIN32_WINNT 0x0600
#endif
#include <windows.h>

typedef SRWLOCK SynurangMutex;
typedef CONDITION_VARIABLE SynurangCond;
typedef HANDLE SynurangThread;

#define SYNURANG_MUTEX_STATIC_INIT SRWLOCK_INIT

static int synurang_mutex_init(SynurangMutex* mutex) {
    InitializeSRWLock(mutex);
    return 0;
}

static void synurang_mutex_destroy(SynurangMutex* mutex) {
    (void)mutex;
}

static void synurang_mutex_lock(SynurangMutex* mutex) {
    AcquireSRWLockExclusive(mutex);
}

static void synurang_mutex_unlock(SynurangMutex* mutex) {
    ReleaseSRWLockExclusive(mutex);
}

static int synurang_cond_init(SynurangCond* cond) {
    InitializeConditionVariable(cond);
    return 0;
}

static void synurang_cond_destroy(SynurangCond* cond) {
    (void)cond;
}

static void synurang_cond_wait(SynurangCond* cond, SynurangMutex* mutex) {
    (void)SleepConditionVariableSRW(cond, mutex, INFINITE, 0);
}

static void synurang_cond_signal(SynurangCond* cond) {
    WakeConditionVariable(cond);
}

static void synurang_cond_broadcast(SynurangCond* cond) {
    WakeAllConditionVariable(cond);
}
#elif !defined(SYNURANG_RUNTIME_NO_THREADS)
#include <pthread.h>

typedef pthread_mutex_t SynurangMutex;
typedef pthread_cond_t SynurangCond;
typedef pthread_t SynurangThread;

#define SYNURANG_MUTEX_STATIC_INIT PTHREAD_MUTEX_INITIALIZER

static int synurang_mutex_init(SynurangMutex* mutex) {
    return pthread_mutex_init(mutex, NULL);
}

static void synurang_mutex_destroy(SynurangMutex* mutex) {
    (void)pthread_mutex_destroy(mutex);
}

static void synurang_mutex_lock(SynurangMutex* mutex) {
    (void)pthread_mutex_lock(mutex);
}

static void synurang_mutex_unlock(SynurangMutex* mutex) {
    (void)pthread_mutex_unlock(mutex);
}

static int synurang_cond_init(SynurangCond* cond) {
    return pthread_cond_init(cond, NULL);
}

static void synurang_cond_destroy(SynurangCond* cond) {
    (void)pthread_cond_destroy(cond);
}

static void synurang_cond_wait(SynurangCond* cond, SynurangMutex* mutex) {
    (void)pthread_cond_wait(cond, mutex);
}

static void synurang_cond_signal(SynurangCond* cond) {
    (void)pthread_cond_signal(cond);
}

static void synurang_cond_broadcast(SynurangCond* cond) {
    (void)pthread_cond_broadcast(cond);
}
#else
/* A single-thread WebAssembly build still uses the exact same state machine.
 * These no-op primitives deliberately do not pretend that waiting is possible:
 * a threadless runtime rejects THREADED mode. Legacy blocking ABI calls may
 * drive the manual poll core, but they never enter a condition wait. */
typedef unsigned char SynurangMutex;
typedef unsigned char SynurangCond;

#define SYNURANG_MUTEX_STATIC_INIT 0

static int synurang_mutex_init(SynurangMutex* mutex) {
    *mutex = 0;
    return 0;
}

static void synurang_mutex_destroy(SynurangMutex* mutex) {
    (void)mutex;
}

static void synurang_mutex_lock(SynurangMutex* mutex) {
    (void)mutex;
}

static void synurang_mutex_unlock(SynurangMutex* mutex) {
    (void)mutex;
}

static int synurang_cond_init(SynurangCond* cond) {
    *cond = 0;
    return 0;
}

static void synurang_cond_destroy(SynurangCond* cond) {
    (void)cond;
}

static void synurang_cond_signal(SynurangCond* cond) {
    (void)cond;
}

static void synurang_cond_broadcast(SynurangCond* cond) {
    (void)cond;
}
#endif

typedef struct SynurangPayload {
    struct SynurangPayload* next;
    size_t len;
    uint8_t* data;
} SynurangPayload;

typedef enum SynurangEventKind {
    SYNURANG_EVENT_NONE = 0,
    SYNURANG_EVENT_OPEN,
    SYNURANG_EVENT_MESSAGE,
    SYNURANG_EVENT_HALF_CLOSE,
    SYNURANG_EVENT_WRITABLE,
    SYNURANG_EVENT_CANCEL
} SynurangEventKind;

struct SynurangRuntime {
    SynurangMutex mutex;
    SynurangCond ready_cond;
    SynurangCond state_cond;

    SynurangExecutionMode execution_mode;
    size_t worker_count;
    size_t inbound_queue_capacity;
    size_t outbound_queue_capacity;
    SynurangWakeupFn wakeup;
    void* wakeup_user_data;

    SynurangStream* ready_head;
    SynurangStream* ready_tail;
    size_t stream_count;
    size_t opening_count;
    size_t active_pollers;
    int stopping;
    int workers_stop;
    int deferred_free;

#if !defined(SYNURANG_RUNTIME_NO_THREADS)
    SynurangThread* workers;
    size_t workers_started;
#endif
};

struct SynurangStream {
    SynurangRuntime* runtime;
    uint64_t handle;
    SynurangStreamCallbacks callbacks;
    void* user_data;

    SynurangMutex mutex;
    SynurangCond state_cond;
    size_t ref_count;
    int in_registry;

    int queued;
    int dispatching;
    SynurangStream* ready_next;

    int open_pending;
    int half_closed;
    int half_close_dispatched;
    int writable_waiting;
    int writable_pending;
    int cancelled;
    int cancel_dispatched;

    SynurangPayload* input_head;
    SynurangPayload* input_tail;
    size_t input_count;
    size_t input_reserved;

    SynurangPayload* output_head;
    SynurangPayload* output_tail;
    size_t output_count;
    size_t output_reserved;
    int output_terminal;
    int terminal_status;
    int terminal_delivered;
    SynurangPayload* terminal_error;

    SynurangStream* registry_next;
};

/* Masking dense monotonic handles distributes them evenly among these buckets,
 * reducing the average lookup chain instead of walking every live stream.
 * The bucket count must stay a power of two. */
#define SYNURANG_REGISTRY_BUCKETS 256u

static SynurangMutex g_registry_mutex = SYNURANG_MUTEX_STATIC_INIT;
static SynurangStream* g_registry_buckets[SYNURANG_REGISTRY_BUCKETS];
static uint64_t g_next_handle = 1u;
static SynurangRuntime* g_default_runtime = NULL;

static size_t synurang_registry_bucket(uint64_t handle) {
    return (size_t)(handle & (uint64_t)(SYNURANG_REGISTRY_BUCKETS - 1u));
}

static void synurang_runtime_free(SynurangRuntime* runtime);
static void synurang_stream_release_internal(SynurangStream* stream);

uint8_t* synurang_response_copy(const void* data, size_t data_len) {
    uint8_t* copy;

    if (data_len != 0u && data == NULL) return NULL;
    copy = (uint8_t*)malloc(data_len == 0u ? 1u : data_len);
    if (copy == NULL) return NULL;
    if (data_len != 0u) memcpy(copy, data, data_len);
    return copy;
}

void synurang_response_free(void* data) {
    free(data);
}

void Synurang_Free(char* ptr) {
    synurang_response_free(ptr);
}

static SynurangPayload* synurang_payload_create(const void* data,
                                                size_t data_len) {
    SynurangPayload* payload;

    payload = (SynurangPayload*)calloc(1u, sizeof(*payload));
    if (payload == NULL) return NULL;
    payload->data = synurang_response_copy(data, data_len);
    if (payload->data == NULL) {
        free(payload);
        return NULL;
    }
    payload->len = data_len;
    return payload;
}

static void synurang_payload_destroy(SynurangPayload* payload) {
    if (payload == NULL) return;
    synurang_response_free(payload->data);
    free(payload);
}

static void synurang_payload_list_destroy(SynurangPayload* payload) {
    while (payload != NULL) {
        SynurangPayload* next = payload->next;
        synurang_payload_destroy(payload);
        payload = next;
    }
}

static size_t synurang_varint_size(uint64_t value) {
    size_t size = 1u;
    while (value >= 0x80u) {
        value >>= 7u;
        ++size;
    }
    return size;
}

static uint8_t* synurang_write_varint(uint8_t* out, uint64_t value) {
    while (value >= 0x80u) {
        *out++ = (uint8_t)((value & 0x7fu) | 0x80u);
        value >>= 7u;
    }
    *out++ = (uint8_t)value;
    return out;
}

uint8_t* synurang_error_response_copy(int32_t code,
                                      const char* message,
                                      size_t message_len,
                                      int32_t grpc_code,
                                      size_t* out_len) {
    size_t encoded_len = 0u;
    size_t message_prefix_len = 0u;
    uint64_t code_value = (uint64_t)(int64_t)code;
    uint64_t grpc_value = (uint64_t)(int64_t)grpc_code;
    uint8_t* encoded;
    uint8_t* cursor;

    if (out_len == NULL || (message_len != 0u && message == NULL)) return NULL;
    *out_len = 0u;

    if (code != 0) encoded_len = 1u + synurang_varint_size(code_value);
    if (message_len != 0u) {
        message_prefix_len = synurang_varint_size((uint64_t)message_len);
        if (message_len > SIZE_MAX - encoded_len - 1u - message_prefix_len) {
            return NULL;
        }
        encoded_len += 1u + message_prefix_len + message_len;
    }
    if (grpc_code != 0) {
        size_t grpc_len = 1u + synurang_varint_size(grpc_value);
        if (grpc_len > SIZE_MAX - encoded_len) return NULL;
        encoded_len += grpc_len;
    }

    /* An empty protobuf payload is indistinguishable from unary success when
     * the ABI encodes failure by negating its byte length. Match the other
     * runtimes' canonical fallback: an explicitly present empty message. */
    if (encoded_len == 0u) encoded_len = 2u;

    encoded = (uint8_t*)malloc(encoded_len);
    if (encoded == NULL) return NULL;
    cursor = encoded;
    if (code != 0) {
        *cursor++ = 0x08u;
        cursor = synurang_write_varint(cursor, code_value);
    }
    if (message_len != 0u) {
        *cursor++ = 0x12u;
        cursor = synurang_write_varint(cursor, (uint64_t)message_len);
        memcpy(cursor, message, message_len);
        cursor += message_len;
    }
    if (grpc_code != 0) {
        *cursor++ = 0x18u;
        cursor = synurang_write_varint(cursor, grpc_value);
    }
    if (cursor == encoded) {
        *cursor++ = 0x12u;
        *cursor++ = 0x00u;
    }

    *out_len = (size_t)(cursor - encoded);
    return encoded;
}

static int synurang_stream_has_work_locked(const SynurangStream* stream) {
    if (stream->cancelled && !stream->cancel_dispatched) return 1;
    if (stream->cancelled) return 0;
    if (stream->output_terminal) return 0;
    if (stream->open_pending) return 1;
    if (stream->input_head != NULL) return 1;
    if (stream->half_closed && !stream->half_close_dispatched) return 1;
    if (stream->writable_pending) return 1;
    return 0;
}

static void synurang_stream_end_input_locked(SynurangStream* stream) {
    stream->open_pending = 0;
    stream->half_close_dispatched = 1;
    stream->writable_waiting = 0;
    stream->writable_pending = 0;
    synurang_payload_list_destroy(stream->input_head);
    stream->input_head = NULL;
    stream->input_tail = NULL;
    stream->input_count = 0u;
    synurang_cond_broadcast(&stream->state_cond);
}

static int synurang_stream_input_full_locked(const SynurangStream* stream) {
    size_t capacity = stream->runtime->inbound_queue_capacity;
    return stream->input_count >= capacity ||
           stream->input_reserved >= capacity - stream->input_count;
}

static int synurang_stream_output_full_locked(const SynurangStream* stream) {
    size_t capacity = stream->runtime->outbound_queue_capacity;
    return stream->output_count >= capacity ||
           stream->output_reserved >= capacity - stream->output_count;
}

/* The caller owns stream->mutex. Returning one asks the caller to invoke the
 * manual executor wakeup after dropping that mutex. */
static int synurang_stream_schedule_locked(SynurangStream* stream) {
    SynurangRuntime* runtime = stream->runtime;
    int notify = 0;

    if (stream->queued || stream->dispatching ||
        !synurang_stream_has_work_locked(stream)) {
        return 0;
    }

    ++stream->ref_count; /* ready queue reference */
    stream->queued = 1;
    stream->ready_next = NULL;

    synurang_mutex_lock(&runtime->mutex);
    if (runtime->ready_tail != NULL) {
        runtime->ready_tail->ready_next = stream;
    } else {
        runtime->ready_head = stream;
        if (!runtime->stopping &&
            runtime->execution_mode == SYNURANG_EXECUTION_MANUAL &&
            runtime->wakeup != NULL) {
            notify = 1;
        }
    }
    runtime->ready_tail = stream;
    synurang_cond_signal(&runtime->ready_cond);
    synurang_mutex_unlock(&runtime->mutex);
    return notify;
}

static void synurang_runtime_notify(SynurangRuntime* runtime, int notify) {
    if (notify && runtime->wakeup != NULL) {
        runtime->wakeup(runtime->wakeup_user_data);
    }
}

static int synurang_runtime_should_notify_manual(SynurangRuntime* runtime) {
    int notify;
    synurang_mutex_lock(&runtime->mutex);
    notify = !runtime->stopping &&
             runtime->execution_mode == SYNURANG_EXECUTION_MANUAL &&
             runtime->wakeup != NULL;
    synurang_mutex_unlock(&runtime->mutex);
    return notify;
}

static void synurang_stream_destroy_final(SynurangStream* stream) {
    SynurangRuntime* runtime = stream->runtime;
    int free_runtime = 0;

    synurang_payload_list_destroy(stream->input_head);
    synurang_payload_list_destroy(stream->output_head);
    synurang_payload_destroy(stream->terminal_error);
    if (stream->callbacks.on_destroy != NULL) {
        stream->callbacks.on_destroy(stream->user_data);
    }
    synurang_cond_destroy(&stream->state_cond);
    synurang_mutex_destroy(&stream->mutex);
    free(stream);

    synurang_mutex_lock(&runtime->mutex);
    if (runtime->stream_count != 0u) --runtime->stream_count;
    if (runtime->stream_count == 0u) {
        synurang_cond_broadcast(&runtime->state_cond);
        if (runtime->deferred_free) free_runtime = 1;
    }
    synurang_mutex_unlock(&runtime->mutex);

    if (free_runtime) synurang_runtime_free(runtime);
}

static void synurang_stream_release_internal(SynurangStream* stream) {
    int destroy = 0;

    if (stream == NULL) return;
    synurang_mutex_lock(&stream->mutex);
    if (stream->ref_count != 0u) {
        --stream->ref_count;
        if (stream->ref_count == 0u) destroy = 1;
    }
    synurang_mutex_unlock(&stream->mutex);
    if (destroy) synurang_stream_destroy_final(stream);
}

SynurangStream* synurang_stream_retain(SynurangStream* stream) {
    if (stream == NULL) return NULL;
    synurang_mutex_lock(&stream->mutex);
    ++stream->ref_count;
    synurang_mutex_unlock(&stream->mutex);
    return stream;
}

void synurang_stream_release(SynurangStream* stream) {
    synurang_stream_release_internal(stream);
}

uint64_t synurang_stream_handle(const SynurangStream* stream) {
    return stream == NULL ? 0u : stream->handle;
}

static SynurangStream* synurang_registry_lookup(uint64_t handle) {
    SynurangStream* stream;

    if (handle == 0u) return NULL;
    synurang_mutex_lock(&g_registry_mutex);
    stream = g_registry_buckets[synurang_registry_bucket(handle)];
    while (stream != NULL && stream->handle != handle) {
        stream = stream->registry_next;
    }
    if (stream != NULL) {
        synurang_mutex_lock(&stream->mutex);
        ++stream->ref_count;
        synurang_mutex_unlock(&stream->mutex);
    }
    synurang_mutex_unlock(&g_registry_mutex);
    return stream;
}

/* Removes a registry entry and transfers its registry reference to the caller. */
static SynurangStream* synurang_registry_take(uint64_t handle) {
    SynurangStream** link;
    SynurangStream* stream = NULL;

    if (handle == 0u) return NULL;
    synurang_mutex_lock(&g_registry_mutex);
    link = &g_registry_buckets[synurang_registry_bucket(handle)];
    while (*link != NULL && (*link)->handle != handle) {
        link = &(*link)->registry_next;
    }
    if (*link != NULL) {
        stream = *link;
        *link = stream->registry_next;
        stream->registry_next = NULL;
        synurang_mutex_lock(&stream->mutex);
        stream->in_registry = 0;
        synurang_mutex_unlock(&stream->mutex);
    }
    synurang_mutex_unlock(&g_registry_mutex);
    return stream;
}

/* Like take(), but chooses any stream owned by runtime. */
static SynurangStream* synurang_registry_take_runtime(
    SynurangRuntime* runtime) {
    SynurangStream* stream = NULL;
    size_t bucket;

    synurang_mutex_lock(&g_registry_mutex);
    for (bucket = 0u; stream == NULL && bucket < SYNURANG_REGISTRY_BUCKETS;
         ++bucket) {
        SynurangStream** link = &g_registry_buckets[bucket];
        while (*link != NULL && (*link)->runtime != runtime) {
            link = &(*link)->registry_next;
        }
        if (*link != NULL) {
            stream = *link;
            *link = stream->registry_next;
            stream->registry_next = NULL;
            synurang_mutex_lock(&stream->mutex);
            stream->in_registry = 0;
            synurang_mutex_unlock(&stream->mutex);
        }
    }
    synurang_mutex_unlock(&g_registry_mutex);
    return stream;
}

SynurangStatus synurang_stream_write(SynurangStream* stream,
                                     const void* data,
                                     size_t data_len) {
    SynurangPayload* payload;
    SynurangRuntime* runtime;
    int notify_ready = 0;
    int notify_output = 0;

    if (stream == NULL || (data_len != 0u && data == NULL) ||
        data_len > (size_t)INT_MAX) {
        return SYNURANG_INVALID_ARGUMENT;
    }

    runtime = stream->runtime;

    synurang_mutex_lock(&stream->mutex);
    if (stream->cancelled || stream->output_terminal) {
        synurang_mutex_unlock(&stream->mutex);
        return SYNURANG_CLOSED;
    }
    if (synurang_stream_output_full_locked(stream)) {
        stream->writable_waiting = 1;
        synurang_mutex_unlock(&stream->mutex);
        return SYNURANG_WOULD_BLOCK;
    }
    ++stream->output_reserved;
    synurang_mutex_unlock(&stream->mutex);

    payload = synurang_payload_create(data, data_len);

    synurang_mutex_lock(&stream->mutex);
    --stream->output_reserved;
    if (payload == NULL) {
        if (!stream->cancelled && !stream->output_terminal &&
            stream->writable_waiting &&
            !synurang_stream_output_full_locked(stream)) {
            stream->writable_waiting = 0;
            stream->writable_pending = 1;
            notify_ready = synurang_stream_schedule_locked(stream);
        }
        synurang_mutex_unlock(&stream->mutex);
        synurang_runtime_notify(runtime, notify_ready);
        return SYNURANG_OUT_OF_MEMORY;
    }
    if (stream->cancelled || stream->output_terminal) {
        synurang_mutex_unlock(&stream->mutex);
        synurang_payload_destroy(payload);
        return SYNURANG_CLOSED;
    }

    notify_output = stream->output_count == 0u;
    if (stream->output_tail != NULL) {
        stream->output_tail->next = payload;
    } else {
        stream->output_head = payload;
    }
    stream->output_tail = payload;
    ++stream->output_count;
    synurang_cond_broadcast(&stream->state_cond);
    synurang_mutex_unlock(&stream->mutex);
    if (notify_output) {
        notify_output = synurang_runtime_should_notify_manual(runtime);
    }
    synurang_runtime_notify(runtime, notify_output);
    return SYNURANG_OK;
}

SynurangStatus synurang_stream_finish(SynurangStream* stream) {
    SynurangRuntime* runtime;
    int notify_output = 0;
    if (stream == NULL) return SYNURANG_INVALID_ARGUMENT;
    runtime = stream->runtime;

    synurang_mutex_lock(&stream->mutex);
    if (stream->output_terminal) {
        synurang_mutex_unlock(&stream->mutex);
        return SYNURANG_OK;
    }
    if (stream->cancelled) {
        synurang_mutex_unlock(&stream->mutex);
        return SYNURANG_CLOSED;
    }
    notify_output = stream->output_count == 0u;
    stream->output_terminal = 1;
    stream->terminal_status = SYNURANG_EOF;
    synurang_stream_end_input_locked(stream);
    synurang_mutex_unlock(&stream->mutex);
    if (notify_output) {
        notify_output = synurang_runtime_should_notify_manual(runtime);
    }
    synurang_runtime_notify(runtime, notify_output);
    return SYNURANG_OK;
}

SynurangStatus synurang_stream_fail(SynurangStream* stream,
                                    int status,
                                    const void* error_data,
                                    size_t error_len) {
    SynurangPayload* error;
    SynurangRuntime* runtime;
    int notify_output;

    if (stream == NULL || status >= 0 ||
        (error_len != 0u && error_data == NULL) ||
        error_len > (size_t)INT_MAX) {
        return SYNURANG_INVALID_ARGUMENT;
    }

    runtime = stream->runtime;

    /* Preserve the idempotent terminal contract without allocating or touching
     * caller payload bytes. A second check after allocation linearizes races
     * with a concurrent finish/fail/cancel. */
    synurang_mutex_lock(&stream->mutex);
    if (stream->output_terminal) {
        synurang_mutex_unlock(&stream->mutex);
        return SYNURANG_OK;
    }
    if (stream->cancelled) {
        synurang_mutex_unlock(&stream->mutex);
        return SYNURANG_CLOSED;
    }
    synurang_mutex_unlock(&stream->mutex);

    error = synurang_payload_create(error_data, error_len);
    if (error == NULL) {
        SynurangStatus result = SYNURANG_OUT_OF_MEMORY;
        synurang_mutex_lock(&stream->mutex);
        if (stream->output_terminal) {
            result = SYNURANG_OK;
        } else if (stream->cancelled) {
            result = SYNURANG_CLOSED;
        }
        synurang_mutex_unlock(&stream->mutex);
        return result;
    }

    synurang_mutex_lock(&stream->mutex);
    if (stream->output_terminal) {
        synurang_mutex_unlock(&stream->mutex);
        synurang_payload_destroy(error);
        return SYNURANG_OK;
    }
    if (stream->cancelled) {
        synurang_mutex_unlock(&stream->mutex);
        synurang_payload_destroy(error);
        return SYNURANG_CLOSED;
    }
    notify_output = stream->output_count == 0u;
    stream->output_terminal = 1;
    stream->terminal_status = status;
    stream->terminal_error = error;
    synurang_stream_end_input_locked(stream);
    synurang_mutex_unlock(&stream->mutex);
    if (notify_output) {
        notify_output = synurang_runtime_should_notify_manual(runtime);
    }
    synurang_runtime_notify(runtime, notify_output);
    return SYNURANG_OK;
}

SynurangStatus synurang_stream_fail_error(SynurangStream* stream,
                                          int32_t code,
                                          int32_t grpc_code,
                                          const char* message) {
    uint8_t* encoded;
    size_t encoded_len;
    SynurangStatus result;

    if (stream == NULL) return SYNURANG_INVALID_ARGUMENT;
    synurang_mutex_lock(&stream->mutex);
    if (stream->output_terminal) {
        synurang_mutex_unlock(&stream->mutex);
        return SYNURANG_OK;
    }
    if (stream->cancelled) {
        synurang_mutex_unlock(&stream->mutex);
        return SYNURANG_CLOSED;
    }
    synurang_mutex_unlock(&stream->mutex);

    if (message == NULL) message = "";
    encoded = synurang_error_response_copy(code, message, strlen(message),
                                           grpc_code, &encoded_len);
    if (encoded == NULL) {
        synurang_mutex_lock(&stream->mutex);
        if (stream->output_terminal) {
            result = SYNURANG_OK;
        } else if (stream->cancelled) {
            result = SYNURANG_CLOSED;
        } else {
            result = SYNURANG_OUT_OF_MEMORY;
        }
        synurang_mutex_unlock(&stream->mutex);
        return result;
    }
    result = synurang_stream_fail(stream, SYNURANG_ERROR, encoded, encoded_len);
    synurang_response_free(encoded);
    return result;
}

static SynurangEventKind synurang_stream_take_event_locked(
    SynurangStream* stream,
    SynurangPayload** message) {
    *message = NULL;

    if (stream->cancelled && !stream->cancel_dispatched) {
        stream->cancel_dispatched = 1;
        stream->open_pending = 0;
        stream->half_close_dispatched = 1;
        stream->writable_pending = 0;
        synurang_payload_list_destroy(stream->input_head);
        stream->input_head = NULL;
        stream->input_tail = NULL;
        stream->input_count = 0u;
        synurang_cond_broadcast(&stream->state_cond);
        return SYNURANG_EVENT_CANCEL;
    }
    if (stream->cancelled) return SYNURANG_EVENT_NONE;
    if (stream->output_terminal) return SYNURANG_EVENT_NONE;

    if (stream->open_pending) {
        stream->open_pending = 0;
        return SYNURANG_EVENT_OPEN;
    }
    if (stream->input_head != NULL) {
        *message = stream->input_head;
        stream->input_head = (*message)->next;
        (*message)->next = NULL;
        if (stream->input_head == NULL) stream->input_tail = NULL;
        if (stream->input_count != 0u) --stream->input_count;
        synurang_cond_broadcast(&stream->state_cond);
        return SYNURANG_EVENT_MESSAGE;
    }
    if (stream->half_closed && !stream->half_close_dispatched) {
        stream->half_close_dispatched = 1;
        return SYNURANG_EVENT_HALF_CLOSE;
    }
    if (stream->writable_pending) {
        stream->writable_pending = 0;
        return SYNURANG_EVENT_WRITABLE;
    }
    return SYNURANG_EVENT_NONE;
}

static SynurangStream* synurang_runtime_pop_ready(SynurangRuntime* runtime) {
    SynurangStream* stream;

    synurang_mutex_lock(&runtime->mutex);
    stream = runtime->ready_head;
    if (stream != NULL) {
        runtime->ready_head = stream->ready_next;
        if (runtime->ready_head == NULL) runtime->ready_tail = NULL;
        stream->ready_next = NULL;
    }
    synurang_mutex_unlock(&runtime->mutex);
    return stream;
}

static size_t synurang_runtime_poll_core(SynurangRuntime* runtime,
                                         size_t max_events) {
    size_t dispatched = 0u;

    if (runtime == NULL) return 0u;
    while (max_events == 0u || dispatched < max_events) {
        SynurangStream* stream = synurang_runtime_pop_ready(runtime);
        SynurangPayload* message;
        SynurangEventKind event;
        int notify;

        if (stream == NULL) break;

        synurang_mutex_lock(&stream->mutex);
        stream->queued = 0;
        stream->dispatching = 1;
        event = synurang_stream_take_event_locked(stream, &message);
        synurang_mutex_unlock(&stream->mutex);

        switch (event) {
            case SYNURANG_EVENT_OPEN:
                if (stream->callbacks.on_open != NULL) {
                    stream->callbacks.on_open(stream, stream->user_data);
                }
                break;
            case SYNURANG_EVENT_MESSAGE:
                if (stream->callbacks.on_message != NULL) {
                    stream->callbacks.on_message(stream, message->data,
                                                 message->len,
                                                 stream->user_data);
                }
                break;
            case SYNURANG_EVENT_HALF_CLOSE:
                if (stream->callbacks.on_half_close != NULL) {
                    stream->callbacks.on_half_close(stream, stream->user_data);
                }
                break;
            case SYNURANG_EVENT_WRITABLE:
                if (stream->callbacks.on_writable != NULL) {
                    stream->callbacks.on_writable(stream, stream->user_data);
                }
                break;
            case SYNURANG_EVENT_CANCEL:
                if (stream->callbacks.on_cancel != NULL) {
                    stream->callbacks.on_cancel(stream, stream->user_data);
                }
                break;
            case SYNURANG_EVENT_NONE:
            default:
                break;
        }

        synurang_payload_destroy(message);
        synurang_mutex_lock(&stream->mutex);
        stream->dispatching = 0;
        notify = synurang_stream_schedule_locked(stream);
        synurang_mutex_unlock(&stream->mutex);
        synurang_runtime_notify(runtime, notify);

        if (event != SYNURANG_EVENT_NONE) ++dispatched;
        synurang_stream_release_internal(stream); /* ready queue reference */
    }
    return dispatched;
}

static int synurang_runtime_begin_poll(SynurangRuntime* runtime,
                                       int allow_stopping) {
    int accepted = 0;
    synurang_mutex_lock(&runtime->mutex);
    if (allow_stopping || !runtime->stopping) {
        ++runtime->active_pollers;
        accepted = 1;
    }
    synurang_mutex_unlock(&runtime->mutex);
    return accepted;
}

static void synurang_runtime_end_poll(SynurangRuntime* runtime) {
    synurang_mutex_lock(&runtime->mutex);
    if (runtime->active_pollers != 0u) --runtime->active_pollers;
    if (runtime->active_pollers == 0u) {
        synurang_cond_broadcast(&runtime->state_cond);
    }
    synurang_mutex_unlock(&runtime->mutex);
}

static size_t synurang_runtime_poll_internal(SynurangRuntime* runtime,
                                             size_t max_events,
                                             int allow_stopping) {
    size_t dispatched;
    if (runtime == NULL ||
        !synurang_runtime_begin_poll(runtime, allow_stopping)) {
        return 0u;
    }
    dispatched = synurang_runtime_poll_core(runtime, max_events);
    synurang_runtime_end_poll(runtime);
    return dispatched;
}

size_t synurang_runtime_poll(SynurangRuntime* runtime, size_t max_events) {
    return synurang_runtime_poll_internal(runtime, max_events, 0);
}

int synurang_runtime_has_pending(SynurangRuntime* runtime) {
    int pending;
    if (runtime == NULL) return 0;
    synurang_mutex_lock(&runtime->mutex);
    pending = runtime->ready_head != NULL;
    synurang_mutex_unlock(&runtime->mutex);
    return pending;
}

#if !defined(SYNURANG_RUNTIME_NO_THREADS)
#if defined(_WIN32)
static DWORD WINAPI synurang_runtime_worker(void* user_data) {
#else
static void* synurang_runtime_worker(void* user_data) {
#endif
    SynurangRuntime* runtime = (SynurangRuntime*)user_data;

    for (;;) {
        int stop;
        synurang_mutex_lock(&runtime->mutex);
        while (runtime->ready_head == NULL && !runtime->workers_stop) {
            synurang_cond_wait(&runtime->ready_cond, &runtime->mutex);
        }
        stop = runtime->workers_stop && runtime->ready_head == NULL;
        synurang_mutex_unlock(&runtime->mutex);
        if (stop) break;
        (void)synurang_runtime_poll_internal(runtime, 1u, 1);
    }
#if defined(_WIN32)
    return 0;
#else
    return NULL;
#endif
}
#endif

static int synurang_runtime_init_options(
    const SynurangRuntimeOptions* options,
    SynurangRuntimeOptions* resolved) {
    size_t copy_size;

    *resolved = (SynurangRuntimeOptions)SYNURANG_RUNTIME_OPTIONS_INIT;
    if (options != NULL) {
        if (options->struct_size < sizeof(size_t)) return 0;
        copy_size = options->struct_size;
        if (copy_size > sizeof(*resolved)) copy_size = sizeof(*resolved);
        memcpy(resolved, options, copy_size);
        resolved->struct_size = sizeof(*resolved);
    }

    if (resolved->execution_mode != SYNURANG_EXECUTION_THREADED &&
        resolved->execution_mode != SYNURANG_EXECUTION_MANUAL) {
        return 0;
    }
#if defined(SYNURANG_RUNTIME_NO_THREADS)
    if (resolved->execution_mode == SYNURANG_EXECUTION_THREADED) return 0;
#endif
    if (resolved->worker_count == 0u) resolved->worker_count = 1u;
    if (resolved->inbound_queue_capacity == 0u) {
        resolved->inbound_queue_capacity =
            SYNURANG_DEFAULT_STREAM_QUEUE_CAPACITY;
    }
    if (resolved->outbound_queue_capacity == 0u) {
        resolved->outbound_queue_capacity =
            SYNURANG_DEFAULT_STREAM_QUEUE_CAPACITY;
    }
    return 1;
}

SynurangRuntime* synurang_runtime_create(
    const SynurangRuntimeOptions* options) {
    SynurangRuntimeOptions resolved;
    SynurangRuntime* runtime;

    if (!synurang_runtime_init_options(options, &resolved)) return NULL;

    runtime = (SynurangRuntime*)calloc(1u, sizeof(*runtime));
    if (runtime == NULL) return NULL;
    if (synurang_mutex_init(&runtime->mutex) != 0) {
        free(runtime);
        return NULL;
    }
    if (synurang_cond_init(&runtime->ready_cond) != 0) {
        synurang_mutex_destroy(&runtime->mutex);
        free(runtime);
        return NULL;
    }
    if (synurang_cond_init(&runtime->state_cond) != 0) {
        synurang_cond_destroy(&runtime->ready_cond);
        synurang_mutex_destroy(&runtime->mutex);
        free(runtime);
        return NULL;
    }

    runtime->execution_mode = resolved.execution_mode;
    runtime->worker_count = resolved.worker_count;
    runtime->inbound_queue_capacity = resolved.inbound_queue_capacity;
    runtime->outbound_queue_capacity = resolved.outbound_queue_capacity;
    runtime->wakeup = resolved.wakeup;
    runtime->wakeup_user_data = resolved.wakeup_user_data;

#if !defined(SYNURANG_RUNTIME_NO_THREADS)
    if (runtime->execution_mode == SYNURANG_EXECUTION_THREADED) {
        size_t i;
        if (runtime->worker_count > SIZE_MAX / sizeof(*runtime->workers)) {
            synurang_runtime_free(runtime);
            return NULL;
        }
        runtime->workers = (SynurangThread*)calloc(runtime->worker_count,
                                                   sizeof(*runtime->workers));
        if (runtime->workers == NULL) {
            synurang_runtime_free(runtime);
            return NULL;
        }
        for (i = 0u; i < runtime->worker_count; ++i) {
#if defined(_WIN32)
            runtime->workers[i] =
                CreateThread(NULL, 0u, synurang_runtime_worker, runtime, 0u,
                             NULL);
            if (runtime->workers[i] == NULL) {
#else
            if (pthread_create(&runtime->workers[i], NULL,
                               synurang_runtime_worker, runtime) != 0) {
#endif
                size_t j;
                synurang_mutex_lock(&runtime->mutex);
                runtime->workers_stop = 1;
                synurang_cond_broadcast(&runtime->ready_cond);
                synurang_mutex_unlock(&runtime->mutex);
                for (j = 0u; j < runtime->workers_started; ++j) {
#if defined(_WIN32)
                    (void)WaitForSingleObject(runtime->workers[j], INFINITE);
                    (void)CloseHandle(runtime->workers[j]);
#else
                    (void)pthread_join(runtime->workers[j], NULL);
#endif
                }
                runtime->workers_started = 0u;
                synurang_runtime_free(runtime);
                return NULL;
            }
            ++runtime->workers_started;
        }
    }
#endif
    return runtime;
}

/* g_registry_mutex is held by the caller. */
static SynurangRuntime* synurang_runtime_default_locked(void) {
    SynurangRuntime* runtime;
    runtime = g_default_runtime;
    if (runtime == NULL) {
        SynurangRuntimeOptions options = SYNURANG_RUNTIME_OPTIONS_INIT;
#if defined(SYNURANG_RUNTIME_NO_THREADS)
        options.execution_mode = SYNURANG_EXECUTION_MANUAL;
#endif
        runtime = synurang_runtime_create(&options);
        if (runtime != NULL) g_default_runtime = runtime;
    }
    return runtime;
}

SynurangRuntime* synurang_runtime_default(void) {
    SynurangRuntime* runtime;
    synurang_mutex_lock(&g_registry_mutex);
    runtime = synurang_runtime_default_locked();
    synurang_mutex_unlock(&g_registry_mutex);
    return runtime;
}

void synurang_runtime_shutdown_default(void) {
    SynurangRuntime* runtime;

    synurang_mutex_lock(&g_registry_mutex);
    runtime = g_default_runtime;
    g_default_runtime = NULL;
    synurang_mutex_unlock(&g_registry_mutex);
    if (runtime != NULL) synurang_runtime_destroy(runtime);
}

uint64_t synurang_stream_open(SynurangRuntime* runtime,
                              const SynurangStreamCallbacks* callbacks,
                              void* user_data) {
    SynurangStream* stream;
    size_t callbacks_size;
    uint64_t handle;
    int use_default = runtime == NULL;
    int notify;

    if (callbacks == NULL || callbacks->struct_size < sizeof(size_t)) return 0u;

    stream = (SynurangStream*)calloc(1u, sizeof(*stream));
    if (stream == NULL) return 0u;
    if (synurang_mutex_init(&stream->mutex) != 0) {
        free(stream);
        return 0u;
    }
    if (synurang_cond_init(&stream->state_cond) != 0) {
        synurang_mutex_destroy(&stream->mutex);
        free(stream);
        return 0u;
    }

    callbacks_size = callbacks->struct_size;
    if (callbacks_size > sizeof(stream->callbacks)) {
        callbacks_size = sizeof(stream->callbacks);
    }
    memset(&stream->callbacks, 0, sizeof(stream->callbacks));
    memcpy(&stream->callbacks, callbacks, callbacks_size);
    stream->callbacks.struct_size = sizeof(stream->callbacks);
    stream->user_data = user_data;
    stream->ref_count = 2u; /* registry reference + this Open call */
    stream->in_registry = 1;
    stream->open_pending = 1;

    /* A NULL runtime is resolved while holding the same global lock used by
     * shutdown_default(). Claim an opening/stream reference before exposing
     * that pointer, so shutdown cannot free it between resolution and publish. */
    if (use_default) {
        synurang_mutex_lock(&g_registry_mutex);
        runtime = synurang_runtime_default_locked();
        if (runtime == NULL) {
            synurang_mutex_unlock(&g_registry_mutex);
            synurang_cond_destroy(&stream->state_cond);
            synurang_mutex_destroy(&stream->mutex);
            free(stream);
            return 0u;
        }
    }

    synurang_mutex_lock(&runtime->mutex);
    if (runtime->stopping) {
        synurang_mutex_unlock(&runtime->mutex);
        if (use_default) synurang_mutex_unlock(&g_registry_mutex);
        synurang_cond_destroy(&stream->state_cond);
        synurang_mutex_destroy(&stream->mutex);
        free(stream);
        return 0u;
    }
    ++runtime->stream_count;
    ++runtime->opening_count;
    synurang_mutex_unlock(&runtime->mutex);
    if (use_default) synurang_mutex_unlock(&g_registry_mutex);
    stream->runtime = runtime;

    synurang_mutex_lock(&g_registry_mutex);
    stream->handle = g_next_handle++;
    if (stream->handle == 0u) stream->handle = g_next_handle++;
    handle = stream->handle;
    {
        SynurangStream** bucket =
            &g_registry_buckets[synurang_registry_bucket(handle)];
        stream->registry_next = *bucket;
        *bucket = stream;
    }
    synurang_mutex_unlock(&g_registry_mutex);

    synurang_mutex_lock(&stream->mutex);
    notify = synurang_stream_schedule_locked(stream);
    synurang_mutex_unlock(&stream->mutex);
    synurang_runtime_notify(runtime, notify);

    /* Keep both the runtime opening claim and the private stream reference
     * through a possibly synchronous wakeup/poll. The callback may close the
     * handle and consume every published reference before wakeup returns. */
    synurang_mutex_lock(&runtime->mutex);
    --runtime->opening_count;
    if (runtime->opening_count == 0u) {
        synurang_cond_broadcast(&runtime->state_cond);
    }
    synurang_mutex_unlock(&runtime->mutex);
    synurang_stream_release_internal(stream); /* Open call reference */
    return handle;
}

static void synurang_stream_cancel_taken(SynurangStream* stream) {
    SynurangRuntime* runtime = stream->runtime;
    int notify = 0;

    synurang_mutex_lock(&stream->mutex);
    if (!stream->cancelled) {
        stream->cancelled = 1;
        if (stream->output_terminal) {
            stream->cancel_dispatched = 1;
            stream->open_pending = 0;
            stream->half_close_dispatched = 1;
            stream->writable_pending = 0;
            synurang_payload_list_destroy(stream->input_head);
            stream->input_head = NULL;
            stream->input_tail = NULL;
            stream->input_count = 0u;
        } else {
            notify = synurang_stream_schedule_locked(stream);
        }
    }
    synurang_cond_broadcast(&stream->state_cond);
    synurang_mutex_unlock(&stream->mutex);
    synurang_runtime_notify(runtime, notify);
    synurang_stream_release_internal(stream); /* transferred registry ref */
}

static void synurang_runtime_free(SynurangRuntime* runtime) {
    if (runtime == NULL) return;
#if !defined(SYNURANG_RUNTIME_NO_THREADS)
    free(runtime->workers);
#endif
    synurang_cond_destroy(&runtime->state_cond);
    synurang_cond_destroy(&runtime->ready_cond);
    synurang_mutex_destroy(&runtime->mutex);
    free(runtime);
}

void synurang_runtime_destroy(SynurangRuntime* runtime) {
    SynurangStream* stream;

    if (runtime == NULL) return;

    /* Be defensive if a caller destroys default() directly instead of using
     * shutdown_default(): never leave a process-global dangling pointer. */
    synurang_mutex_lock(&g_registry_mutex);
    if (g_default_runtime == runtime) g_default_runtime = NULL;
    synurang_mutex_unlock(&g_registry_mutex);

    synurang_mutex_lock(&runtime->mutex);
    if (runtime->stopping) {
        synurang_mutex_unlock(&runtime->mutex);
        return;
    }
    runtime->stopping = 1;
#if !defined(SYNURANG_RUNTIME_NO_THREADS)
    while (runtime->opening_count != 0u) {
        synurang_cond_wait(&runtime->state_cond, &runtime->mutex);
    }
#endif
    synurang_mutex_unlock(&runtime->mutex);

    while ((stream = synurang_registry_take_runtime(runtime)) != NULL) {
        synurang_stream_cancel_taken(stream);
    }

#if !defined(SYNURANG_RUNTIME_NO_THREADS)
    if (runtime->execution_mode == SYNURANG_EXECUTION_THREADED) {
        size_t i;
        synurang_mutex_lock(&runtime->mutex);
        runtime->workers_stop = 1;
        synurang_cond_broadcast(&runtime->ready_cond);
        synurang_mutex_unlock(&runtime->mutex);
        for (i = 0u; i < runtime->workers_started; ++i) {
#if defined(_WIN32)
            (void)WaitForSingleObject(runtime->workers[i], INFINITE);
            (void)CloseHandle(runtime->workers[i]);
#else
            (void)pthread_join(runtime->workers[i], NULL);
#endif
        }
        runtime->workers_started = 0u;
    }

    /* A public/manual poll which entered before stopping may finish a callback
     * by enqueueing its deferred cancel after workers have gone idle. Wait for
     * every such poller, then use the destroy thread to drain the stable tail. */
    synurang_mutex_lock(&runtime->mutex);
    while (runtime->active_pollers != 0u) {
        synurang_cond_wait(&runtime->state_cond, &runtime->mutex);
    }
    synurang_mutex_unlock(&runtime->mutex);
    (void)synurang_runtime_poll_internal(runtime, 0u, 1);

    synurang_mutex_lock(&runtime->mutex);
    while (runtime->stream_count != 0u) {
        synurang_cond_wait(&runtime->state_cond, &runtime->mutex);
    }
    synurang_mutex_unlock(&runtime->mutex);
    synurang_runtime_free(runtime);
#else
    (void)synurang_runtime_poll_internal(runtime, 0u, 1);
    synurang_mutex_lock(&runtime->mutex);
    if (runtime->stream_count != 0u) {
        /* A retained async token violated the release-before-destroy contract.
         * Keep the runtime alive until its last release rather than dangling. */
        runtime->deferred_free = 1;
        synurang_mutex_unlock(&runtime->mutex);
        return;
    }
    synurang_mutex_unlock(&runtime->mutex);
    synurang_runtime_free(runtime);
#endif
}

static int synurang_stream_send_internal(uint64_t handle,
                                         const char* data,
                                         int data_len,
                                         int allow_blocking) {
    SynurangStream* stream;
    SynurangPayload* payload = NULL;
    SynurangRuntime* runtime;
    size_t pumped;
    int notify = 0;
    int result = SYNURANG_OK;

    if (data_len < 0 || (data_len != 0 && data == NULL)) {
        return SYNURANG_INVALID_ARGUMENT;
    }
    stream = synurang_registry_lookup(handle);
    if (stream == NULL) return SYNURANG_NOT_FOUND;
    runtime = stream->runtime;

    synurang_mutex_lock(&stream->mutex);
    while (!stream->cancelled && !stream->half_closed &&
           !stream->output_terminal &&
           synurang_stream_input_full_locked(stream)) {
        if (!allow_blocking) {
            result = SYNURANG_WOULD_BLOCK;
            break;
        }
#if !defined(SYNURANG_RUNTIME_NO_THREADS)
        if (runtime->execution_mode == SYNURANG_EXECUTION_THREADED) {
            synurang_cond_wait(&stream->state_cond, &stream->mutex);
            continue;
        }
#endif
        /* A manual runtime owns no worker, so the blocking ABI call drains the
         * queue itself rather than reporting WOULD_BLOCK forever. */
        synurang_mutex_unlock(&stream->mutex);
        pumped = synurang_runtime_poll_internal(runtime, 1u, 0);
        synurang_mutex_lock(&stream->mutex);
        /* Another poller may have consumed the ready event while this call had
         * the stream unlocked. Decide WOULD_BLOCK only from the current state;
         * otherwise let the loop observe newly freed capacity or terminal. */
        if (pumped == 0u && !stream->cancelled && !stream->half_closed &&
            !stream->output_terminal &&
            synurang_stream_input_full_locked(stream)) {
            result = SYNURANG_WOULD_BLOCK;
            break;
        }
    }

    if (result == SYNURANG_OK &&
        (stream->cancelled || stream->half_closed ||
         stream->output_terminal)) {
        result = SYNURANG_CLOSED;
    }
    if (result == SYNURANG_OK) {
        ++stream->input_reserved;
    }
    synurang_mutex_unlock(&stream->mutex);

    if (result != SYNURANG_OK) {
        synurang_stream_release_internal(stream);
        return result;
    }

    payload = synurang_payload_create(data, (size_t)data_len);

    synurang_mutex_lock(&stream->mutex);
    --stream->input_reserved;
    if (payload == NULL) {
        synurang_cond_broadcast(&stream->state_cond);
        result = SYNURANG_OUT_OF_MEMORY;
    } else if (stream->cancelled || stream->half_closed ||
               stream->output_terminal) {
        synurang_cond_broadcast(&stream->state_cond);
        result = SYNURANG_CLOSED;
    } else {
        if (stream->input_tail != NULL) {
            stream->input_tail->next = payload;
        } else {
            stream->input_head = payload;
        }
        stream->input_tail = payload;
        ++stream->input_count;
        payload = NULL;
        notify = synurang_stream_schedule_locked(stream);
    }
    synurang_mutex_unlock(&stream->mutex);
    synurang_runtime_notify(runtime, notify);

    synurang_payload_destroy(payload);
    synurang_stream_release_internal(stream);
    return result;
}

int Synurang_Stream_Send(uint64_t handle, char* data, int data_len) {
    return synurang_stream_send_internal(handle, data, data_len, 1);
}

int Synurang_Stream_TrySend(uint64_t handle,
                            const char* data,
                            int data_len) {
    return synurang_stream_send_internal(handle, data, data_len, 0);
}

static char* synurang_stream_recv_internal(uint64_t handle,
                                           int* resp_len,
                                           int* status,
                                           int allow_blocking) {
    SynurangStream* stream;
    SynurangRuntime* runtime;
    SynurangPayload* payload = NULL;
    char* result = NULL;
    size_t pumped;
    int result_status = SYNURANG_PENDING;
    int result_len = 0;
    int notify = 0;

    if (resp_len != NULL) *resp_len = 0;
    if (status != NULL) *status = SYNURANG_PENDING;

    stream = synurang_registry_lookup(handle);
    if (stream == NULL) {
        if (status != NULL) *status = SYNURANG_NOT_FOUND;
        return NULL;
    }
    runtime = stream->runtime;

    synurang_mutex_lock(&stream->mutex);
    while (stream->output_head == NULL && !stream->output_terminal &&
           !stream->cancelled) {
        if (!allow_blocking) break;
#if !defined(SYNURANG_RUNTIME_NO_THREADS)
        if (runtime->execution_mode == SYNURANG_EXECUTION_THREADED) {
            synurang_cond_wait(&stream->state_cond, &stream->mutex);
            continue;
        }
#endif
        /* Same contract as Send: on a manual runtime the calling thread is the
         * executor, so pump one event and re-check. A pass that dispatches
         * nothing means no callback can still publish output, and the caller
         * gets PENDING instead of spinning. */
        synurang_mutex_unlock(&stream->mutex);
        pumped = synurang_runtime_poll_internal(runtime, 1u, 0);
        synurang_mutex_lock(&stream->mutex);
        if (pumped == 0u) break;
    }

    if (stream->output_head != NULL) {
        int was_full = synurang_stream_output_full_locked(stream);
        payload = stream->output_head;
        stream->output_head = payload->next;
        payload->next = NULL;
        if (stream->output_head == NULL) stream->output_tail = NULL;
        if (stream->output_count != 0u) --stream->output_count;
        result = (char*)payload->data;
        payload->data = NULL;
        result_len = (int)payload->len;
        result_status = SYNURANG_OK;
        if (was_full && stream->writable_waiting &&
            !stream->output_terminal && !stream->cancelled &&
            !synurang_stream_output_full_locked(stream)) {
            stream->writable_waiting = 0;
            stream->writable_pending = 1;
            notify = synurang_stream_schedule_locked(stream);
        }
        synurang_cond_broadcast(&stream->state_cond);
    } else if (stream->output_terminal) {
        if (stream->terminal_status < 0 && !stream->terminal_delivered) {
            payload = stream->terminal_error;
            stream->terminal_error = NULL;
            stream->terminal_delivered = 1;
            result_status = stream->terminal_status;
            if (payload != NULL) {
                result = (char*)payload->data;
                payload->data = NULL;
                result_len = (int)payload->len;
            }
        } else {
            result_status = SYNURANG_EOF;
        }
    } else if (stream->cancelled) {
        result_status = SYNURANG_CLOSED;
    }
    synurang_mutex_unlock(&stream->mutex);
    synurang_runtime_notify(runtime, notify);

    synurang_payload_destroy(payload);
    synurang_stream_release_internal(stream);
    if (resp_len != NULL) *resp_len = result_len;
    if (status != NULL) *status = result_status;
    return result;
}

char* Synurang_Stream_Recv(uint64_t handle, int* resp_len, int* status) {
    return synurang_stream_recv_internal(handle, resp_len, status, 1);
}

char* Synurang_Stream_TryRecv(uint64_t handle,
                              int* resp_len,
                              int* status) {
    return synurang_stream_recv_internal(handle, resp_len, status, 0);
}

void Synurang_Stream_CloseSend(uint64_t handle) {
    SynurangStream* stream = synurang_registry_lookup(handle);
    SynurangRuntime* runtime;
    int notify = 0;

    if (stream == NULL) return;
    runtime = stream->runtime;
    synurang_mutex_lock(&stream->mutex);
    if (!stream->cancelled && !stream->half_closed &&
        !stream->output_terminal) {
        stream->half_closed = 1;
        notify = synurang_stream_schedule_locked(stream);
    }
    synurang_cond_broadcast(&stream->state_cond);
    synurang_mutex_unlock(&stream->mutex);
    synurang_runtime_notify(runtime, notify);
    synurang_stream_release_internal(stream);
}

void Synurang_Stream_Close(uint64_t handle) {
    SynurangStream* stream = synurang_registry_take(handle);
    if (stream != NULL) synurang_stream_cancel_taken(stream);
}
