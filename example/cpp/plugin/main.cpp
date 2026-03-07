// C++ Plugin - uses shared service with FFI interface
#include "example_ffi_plugin.h"
#include "../service/greeter_service.h"
#include <iostream>
#include <stdexcept>

namespace example::v1 {

namespace {

constexpr const char* kErrorTriggerName = "trigger_error";
constexpr int32_t kCppUnaryFfiCode = 4201;
constexpr int32_t kCppServerFfiCode = 4202;
constexpr int32_t kCppClientFfiCode = 4203;
constexpr int32_t kCppBidiFfiCode = 4204;

bool is_error_trigger_request(const std::string& name) {
    return name == kErrorTriggerName;
}

FfiError ffi_test_error(const char* message, int32_t code) {
    return FfiError(message, code, 10);
}

}  // namespace

// Adapter: wraps shared logic with FFI plugin interface
class MyGoGreeterPlugin : public GoGreeterServicePlugin {
    GreeterServiceLogic<HelloRequest, HelloResponse, void> logic{"cpp-plugin"};

public:
    HelloResponse Bar(const HelloRequest& request) override {
        if (is_error_trigger_request(request.name())) {
            throw ffi_test_error("cpp unary ffi error", kCppUnaryFfiCode);
        }
        return logic.Bar(request);
    }

    void BarServerStream(const HelloRequest& request, 
                         PluginStream<HelloRequest, HelloResponse>* stream) override {
        if (is_error_trigger_request(request.name())) {
            throw ffi_test_error("cpp server stream ffi error", kCppServerFfiCode);
        }
        // Wrap PluginStream to work with template
        struct StreamWriter {
            PluginStream<HelloRequest, HelloResponse>* s;
            bool Write(const HelloResponse& r) { return s->Send(r); }
        } writer{stream};
        logic.BarServerStream(request, &writer);
    }

    HelloResponse BarClientStream(PluginStream<HelloRequest, HelloResponse>* stream) override {
        int count = 0;
        HelloRequest req;
        while (stream->Recv(&req)) {
            if (is_error_trigger_request(req.name())) {
                throw ffi_test_error("cpp client stream ffi error", kCppClientFfiCode);
            }
            count++;
        }
        HelloResponse response;
        response.set_message("Received " + std::to_string(count) + " messages");
        response.set_from("cpp-plugin");
        return response;
    }

    void BarBidiStream(PluginStream<HelloRequest, HelloResponse>* stream) override {
        HelloRequest req;
        while (stream->Recv(&req)) {
            if (is_error_trigger_request(req.name())) {
                throw ffi_test_error("cpp bidi stream ffi error", kCppBidiFfiCode);
            }
            HelloResponse response;
            response.set_message("Echo: " + req.name());
            response.set_from("cpp-plugin");
            if (!stream->Send(response)) {
                break;
            }
        }
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
