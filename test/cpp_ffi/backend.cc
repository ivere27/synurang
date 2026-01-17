#include <cstring>
#include <cstdlib>
#include <cstdio>

// FFI structures matching Dart/Go definitions
struct CoreArgument {
    char* storagePath;
    char* cachePath;
    char* engineSocketPath;
    char* engineTcpPort;
    char* viewSocketPath;
    char* viewTcpPort;
    char* token;
    int enableCache;
    long long streamTimeout;
};

struct FfiData {
    void* data;
    long long len;
};

extern "C" {

int StartGrpcServer(struct CoreArgument cArg) {
    printf("[C++] StartGrpcServer called\n");
    printf("[C++] Token: %s\n", cArg.token ? cArg.token : "null");
    return 0;
}

int StopGrpcServer() {
    printf("[C++] StopGrpcServer called\n");
    return 0;
}

struct FfiData InvokeBackend(char* method, void* data, long long len) {
    printf("[C++] InvokeBackend called: %s (len: %lld)\n", method, len);

    const char* responseText = "Hello from C++ Backend!";
    long long respLen = strlen(responseText);

    void* respData = malloc(respLen);
    memcpy(respData, responseText, respLen);

    struct FfiData result;
    result.data = respData;
    result.len = respLen;
    return result;
}

struct FfiData InvokeBackendWithMeta(char* method, void* data, long long len, void* meta, long long metaLen) {
    return InvokeBackend(method, data, len);
}

void FreeFfiData(void* data) {
    if (data) {
        printf("[C++] FreeFfiData called\n");
        free(data);
    }
}

// Stubs for streaming (not implemented in this mock)
long long InvokeBackendServerStream(char* method, void* data, long long len) { return -1; }
long long InvokeBackendClientStream(char* method) { return -1; }
long long InvokeBackendBidiStream(char* method) { return -1; }
int SendStreamData(long long streamId, void* data, long long len) { return 0; }
void CloseStream(long long streamId) {}
void CloseStreamInput(long long streamId) {}
void StreamReady(long long streamId) {}
void RegisterDartCallback(void* callback) {}
void RegisterStreamCallback(void* callback) {}
void SendFfiResponse(long long requestId, void* data, long long len) {}

// Stubs for cache (not implemented in this mock)
struct FfiData CacheGet(char* storeName, char* key) { struct FfiData d = {0,0}; return d; }
int CachePut(char* storeName, char* key, void* data, long long len, long long ttl) { return 0; }
int CacheContains(char* storeName, char* key) { return 0; }
int CacheDelete(char* storeName, char* key) { return 0; }

} // extern "C"
