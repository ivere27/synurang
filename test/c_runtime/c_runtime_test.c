#define _POSIX_C_SOURCE 200809L

#include <synurang/c_runtime.h>

#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#ifndef SYNURANG_TEST_MANUAL_ONLY
#include <pthread.h>
#include <sched.h>
#endif

#define CHECK(condition)                                                     \
    do {                                                                     \
        if (!(condition)) {                                                  \
            fprintf(stderr, "CHECK failed at %s:%d: %s\n",                 \
                    __FILE__, __LINE__, #condition);                         \
            return 1;                                                        \
        }                                                                    \
    } while (0)

_Static_assert(SYNURANG_INVALID_ARGUMENT == -8,
               "INVALID_ARGUMENT must use its distinct status value");
_Static_assert(SYNURANG_INVALID_ARGUMENT != SYNURANG_ERROR,
               "invalid arguments must not alias generic wire errors");

typedef struct TestContext {
    atomic_int opens;
    atomic_int messages;
    atomic_int half_closes;
    atomic_int writables;
    atomic_int cancels;
    atomic_int destroys;
    atomic_int first_write_status;
    atomic_int second_write_status;
    atomic_int retry_write_status;
    atomic_int terminal_status;
    atomic_int active_callbacks;
    atomic_int serialization_violations;
    const char* first_response;
    const char* second_response;
    const char* failure_data;
    int failure_status;
    int retry_second;
    int retain_on_open;
    int fail_after_write;
    int finish_on_message;
    int serialization_check;
    SynurangStream* retained;
} TestContext;

static void on_open(SynurangStream* stream, void* user_data) {
    TestContext* context = (TestContext*)user_data;
    if (context->retain_on_open) {
        context->retained = synurang_stream_retain(stream);
    }
    atomic_fetch_add(&context->opens, 1);
}

static void on_message(SynurangStream* stream,
                       const uint8_t* data,
                       size_t data_len,
                       void* user_data) {
    TestContext* context = (TestContext*)user_data;
    SynurangStatus status;
    (void)data;
    (void)data_len;
    atomic_fetch_add(&context->messages, 1);

    if (context->serialization_check) {
        struct timespec pause = {0, 1000000L};
        if (atomic_fetch_add(&context->active_callbacks, 1) != 0) {
            atomic_fetch_add(&context->serialization_violations, 1);
        }
        (void)nanosleep(&pause, NULL);
        atomic_fetch_sub(&context->active_callbacks, 1);
        return;
    }

    if (context->failure_status < 0 && !context->fail_after_write) {
        status = synurang_stream_fail(
            stream,
            context->failure_status,
            context->failure_data,
            strlen(context->failure_data));
        atomic_store(&context->first_write_status, (int)status);
        return;
    }

    status = synurang_stream_write(
        stream, context->first_response, strlen(context->first_response));
    atomic_store(&context->first_write_status, (int)status);

    if (context->second_response != NULL) {
        status = synurang_stream_write(
            stream, context->second_response, strlen(context->second_response));
        atomic_store(&context->second_write_status, (int)status);
        if (status == SYNURANG_WOULD_BLOCK) {
            context->retry_second = 1;
        }
    }

    if (context->failure_status < 0) {
        status = synurang_stream_fail(
            stream,
            context->failure_status,
            context->failure_data,
            strlen(context->failure_data));
        atomic_store(&context->terminal_status, (int)status);
    }

    if (context->finish_on_message) {
        status = synurang_stream_finish(stream);
        atomic_store(&context->terminal_status, (int)status);
    }
}

static void on_half_close(SynurangStream* stream, void* user_data) {
    TestContext* context = (TestContext*)user_data;
    atomic_fetch_add(&context->half_closes, 1);
    (void)synurang_stream_finish(stream);
}

static void on_writable(SynurangStream* stream, void* user_data) {
    TestContext* context = (TestContext*)user_data;
    SynurangStatus status;
    atomic_fetch_add(&context->writables, 1);
    if (!context->retry_second) {
        return;
    }
    context->retry_second = 0;
    status = synurang_stream_write(
        stream, context->second_response, strlen(context->second_response));
    atomic_store(&context->retry_write_status, (int)status);
}

static void on_cancel(SynurangStream* stream, void* user_data) {
    TestContext* context = (TestContext*)user_data;
    (void)stream;
    atomic_fetch_add(&context->cancels, 1);
    if (context->retained != NULL) {
        synurang_stream_release(context->retained);
        context->retained = NULL;
    }
}

static void on_destroy(void* user_data) {
    TestContext* context = (TestContext*)user_data;
    atomic_fetch_add(&context->destroys, 1);
}

static SynurangStreamCallbacks test_callbacks(void) {
    SynurangStreamCallbacks callbacks = SYNURANG_STREAM_CALLBACKS_INIT;
    callbacks.on_open = on_open;
    callbacks.on_message = on_message;
    callbacks.on_half_close = on_half_close;
    callbacks.on_writable = on_writable;
    callbacks.on_cancel = on_cancel;
    callbacks.on_destroy = on_destroy;
    return callbacks;
}

static void count_wakeup(void* user_data) {
    atomic_int* count = (atomic_int*)user_data;
    atomic_fetch_add(count, 1);
}

static int receive_equals(uint64_t handle,
                          int nonblocking,
                          const char* expected) {
    int response_len = -1;
    int status = SYNURANG_INTERNAL;
    char* response;
    if (nonblocking) {
        response = Synurang_Stream_TryRecv(handle, &response_len, &status);
    } else {
        response = Synurang_Stream_Recv(handle, &response_len, &status);
    }
    CHECK(status == SYNURANG_OK);
    CHECK(response != NULL);
    CHECK(response_len == (int)strlen(expected));
    CHECK(memcmp(response, expected, (size_t)response_len) == 0);
    Synurang_Free(response);
    return 0;
}

typedef struct ReentrantOpenContext {
    SynurangRuntime* runtime;
    atomic_int wakeups;
    atomic_int opens;
    atomic_int cancels;
    atomic_int destroys;
} ReentrantOpenContext;

static void reentrant_open_wakeup(void* user_data) {
    ReentrantOpenContext* context = (ReentrantOpenContext*)user_data;
    atomic_fetch_add(&context->wakeups, 1);
    (void)synurang_runtime_poll(context->runtime, 0u);
}

static void reentrant_open_on_open(SynurangStream* stream, void* user_data) {
    ReentrantOpenContext* context = (ReentrantOpenContext*)user_data;
    atomic_fetch_add(&context->opens, 1);
    Synurang_Stream_Close(synurang_stream_handle(stream));
}

static void reentrant_open_on_cancel(SynurangStream* stream,
                                     void* user_data) {
    ReentrantOpenContext* context = (ReentrantOpenContext*)user_data;
    (void)stream;
    atomic_fetch_add(&context->cancels, 1);
}

static void reentrant_open_on_destroy(void* user_data) {
    ReentrantOpenContext* context = (ReentrantOpenContext*)user_data;
    atomic_fetch_add(&context->destroys, 1);
}

/* The wakeup callback is deliberately synchronous: it polls on the Open call
 * stack, and on_open closes the last public handle. The Open implementation
 * must keep a private stream reference until it has safely returned the token. */
static int test_reentrant_open_wakeup_close(void) {
    SynurangRuntimeOptions options = SYNURANG_RUNTIME_OPTIONS_INIT;
    SynurangStreamCallbacks callbacks = SYNURANG_STREAM_CALLBACKS_INIT;
    ReentrantOpenContext context = {0};
    SynurangRuntime* runtime;
    uint64_t handle;

    options.execution_mode = SYNURANG_EXECUTION_MANUAL;
    options.wakeup = reentrant_open_wakeup;
    options.wakeup_user_data = &context;
    runtime = synurang_runtime_create(&options);
    CHECK(runtime != NULL);
    context.runtime = runtime;

    callbacks.on_open = reentrant_open_on_open;
    callbacks.on_cancel = reentrant_open_on_cancel;
    callbacks.on_destroy = reentrant_open_on_destroy;
    handle = synurang_stream_open(runtime, &callbacks, &context);
    CHECK(handle != 0u);
    CHECK(atomic_load(&context.wakeups) >= 1);
    CHECK(atomic_load(&context.opens) == 1);
    CHECK(atomic_load(&context.cancels) == 1);
    CHECK(atomic_load(&context.destroys) == 1);
    CHECK(Synurang_Stream_TrySend(handle, "closed", 6) ==
          SYNURANG_NOT_FOUND);

    synurang_runtime_destroy(runtime);
    return 0;
}

static int test_manual_async_output_wakeup(void) {
    SynurangRuntimeOptions options = SYNURANG_RUNTIME_OPTIONS_INIT;
    SynurangStreamCallbacks callbacks = test_callbacks();
    TestContext context = {0};
    TestContext failed = {0};
    atomic_int wakeups = 0;
    SynurangRuntime* runtime;
    uint64_t handle;
    uint64_t failed_handle;
    int wakeup_count;
    int response_len = -1;
    int status = SYNURANG_INTERNAL;
    char* response;

    options.execution_mode = SYNURANG_EXECUTION_MANUAL;
    options.outbound_queue_capacity = 2u;
    options.wakeup = count_wakeup;
    options.wakeup_user_data = &wakeups;
    context.retain_on_open = 1;
    runtime = synurang_runtime_create(&options);
    CHECK(runtime != NULL);
    handle = synurang_stream_open(runtime, &callbacks, &context);
    CHECK(handle != 0u);
    CHECK(synurang_runtime_poll(runtime, 1u) == 1u);
    CHECK(context.retained != NULL);

    wakeup_count = atomic_load(&wakeups);
    CHECK(synurang_stream_write(context.retained, "async-1", 7u) ==
          SYNURANG_OK);
    CHECK(atomic_load(&wakeups) == wakeup_count + 1);
    CHECK(synurang_stream_write(context.retained, "async-2", 7u) ==
          SYNURANG_OK);
    CHECK(atomic_load(&wakeups) == wakeup_count + 1);
    CHECK(receive_equals(handle, 1, "async-1") == 0);
    CHECK(receive_equals(handle, 1, "async-2") == 0);

    wakeup_count = atomic_load(&wakeups);
    CHECK(synurang_stream_finish(context.retained) == SYNURANG_OK);
    CHECK(atomic_load(&wakeups) == wakeup_count + 1);
    response = Synurang_Stream_TryRecv(handle, &response_len, &status);
    CHECK(response == NULL);
    CHECK(response_len == 0);
    CHECK(status == SYNURANG_EOF);

    synurang_stream_release(context.retained);
    context.retained = NULL;
    Synurang_Stream_Close(handle);

    failed.retain_on_open = 1;
    failed_handle = synurang_stream_open(runtime, &callbacks, &failed);
    CHECK(failed_handle != 0u);
    CHECK(synurang_runtime_poll(runtime, 1u) == 1u);
    CHECK(failed.retained != NULL);
    wakeup_count = atomic_load(&wakeups);
    CHECK(synurang_stream_fail(
              failed.retained, SYNURANG_INTERNAL, "async-error", 11u) ==
          SYNURANG_OK);
    CHECK(atomic_load(&wakeups) == wakeup_count + 1);
    response = Synurang_Stream_TryRecv(
        failed_handle, &response_len, &status);
    CHECK(response != NULL);
    CHECK(response_len == 11);
    CHECK(memcmp(response, "async-error", 11u) == 0);
    CHECK(status == SYNURANG_INTERNAL);
    Synurang_Free(response);
    response = Synurang_Stream_TryRecv(
        failed_handle, &response_len, &status);
    CHECK(response == NULL);
    CHECK(status == SYNURANG_EOF);
    synurang_stream_release(failed.retained);
    failed.retained = NULL;
    Synurang_Stream_Close(failed_handle);

    synurang_runtime_destroy(runtime);
    CHECK(atomic_load(&context.cancels) == 0);
    CHECK(atomic_load(&context.destroys) == 1);
    CHECK(atomic_load(&failed.cancels) == 0);
    CHECK(atomic_load(&failed.destroys) == 1);
    return 0;
}

/* Passing an intentionally invalid non-NULL source pointer after a queue is
 * full proves WOULD_BLOCK is decided before allocating or copying a payload. */
static int test_capacity_reserves_before_copy(void) {
    SynurangRuntimeOptions options = SYNURANG_RUNTIME_OPTIONS_INIT;
    SynurangStreamCallbacks callbacks = test_callbacks();
    TestContext context = {0};
    SynurangRuntime* runtime;
    uint64_t handle;
    const char* invalid_data = (const char*)(uintptr_t)1u;
    int response_len = -1;
    int status = SYNURANG_INTERNAL;
    char* response;

    options.execution_mode = SYNURANG_EXECUTION_MANUAL;
    options.inbound_queue_capacity = 1u;
    options.outbound_queue_capacity = 1u;
    context.first_response = "bounded";
    context.retain_on_open = 1;
    runtime = synurang_runtime_create(&options);
    CHECK(runtime != NULL);
    handle = synurang_stream_open(runtime, &callbacks, &context);
    CHECK(handle != 0u);
    CHECK(synurang_runtime_poll(runtime, 1u) == 1u);
    CHECK(context.retained != NULL);

    CHECK(Synurang_Stream_TrySend(handle, "q", 1) == SYNURANG_OK);
    CHECK(Synurang_Stream_TrySend(handle, invalid_data, 1) ==
          SYNURANG_WOULD_BLOCK);
    CHECK(synurang_runtime_poll(runtime, 1u) == 1u);
    CHECK(atomic_load(&context.messages) == 1);
    CHECK(synurang_stream_write(context.retained, invalid_data, 1u) ==
          SYNURANG_WOULD_BLOCK);

    CHECK(receive_equals(handle, 1, "bounded") == 0);
    CHECK(synurang_runtime_has_pending(runtime));
    CHECK(synurang_stream_finish(context.retained) == SYNURANG_OK);
    CHECK(Synurang_Stream_TrySend(handle, invalid_data, 1) ==
          SYNURANG_CLOSED);
    response = Synurang_Stream_TryRecv(handle, &response_len, &status);
    CHECK(response == NULL);
    CHECK(status == SYNURANG_EOF);
    CHECK(synurang_runtime_poll(runtime, 0u) == 0u);
    CHECK(atomic_load(&context.writables) == 0);

    synurang_stream_release(context.retained);
    context.retained = NULL;
    Synurang_Stream_Close(handle);
    synurang_runtime_destroy(runtime);
    CHECK(atomic_load(&context.destroys) == 1);
    return 0;
}

static int test_terminal_discards_input(void) {
    SynurangRuntimeOptions options = SYNURANG_RUNTIME_OPTIONS_INIT;
    SynurangStreamCallbacks callbacks = test_callbacks();
    TestContext finished = {0};
    TestContext failed = {0};
    SynurangRuntime* runtime;
    uint64_t finished_handle;
    uint64_t failed_handle;
    int response_len = -1;
    int status = SYNURANG_INTERNAL;
    char* response;

    options.execution_mode = SYNURANG_EXECUTION_MANUAL;
    options.inbound_queue_capacity = 4u;
    options.outbound_queue_capacity = 4u;
    runtime = synurang_runtime_create(&options);
    CHECK(runtime != NULL);

    finished.first_response = "finished";
    finished.finish_on_message = 1;
    atomic_store(&finished.terminal_status, SYNURANG_INTERNAL);
    finished_handle = synurang_stream_open(runtime, &callbacks, &finished);
    CHECK(finished_handle != 0u);
    CHECK(synurang_runtime_poll(runtime, 1u) == 1u);
    CHECK(Synurang_Stream_TrySend(finished_handle, "one", 3) == SYNURANG_OK);
    CHECK(Synurang_Stream_TrySend(finished_handle, "two", 3) == SYNURANG_OK);
    Synurang_Stream_CloseSend(finished_handle);
    CHECK(synurang_runtime_poll(runtime, 1u) == 1u);
    CHECK(atomic_load(&finished.messages) == 1);
    CHECK(atomic_load(&finished.half_closes) == 0);
    CHECK(atomic_load(&finished.terminal_status) == SYNURANG_OK);
    CHECK(!synurang_runtime_has_pending(runtime));
    CHECK(Synurang_Stream_TrySend(finished_handle, "late", 4) ==
          SYNURANG_CLOSED);
    CHECK(receive_equals(finished_handle, 1, "finished") == 0);
    response = Synurang_Stream_TryRecv(
        finished_handle, &response_len, &status);
    CHECK(response == NULL);
    CHECK(status == SYNURANG_EOF);
    Synurang_Stream_Close(finished_handle);

    failed.first_response = "before-error";
    failed.failure_data = "terminal-error";
    failed.failure_status = SYNURANG_INTERNAL;
    failed.fail_after_write = 1;
    failed.retain_on_open = 1;
    atomic_store(&failed.terminal_status, SYNURANG_INTERNAL);
    failed_handle = synurang_stream_open(runtime, &callbacks, &failed);
    CHECK(failed_handle != 0u);
    CHECK(synurang_runtime_poll(runtime, 1u) == 1u);
    CHECK(Synurang_Stream_TrySend(failed_handle, "one", 3) == SYNURANG_OK);
    CHECK(Synurang_Stream_TrySend(failed_handle, "two", 3) == SYNURANG_OK);
    Synurang_Stream_CloseSend(failed_handle);
    CHECK(synurang_runtime_poll(runtime, 1u) == 1u);
    CHECK(atomic_load(&failed.messages) == 1);
    CHECK(atomic_load(&failed.half_closes) == 0);
    CHECK(atomic_load(&failed.first_write_status) == SYNURANG_OK);
    CHECK(atomic_load(&failed.terminal_status) == SYNURANG_OK);
    CHECK(!synurang_runtime_has_pending(runtime));
    CHECK(Synurang_Stream_TrySend(failed_handle, "late", 4) ==
          SYNURANG_CLOSED);
    CHECK(receive_equals(failed_handle, 1, "before-error") == 0);
    response = Synurang_Stream_TryRecv(failed_handle, &response_len, &status);
    CHECK(response != NULL);
    CHECK(response_len == 14);
    CHECK(memcmp(response, "terminal-error", 14u) == 0);
    CHECK(status == SYNURANG_INTERNAL);
    Synurang_Free(response);
    response = Synurang_Stream_TryRecv(failed_handle, &response_len, &status);
    CHECK(response == NULL);
    CHECK(status == SYNURANG_EOF);
    CHECK(failed.retained != NULL);
    Synurang_Stream_Close(failed_handle);
    CHECK(synurang_stream_fail(failed.retained,
                               SYNURANG_INTERNAL,
                               (const void*)(uintptr_t)1u,
                               1u) == SYNURANG_OK);
    CHECK(synurang_stream_fail_error(failed.retained,
                                     1,
                                     2,
                                     (const char*)(uintptr_t)1u) ==
          SYNURANG_OK);
    CHECK(synurang_stream_finish(failed.retained) == SYNURANG_OK);
    synurang_stream_release(failed.retained);
    failed.retained = NULL;

    synurang_runtime_destroy(runtime);
    CHECK(atomic_load(&finished.cancels) == 0);
    CHECK(atomic_load(&finished.destroys) == 1);
    CHECK(atomic_load(&failed.cancels) == 0);
    CHECK(atomic_load(&failed.destroys) == 1);
    return 0;
}

static int test_manual_poll(void) {
    SynurangRuntimeOptions options = SYNURANG_RUNTIME_OPTIONS_INIT;
    SynurangStreamCallbacks callbacks = test_callbacks();
    SynurangRuntime* runtime;
    TestContext context = {0};
    TestContext cancelled = {0};
    TestContext failed = {0};
    atomic_int wakeups = 0;
    uint64_t handle;
    uint64_t cancelled_handle;
    uint64_t failed_handle;
    int response_len = -1;
    int status = SYNURANG_INTERNAL;
    char* response;

    options.execution_mode = SYNURANG_EXECUTION_MANUAL;
    options.inbound_queue_capacity = 1u;
    options.outbound_queue_capacity = 1u;
    options.wakeup = count_wakeup;
    options.wakeup_user_data = &wakeups;
    runtime = synurang_runtime_create(&options);
    CHECK(runtime != NULL);

    context.first_response = "first";
    context.second_response = "second";
    atomic_store(&context.first_write_status, SYNURANG_INTERNAL);
    atomic_store(&context.second_write_status, SYNURANG_INTERNAL);
    atomic_store(&context.retry_write_status, SYNURANG_INTERNAL);

    handle = synurang_stream_open(runtime, &callbacks, &context);
    CHECK(handle != 0u);
    CHECK(atomic_load(&wakeups) >= 1);
    CHECK(synurang_runtime_has_pending(runtime));

    response = Synurang_Stream_TryRecv(handle, &response_len, &status);
    CHECK(response == NULL);
    CHECK(response_len == 0);
    CHECK(status == SYNURANG_PENDING);

    /* The non-blocking form never runs callbacks of its own. */
    CHECK(atomic_load(&context.opens) == 0);

    CHECK(synurang_runtime_poll(runtime, 1u) == 1u);
    CHECK(atomic_load(&context.opens) == 1);

    CHECK(Synurang_Stream_TrySend(handle, "one", 3) == SYNURANG_OK);
    CHECK(Synurang_Stream_TrySend(handle, "two", 3) ==
          SYNURANG_WOULD_BLOCK);
    CHECK(synurang_runtime_poll(runtime, 0u) >= 1u);
    CHECK(atomic_load(&context.messages) == 1);
    CHECK(atomic_load(&context.first_write_status) == SYNURANG_OK);
    CHECK(atomic_load(&context.second_write_status) ==
          SYNURANG_WOULD_BLOCK);

    CHECK(receive_equals(handle, 1, "first") == 0);
    CHECK(synurang_runtime_has_pending(runtime));
    CHECK(synurang_runtime_poll(runtime, 0u) >= 1u);
    CHECK(atomic_load(&context.writables) == 1);
    CHECK(atomic_load(&context.retry_write_status) == SYNURANG_OK);
    CHECK(receive_equals(handle, 1, "second") == 0);

    Synurang_Stream_CloseSend(handle);
    CHECK(synurang_runtime_poll(runtime, 0u) >= 1u);
    CHECK(atomic_load(&context.half_closes) == 1);
    response = Synurang_Stream_TryRecv(handle, &response_len, &status);
    CHECK(response == NULL);
    CHECK(response_len == 0);
    CHECK(status == SYNURANG_EOF);
    Synurang_Stream_Close(handle);

    cancelled.first_response = "unused";
    cancelled.retain_on_open = 1;
    cancelled_handle = synurang_stream_open(runtime, &callbacks, &cancelled);
    CHECK(cancelled_handle != 0u);
    CHECK(synurang_runtime_poll(runtime, 0u) >= 1u);
    CHECK(cancelled.retained != NULL);
    CHECK(synurang_stream_handle(cancelled.retained) == cancelled_handle);
    Synurang_Stream_Close(cancelled_handle);
    (void)synurang_runtime_poll(runtime, 0u);

    failed.first_response = "unused";
    failed.failure_data = "wire-error";
    failed.failure_status = SYNURANG_INTERNAL;
    failed_handle = synurang_stream_open(runtime, &callbacks, &failed);
    CHECK(failed_handle != 0u);
    CHECK(synurang_runtime_poll(runtime, 0u) >= 1u);
    CHECK(Synurang_Stream_TrySend(failed_handle, "fail", 4) == SYNURANG_OK);
    CHECK(synurang_runtime_poll(runtime, 0u) >= 1u);
    response = Synurang_Stream_TryRecv(
        failed_handle, &response_len, &status);
    CHECK(status == SYNURANG_INTERNAL);
    CHECK(response != NULL);
    CHECK(response_len == 10);
    CHECK(memcmp(response, "wire-error", 10u) == 0);
    Synurang_Free(response);
    Synurang_Stream_Close(failed_handle);

    synurang_runtime_destroy(runtime);
    CHECK(atomic_load(&context.cancels) == 0);
    CHECK(atomic_load(&context.destroys) == 1);
    CHECK(atomic_load(&cancelled.cancels) == 1);
    CHECK(atomic_load(&cancelled.destroys) == 1);
    CHECK(atomic_load(&failed.destroys) == 1);
    return 0;
}

/* Pumping from a blocking call means a callback can re-enter the executor.
 * The stream being dispatched is not on the ready queue, so it can never be
 * dispatched twice, and a pass with nothing left to run has to terminate
 * rather than spin. */
typedef struct ReentrantPumpContext {
    uint64_t handle;
    int messages;
    int nested_status;
    int nested_returned;
} ReentrantPumpContext;

static void reentrant_pump_on_message(SynurangStream* stream,
                                      const uint8_t* data,
                                      size_t data_len,
                                      void* user_data) {
    ReentrantPumpContext* context = (ReentrantPumpContext*)user_data;
    int response_len = -1;
    int status = SYNURANG_INTERNAL;
    char* response;
    (void)data;
    (void)data_len;
    ++context->messages;
    /* Blocking receive on our own stream, from inside our own callback. */
    response = Synurang_Stream_Recv(context->handle, &response_len, &status);
    context->nested_status = status;
    context->nested_returned = 1;
    Synurang_Free(response);
    (void)synurang_stream_write(stream, "late", 4u);
}

static int test_manual_pump_reentrancy(void) {
    SynurangRuntimeOptions options = SYNURANG_RUNTIME_OPTIONS_INIT;
    SynurangStreamCallbacks callbacks = SYNURANG_STREAM_CALLBACKS_INIT;
    SynurangRuntime* runtime;
    ReentrantPumpContext context = {0};

    options.execution_mode = SYNURANG_EXECUTION_MANUAL;
    runtime = synurang_runtime_create(&options);
    CHECK(runtime != NULL);
    callbacks.on_message = reentrant_pump_on_message;

    context.nested_status = SYNURANG_INTERNAL;
    context.handle = synurang_stream_open(runtime, &callbacks, &context);
    CHECK(context.handle != 0u);
    CHECK(Synurang_Stream_TrySend(context.handle, "ping", 4) == SYNURANG_OK);

    /* Drives on_message, whose nested Recv must return rather than deadlock or
     * re-dispatch the stream that is already running. */
    CHECK(synurang_runtime_poll(runtime, 0u) >= 1u);
    CHECK(context.messages == 1);
    CHECK(context.nested_returned == 1);
    CHECK(context.nested_status == SYNURANG_PENDING);
    CHECK(receive_equals(context.handle, 1, "late") == 0);

    Synurang_Stream_Close(context.handle);
    synurang_runtime_destroy(runtime);
    return 0;
}

/* A manual runtime owns no worker, so the blocking plugin-ABI names have to
 * drive the loop from the calling thread. That is what lets a stock blocking
 * host (which only knows Send/Recv) drive a manual or threadless plugin
 * instead of seeing a bare SYNURANG_PENDING it cannot act on. */
static int test_manual_blocking_abi_pumps(void) {
    SynurangRuntimeOptions options = SYNURANG_RUNTIME_OPTIONS_INIT;
    SynurangStreamCallbacks callbacks = test_callbacks();
    SynurangRuntime* runtime;
    TestContext echo = {0};
    TestContext backpressure = {0};
    TestContext idle = {0};
    uint64_t echo_handle;
    uint64_t backpressure_handle;
    uint64_t idle_handle;
    int response_len = -1;
    int status = SYNURANG_INTERNAL;
    char* response;

    options.execution_mode = SYNURANG_EXECUTION_MANUAL;
    options.inbound_queue_capacity = 1u;
    options.outbound_queue_capacity = 1u;
    runtime = synurang_runtime_create(&options);
    CHECK(runtime != NULL);

    /* Recv alone must run on_open and on_message and hand back the response,
     * with no synurang_runtime_poll() call anywhere in the host. */
    echo.first_response = "echo";
    echo.finish_on_message = 1;
    echo_handle = synurang_stream_open(runtime, &callbacks, &echo);
    CHECK(echo_handle != 0u);
    CHECK(Synurang_Stream_Send(echo_handle, "hi", 2) == SYNURANG_OK);
    CHECK(receive_equals(echo_handle, 0, "echo") == 0);
    CHECK(atomic_load(&echo.opens) == 1);
    CHECK(atomic_load(&echo.messages) == 1);
    response = Synurang_Stream_Recv(echo_handle, &response_len, &status);
    CHECK(response == NULL);
    CHECK(status == SYNURANG_EOF);
    Synurang_Stream_Close(echo_handle);

    /* A full inbound queue is drained by the blocking Send itself, where the
     * non-blocking form can only report WOULD_BLOCK. */
    backpressure.first_response = "drained";
    backpressure_handle =
        synurang_stream_open(runtime, &callbacks, &backpressure);
    CHECK(backpressure_handle != 0u);
    CHECK(Synurang_Stream_Send(backpressure_handle, "a", 1) == SYNURANG_OK);
    CHECK(Synurang_Stream_TrySend(backpressure_handle, "b", 1) ==
          SYNURANG_WOULD_BLOCK);
    CHECK(Synurang_Stream_Send(backpressure_handle, "b", 1) == SYNURANG_OK);
    CHECK(atomic_load(&backpressure.messages) == 1);
    Synurang_Stream_Close(backpressure_handle);

    /* With nothing left to dispatch the pump stops instead of spinning. */
    idle_handle = synurang_stream_open(runtime, &callbacks, &idle);
    CHECK(idle_handle != 0u);
    response = Synurang_Stream_Recv(idle_handle, &response_len, &status);
    CHECK(response == NULL);
    CHECK(response_len == 0);
    CHECK(status == SYNURANG_PENDING);
    CHECK(atomic_load(&idle.opens) == 1);
    CHECK(!synurang_runtime_has_pending(runtime));
    Synurang_Stream_Close(idle_handle);

    synurang_runtime_destroy(runtime);
    CHECK(atomic_load(&echo.destroys) == 1);
    CHECK(atomic_load(&backpressure.destroys) == 1);
    CHECK(atomic_load(&idle.destroys) == 1);
    return 0;
}

static int test_error_response_wire(void) {
    static const uint8_t expected[] = {
        0x08u, 0x07u, 0x12u, 0x03u, 'b', 'a', 'd', 0x18u, 0x0du
    };
    size_t encoded_len = 123u;
    uint8_t* encoded = synurang_error_response_copy(
        7, "bad", 3u, 13, &encoded_len);
    CHECK(Synurang_Stream_Send(0u, NULL, -1) ==
          SYNURANG_INVALID_ARGUMENT);
    CHECK(Synurang_Stream_TrySend(0u, NULL, -1) ==
          SYNURANG_INVALID_ARGUMENT);
    CHECK(encoded != NULL);
    CHECK(encoded_len == sizeof(expected));
    CHECK(memcmp(encoded, expected, sizeof(expected)) == 0);
    synurang_response_free(encoded);

    encoded = synurang_error_response_copy(0, NULL, 0u, 0, &encoded_len);
    CHECK(encoded != NULL);
    CHECK(encoded_len == 2u);
    CHECK(encoded[0] == 0x12u && encoded[1] == 0x00u);
    synurang_response_free(encoded);
    return 0;
}

#ifndef SYNURANG_TEST_MANUAL_ONLY
static int wait_for_nonzero(atomic_int* value) {
    struct timespec pause = {0, 1000000L};
    int i;
    for (i = 0; i < 5000; ++i) {
        if (atomic_load(value) != 0) return 1;
        (void)nanosleep(&pause, NULL);
    }
    return atomic_load(value) != 0;
}

static int wait_for_handle_removal(uint64_t handle) {
    struct timespec pause = {0, 1000000L};
    int i;
    for (i = 0; i < 5000; ++i) {
        int status = Synurang_Stream_TrySend(handle, NULL, 0);
        if (status == SYNURANG_NOT_FOUND) return 1;
        if (status != SYNURANG_OK && status != SYNURANG_WOULD_BLOCK &&
            status != SYNURANG_CLOSED) {
            return 0;
        }
        (void)nanosleep(&pause, NULL);
    }
    return 0;
}

#if defined(SYNURANG_TEST_PTHREAD_WRAP)
/* Test-only linker interposition stops Send at a semantic lock boundary:
 * registry lookup identifies the stream mutex, then Send takes that same
 * mutex to inspect a full queue. A competing poller removes the ready item and
 * waits on that mutex. Send's unlock is held until the poller has consumed the
 * message (and optional cancellation), so Send's own poll must return zero. */
typedef struct ManualSendPollRaceContext {
    SynurangRuntime* runtime;
    uint64_t handle;
    pthread_mutex_t* stream_mutex;
    int close_in_callback;
    atomic_int sender_holds_stream;
    atomic_int poller_waiting_for_stream;
    atomic_int poller_finished;
    atomic_int hook_failed;
    atomic_int sender_status;
    atomic_int poll_count;
    atomic_int messages;
    atomic_int destroys;
} ManualSendPollRaceContext;

static _Thread_local ManualSendPollRaceContext* g_send_race_sender;
static _Thread_local unsigned int g_send_race_lock_depth;
static _Thread_local int g_send_race_check_lock;
static _Thread_local int g_send_race_hook_consumed;
static _Atomic(ManualSendPollRaceContext*) g_send_race_active;

int __real_pthread_mutex_lock(pthread_mutex_t* mutex);
int __real_pthread_mutex_unlock(pthread_mutex_t* mutex);

int __wrap_pthread_mutex_lock(pthread_mutex_t* mutex) {
    ManualSendPollRaceContext* sender = g_send_race_sender;
    ManualSendPollRaceContext* active = atomic_load(&g_send_race_active);
    int result;

    /* pop_ready() has removed the stream before the poller reaches this lock.
     * Signal before the real lock, which Send deliberately still holds. */
    if (sender == NULL && active != NULL &&
        active->stream_mutex == mutex &&
        atomic_load(&active->sender_holds_stream)) {
        atomic_store(&active->poller_waiting_for_stream, 1);
    }

    result = __real_pthread_mutex_lock(mutex);
    if (result != 0 || sender == NULL) return result;

    if (sender->stream_mutex == NULL && g_send_race_lock_depth == 1u) {
        /* registry_lookup holds the registry mutex while taking this mutex. */
        sender->stream_mutex = mutex;
    } else if (!g_send_race_hook_consumed &&
               g_send_race_lock_depth == 0u &&
               sender->stream_mutex == mutex) {
        g_send_race_check_lock = 1;
        atomic_store(&sender->sender_holds_stream, 1);
        if (!wait_for_nonzero(&sender->poller_waiting_for_stream)) {
            atomic_store(&sender->hook_failed, 1);
        }
    }
    ++g_send_race_lock_depth;
    return result;
}

int __wrap_pthread_mutex_unlock(pthread_mutex_t* mutex) {
    ManualSendPollRaceContext* sender = g_send_race_sender;
    int wait_for_poller =
        sender != NULL && g_send_race_check_lock &&
        sender->stream_mutex == mutex;
    int result = __real_pthread_mutex_unlock(mutex);

    if (sender != NULL && g_send_race_lock_depth != 0u) {
        --g_send_race_lock_depth;
    }
    if (result == 0 && wait_for_poller) {
        g_send_race_check_lock = 0;
        g_send_race_hook_consumed = 1;
        if (!wait_for_nonzero(&sender->poller_finished)) {
            atomic_store(&sender->hook_failed, 1);
        }
    }
    return result;
}

static void manual_send_race_on_message(SynurangStream* stream,
                                        const uint8_t* data,
                                        size_t data_len,
                                        void* user_data) {
    ManualSendPollRaceContext* context =
        (ManualSendPollRaceContext*)user_data;
    (void)stream;
    (void)data;
    (void)data_len;
    atomic_fetch_add(&context->messages, 1);
    if (context->close_in_callback) {
        Synurang_Stream_Close(context->handle);
    }
}

static void manual_send_race_on_destroy(void* user_data) {
    ManualSendPollRaceContext* context =
        (ManualSendPollRaceContext*)user_data;
    atomic_fetch_add(&context->destroys, 1);
}

static void* manual_send_race_sender(void* user_data) {
    ManualSendPollRaceContext* context =
        (ManualSendPollRaceContext*)user_data;
    g_send_race_sender = context;
    g_send_race_lock_depth = 0u;
    g_send_race_check_lock = 0;
    g_send_race_hook_consumed = 0;
    atomic_store(&context->sender_status,
                 Synurang_Stream_Send(context->handle, "second", 6));
    g_send_race_sender = NULL;
    return NULL;
}

static void* manual_send_race_poller(void* user_data) {
    ManualSendPollRaceContext* context =
        (ManualSendPollRaceContext*)user_data;
    size_t count;
    if (!wait_for_nonzero(&context->sender_holds_stream)) {
        atomic_store(&context->hook_failed, 1);
        atomic_store(&context->poller_finished, 1);
        return NULL;
    }
    count = synurang_runtime_poll(context->runtime, 0u);
    atomic_store(&context->poll_count, (int)count);
    atomic_store(&context->poller_finished, 1);
    return NULL;
}

static int run_manual_send_empty_poll_case(int close_in_callback,
                                           int* sender_status,
                                           int* queue_status) {
    SynurangRuntimeOptions options = SYNURANG_RUNTIME_OPTIONS_INIT;
    SynurangStreamCallbacks callbacks = SYNURANG_STREAM_CALLBACKS_INIT;
    ManualSendPollRaceContext context = {0};
    pthread_t sender;
    pthread_t poller;

    CHECK(sender_status != NULL);
    CHECK(queue_status != NULL);

    options.execution_mode = SYNURANG_EXECUTION_MANUAL;
    options.inbound_queue_capacity = 1u;
    context.runtime = synurang_runtime_create(&options);
    CHECK(context.runtime != NULL);
    context.close_in_callback = close_in_callback;
    atomic_store(&context.sender_status, SYNURANG_INTERNAL);
    callbacks.on_message = manual_send_race_on_message;
    callbacks.on_destroy = manual_send_race_on_destroy;
    context.handle =
        synurang_stream_open(context.runtime, &callbacks, &context);
    CHECK(context.handle != 0u);
    CHECK(synurang_runtime_poll(context.runtime, 1u) == 1u);
    CHECK(Synurang_Stream_TrySend(context.handle, "first", 5) ==
          SYNURANG_OK);

    atomic_store(&g_send_race_active, &context);
    CHECK(pthread_create(&poller, NULL, manual_send_race_poller, &context) ==
          0);
    CHECK(pthread_create(&sender, NULL, manual_send_race_sender, &context) ==
          0);
    CHECK(pthread_join(sender, NULL) == 0);
    CHECK(pthread_join(poller, NULL) == 0);
    atomic_store(&g_send_race_active, NULL);

    CHECK(!atomic_load(&context.hook_failed));
    CHECK(atomic_load(&context.messages) == 1);
    CHECK(atomic_load(&context.poll_count) ==
          (close_in_callback ? 2 : 1));
    *sender_status = atomic_load(&context.sender_status);
    if (close_in_callback) {
        *queue_status =
            Synurang_Stream_TrySend(context.handle, NULL, 0);
        CHECK(*queue_status == SYNURANG_NOT_FOUND);
    } else {
        /* With the fix, OK reserved and queued `second`, so capacity remains
         * full. The old result is WOULD_BLOCK here and leaves capacity free. */
        *queue_status =
            Synurang_Stream_TrySend(context.handle, NULL, 0);
        Synurang_Stream_Close(context.handle);
        CHECK(synurang_runtime_poll(context.runtime, 0u) == 1u);
    }
    synurang_runtime_destroy(context.runtime);
    CHECK(atomic_load(&context.destroys) == 1);
    return 0;
}

static int test_manual_send_rechecks_after_empty_poll(void) {
    int capacity_status = SYNURANG_INTERNAL;
    int capacity_queue_status = SYNURANG_INTERNAL;
    int close_status = SYNURANG_INTERNAL;
    int close_queue_status = SYNURANG_INTERNAL;
    CHECK(run_manual_send_empty_poll_case(
              0, &capacity_status, &capacity_queue_status) == 0);
    CHECK(run_manual_send_empty_poll_case(
              1, &close_status, &close_queue_status) == 0);
    if (capacity_status != SYNURANG_OK ||
        capacity_queue_status != SYNURANG_WOULD_BLOCK ||
        close_status != SYNURANG_CLOSED) {
        fprintf(stderr,
                "manual Send post-poll results: capacity=%d queue=%d "
                "close=%d\n",
                capacity_status, capacity_queue_status, close_status);
    }
    CHECK(capacity_status == SYNURANG_OK);
    CHECK(capacity_queue_status == SYNURANG_WOULD_BLOCK);
    CHECK(close_status == SYNURANG_CLOSED);
    return 0;
}
#endif

typedef struct PollDestroyContext {
    atomic_int callback_entered;
    atomic_int release_callback;
    atomic_int cancels;
    atomic_int destroys;
} PollDestroyContext;

typedef struct PollDestroyArguments {
    SynurangRuntime* runtime;
    size_t poll_result;
    atomic_int destroy_done;
} PollDestroyArguments;

static void poll_destroy_on_open(SynurangStream* stream, void* user_data) {
    PollDestroyContext* context = (PollDestroyContext*)user_data;
    (void)stream;
    atomic_store(&context->callback_entered, 1);
    while (!atomic_load(&context->release_callback)) {
        (void)sched_yield();
    }
}

static void poll_destroy_on_cancel(SynurangStream* stream, void* user_data) {
    PollDestroyContext* context = (PollDestroyContext*)user_data;
    (void)stream;
    atomic_fetch_add(&context->cancels, 1);
}

static void poll_destroy_on_destroy(void* user_data) {
    PollDestroyContext* context = (PollDestroyContext*)user_data;
    atomic_fetch_add(&context->destroys, 1);
}

static void* poll_destroy_poll_thread(void* user_data) {
    PollDestroyArguments* arguments = (PollDestroyArguments*)user_data;
    arguments->poll_result = synurang_runtime_poll(arguments->runtime, 1u);
    return NULL;
}

static void* poll_destroy_destroy_thread(void* user_data) {
    PollDestroyArguments* arguments = (PollDestroyArguments*)user_data;
    synurang_runtime_destroy(arguments->runtime);
    atomic_store(&arguments->destroy_done, 1);
    return NULL;
}

static int test_manual_poll_destroy_race(void) {
    SynurangRuntimeOptions options = SYNURANG_RUNTIME_OPTIONS_INIT;
    SynurangStreamCallbacks callbacks = SYNURANG_STREAM_CALLBACKS_INIT;
    PollDestroyContext context = {0};
    PollDestroyArguments arguments = {0};
    SynurangRuntime* runtime;
    pthread_t poll_thread;
    pthread_t destroy_thread;
    uint64_t handle;

    options.execution_mode = SYNURANG_EXECUTION_MANUAL;
    runtime = synurang_runtime_create(&options);
    CHECK(runtime != NULL);
    arguments.runtime = runtime;
    callbacks.on_open = poll_destroy_on_open;
    callbacks.on_cancel = poll_destroy_on_cancel;
    callbacks.on_destroy = poll_destroy_on_destroy;
    handle = synurang_stream_open(runtime, &callbacks, &context);
    CHECK(handle != 0u);

    CHECK(pthread_create(&poll_thread, NULL, poll_destroy_poll_thread,
                         &arguments) == 0);
    CHECK(wait_for_nonzero(&context.callback_entered));
    CHECK(pthread_create(&destroy_thread, NULL, poll_destroy_destroy_thread,
                         &arguments) == 0);
    /* NOT_FOUND proves destroy has removed/cancelled this stream and is now
     * waiting for the already-entered poll callback, without timing guesses. */
    CHECK(wait_for_handle_removal(handle));
    CHECK(atomic_load(&arguments.destroy_done) == 0);

    atomic_store(&context.release_callback, 1);
    CHECK(pthread_join(poll_thread, NULL) == 0);
    CHECK(pthread_join(destroy_thread, NULL) == 0);
    CHECK(arguments.poll_result == 1u);
    CHECK(atomic_load(&arguments.destroy_done) == 1);
    CHECK(atomic_load(&context.cancels) == 1);
    CHECK(atomic_load(&context.destroys) == 1);
    return 0;
}

typedef struct BlockingSendContext {
    atomic_int callback_entered;
    atomic_int release_callback;
    atomic_int cancels;
    atomic_int destroys;
    SynurangStream* retained;
} BlockingSendContext;

typedef struct BlockingSendArguments {
    uint64_t handle;
    atomic_int started;
    atomic_int finished;
    atomic_int status;
} BlockingSendArguments;

static void blocking_send_on_open(SynurangStream* stream, void* user_data) {
    BlockingSendContext* context = (BlockingSendContext*)user_data;
    context->retained = synurang_stream_retain(stream);
    atomic_store(&context->callback_entered, 1);
    while (!atomic_load(&context->release_callback)) {
        (void)sched_yield();
    }
}

static void blocking_send_on_cancel(SynurangStream* stream, void* user_data) {
    BlockingSendContext* context = (BlockingSendContext*)user_data;
    (void)stream;
    atomic_fetch_add(&context->cancels, 1);
}

static void blocking_send_on_destroy(void* user_data) {
    BlockingSendContext* context = (BlockingSendContext*)user_data;
    atomic_fetch_add(&context->destroys, 1);
}

static void* blocking_send_thread(void* user_data) {
    BlockingSendArguments* arguments = (BlockingSendArguments*)user_data;
    int status;
    atomic_store(&arguments->started, 1);
    status = Synurang_Stream_Send(arguments->handle, "blocked", 7);
    atomic_store(&arguments->status, status);
    atomic_store(&arguments->finished, 1);
    return NULL;
}

static int test_terminal_wakes_blocking_send(void) {
    SynurangRuntimeOptions options = SYNURANG_RUNTIME_OPTIONS_INIT;
    SynurangStreamCallbacks callbacks = SYNURANG_STREAM_CALLBACKS_INIT;
    BlockingSendContext context = {0};
    BlockingSendArguments arguments = {0};
    SynurangRuntime* runtime;
    pthread_t sender;
    struct timespec pause = {0, 20000000L};
    uint64_t handle;

    options.execution_mode = SYNURANG_EXECUTION_THREADED;
    options.worker_count = 1u;
    options.inbound_queue_capacity = 1u;
    runtime = synurang_runtime_create(&options);
    CHECK(runtime != NULL);
    callbacks.on_open = blocking_send_on_open;
    callbacks.on_cancel = blocking_send_on_cancel;
    callbacks.on_destroy = blocking_send_on_destroy;
    handle = synurang_stream_open(runtime, &callbacks, &context);
    CHECK(handle != 0u);
    CHECK(wait_for_nonzero(&context.callback_entered));
    CHECK(context.retained != NULL);

    CHECK(Synurang_Stream_Send(handle, "queued", 6) == SYNURANG_OK);
    arguments.handle = handle;
    atomic_store(&arguments.status, SYNURANG_INTERNAL);
    CHECK(pthread_create(&sender, NULL, blocking_send_thread, &arguments) == 0);
    CHECK(wait_for_nonzero(&arguments.started));
    (void)nanosleep(&pause, NULL);
    CHECK(atomic_load(&arguments.finished) == 0);

    CHECK(synurang_stream_finish(context.retained) == SYNURANG_OK);
    CHECK(pthread_join(sender, NULL) == 0);
    CHECK(atomic_load(&arguments.finished) == 1);
    CHECK(atomic_load(&arguments.status) == SYNURANG_CLOSED);

    synurang_stream_release(context.retained);
    context.retained = NULL;
    atomic_store(&context.release_callback, 1);
    Synurang_Stream_Close(handle);
    synurang_runtime_destroy(runtime);
    CHECK(atomic_load(&context.cancels) == 0);
    CHECK(atomic_load(&context.destroys) == 1);
    return 0;
}

static int test_threaded_blocking_recv(void) {
    SynurangRuntimeOptions options = SYNURANG_RUNTIME_OPTIONS_INIT;
    SynurangStreamCallbacks callbacks = test_callbacks();
    SynurangRuntime* runtime;
    TestContext context = {0};
    TestContext cancelled = {0};
    uint64_t handle;
    uint64_t cancelled_handle;
    int response_len = -1;
    int status = SYNURANG_INTERNAL;
    char* response;

    options.execution_mode = SYNURANG_EXECUTION_THREADED;
    options.worker_count = 1u;
    runtime = synurang_runtime_create(&options);
    CHECK(runtime != NULL);

    context.first_response = "threaded";
    atomic_store(&context.first_write_status, SYNURANG_INTERNAL);
    handle = synurang_stream_open(runtime, &callbacks, &context);
    CHECK(handle != 0u);
    CHECK(Synurang_Stream_Send(handle, "request", 7) == SYNURANG_OK);

    /* This is the compatibility contract: Recv waits for the worker callback
     * instead of exposing PENDING to an existing synchronous host. */
    CHECK(receive_equals(handle, 0, "threaded") == 0);
    CHECK(atomic_load(&context.messages) == 1);
    CHECK(atomic_load(&context.first_write_status) == SYNURANG_OK);

    Synurang_Stream_CloseSend(handle);
    response = Synurang_Stream_Recv(handle, &response_len, &status);
    CHECK(response == NULL);
    CHECK(response_len == 0);
    CHECK(status == SYNURANG_EOF);
    CHECK(atomic_load(&context.half_closes) == 1);
    Synurang_Stream_Close(handle);

    cancelled.first_response = "unused";
    cancelled_handle = synurang_stream_open(runtime, &callbacks, &cancelled);
    CHECK(cancelled_handle != 0u);
    Synurang_Stream_Close(cancelled_handle);

    synurang_runtime_destroy(runtime);
    CHECK(atomic_load(&context.destroys) == 1);
    CHECK(atomic_load(&cancelled.cancels) == 1);
    CHECK(atomic_load(&cancelled.destroys) == 1);
    return 0;
}

static int test_multiworker_serializes_one_stream(void) {
    enum { MESSAGE_COUNT = 32 };
    SynurangRuntimeOptions options = SYNURANG_RUNTIME_OPTIONS_INIT;
    SynurangStreamCallbacks callbacks = test_callbacks();
    SynurangRuntime* runtime;
    TestContext context = {0};
    uint64_t handle;
    int response_len = -1;
    int status = SYNURANG_INTERNAL;
    char* response;
    int i;

    options.execution_mode = SYNURANG_EXECUTION_THREADED;
    options.worker_count = 4u;
    options.inbound_queue_capacity = 64u;
    context.serialization_check = 1;
    runtime = synurang_runtime_create(&options);
    CHECK(runtime != NULL);
    handle = synurang_stream_open(runtime, &callbacks, &context);
    CHECK(handle != 0u);

    for (i = 0; i < MESSAGE_COUNT; ++i) {
        CHECK(Synurang_Stream_TrySend(handle, "x", 1) == SYNURANG_OK);
    }
    Synurang_Stream_CloseSend(handle);
    response = Synurang_Stream_Recv(handle, &response_len, &status);
    CHECK(response == NULL);
    CHECK(status == SYNURANG_EOF);
    CHECK(atomic_load(&context.messages) == MESSAGE_COUNT);
    CHECK(atomic_load(&context.active_callbacks) == 0);
    CHECK(atomic_load(&context.serialization_violations) == 0);
    Synurang_Stream_Close(handle);
    synurang_runtime_destroy(runtime);
    CHECK(atomic_load(&context.destroys) == 1);
    return 0;
}

typedef struct RaceArguments {
    uint64_t handle;
    atomic_int stop;
    atomic_int unexpected;
} RaceArguments;

static int send_status_expected(int status) {
    return status == SYNURANG_OK || status == SYNURANG_WOULD_BLOCK ||
           status == SYNURANG_CLOSED || status == SYNURANG_NOT_FOUND ||
           status == SYNURANG_SHUTTING_DOWN;
}

static void* close_race_sender(void* user_data) {
    RaceArguments* arguments = (RaceArguments*)user_data;
    while (!atomic_load(&arguments->stop)) {
        int status = Synurang_Stream_TrySend(arguments->handle, "r", 1);
        if (!send_status_expected(status)) {
            atomic_store(&arguments->unexpected, status);
            break;
        }
        (void)sched_yield();
    }
    return NULL;
}

static int recv_status_expected(int status) {
    return status == SYNURANG_OK || status == SYNURANG_PENDING ||
           status == SYNURANG_EOF || status == SYNURANG_CLOSED ||
           status == SYNURANG_NOT_FOUND || status == SYNURANG_SHUTTING_DOWN;
}

static void* close_race_receiver(void* user_data) {
    RaceArguments* arguments = (RaceArguments*)user_data;
    while (!atomic_load(&arguments->stop)) {
        int response_len = -1;
        int status = SYNURANG_INTERNAL;
        char* response = Synurang_Stream_TryRecv(
            arguments->handle, &response_len, &status);
        if (!recv_status_expected(status)) {
            atomic_store(&arguments->unexpected, status);
            Synurang_Free(response);
            break;
        }
        Synurang_Free(response);
        (void)sched_yield();
    }
    return NULL;
}

static int test_concurrent_close(void) {
    SynurangRuntimeOptions options = SYNURANG_RUNTIME_OPTIONS_INIT;
    SynurangStreamCallbacks callbacks = test_callbacks();
    SynurangRuntime* runtime;
    TestContext context = {0};
    RaceArguments arguments = {0};
    pthread_t sender;
    pthread_t receiver;
    struct timespec pause = {0, 20000000L};

    options.execution_mode = SYNURANG_EXECUTION_THREADED;
    options.worker_count = 4u;
    context.first_response = "race";
    runtime = synurang_runtime_create(&options);
    CHECK(runtime != NULL);
    arguments.handle = synurang_stream_open(runtime, &callbacks, &context);
    CHECK(arguments.handle != 0u);
    CHECK(pthread_create(&sender, NULL, close_race_sender, &arguments) == 0);
    CHECK(pthread_create(&receiver, NULL, close_race_receiver, &arguments) == 0);

    (void)nanosleep(&pause, NULL);
    Synurang_Stream_Close(arguments.handle);
    atomic_store(&arguments.stop, 1);
    CHECK(pthread_join(sender, NULL) == 0);
    CHECK(pthread_join(receiver, NULL) == 0);
    synurang_runtime_destroy(runtime);
    CHECK(atomic_load(&arguments.unexpected) == 0);
    CHECK(atomic_load(&context.cancels) == 1);
    CHECK(atomic_load(&context.destroys) == 1);
    return 0;
}

static int use_default_runtime_once(TestContext* context) {
    SynurangStreamCallbacks callbacks = test_callbacks();
    SynurangRuntime* runtime = synurang_runtime_default();
    uint64_t handle;
    int response_len = -1;
    int status = SYNURANG_INTERNAL;
    char* response;
    CHECK(runtime != NULL);
    context->first_response = "default";
    handle = synurang_stream_open(NULL, &callbacks, context);
    CHECK(handle != 0u);
    CHECK(Synurang_Stream_Send(handle, "request", 7) == SYNURANG_OK);
    CHECK(receive_equals(handle, 0, "default") == 0);
    Synurang_Stream_CloseSend(handle);
    response = Synurang_Stream_Recv(handle, &response_len, &status);
    CHECK(response == NULL);
    CHECK(status == SYNURANG_EOF);
    Synurang_Stream_Close(handle);
    return 0;
}

static int test_default_runtime_recreates(void) {
    TestContext first = {0};
    TestContext second = {0};
    CHECK(use_default_runtime_once(&first) == 0);
    synurang_runtime_shutdown_default();
    CHECK(atomic_load(&first.destroys) == 1);

    CHECK(use_default_runtime_once(&second) == 0);
    synurang_runtime_shutdown_default();
    CHECK(atomic_load(&second.destroys) == 1);
    return 0;
}
#endif

int main(void) {
    CHECK(test_error_response_wire() == 0);
    CHECK(test_reentrant_open_wakeup_close() == 0);
    CHECK(test_manual_async_output_wakeup() == 0);
    CHECK(test_capacity_reserves_before_copy() == 0);
    CHECK(test_terminal_discards_input() == 0);
    CHECK(test_manual_poll() == 0);
    CHECK(test_manual_blocking_abi_pumps() == 0);
    CHECK(test_manual_pump_reentrancy() == 0);
#ifndef SYNURANG_TEST_MANUAL_ONLY
#if defined(SYNURANG_TEST_PTHREAD_WRAP)
    CHECK(test_manual_send_rechecks_after_empty_poll() == 0);
#endif
    CHECK(test_manual_poll_destroy_race() == 0);
    CHECK(test_terminal_wakes_blocking_send() == 0);
    CHECK(test_threaded_blocking_recv() == 0);
    CHECK(test_multiworker_serializes_one_stream() == 0);
    CHECK(test_concurrent_close() == 0);
    CHECK(test_default_runtime_recreates() == 0);
#endif
    puts("C runtime tests passed.");
    return 0;
}
