#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#define EXPORT __declspec(dllexport)
#else
#define EXPORT __attribute__((visibility("default")))
#endif

typedef struct StreamState {
    uint64_t handle;
    unsigned char *data;
    int32_t len;
    int delivered;
    int in_use;
} StreamState;

static StreamState streams[16];
static uint64_t next_handle = 1;

static const unsigned char error_payload[] = {
    0x08, 0x7b,
    0x12, 0x04, 'b', 'o', 'o', 'm',
    0x18, 0x0a,
};

static unsigned char *copy_bytes(const unsigned char *data, int32_t len) {
    size_t alloc_len = len > 0 ? (size_t)len : 1u;
    unsigned char *out = (unsigned char *)malloc(alloc_len);
    if (out != NULL && len > 0) {
        memcpy(out, data, (size_t)len);
    }
    return out;
}

static StreamState *find_stream(uint64_t handle) {
    int i;
    for (i = 0; i < 16; ++i) {
        if (streams[i].in_use && streams[i].handle == handle) {
            return &streams[i];
        }
    }
    return NULL;
}

EXPORT void Synurang_Free(void *ptr) {
    free(ptr);
}

EXPORT unsigned char *Synurang_Invoke_TestService(
    const char *method,
    const unsigned char *data,
    int32_t data_len,
    int32_t *response_len
) {
    if (strcmp(method, "/test.v1.TestService/NullEmpty") == 0) {
        *response_len = 0;
        return NULL;
    }
    if (strcmp(method, "/test.v1.TestService/AllocatedEmpty") == 0) {
        *response_len = 0;
        return copy_bytes(NULL, 0);
    }
    if (strcmp(method, "/test.v1.TestService/Error") == 0) {
        *response_len = -(int32_t)sizeof(error_payload);
        return copy_bytes(error_payload, (int32_t)sizeof(error_payload));
    }
    *response_len = data_len;
    return copy_bytes(data, data_len);
}

EXPORT uint64_t Synurang_Stream_TestService_Open(const char *method) {
    int i;
    if (strcmp(method, "/test.v1.TestService/OpenFail") == 0) {
        return 0;
    }
    for (i = 0; i < 16; ++i) {
        if (!streams[i].in_use) {
            streams[i].handle = next_handle++;
            streams[i].data = NULL;
            streams[i].len = 0;
            streams[i].delivered = 0;
            streams[i].in_use = 1;
            return streams[i].handle;
        }
    }
    return 0;
}

EXPORT int32_t Synurang_Stream_Send(
    uint64_t handle,
    const unsigned char *data,
    int32_t data_len
) {
    StreamState *stream = find_stream(handle);
    if (stream == NULL) {
        return -1;
    }
    if (data_len == 1 && data != NULL && data[0] == 0xff) {
        return -7;
    }
    free(stream->data);
    stream->data = copy_bytes(data, data_len);
    stream->len = data_len;
    stream->delivered = 0;
    return 0;
}

EXPORT unsigned char *Synurang_Stream_Recv(
    uint64_t handle,
    int32_t *response_len,
    int32_t *status
) {
    StreamState *stream = find_stream(handle);
    if (stream == NULL) {
        *response_len = 0;
        *status = -2;
        return NULL;
    }
    if (stream->len == 5 && memcmp(stream->data, "error", 5) == 0) {
        stream->delivered = 1;
        *response_len = (int32_t)sizeof(error_payload);
        *status = -1;
        return copy_bytes(error_payload, (int32_t)sizeof(error_payload));
    }
    if (stream->delivered) {
        *response_len = 0;
        *status = 1;
        return NULL;
    }
    stream->delivered = 1;
    *response_len = stream->len;
    *status = 0;
    return copy_bytes(stream->data, stream->len);
}

EXPORT void Synurang_Stream_CloseSend(uint64_t handle) {
    (void)handle;
}

EXPORT void Synurang_Stream_Close(uint64_t handle) {
    StreamState *stream = find_stream(handle);
    if (stream == NULL) {
        return;
    }
    free(stream->data);
    memset(stream, 0, sizeof(*stream));
}

