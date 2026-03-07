// C++ Host Test
//
// Tests C++ parent loading Go/C++/Rust plugins and invoking all 4 RPC types.
//
// Build:
//   cmake -B build -DCMAKE_BUILD_TYPE=Release
//   cmake --build build
//
// Run:
//   ./build/test_cpp_host

#include <iostream>
#include <string>
#include <vector>
#include <filesystem>
#include <stdexcept>

#include "synurang/plugin_host.hpp"

std::vector<uint8_t> make_hello_request(const std::string& name);

namespace {

constexpr const char* kErrorTriggerName = "trigger_error";

struct Counters {
    int passed = 0;
    int failed = 0;
    int skipped = 0;
};

struct ExpectedFfiError {
    std::string message;
    int32_t code;
    int32_t grpc_code;
};

ExpectedFfiError expected_ffi_error(const std::string& plugin_name, const std::string& rpc_kind) {
    if (plugin_name == "Go") {
        if (rpc_kind == "unary") return {"go unary ffi error", 4101, 10};
        if (rpc_kind == "server") return {"go server stream ffi error", 4102, 10};
        if (rpc_kind == "client") return {"go client stream ffi error", 4103, 10};
        if (rpc_kind == "bidi") return {"go bidi stream ffi error", 4104, 10};
    }
    if (plugin_name == "C++") {
        if (rpc_kind == "unary") return {"cpp unary ffi error", 4201, 10};
        if (rpc_kind == "server") return {"cpp server stream ffi error", 4202, 10};
        if (rpc_kind == "client") return {"cpp client stream ffi error", 4203, 10};
        if (rpc_kind == "bidi") return {"cpp bidi stream ffi error", 4204, 10};
    }
    if (plugin_name == "Rust") {
        if (rpc_kind == "unary") return {"rust unary ffi error", 4301, 10};
        if (rpc_kind == "server") return {"rust server stream ffi error", 4302, 10};
        if (rpc_kind == "client") return {"rust client stream ffi error", 4303, 10};
        if (rpc_kind == "bidi") return {"rust bidi stream ffi error", 4304, 10};
    }
    throw std::runtime_error("unknown plugin/rpc expectation: " + plugin_name + "/" + rpc_kind);
}

void assert_ffi_error(
    const std::string& label,
    const synurang::FfiError& error,
    const ExpectedFfiError& expected
) {
    if (expected.message != error.what()) {
        throw std::runtime_error(label + " message mismatch: expected=" + expected.message +
                                 " got=" + error.what());
    }
    if (expected.code != error.code()) {
        throw std::runtime_error(label + " code mismatch: expected=" + std::to_string(expected.code) +
                                 " got=" + std::to_string(error.code()));
    }
    if (expected.grpc_code != error.grpc_code()) {
        throw std::runtime_error(label + " grpc_code mismatch: expected=" +
                                 std::to_string(expected.grpc_code) + " got=" +
                                 std::to_string(error.grpc_code()));
    }
}

void test_structured_ffi_errors(synurang::PluginHost& plugin, const std::string& plugin_name) {
    try {
        plugin.invoke("GoGreeterService", "/example.v1.GoGreeterService/Bar",
                      make_hello_request(kErrorTriggerName));
        throw std::runtime_error("unary expected FfiError");
    } catch (const synurang::FfiError& e) {
        assert_ffi_error("unary", e, expected_ffi_error(plugin_name, "unary"));
    }

    {
        auto stream = plugin.open_stream("GoGreeterService", "/example.v1.GoGreeterService/BarServerStream");
        try {
            stream->send(make_hello_request(kErrorTriggerName));
            stream->close_send();
            bool eof = false;
            auto data = stream->recv(eof);
            throw std::runtime_error(std::string("server-stream expected FfiError, got ") +
                                     (eof ? "EOF" : "data"));
        } catch (const synurang::FfiError& e) {
            assert_ffi_error("server-stream", e, expected_ffi_error(plugin_name, "server"));
        }
    }

    {
        auto stream = plugin.open_stream("GoGreeterService", "/example.v1.GoGreeterService/BarClientStream");
        try {
            stream->send(make_hello_request(kErrorTriggerName));
            stream->close_send();
            bool eof = false;
            auto data = stream->recv(eof);
            throw std::runtime_error(std::string("client-stream expected FfiError, got ") +
                                     (eof ? "EOF" : "data"));
        } catch (const synurang::FfiError& e) {
            assert_ffi_error("client-stream", e, expected_ffi_error(plugin_name, "client"));
        }
    }

    {
        auto stream = plugin.open_stream("GoGreeterService", "/example.v1.GoGreeterService/BarBidiStream");
        try {
            stream->send(make_hello_request(kErrorTriggerName));
            stream->close_send();
            bool eof = false;
            auto data = stream->recv(eof);
            throw std::runtime_error(std::string("bidi expected FfiError, got ") +
                                     (eof ? "EOF" : "data"));
        } catch (const synurang::FfiError& e) {
            assert_ffi_error("bidi", e, expected_ffi_error(plugin_name, "bidi"));
        }
    }
}

}  // namespace

// Simple test proto serialization (for demo purposes)
// In production, use protobuf generated code
std::vector<uint8_t> make_hello_request(const std::string& name) {
    // HelloRequest: field 1 (string name)
    std::vector<uint8_t> data;
    data.push_back(0x0a);  // field 1, wire type 2 (length-delimited)
    data.push_back(static_cast<uint8_t>(name.size()));
    data.insert(data.end(), name.begin(), name.end());
    return data;
}

