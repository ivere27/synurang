// C++ Plugin - uses shared service with FFI interface
#include "example_ffi_plugin.h"
#include "../service/greeter_service.h"
#include <iostream>

namespace example::v1 {

// Adapter: wraps shared logic with FFI plugin interface
class MyGoGreeterPlugin : public GoGreeterServicePlugin {
    GreeterServiceLogic<HelloRequest, HelloResponse, void> logic{"cpp-plugin"};

public:
    HelloResponse Bar(const HelloRequest& request) override {
        return logic.Bar(request);
    }

    void BarServerStream(const HelloRequest& request, 
                         PluginStream<HelloRequest, HelloResponse>* stream) override {
        // Wrap PluginStream to work with template
        struct StreamWriter {
            PluginStream<HelloRequest, HelloResponse>* s;
            bool Write(const HelloResponse& r) { return s->Send(r); }
        } writer{stream};
        logic.BarServerStream(request, &writer);
    }

    HelloResponse BarClientStream(PluginStream<HelloRequest, HelloResponse>* stream) override {
        struct StreamReader {
            PluginStream<HelloRequest, HelloResponse>* s;
            bool Read(HelloRequest* r) { return s->Recv(r); }
        } reader{stream};
        return logic.BarClientStream(&reader);
    }

    void BarBidiStream(PluginStream<HelloRequest, HelloResponse>* stream) override {
        struct BidiStream {
            PluginStream<HelloRequest, HelloResponse>* s;
            bool Read(HelloRequest* r) { return s->Recv(r); }
            bool Write(const HelloResponse& r) { return s->Send(r); }
        } bidi{stream};
        logic.BarBidiStream(&bidi);
    }

    // Stub implementations
    FileStatus UploadFile(PluginStream<FileChunk, FileStatus>* stream) override {
        return FileStatus{};
    }
    void DownloadFile(const DownloadFileRequest& req,
                      PluginStream<DownloadFileRequest, FileChunk>* stream) override {}
    void BidiFile(PluginStream<FileChunk, FileChunk>* stream) override {}
    HelloResponse Trigger(const TriggerRequest& req) override { return HelloResponse{}; }
    GoroutinesResponse GetGoroutines(const GoroutinesRequest& req) override { return GoroutinesResponse{}; }
};

static MyGoGreeterPlugin g_plugin;

__attribute__((constructor))
static void init_plugin() {
    std::cerr << "[C++ Plugin] Initializing..." << std::endl;
    RegisterGoGreeterServicePlugin(&g_plugin);
}

} // namespace example::v1
