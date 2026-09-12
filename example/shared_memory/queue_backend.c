#include "queue_backend.h"
#include "frame_queue_ffi.h"

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define LIMIT 64u
#define FIFO SYNURANG_EXAMPLE_SHM_QUEUE_POLICY_FIFO
#define LATEST SYNURANG_EXAMPLE_SHM_QUEUE_POLICY_LATEST
#define BATCH SYNURANG_EXAMPLE_SHM_QUEUE_POLICY_BATCH
#define READY SYNURANG_EXAMPLE_SHM_FRAME_EVENT_READY
#define PROCESSED SYNURANG_EXAMPLE_SHM_FRAME_EVENT_PROCESSED
#define DROPPED SYNURANG_EXAMPLE_SHM_FRAME_EVENT_DROPPED
#define SUMMARY SYNURANG_EXAMPLE_SHM_FRAME_EVENT_SUMMARY
typedef SynurangExampleShmQueueConfig Config;
typedef SynurangExampleShmFrameResult Result;
typedef struct Service Service;
typedef struct Job {
    SynurangExampleShmFrame frame;
    uint64_t enqueued_ns;
} Job;
typedef struct Session {
    Service* service;
    SynurangStream* stream;
    pthread_mutex_t mutex;
    pthread_cond_t changed;
    Config config;
    uint8_t* mapping;
    size_t mapping_size;
    int configured, half_closed, stopped, paused;
    unsigned char busy[LIMIT];
    Job input[LIMIT];
    Result output[LIMIT];
    size_t input_head, input_count, output_head, output_count;
    uint32_t input_high_water, output_high_water;
    uint64_t last_id, processed, dropped, batches;
} Session;
struct Service {
    pthread_mutex_t mutex;
    pthread_cond_t changed;
    pthread_t worker;
    int started, stopping;
    Session* active;
};

static uint64_t now_ns(void) {
    struct timespec time;
    (void)clock_gettime(CLOCK_MONOTONIC, &time);
    return (uint64_t)time.tv_sec * 1000000000u + (uint64_t)time.tv_nsec;
}

/* All *_locked helpers require the session mutex. Only the worker waits;
 * runtime callbacks return promptly. Absolute deadlines survive spurious wakes. */
static void wait_until_locked(Session* s, uint64_t deadline) {
    const struct timespec time = {
        (time_t)(deadline / 1000000000u), (long)(deadline % 1000000000u)
    };
    (void)pthread_cond_timedwait(&s->changed, &s->mutex, &time);
}

static void fail_locked(Session* s, int code, const char* message) {
    s->stopped = 1;
    (void)pthread_cond_broadcast(&s->changed);
    (void)synurang_stream_fail_error(s->stream, 0, code, message);
}

/* The reliable result queue never drops an ownership notification. The runtime
 * also has a bounded transport queue; on_writable restarts this pump. */
static void flush_locked(Session* s) {
    while (s->output_count && !s->stopped) {
        Result* result = &s->output[s->output_head];
        SynurangStatus status = frame_queue_run_respond(s->stream, result);
        if (status == SYNURANG_WOULD_BLOCK) return;
        if (status != SYNURANG_OK) {
            fail_locked(s, 13, "Cannot publish frame result");
            return;
        }
        if (result->field_event == PROCESSED || result->field_event == DROPPED)
            s->busy[result->field_slot] = 0;
        s->output_head = (s->output_head + 1) % LIMIT;
        --s->output_count;
        (void)pthread_cond_broadcast(&s->changed);
    }
}

static int publish_locked(Session* s, const Result* result) {
    while (!s->stopped && s->output_count == s->config.field_output_capacity)
        (void)pthread_cond_wait(&s->changed, &s->mutex);
    if (s->stopped) return 0;
    s->output[(s->output_head + s->output_count) % LIMIT] = *result;
    ++s->output_count;
    if (s->output_count > s->output_high_water)
        s->output_high_water = (uint32_t)s->output_count;
    flush_locked(s);
    return !s->stopped;
}

static Result result_for(const Job* job, int event) {
    Result result;
    synurang_example_shm_frame_result_init(&result);
    result.field_event = event;
    result.field_slot = job->frame.field_slot;
    result.field_frame_id = job->frame.field_frame_id;
    result.field_captured_ns = job->frame.field_captured_ns;
    return result;
}

/* Read and annotate RGB24 in the actual shared pages. Red is the target, blue
 * is a defect. A green/yellow border reports a clean/defective target. There is
 * no image allocation, image memcpy, codec, or inference dependency here. */
