#include "shared_memory_ffi.h"
#include "queue_backend.h"

#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

/* Keep this callback's example computation short. A real media worker should
 * retain its stream and stop using the mapping before publishing completion. */
#define MAX_PAYLOAD (64u * 1024u)

static void process(SynurangStream* stream,
                    const SynurangExampleShmBufferRequest* request, void* context) {
    char name[256];
    struct stat info;
    int fd;
    long page_size;
    uint64_t map_offset, delta, file_size, checksum = 0;
    size_t map_size;
    uint8_t* mapping;
    uint8_t* payload;
    SynurangExampleShmBufferDone done;
    (void)context;

    if (request->field_name.len < 2 || request->field_name.len >= sizeof(name) ||
        request->field_name.data[0] != '/' ||
        memchr(request->field_name.data, '\0', request->field_name.len) != NULL ||
        memchr(request->field_name.data + 1, '/', request->field_name.len - 1) != NULL ||
        request->field_length == 0 || request->field_length > MAX_PAYLOAD ||
        request->field_xor_mask > 255) {
        (void)synurang_stream_fail_error(stream, 0, 3, "Invalid shared-memory descriptor (maximum 64 KiB)");
        return;
    }
    memcpy(name, request->field_name.data, request->field_name.len);
    name[request->field_name.len] = '\0';
    fd = shm_open(name, O_RDWR, 0);
    if (fd < 0) {
        (void)synurang_stream_fail_error(stream, 0, errno == ENOENT ? 5 : 13, "Cannot open shared memory");
        return;
    }
    if (fstat(fd, &info) != 0 || info.st_size < 0) {
        (void)close(fd);
        (void)synurang_stream_fail_error(stream, 0, 13, "Cannot inspect shared memory");
        return;
    }
    file_size = (uint64_t)info.st_size;
    /* Subtraction avoids overflow even for an offset supplied as UINT64_MAX. */
    if (request->field_offset > file_size ||
        request->field_length > file_size - request->field_offset) {
        (void)close(fd);
        (void)synurang_stream_fail_error(stream, 0, 11, "Shared-memory range is out of bounds");
        return;
    }
    page_size = sysconf(_SC_PAGESIZE);
    if (page_size <= 0) {
        (void)close(fd);
        (void)synurang_stream_fail_error(stream, 0, 13, "Cannot determine page size");
        return;
    }
    /* mmap offsets are page-aligned; the descriptor itself need not be. */
    map_offset = request->field_offset - request->field_offset % (uint64_t)page_size;
    delta = request->field_offset - map_offset;
    if (delta > SIZE_MAX - request->field_length) {
        (void)close(fd);
        (void)synurang_stream_fail_error(stream, 0, 11, "Mapping size is out of bounds");
        return;
    }
    map_size = (size_t)(delta + request->field_length);
    mapping = mmap(NULL, map_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, (off_t)map_offset);
    (void)close(fd); /* The mapping owns its reference to the shared pages. */
    if (mapping == MAP_FAILED) {
        (void)synurang_stream_fail_error(stream, 0, 13, "Cannot map shared memory");
        return;
    }

    /* This is the payload: read and write the caller's actual shared pages.
     * No protobuf bytes field, payload allocation, or payload memcpy is used. */
    payload = mapping + (size_t)delta;
    for (size_t i = 0; i < (size_t)request->field_length; ++i) {
        payload[i] ^= (uint8_t)request->field_xor_mask;
        checksum += payload[i];
    }

    /* Done is permission to reuse the region. Stop accessing it BEFORE ACK. */
    if (munmap(mapping, map_size) != 0) {
        (void)synurang_stream_fail_error(stream, 0, 13, "Cannot unmap shared memory");
        return;
    }
    synurang_example_shm_buffer_done_init(&done);
    done.field_request_id = request->field_request_id;
    done.field_bytes_processed = request->field_length;
    done.field_checksum = checksum;
    if (shared_memory_process_respond(stream, &done) == SYNURANG_OK)
        (void)synurang_stream_finish(stream);
    else
        (void)synurang_stream_fail_error(stream, 0, 13, "Cannot publish completion");
}

static SynurangInstance* create(const SynurangRuntimeOptions* options) {
    SynurangInstance* instance = synurang_instance_create(options);
    SharedMemoryHandlers handlers = {0};
    if (instance == NULL) return NULL;
    handlers.process.message = process;
    if (shared_memory_register(instance, &handlers, NULL) != SYNURANG_OK ||
        example_frame_queue_register(instance) != SYNURANG_OK) {
        (void)synurang_instance_destroy(instance);
        return NULL;
    }
    return instance;
}

SYNURANG_DEFINE_MODULE(Synurang_GetApi, create)
