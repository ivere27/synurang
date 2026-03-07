// Synurang C++ Plugin Host - Windows Implementation
//
// Uses LoadLibrary/GetProcAddress for dynamic library loading on Windows.

#include "synurang/plugin_host.hpp"

#ifdef _WIN32

#include <windows.h>
#include <cstring>

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
    HMODULE handle = nullptr;
    FreeFunc free_ptr = nullptr;
    
    std::mutex mutex;
    std::map<std::string, InvokeFunc> invokers;
    std::map<std::string, StreamOpenFunc> stream_openers;
    std::unique_ptr<StreamFuncs> stream_funcs;
    bool closed = false;

    PluginState(HMODULE h, FreeFunc f) : handle(h), free_ptr(f) {}

    ~PluginState() {
        if (handle) {
            FreeLibrary(handle);
        }
    }

    void* lookup(const char* name) {
        return reinterpret_cast<void*>(GetProcAddress(handle, name));
    }
};

PluginHost PluginHost::load(const std::string& path) {
    // Convert to wide string for LoadLibraryW
    int size_needed = MultiByteToWideChar(CP_UTF8, 0, path.c_str(), -1, nullptr, 0);
    std::wstring wide_path(size_needed, 0);
    MultiByteToWideChar(CP_UTF8, 0, path.c_str(), -1, &wide_path[0], size_needed);

    HMODULE handle = LoadLibraryW(wide_path.c_str());
    if (!handle) {
        DWORD error = GetLastError();
        throw FfiError("Failed to load plugin: error code " + std::to_string(error));
    }

    void* free_ptr = reinterpret_cast<void*>(GetProcAddress(handle, "Synurang_Free"));
    if (!free_ptr) {
        FreeLibrary(handle);
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

    std::vector<char> method_buf(method.begin(), method.end());
    method_buf.push_back('\0');

    char* data_ptr = nullptr;
    if (!data.empty()) {
        data_ptr = reinterpret_cast<char*>(const_cast<uint8_t*>(data.data()));
    }

    int resp_len = 0;
    char* resp = invoke_fn(method_buf.data(), data_ptr, static_cast<int>(data.size()), &resp_len);

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

    uint64_t handle = open_fn(method_buf.data());
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
    if (closed_ || !state_) throw PluginClosedError();
    
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

    int result = send_fn(handle_, data_ptr, static_cast<int>(data.size()));
    if (result != 0) throw FfiError("Stream send failed: " + std::to_string(result));
}

std::vector<uint8_t> PluginStream::recv(bool& eof) {
    if (closed_ || !state_) throw PluginClosedError();

    StreamRecvFunc recv_fn = nullptr;
    FreeFunc free_fn = state_->free_ptr;
    {
        std::lock_guard<std::mutex> lock(state_->mutex);
        if (state_->stream_funcs) recv_fn = state_->stream_funcs->recv;
    }
    if (!recv_fn) throw FfiError("Stream functions missing");

    int resp_len = 0;
    int status = 0;
    char* resp = recv_fn(handle_, &resp_len, &status);

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
    if (closed_ || !state_) return;
    
    StreamCloseSendFunc fn = nullptr;
    {
        std::lock_guard<std::mutex> lock(state_->mutex);
        if (state_->stream_funcs) fn = state_->stream_funcs->close_send;
    }
    if (fn) fn(handle_);
}

void PluginStream::close() {
    if (closed_) return;
    closed_ = true;
    
    if (state_) {
        StreamCloseFunc fn = nullptr;
        {
            std::lock_guard<std::mutex> lock(state_->mutex);
            if (state_->stream_funcs) fn = state_->stream_funcs->close;
        }
        if (fn) fn(handle_);
    }
}

} // namespace synurang

#endif // _WIN32