static void detect(Session* s, const Job* job, Result* result) {
    uint32_t width = s->config.field_width, height = s->config.field_height;
    uint32_t left = width, top = height, right = 0, bottom = 0;
    uint8_t* pixels = s->mapping + (size_t)job->frame.field_slot * s->config.field_slot_stride;
    for (uint32_t y = 0; y < height; ++y) {
        for (uint32_t x = 0; x < width; ++x) {
            uint8_t* p = pixels + ((size_t)y * width + x) * 3;
            if (p[2] > 180 && p[0] < 80 && p[1] < 80) result->field_defect = 1;
            if (p[0] <= 180 || p[1] >= 80 || p[2] >= 80) continue;
            if (x < left) left = x;
            if (x > right) right = x;
            if (y < top) top = y;
            if (y > bottom) bottom = y;
            result->field_detected = 1;
        }
    }
    if (!result->field_detected) return;
    result->field_x = left;
    result->field_y = top;
    result->field_width = right - left + 1;
    result->field_height = bottom - top + 1;
    for (uint32_t y = top; y <= bottom; ++y) {
        for (uint32_t x = left; x <= right; ++x) {
            if (x != left && x != right && y != top && y != bottom) continue;
            uint8_t* p = pixels + ((size_t)y * width + x) * 3;
            p[0] = result->field_defect ? 255 : 0;
            p[1] = 255;
            p[2] = 0;
        }
    }
}

static int run_session(Session* s) {
    Job jobs[LIMIT];
    (void)pthread_mutex_lock(&s->mutex);
    while (!s->stopped) {
        if (!s->configured || !s->input_count) {
            if (s->configured && s->half_closed) break;
            (void)pthread_cond_wait(&s->changed, &s->mutex);
            continue;
        }
        if (s->config.field_policy == BATCH && !s->half_closed &&
            s->input_count < s->config.field_batch_size) {
            uint64_t deadline = s->input[s->input_head].enqueued_ns +
                               (uint64_t)s->config.field_batch_wait_ms * 1000000u;
            if (now_ns() < deadline) {
                wait_until_locked(s, deadline);
                continue;
            }
        }
        size_t count = 1;
        if (s->config.field_policy == LATEST) count = s->input_count;
        else if (s->config.field_policy == BATCH)
            count = s->input_count < s->config.field_batch_size ?
                    s->input_count : s->config.field_batch_size;
        for (size_t i = 0; i < count; ++i) {
            jobs[i] = s->input[s->input_head];
            s->input_head = (s->input_head + 1) % LIMIT;
        }
        s->input_count -= count;
        if (s->paused) {
            s->paused = 0;
            synurang_stream_resume_input(s->stream);
        }
        ++s->batches;
        for (size_t i = 0; i < count && !s->stopped; ++i) {
            if (s->config.field_policy == LATEST && i + 1 != count) {
                Result dropped = result_for(&jobs[i], DROPPED);
                dropped.field_completed_ns = now_ns();
                if (publish_locked(s, &dropped)) ++s->dropped;
                continue;
            }
            Result result = result_for(&jobs[i], PROCESSED);
            result.field_batch_id = s->batches;
            result.field_batch_size = s->config.field_policy == BATCH ? (uint32_t)count : 1;
            result.field_started_ns = now_ns();
            uint64_t deadline = result.field_started_ns +
                               (uint64_t)s->config.field_simulate_work_ms * 1000000u;
            while (!s->stopped && now_ns() < deadline) wait_until_locked(s, deadline);
            if (s->stopped) break;
            (void)pthread_mutex_unlock(&s->mutex);
            detect(s, &jobs[i], &result);
            (void)pthread_mutex_lock(&s->mutex);
            /* No further access to this slot after publishing its completion. */
            result.field_completed_ns = now_ns();
            if (publish_locked(s, &result)) ++s->processed;
        }
    }
    /* On cancellation results may be unreadable. Retain the stream until all
     * pixel access has stopped and the mapping is gone; host.close waits for it. */
    if (s->mapping) {
        if (munmap(s->mapping, s->mapping_size) != 0)
            fail_locked(s, 13, "Cannot unmap frame pool");
        s->mapping = NULL;
    }
    if (!s->stopped) {
        Result summary;
        synurang_example_shm_frame_result_init(&summary);
        summary.field_event = SUMMARY;
        summary.field_input_high_water = s->input_high_water;
        summary.field_output_high_water = s->output_high_water;
        summary.field_processed = s->processed;
        summary.field_dropped = s->dropped;
        summary.field_batches = s->batches;
        (void)publish_locked(s, &summary);
        while (s->output_count && !s->stopped)
            (void)pthread_cond_wait(&s->changed, &s->mutex);
    }
    int success = !s->stopped;
    (void)pthread_mutex_unlock(&s->mutex);
    return success;
}

