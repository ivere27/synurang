#ifndef SYNURANG_CORE_HPP
#define SYNURANG_CORE_HPP

#include <string>
#include <vector>
#include <map>
#include <functional>
#include <cstdlib>
#include <cstring>

namespace synurang {

// Core Argument Structure (matching C/Go definition)
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

// FFI Data Structure (matching C/Go definition)
// Zero-copy: data is allocated via malloc and ownership is transferred to Dart.
// Dart calls FreeFfiData() to deallocate.
struct FfiData {
    void* data;
    long long len;
    
    // Create from string (allocates C memory)
    static FfiData fromString(const std::string& s) {
        FfiData result;
        if (s.empty()) {
            result.data = nullptr;
            result.len = 0;
        } else {
            result.data = malloc(s.size());
            if (result.data) {
                memcpy(result.data, s.data(), s.size());
                result.len = static_cast<long long>(s.size());
            } else {
                result.len = 0;
            }
        }
        return result;
    }
    
    // Create empty response
    static FfiData empty() {
        return FfiData{nullptr, 0};
    }
};

// =============================================================================
// Service Interface
// =============================================================================

// Base interface for generated service dispatchers.
// The protoc plugin generates FfiDispatcher classes that implement this.
// 
// Example usage:
//   1. Implement your gRPC service (MyService::Service)
//   2. Use generated FfiDispatcher::Invoke(service, method, data)
//   3. The dispatcher routes to the correct method and returns serialized response
class ServiceDispatcher {
public:
    virtual ~ServiceDispatcher() = default;
    
    // Invoke a method by name. Returns serialized protobuf response.
    // Empty string indicates an error.
    virtual std::string Invoke(const std::string& method, const std::string& data) = 0;
};

// Global dispatcher registration (set by generated code or user)
extern ServiceDispatcher* g_dispatcher;

inline void RegisterDispatcher(ServiceDispatcher* dispatcher) {
    g_dispatcher = dispatcher;
}

} // namespace synurang

// =============================================================================
// FFI Exports - Must match Go/Rust interface exactly
// =============================================================================

extern "C" {

// Server lifecycle
int StartGrpcServer(synurang::CoreArgument cArg);
int StopGrpcServer();

// Unary invocation (Dart -> C++)
// Zero-copy request: data points to Dart's memory, read-only.
// Zero-copy response: FfiData.data is malloc'd, Dart will free via FreeFfiData.
synurang::FfiData InvokeBackend(char* method, void* data, long long len);
synurang::FfiData InvokeBackendWithMeta(char* method, void* data, long long len, 
                                        void* meta, long long metaLen);

// Memory management
void FreeFfiData(void* data);

// Dart callback registration (C++ -> Dart)
typedef void (*InvokeDartCallback)(long long requestId, char* method, void* data, long long len);
void RegisterDartCallback(InvokeDartCallback callback);
void SendFfiResponse(long long requestId, void* data, long long len);

// Streaming (stubs - not implemented for C++)
// TODO: Implement streaming support for C++ backend
typedef void (*StreamCallback)(long long streamId, char msgType, void* data, long long len);
void RegisterStreamCallback(StreamCallback callback);
long long InvokeBackendServerStream(char* method, void* data, long long len);
long long InvokeBackendClientStream(char* method);
long long InvokeBackendBidiStream(char* method);
int SendStreamData(long long streamId, void* data, long long len);
void CloseStream(long long streamId);
void CloseStreamInput(long long streamId);
void StreamReady(long long streamId);

// Cache (stubs - not implemented for C++)
// TODO: Implement cache support for C++ backend
synurang::FfiData CacheGet(char* store, char* key);
int CachePut(char* store, char* key, void* data, long long len, long long ttlSeconds);
int CacheContains(char* store, char* key);
int CacheDelete(char* store, char* key);

} // extern "C"

#endif // SYNURANG_CORE_HPP
