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

namespace synurang {

// Errors
class PluginError : public std::runtime_error {
public:
    explicit PluginError(const std::string& msg) : std::runtime_error(msg) {}
};

class PluginClosedError : public PluginError {
public:
    PluginClosedError() : PluginError("plugin is closed") {}
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
    bool closed_ = false;
    
    PluginStream(std::shared_ptr<PluginState> state, uint64_t handle);
    
    friend class PluginHost;
};

} // namespace synurang

#endif // SYNURANG_PLUGIN_HOST_HPP