static void* work(void* context) {
    Service* service = context;
    (void)pthread_mutex_lock(&service->mutex);
    for (;;) {
        while (!service->active && !service->stopping)
            (void)pthread_cond_wait(&service->changed, &service->mutex);
        if (service->stopping) break;
        Session* session = service->active;
        SynurangStream* stream = session->stream;
        (void)pthread_mutex_unlock(&service->mutex);
        int success = run_session(session);
        (void)pthread_mutex_lock(&service->mutex);
        service->active = NULL;
        (void)pthread_mutex_unlock(&service->mutex);
        /* A caller can start the next session as soon as it receives EOF. */
        if (success) (void)synurang_stream_finish(stream);
        synurang_stream_release(stream); /* May free session: never touch it again. */
        (void)pthread_mutex_lock(&service->mutex);
    }
    (void)pthread_mutex_unlock(&service->mutex);
    return NULL;
}

static void opened(SynurangStream* stream, void* context) {
    Session* s = context;
    Service* service = s->service;
    s->stream = stream;
    (void)pthread_mutex_lock(&service->mutex);
    if (service->active) {
        (void)pthread_mutex_unlock(&service->mutex);
        (void)synurang_stream_fail_error(stream, 0, 8, "One active frame queue per instance");
        return;
    }
    if (!service->started) {
        if (pthread_create(&service->worker, NULL, work, service) != 0) {
            (void)pthread_mutex_unlock(&service->mutex);
            (void)synurang_stream_fail_error(stream, 0, 13, "Cannot start frame worker");
            return;
        }
        service->started = 1;
    }
    s->stream = synurang_stream_retain(stream);
    service->active = s;
    (void)pthread_cond_signal(&service->changed);
    (void)pthread_mutex_unlock(&service->mutex);
}

