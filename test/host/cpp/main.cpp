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

#include "synurang/plugin_host.hpp"

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
    size_t len = data[1];
    if (data.size() < 2 + len) {
        return "<truncated>";
    }
    return std::string(data.begin() + 2, data.begin() + 2 + len);
}

void test_plugin(const std::string& path, const std::string& name) {
    std::cout << "\n▶ Testing " << name << " plugin: " << path << std::endl;

    if (!std::filesystem::exists(path)) {
        std::cout << "  ⚠ SKIP: Plugin not found" << std::endl;
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
        } catch (const std::exception& e) {
            std::cout << "✗ " << e.what() << std::endl;
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
        } catch (const std::exception& e) {
            std::cout << "✗ " << e.what() << std::endl;
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
        } catch (const std::exception& e) {
            std::cout << "✗ " << e.what() << std::endl;
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
        } catch (const std::exception& e) {
            std::cout << "✗ " << e.what() << std::endl;
        }

        plugin.close();
    } catch (const std::exception& e) {
        std::cout << "  ✗ Failed: " << e.what() << std::endl;
    }
}

int main() {
    std::cout << "═══════════════════════════════════════════════════════════════" << std::endl;
    std::cout << "  C++ Host Test (All 4 RPC Types × 3 Plugin Languages)" << std::endl;
    std::cout << "═══════════════════════════════════════════════════════════════" << std::endl;

    test_plugin("bin/libplugin_go.so", "Go");
    test_plugin("bin/libplugin_cpp.so", "C++");
    test_plugin("bin/libplugin_rust.so", "Rust");

    std::cout << "\n═══════════════════════════════════════════════════════════════" << std::endl;
    std::cout << "  C++ Host Test Complete" << std::endl;
    std::cout << "═══════════════════════════════════════════════════════════════" << std::endl;

    return 0;
}