std::string extract_message(const std::vector<uint8_t>& data) {
    // HelloResponse: field 1 (string message)
    if (data.size() < 2 || data[0] != 0x0a) {
        return "<parse error>";
    }
    // Decode protobuf varint length
    size_t len = 0;
    size_t offset = 1;
    unsigned shift = 0;
    while (offset < data.size()) {
        uint8_t b = data[offset++];
        len |= static_cast<size_t>(b & 0x7f) << shift;
        if ((b & 0x80) == 0) break;
        shift += 7;
        if (shift >= 35) return "<varint overflow>";
    }
    if (data.size() < offset + len) {
        return "<truncated>";
    }
    return std::string(data.begin() + offset, data.begin() + offset + len);
}

void test_plugin(const std::string& path, const std::string& name, Counters& counters) {
    std::cout << "\n▶ Testing " << name << " plugin: " << path << std::endl;

    if (!std::filesystem::exists(path)) {
        std::cout << "  ⚠ SKIP: Plugin not found" << std::endl;
        counters.skipped++;
        return;
    }

    try {
        auto plugin = synurang::PluginHost::load(path);

        // Test 1: Unary RPC
        std::cout << "  [1/4] Unary RPC... ";
        try {
            auto req = make_hello_request("CppHost");
            auto resp = plugin.invoke("GoGreeterService", "/example.v1.GoGreeterService/Bar", req);
            std::cout << "✓ " << extract_message(resp) << std::endl;
            counters.passed++;
        } catch (const std::exception& e) {
            std::cout << "✗ " << e.what() << std::endl;
            counters.failed++;
        }

        // Test 2: Server Streaming
        std::cout << "  [2/4] Server Streaming... ";
        try {
            auto stream = plugin.open_stream("GoGreeterService", "/example.v1.GoGreeterService/BarServerStream");
            auto req = make_hello_request("StreamTest");
            stream->send(req);
            stream->close_send();
            
            int count = 0;
            bool eof = false;
            while (!eof) {
                auto data = stream->recv(eof);
                if (!eof) count++;
            }
            std::cout << "✓ received " << count << " messages" << std::endl;
            counters.passed++;
        } catch (const std::exception& e) {
            std::cout << "✗ " << e.what() << std::endl;
            counters.failed++;
        }

        // Test 3: Client Streaming
        std::cout << "  [3/4] Client Streaming... ";
        try {
            auto stream = plugin.open_stream("GoGreeterService", "/example.v1.GoGreeterService/BarClientStream");
            for (int i = 0; i < 3; i++) {
                auto req = make_hello_request("Msg" + std::to_string(i));
                stream->send(req);
            }
            stream->close_send();
            
            bool eof = false;
            auto resp = stream->recv(eof);
            std::cout << "✓ " << extract_message(resp) << std::endl;
            counters.passed++;
        } catch (const std::exception& e) {
            std::cout << "✗ " << e.what() << std::endl;
            counters.failed++;
        }

        // Test 4: Bidirectional Streaming
        std::cout << "  [4/4] Bidi Streaming... ";
        try {
            auto stream = plugin.open_stream("GoGreeterService", "/example.v1.GoGreeterService/BarBidiStream");
            
            // Send messages
            for (int i = 0; i < 3; i++) {
                auto req = make_hello_request("Ping" + std::to_string(i));
                stream->send(req);
            }
            stream->close_send();
            
            // Receive responses
            int count = 0;
            bool eof = false;
            while (!eof) {
                auto data = stream->recv(eof);
                if (!eof) count++;
            }
            std::cout << "✓ echoed " << count << " messages" << std::endl;
            counters.passed++;
        } catch (const std::exception& e) {
            std::cout << "✗ " << e.what() << std::endl;
            counters.failed++;
        }

        // Test 5: Structured FFI errors
        std::cout << "  [5/5] Structured FFI Errors... ";
        try {
            test_structured_ffi_errors(plugin, name);
            std::cout << "✓ unary/server/client/bidi" << std::endl;
            counters.passed++;
        } catch (const std::exception& e) {
            std::cout << "✗ " << e.what() << std::endl;
            counters.failed++;
        }

        plugin.close();
    } catch (const std::exception& e) {
        std::cout << "  ✗ Failed: " << e.what() << std::endl;
        counters.failed++;
    }
}

int main() {
    Counters counters;
    std::cout << "═══════════════════════════════════════════════════════════════" << std::endl;
    std::cout << "  C++ Host Test (All 4 RPC Types × 3 Plugin Languages)" << std::endl;
    std::cout << "═══════════════════════════════════════════════════════════════" << std::endl;

    test_plugin("bin/libplugin_go.so", "Go", counters);
    test_plugin("bin/libplugin_cpp.so", "C++", counters);
    test_plugin("bin/libplugin_rust.so", "Rust", counters);

    std::cout << "\n═══════════════════════════════════════════════════════════════" << std::endl;
    std::cout << "  C++ Host Test Complete" << std::endl;
    std::cout << "  Passed: " << counters.passed
              << "  Failed: " << counters.failed
              << "  Skipped: " << counters.skipped << std::endl;
    std::cout << "═══════════════════════════════════════════════════════════════" << std::endl;

    return counters.failed > 0 ? 1 : 0;
}