static void configure_locked(Session* s, const Config* c) {
    char name[256];
    struct stat info;
    if (s->configured || c->field_name.len < 2 || c->field_name.len >= sizeof(name) ||
        c->field_name.data[0] != '/' || memchr(c->field_name.data, 0, c->field_name.len) ||
        memchr(c->field_name.data + 1, '/', c->field_name.len - 1) ||
        c->field_width < 1 || c->field_width > 256 || c->field_height < 1 || c->field_height > 256 ||
        c->field_slot_count < 1 || c->field_slot_count > LIMIT ||
        c->field_input_capacity < 1 || c->field_input_capacity > LIMIT ||
        c->field_output_capacity < 1 || c->field_output_capacity > LIMIT ||
        c->field_policy < FIFO || c->field_policy > BATCH || c->field_simulate_work_ms > 1000 ||
        (c->field_policy == BATCH && (c->field_batch_size < 1 ||
         c->field_batch_size > c->field_input_capacity || c->field_batch_size > c->field_slot_count ||
         c->field_batch_wait_ms < 1 || c->field_batch_wait_ms > 1000))) {
        fail_locked(s, 3, "Invalid queue configuration");
        return;
    }
    size_t pixels = (size_t)c->field_width * c->field_height * 3;
    if (c->field_slot_stride < pixels || c->field_slot_stride > pixels + 4096) {
        fail_locked(s, 3, "Invalid RGB slot stride");
        return;
    }
    memcpy(name, c->field_name.data, c->field_name.len);
    name[c->field_name.len] = 0;
    int fd = shm_open(name, O_RDWR, 0);
    if (fd < 0) {
        fail_locked(s, errno == ENOENT ? 5 : 13, "Cannot open frame pool");
        return;
    }
    s->mapping_size = (size_t)c->field_slot_count * c->field_slot_stride;
    int valid = fstat(fd, &info) == 0 && info.st_size >= 0 && (uint64_t)info.st_size >= s->mapping_size;
    if (valid) {
        void* mapping = mmap(NULL, s->mapping_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        if (mapping != MAP_FAILED) s->mapping = mapping;
    }
    (void)close(fd);
    if (!valid || !s->mapping) {
        fail_locked(s, valid ? 13 : 11, "Cannot map frame pool range");
        return;
    }
    s->config = *c;
    s->config.field_name.data = NULL; /* Decoded message is borrowed. */
    s->config.field_name.len = 0;
    s->configured = 1;
    Result ready;
    synurang_example_shm_frame_result_init(&ready);
    ready.field_event = READY;
    /* First output: capacity is nonzero, so this callback cannot wait. */
    (void)publish_locked(s, &ready);
    (void)pthread_cond_signal(&s->changed);
}

static void message(SynurangStream* stream, const uint8_t* data, size_t size, void* context) {
    Session* s = context;
    SynurangExampleShmQueueRequest request;
    (void)stream;
    synurang_example_shm_queue_request_init(&request);
    SynurangLiteStatus status = synurang_example_shm_queue_request_decode(&request, data, size);
    (void)pthread_mutex_lock(&s->mutex);
    if (!s->stopped) {
        if (status != SYNURANG_LITE_OK) fail_locked(s, 3, "Malformed queue request");
        else if (request.which_value == 1 && request.field_config) configure_locked(s, request.field_config);
        else if (request.which_value == 2 && request.field_frame && s->configured) {
            const SynurangExampleShmFrame* frame = request.field_frame;
            if (frame->field_slot >= s->config.field_slot_count ||
                frame->field_frame_id <= s->last_id || s->busy[frame->field_slot]) {
                fail_locked(s, 3, "Invalid frame ID or slot still owned by backend");
            } else {
                Job* job = &s->input[(s->input_head + s->input_count) % LIMIT];
                job->frame = *frame;
                job->enqueued_ns = now_ns();
                s->last_id = frame->field_frame_id;
                s->busy[frame->field_slot] = 1;
                ++s->input_count;
                if (s->input_count > s->input_high_water) s->input_high_water = (uint32_t)s->input_count;
                if (s->input_count == s->config.field_input_capacity) {
                    s->paused = 1;
                    synurang_stream_pause_input(s->stream);
                }
                (void)pthread_cond_signal(&s->changed);
            }
        } else fail_locked(s, 3, "Send one configuration before frame descriptors");
    }
    (void)pthread_mutex_unlock(&s->mutex);
    synurang_example_shm_queue_request_free(&request);
}

static void half_closed(SynurangStream* stream, void* context) {
    Session* s = context;
    (void)stream;
    (void)pthread_mutex_lock(&s->mutex);
    s->half_closed = 1;
    if (!s->configured) fail_locked(s, 3, "Missing queue configuration");
    (void)pthread_cond_signal(&s->changed);
    (void)pthread_mutex_unlock(&s->mutex);
}

static void writable(SynurangStream* stream, void* context) {
    Session* s = context;
    (void)stream;
    (void)pthread_mutex_lock(&s->mutex);
    flush_locked(s);
    (void)pthread_mutex_unlock(&s->mutex);
}

static void cancelled(SynurangStream* stream, void* context) {
    Session* s = context;
    (void)stream;
    (void)pthread_mutex_lock(&s->mutex);
    s->stopped = 1;
    (void)pthread_cond_broadcast(&s->changed);
    (void)pthread_mutex_unlock(&s->mutex);
}

static void session_destroy(void* context) {
    Session* s = context;
    (void)pthread_cond_destroy(&s->changed);
    (void)pthread_mutex_destroy(&s->mutex);
    free(s);
}

static uint64_t open_session(SynurangRuntime* runtime, const SynurangCallOptions* options, void* context) {
    Session* s = calloc(1, sizeof(*s));
    pthread_condattr_t attributes;
    const SynurangStreamCallbacks callbacks = {
        sizeof(callbacks), opened, message, half_closed, writable, cancelled, session_destroy
    };
    (void)options;
    if (!s) return 0;
    s->service = context;
    if (pthread_mutex_init(&s->mutex, NULL) != 0) { free(s); return 0; }
    if (pthread_condattr_init(&attributes) != 0) {
        (void)pthread_mutex_destroy(&s->mutex); free(s); return 0;
    }
    int status = pthread_condattr_setclock(&attributes, CLOCK_MONOTONIC);
    if (!status) status = pthread_cond_init(&s->changed, &attributes);
    (void)pthread_condattr_destroy(&attributes);
    if (status) { (void)pthread_mutex_destroy(&s->mutex); free(s); return 0; }
    uint64_t handle = synurang_stream_open(runtime, &callbacks, s);
    if (!handle) session_destroy(s);
    return handle;
}

static void service_destroy(void* context) {
    Service* service = context;
    /* Registration teardown runs after all retained streams retire. Join the
     * persistent worker here, before dlclose, rather than detaching a thread
     * that might still execute module code after its final stream release. */
    (void)pthread_mutex_lock(&service->mutex);
    service->stopping = 1;
    (void)pthread_cond_signal(&service->changed);
    (void)pthread_mutex_unlock(&service->mutex);
    if (service->started) (void)pthread_join(service->worker, NULL);
    (void)pthread_cond_destroy(&service->changed);
    (void)pthread_mutex_destroy(&service->mutex);
    free(service);
}

int example_frame_queue_register(SynurangInstance* instance) {
    Service* service = calloc(1, sizeof(*service));
    if (!service) return SYNURANG_OUT_OF_MEMORY;
    if (pthread_mutex_init(&service->mutex, NULL) != 0) { free(service); return SYNURANG_INTERNAL; }
    if (pthread_cond_init(&service->changed, NULL) != 0) {
        (void)pthread_mutex_destroy(&service->mutex); free(service); return SYNURANG_INTERNAL;
    }
    int status = synurang_instance_register(instance, "/synurang.example.shm.FrameQueue/Run",
                                            1, 1, open_session, service, service_destroy);
    if (status != SYNURANG_OK) service_destroy(service);
    return status;
}
