// Synurang C++ Plugin Host - Unix Implementation
//
// Uses dlopen/dlsym for dynamic library loading on Linux/macOS/Android/iOS.

#include "synurang/plugin_host.hpp"

#ifndef _WIN32

#include <dlfcn.h>
#include <cstring>

#include <condition_variable>
#include <atomic>

namespace synurang {

// FFI function signatures
using InvokeFunc = char* (*)(char* method, char* data, int data_len, int* resp_len);
using FreeFunc = void (*)(char* ptr);
using StreamOpenFunc = uint64_t (*)(char* method);
using StreamSendFunc = int (*)(uint64_t handle, char* data, int data_len);
using StreamRecvFunc = char* (*)(uint64_t handle, int* resp_len, int* status);
using StreamCloseSendFunc = void (*)(uint64_t handle);
using StreamCloseFunc = void (*)(uint64_t handle);

struct StreamFuncs {
    StreamSendFunc send = nullptr;
    StreamRecvFunc recv = nullptr;
    StreamCloseSendFunc close_send = nullptr;
    StreamCloseFunc close = nullptr;
};

// Internal state managed by shared_ptr
struct PluginState {
    void* handle = nullptr;
    FreeFunc free_ptr = nullptr;
    
    std::mutex mutex;
    std::map<std::string, InvokeFunc> invokers;
    std::map<std::string, StreamOpenFunc> stream_openers;
    std::unique_ptr<StreamFuncs> stream_funcs;
    bool closed = false;

    // Active execution tracking
    std::atomic<int> active_calls{0};
    std::condition_variable cv;

    PluginState(void* h, FreeFunc f) : handle(h), free_ptr(f) {}

    ~PluginState() {
        // Wait for all active FFI calls to finish
        std::unique_lock<std::mutex> lock(mutex);
        cv.wait(lock, [this] { return active_calls == 0; });
        
        if (handle) {
            dlclose(handle);
        }
    }

