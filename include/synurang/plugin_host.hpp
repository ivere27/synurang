// Synurang C++ Plugin Host
//
// This header allows C++ applications to load and call Go/C++/Rust plugins
// that export Synurang FFI symbols.
//
// Usage:
//   #include <synurang/plugin_host.hpp>
//
//   auto plugin = synurang::PluginHost::load("./libmyplugin.so");
//   auto response = plugin.invoke("MyService", "/pkg.MyService/Method", request_data);
//   plugin.close(); // Optional, destructor closes automatically

#ifndef SYNURANG_PLUGIN_HOST_HPP
#define SYNURANG_PLUGIN_HOST_HPP

#include <string>
#include <vector>
#include <cstdint>
#include <stdexcept>
#include <memory>
#include <mutex>
#include <map>
#include <atomic>

namespace synurang {

// Errors
class FfiError : public std::runtime_error {
public:
    explicit FfiError(const std::string& msg, int32_t code = 0, int32_t grpc_code = 2)
        : std::runtime_error(msg), code_(code), grpc_code_(grpc_code) {}

    int32_t code() const noexcept { return code_; }
    int32_t grpc_code() const noexcept { return grpc_code_; }

private:
    int32_t code_;
    int32_t grpc_code_;
};

class PluginClosedError : public FfiError {
public:
    PluginClosedError() : FfiError("plugin is closed") {}
};

// Stream handle for streaming RPCs
class PluginStream;

// Internal state structure (forward declaration)
struct PluginState;

// Plugin host for loading and calling Synurang plugins
// This class is a lightweight handle to the underlying plugin state.
// It can be copied and moved cheaply. The plugin remains loaded as long
// as any PluginHost or PluginStream referencing it exists.
class PluginHost {
public:
    // Load a plugin from the given path
    static PluginHost load(const std::string& path);

    PluginHost() = default;
    
    // Copy/Move allowed (shared ownership)
    PluginHost(const PluginHost&) = default;
    PluginHost& operator=(const PluginHost&) = default;
    PluginHost(PluginHost&&) = default;
    PluginHost& operator=(PluginHost&&) = default;

    // Invoke a unary RPC method
    std::vector<uint8_t> invoke(
        const std::string& service_name,
        const std::string& method,
        const std::vector<uint8_t>& data
    );

    // Open a streaming RPC
    std::unique_ptr<PluginStream> open_stream(
        const std::string& service_name,
        const std::string& method
    );

    // Explicitly close the plugin (prevent further calls).
    // The library will actually unload when all references are dropped.
    void close();

private:
    std::shared_ptr<PluginState> state_;
    
    explicit PluginHost(std::shared_ptr<PluginState> state);
};

// Stream handle for streaming RPCs
class PluginStream {
public:
    // Send data to the stream
    void send(const std::vector<uint8_t>& data);
    
    // Receive data from the stream
    // Returns empty vector and sets eof=true when stream ends
    std::vector<uint8_t> recv(bool& eof);
    
    // Close the send side of the stream
    void close_send();
    
    // Close the stream completely
    void close();
    
    ~PluginStream();
    
    // No copy (streams are unique handles)
    PluginStream(const PluginStream&) = delete;
    PluginStream& operator=(const PluginStream&) = delete;
    
    // Move allowed
    PluginStream(PluginStream&&) = default;
    PluginStream& operator=(PluginStream&&) = default;

private:
    // Holds reference to state to keep library loaded
    std::shared_ptr<PluginState> state_;
    uint64_t handle_ = 0;
    std::atomic<bool> closed_{false};
    
    PluginStream(std::shared_ptr<PluginState> state, uint64_t handle);
    
    friend class PluginHost;
};

// =============================================================================
// core.v1.Error protobuf decoder (inline, no protobuf dependency)
//
// Only handles varint (wire type 0) and length-delimited (wire type 2) fields.
// core.v1.Error uses: field 1 = int32 code, field 2 = string message,
// field 3 = int32 grpc_code.
// =============================================================================

namespace detail {

inline int abs_len(int value) {
    return value < 0 ? -value : value;
}

inline bool read_varint(const std::vector<uint8_t>& data, size_t* index, uint64_t* value) {
    uint64_t out = 0;
    int shift = 0;
    while (*index < data.size() && shift < 64) {
        uint8_t b = data[(*index)++];
        out |= static_cast<uint64_t>(b & 0x7f) << shift;
        if ((b & 0x80) == 0) {
            *value = out;
            return true;
        }
        shift += 7;
    }
    return false;
}

inline size_t skip_field(const std::vector<uint8_t>& data, size_t index, uint64_t wire_type) {
    switch (wire_type) {
        case 0: {
            uint64_t ignored = 0;
            return read_varint(data, &index, &ignored) ? index : data.size();
        }
        case 2: {
            uint64_t len = 0;
            if (!read_varint(data, &index, &len)) return data.size();
            size_t next = index + static_cast<size_t>(len);
            return next <= data.size() ? next : data.size();
        }
        default:
            return data.size();
    }
}

inline FfiError decode_ffi_error(const std::vector<uint8_t>& payload) {
    size_t index = 0;
    int32_t code = 0;
    int32_t grpc_code = 0;
    std::string message;
    bool has_message = false;

    while (index < payload.size()) {
        uint64_t tag = 0;
        if (!read_varint(payload, &index, &tag) || tag == 0) break;
        const uint64_t field = tag >> 3;
        const uint64_t wire = tag & 0x07;
        switch (field) {
            case 1:
                if (wire != 0) {
                    index = skip_field(payload, index, wire);
                    break;
                }
                {
                    uint64_t value = 0;
                    if (!read_varint(payload, &index, &value)) {
                        index = payload.size();
                        break;
                    }
                    code = static_cast<int32_t>(value);
                }
                break;
            case 2:
                if (wire != 2) {
                    index = skip_field(payload, index, wire);
                    break;
                }
                {
                    uint64_t len = 0;
                    if (!read_varint(payload, &index, &len)) {
                        index = payload.size();
                        break;
                    }
                    size_t size = static_cast<size_t>(len);
                    if (index + size > payload.size()) {
                        index = payload.size();
                        break;
                    }
                    message.assign(reinterpret_cast<const char*>(payload.data() + index), size);
                    index += size;
                    has_message = true;
                }
                break;
            case 3:
                if (wire != 0) {
                    index = skip_field(payload, index, wire);
                    break;
                }
                {
                    uint64_t value = 0;
                    if (!read_varint(payload, &index, &value)) {
                        index = payload.size();
                        break;
                    }
                    grpc_code = static_cast<int32_t>(value);
                }
                break;
            default:
                index = skip_field(payload, index, wire);
                break;
        }
    }

    if (!has_message) {
        message.assign(reinterpret_cast<const char*>(payload.data()), payload.size());
    }
    return FfiError(message, code, grpc_code);
}

} // namespace detail

} // namespace synurang

#endif // SYNURANG_PLUGIN_HOST_HPP
