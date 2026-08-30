#ifndef SYNURANG_C_RUNTIME_H_
#define SYNURANG_C_RUNTIME_H_

#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32) && defined(SYNURANG_C_RUNTIME_SHARED)
#if defined(SYNURANG_C_RUNTIME_BUILDING)
#define SYNURANG_C_RUNTIME_API __declspec(dllexport)
#else
#define SYNURANG_C_RUNTIME_API __declspec(dllimport)
#endif
#elif defined(__GNUC__) || defined(__clang__)
#define SYNURANG_C_RUNTIME_API __attribute__((visibility("default")))
#else
#define SYNURANG_C_RUNTIME_API
#endif

#ifdef __cplusplus
extern "C" {
#endif

#define SYNURANG_DEFAULT_STREAM_QUEUE_CAPACITY 16u

typedef struct SynurangRuntime SynurangRuntime;
typedef struct SynurangStream SynurangStream;

/* DATA and OK deliberately share zero with the existing streaming ABI.
 * EOF is one for the same reason. PENDING is returned when a non-blocking or
 * manual operation cannot make immediate progress. All failures are negative.
 * SYNURANG_ERROR keeps -1 because that is the generic negative marker hosts
 * expect on the wire; every other failure has a distinct value. */
typedef enum SynurangStatus {
    SYNURANG_OK = 0,
    SYNURANG_EOF = 1,
    SYNURANG_PENDING = 3,
    SYNURANG_ERROR = -1,
    SYNURANG_NOT_FOUND = -2,
    SYNURANG_CLOSED = -3,
    SYNURANG_WOULD_BLOCK = -4,
    SYNURANG_OUT_OF_MEMORY = -5,
    SYNURANG_SHUTTING_DOWN = -6,
    SYNURANG_INTERNAL = -7,
    SYNURANG_INVALID_ARGUMENT = -8
} SynurangStatus;

typedef enum SynurangExecutionMode {
    /* Runtime-owned worker threads call the same poll core used by MANUAL. */
    SYNURANG_EXECUTION_THREADED = 0,
    /* No runtime thread is created. The embedding event loop calls poll(). */
    SYNURANG_EXECUTION_MANUAL = 1
} SynurangExecutionMode;

/* Called in MANUAL mode after callback work changes the ready queue from empty
 * to non-empty, or after a stream changes from having no readable output to
 * having data/EOF/error available. It may run on any producer thread and must
 * return promptly. A libuv embedding normally calls uv_async_send(); a
 * WebAssembly embedding normally schedules a microtask. The scheduled task
 * calls synurang_runtime_poll() and/or drains known stream handles with
 * Synurang_Stream_TryRecv(). The callback must not destroy the runtime. */
typedef void (*SynurangWakeupFn)(void* user_data);

typedef struct SynurangRuntimeOptions {
    size_t struct_size;
    SynurangExecutionMode execution_mode;
    size_t worker_count;
    size_t inbound_queue_capacity;
    size_t outbound_queue_capacity;
    SynurangWakeupFn wakeup;
    void* wakeup_user_data;
} SynurangRuntimeOptions;

#define SYNURANG_RUNTIME_OPTIONS_INIT                                      \
    {                                                                     \
        sizeof(SynurangRuntimeOptions), SYNURANG_EXECUTION_THREADED, 1u,  \
            SYNURANG_DEFAULT_STREAM_QUEUE_CAPACITY,                       \
            SYNURANG_DEFAULT_STREAM_QUEUE_CAPACITY, NULL, NULL            \
    }

/* Stream callbacks are serialized per stream. With a threaded runtime they
 * execute on one of its workers; with a manual runtime they execute inside an
 * explicit poll or the legacy blocking ABI's internal manual pump. Message
 * bytes are borrowed for the duration of the callback. The stream argument is
 * also borrowed: retain it before starting an asynchronous operation and
 * release it from that operation's completion or cancellation path.
 *
 * on_destroy is called exactly once after the handle has been removed and all
 * runtime, callback, and explicitly-retained stream references are gone. It
 * is the place for a generated adapter to free per-stream user_data. */
typedef struct SynurangStreamCallbacks {
    size_t struct_size;
    void (*on_open)(SynurangStream* stream, void* user_data);
    void (*on_message)(SynurangStream* stream,
                       const uint8_t* data,
                       size_t data_len,
                       void* user_data);
    void (*on_half_close)(SynurangStream* stream, void* user_data);
    void (*on_writable)(SynurangStream* stream, void* user_data);
    void (*on_cancel)(SynurangStream* stream, void* user_data);
    void (*on_destroy)(void* user_data);
} SynurangStreamCallbacks;

#define SYNURANG_STREAM_CALLBACKS_INIT                                    \
    {                                                                     \
        sizeof(SynurangStreamCallbacks), NULL, NULL, NULL, NULL, NULL, NULL \
    }

/* options == NULL creates a threaded runtime with one worker and bounded
 * queues of SYNURANG_DEFAULT_STREAM_QUEUE_CAPACITY entries. In a build with
 * SYNURANG_RUNTIME_NO_THREADS, only MANUAL is accepted. */
SYNURANG_C_RUNTIME_API SynurangRuntime* synurang_runtime_create(
    const SynurangRuntimeOptions* options);

/* Borrowed pointer to the process-wide default runtime. Threadless builds use
 * MANUAL; other builds use THREADED. Direct uses of this borrowed pointer must
 * be externally synchronized with shutdown_default(). Prefer
 * synurang_stream_open(NULL, ...) when opening on the default runtime: that
 * path synchronizes its lifetime internally. Do not destroy this pointer
 * directly. */
SYNURANG_C_RUNTIME_API SynurangRuntime* synurang_runtime_default(void);

/* Stops and releases the current default runtime. A later default() or Open
 * lazily creates a fresh one. Generated unregister/DSO teardown code should
 * call this after closing its active streams and before dlclose. */
SYNURANG_C_RUNTIME_API void synurang_runtime_shutdown_default(void);

/* Dispatch at most max_events callbacks without blocking. max_events == 0
 * means "drain the current ready queue". The return value is the number of
 * callbacks dispatched. Fairness is per event, not per stream. */
SYNURANG_C_RUNTIME_API size_t synurang_runtime_poll(
    SynurangRuntime* runtime,
    size_t max_events);

SYNURANG_C_RUNTIME_API int synurang_runtime_has_pending(
    SynurangRuntime* runtime);

/* Stops accepting new streams, waits for already-entered poll calls, cancels
 * existing streams, drains their runtime callbacks, and joins owned workers.
 * Thread-capable builds wait for explicitly retained stream references. A
 * SYNURANG_RUNTIME_NO_THREADS build cannot wait: destroy returns after marking
 * the runtime for deferred free, and its storage is freed by the last stream
 * release. In both modes, cancel outstanding async work and release retained
 * references before destroy whenever possible. Do not start a new runtime
 * operation concurrently with destroy, and do not call it from a stream or
 * wakeup callback. */
SYNURANG_C_RUNTIME_API void synurang_runtime_destroy(
    SynurangRuntime* runtime);

/* Called by generated service-specific Open adapters. A NULL runtime selects
 * synurang_runtime_default(). callbacks is copied. Ownership of user_data is
 * transferred only on success; on a zero return the caller must free it and
 * on_destroy is not called. Zero is returned on allocation failure or while
 * the runtime is shutting down. */
SYNURANG_C_RUNTIME_API uint64_t synurang_stream_open(
    SynurangRuntime* runtime,
    const SynurangStreamCallbacks* callbacks,
    void* user_data);

SYNURANG_C_RUNTIME_API uint64_t synurang_stream_handle(
    const SynurangStream* stream);

SYNURANG_C_RUNTIME_API SynurangStream* synurang_stream_retain(
    SynurangStream* stream);

SYNURANG_C_RUNTIME_API void synurang_stream_release(
    SynurangStream* stream);

/* Callback-side response operations. write() copies data before returning.
 * A full bounded response queue returns WOULD_BLOCK before accessing data and
 * arranges one later on_writable callback after a receiver frees capacity.
 * finish() and fail() terminate the entire RPC: future Send calls return
 * CLOSED and queued/pending input callbacks are discarded. Already queued
 * responses remain readable, followed by EOF or the supplied serialized
 * core.v1.Error (whose status must be negative). Normal terminal completion
 * does not call on_cancel. Terminal operations are idempotent when repeated
 * with the same stream. */
SYNURANG_C_RUNTIME_API SynurangStatus synurang_stream_write(
    SynurangStream* stream,
    const void* data,
    size_t data_len);

SYNURANG_C_RUNTIME_API SynurangStatus synurang_stream_finish(
    SynurangStream* stream);

SYNURANG_C_RUNTIME_API SynurangStatus synurang_stream_fail(
    SynurangStream* stream,
    int status,
    const void* error_data,
    size_t error_len);

/* Convenience form which encodes core.v1.Error and publishes it with stream
 * status SYNURANG_ERROR (the generic negative ABI error marker). */
SYNURANG_C_RUNTIME_API SynurangStatus synurang_stream_fail_error(
    SynurangStream* stream,
    int32_t code,
    int32_t grpc_code,
    const char* message);

/* Common response allocator used by generated unary adapters and stream Recv.
 * response_copy returns a distinct, freeable allocation for an empty payload.
 */
SYNURANG_C_RUNTIME_API uint8_t* synurang_response_copy(
    const void* data,
    size_t data_len);

/* Encodes core.v1.Error { code: 1, message: 2, grpc_code: 3 } without taking
 * a protobuf runtime dependency. out_len is required. */
SYNURANG_C_RUNTIME_API uint8_t* synurang_error_response_copy(
    int32_t code,
    const char* message,
    size_t message_len,
    int32_t grpc_code,
    size_t* out_len);

SYNURANG_C_RUNTIME_API void synurang_response_free(void* data);

/* Existing plugin ABI. In THREADED mode Send and Recv wait for capacity/data.
 * In MANUAL mode they never block; the calling thread becomes the executor and
 * dispatches pending callbacks until the operation completes or a pass runs
 * nothing, so a host that knows only this ABI can still drive a manual or
 * threadless plugin. Send reports WOULD_BLOCK and Recv reports PENDING only
 * once no callback can make further progress. Event-loop integrations should
 * still prefer TrySend/TryRecv: they never explicitly pump stream callbacks
 * and let the embedding drive synurang_runtime_poll() on its own schedule.
 * They can invoke the configured wakeup; if that wakeup polls synchronously,
 * callbacks may therefore re-enter before the Try call returns. Queue capacity
 * is reserved before input bytes are copied, so WOULD_BLOCK does not access
 * data. */
SYNURANG_C_RUNTIME_API int Synurang_Stream_Send(
    uint64_t handle,
    char* data,
    int data_len);

SYNURANG_C_RUNTIME_API int Synurang_Stream_TrySend(
    uint64_t handle,
    const char* data,
    int data_len);

SYNURANG_C_RUNTIME_API char* Synurang_Stream_Recv(
    uint64_t handle,
    int* resp_len,
    int* status);

SYNURANG_C_RUNTIME_API char* Synurang_Stream_TryRecv(
    uint64_t handle,
    int* resp_len,
    int* status);

SYNURANG_C_RUNTIME_API void Synurang_Stream_CloseSend(uint64_t handle);
SYNURANG_C_RUNTIME_API void Synurang_Stream_Close(uint64_t handle);
SYNURANG_C_RUNTIME_API void Synurang_Free(char* ptr);

#ifdef __cplusplus
}  /* extern "C" */
#endif

#endif  /* SYNURANG_C_RUNTIME_H_ */