    void* lookup(const char* name) {
        return dlsym(handle, name);
    }
};

// RAII helper for active call tracking
struct ScopedCall {
    std::shared_ptr<PluginState> state;
    ScopedCall(std::shared_ptr<PluginState> s) : state(s) {
        state->active_calls++;
    }
    ~ScopedCall() {
        state->active_calls--;
        state->cv.notify_all();
    }
};

PluginHost PluginHost::load(const std::string& path) {
    void* handle = dlopen(path.c_str(), RTLD_LAZY);
    if (!handle) {
        throw FfiError(std::string("Failed to load plugin: ") + dlerror());
    }

    void* free_ptr = dlsym(handle, "Synurang_Free");
    if (!free_ptr) {
        dlclose(handle);
        throw FfiError("Plugin missing Synurang_Free symbol");
    }

    auto state = std::make_shared<PluginState>(handle, reinterpret_cast<FreeFunc>(free_ptr));
    return PluginHost(state);
}

PluginHost::PluginHost(std::shared_ptr<PluginState> state) : state_(state) {}

void PluginHost::close() {
    if (state_) {
        std::lock_guard<std::mutex> lock(state_->mutex);
        state_->closed = true;
    }
}

std::vector<uint8_t> PluginHost::invoke(
    const std::string& service_name,
    const std::string& method,
    const std::vector<uint8_t>& data
) {
    if (!state_) throw FfiError("Plugin not initialized");

    InvokeFunc invoke_fn = nullptr;
    FreeFunc free_fn = state_->free_ptr;

    {
        std::lock_guard<std::mutex> lock(state_->mutex);
        if (state_->closed) throw PluginClosedError();

        auto it = state_->invokers.find(service_name);
        if (it != state_->invokers.end()) {
            invoke_fn = it->second;
        } else {
            std::string sym_name = "Synurang_Invoke_" + service_name;
            void* ptr = state_->lookup(sym_name.c_str());
            if (!ptr) {
                throw FfiError("Service not found: " + service_name);
            }
            invoke_fn = reinterpret_cast<InvokeFunc>(ptr);
            state_->invokers[service_name] = invoke_fn;
        }
    }

    // Call without holding lock
    std::vector<char> method_buf(method.begin(), method.end());
    method_buf.push_back('\0');

    char* data_ptr = nullptr;
    if (!data.empty()) {
        data_ptr = reinterpret_cast<char*>(const_cast<uint8_t*>(data.data()));
    }

    int resp_len = 0;
    char* resp;
    {
        ScopedCall call(state_);
        resp = invoke_fn(method_buf.data(), data_ptr, static_cast<int>(data.size()), &resp_len);
    }

    if (!resp) {
        if (resp_len == 0) return {};
        throw FfiError("Plugin returned null");
    }

    std::vector<uint8_t> result(resp, resp + detail::abs_len(resp_len));
    free_fn(resp);

    if (resp_len < 0) {
        throw detail::decode_ffi_error(result);
    }
    return result;
}

std::unique_ptr<PluginStream> PluginHost::open_stream(
    const std::string& service_name,
    const std::string& method
) {
    if (!state_) throw FfiError("Plugin not initialized");

    StreamOpenFunc open_fn = nullptr;
    {
        std::lock_guard<std::mutex> lock(state_->mutex);
        if (state_->closed) throw PluginClosedError();

        // Ensure stream funcs
        if (!state_->stream_funcs) {
            auto send = state_->lookup("Synurang_Stream_Send");
            auto recv = state_->lookup("Synurang_Stream_Recv");
            auto close_send = state_->lookup("Synurang_Stream_CloseSend");
            auto close = state_->lookup("Synurang_Stream_Close");

            if (!send || !recv || !close_send || !close) {
                throw FfiError("Incomplete streaming support");
            }

            state_->stream_funcs = std::make_unique<StreamFuncs>();
            state_->stream_funcs->send = reinterpret_cast<StreamSendFunc>(send);
            state_->stream_funcs->recv = reinterpret_cast<StreamRecvFunc>(recv);
            state_->stream_funcs->close_send = reinterpret_cast<StreamCloseSendFunc>(close_send);
            state_->stream_funcs->close = reinterpret_cast<StreamCloseFunc>(close);
        }

        auto it = state_->stream_openers.find(service_name);
        if (it != state_->stream_openers.end()) {
            open_fn = it->second;
        } else {
            std::string sym_name = "Synurang_Stream_" + service_name + "_Open";
            void* ptr = state_->lookup(sym_name.c_str());
            if (!ptr) {
                throw FfiError("Streaming not supported for " + service_name);
            }
            open_fn = reinterpret_cast<StreamOpenFunc>(ptr);
            state_->stream_openers[service_name] = open_fn;
        }
    }

    std::vector<char> method_buf(method.begin(), method.end());
    method_buf.push_back('\0');

    uint64_t handle;
    {
        ScopedCall call(state_);
        handle = open_fn(method_buf.data());
    }
    if (handle == 0) throw FfiError("Failed to open stream");

    return std::unique_ptr<PluginStream>(new PluginStream(state_, handle));
}

// PluginStream

PluginStream::PluginStream(std::shared_ptr<PluginState> state, uint64_t handle)
    : state_(state), handle_(handle) {}

PluginStream::~PluginStream() {
    close();
}

void PluginStream::send(const std::vector<uint8_t>& data) {
    if (closed_.load(std::memory_order_acquire) || !state_) throw PluginClosedError();
    
    StreamSendFunc send_fn = nullptr;
    {
        std::lock_guard<std::mutex> lock(state_->mutex);
        if (state_->stream_funcs) send_fn = state_->stream_funcs->send;
    }
    if (!send_fn) throw FfiError("Stream functions missing");

    char* data_ptr = nullptr;
    if (!data.empty()) {
        data_ptr = reinterpret_cast<char*>(const_cast<uint8_t*>(data.data()));
    }

    int result;
    {
        ScopedCall call(state_);
        result = send_fn(handle_, data_ptr, static_cast<int>(data.size()));
    }
    if (result != 0) throw FfiError("Stream send failed: " + std::to_string(result));
}

std::vector<uint8_t> PluginStream::recv(bool& eof) {
    if (closed_.load(std::memory_order_acquire) || !state_) throw PluginClosedError();

    StreamRecvFunc recv_fn = nullptr;
    FreeFunc free_fn = state_->free_ptr;
    {
        std::lock_guard<std::mutex> lock(state_->mutex);
        if (state_->stream_funcs) recv_fn = state_->stream_funcs->recv;
    }
    if (!recv_fn) throw FfiError("Stream functions missing");

    int resp_len = 0;
    int status = 0;
    char* resp;
    {
        ScopedCall call(state_);
        resp = recv_fn(handle_, &resp_len, &status);
    }

    eof = false;
    if (status == 1) {
        eof = true;
        if (resp) free_fn(resp);
        return {};
    }

    if (status < 0) {
        if (resp && resp_len > 0) {
            std::vector<uint8_t> payload(resp, resp + resp_len);
            free_fn(resp);
            throw detail::decode_ffi_error(payload);
        }
        if (resp) free_fn(resp);
        throw FfiError("Stream error: " + std::to_string(status));
    }

    if (status != 0) {
        if (resp) free_fn(resp);
        throw FfiError("Stream error: " + std::to_string(status));
    }

    if (!resp) {
        if (resp_len == 0) return {};
        throw FfiError("Plugin returned null");
    }

    std::vector<uint8_t> result(resp, resp + resp_len);
    free_fn(resp);
    return result;
}

void PluginStream::close_send() {
    if (closed_.load(std::memory_order_acquire) || !state_) return;
    
    StreamCloseSendFunc fn = nullptr;
    {
        std::lock_guard<std::mutex> lock(state_->mutex);
        if (state_->stream_funcs) fn = state_->stream_funcs->close_send;
    }
    if (fn) {
        ScopedCall call(state_);
        fn(handle_);
    }
}

void PluginStream::close() {
    if (closed_.exchange(true, std::memory_order_acq_rel)) return;

    if (state_) {
        StreamCloseFunc fn = nullptr;
        {
            std::lock_guard<std::mutex> lock(state_->mutex);
            if (state_->stream_funcs) fn = state_->stream_funcs->close;
        }
        if (fn) {
            ScopedCall call(state_);
            fn(handle_);
        }
    }
    // We keep state_ reference until destruction
}

} // namespace synurang

#endif // !_WIN32
