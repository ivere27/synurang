// FFI API Test (C++) — No gRPC dependency
//
// Tests all 4 RPC types using synurang::PluginHost directly with
// hand-crafted protobuf bytes. No gRPC or protobuf library needed.
//
// Build (from project root):
//   cmake -B test/ffi/cpp/build -S test/ffi/cpp
//   cmake --build test/ffi/cpp/build
//
// Run (from project root):
//   ./bin/test_ffi_cpp [plugin-path]
//
// Default plugin: bin/libplugin_go.so

#include <iostream>
#include <string>
#include <vector>
#include <filesystem>
#include <thread>
#include <atomic>

#include "synurang/plugin_host.hpp"

// =============================================================================
// Protobuf helpers (hand-crafted, no protobuf library needed)
// =============================================================================

// Encode HelloRequest { name = value }
// Proto wire format: field 1, wire type 2 (length-delimited)
std::vector<uint8_t> encode_hello_request(const std::string& name) {
    std::vector<uint8_t> data;
    data.push_back(0x0a);  // field 1, wire type 2
    data.push_back(static_cast<uint8_t>(name.size()));
    data.insert(data.end(), name.begin(), name.end());
    return data;
}

// Decode HelloResponse.message (field 1, string)
std::string decode_hello_message(const std::vector<uint8_t>& data) {
    if (data.size() < 2 || data[0] != 0x0a) {
        return "<parse error>";
    }
    size_t len = data[1];
    if (data.size() < 2 + len) {
        return "<truncated>";
    }
    return std::string(data.begin() + 2, data.begin() + 2 + len);
}

// =============================================================================
// Tests
// =============================================================================

int passed = 0;
int failed = 0;

void test_unary(synurang::PluginHost& plugin) {
    std::cout << "  [1/4] Unary RPC... " << std::flush;

    auto req = encode_hello_request("CppFFI");
    auto resp = plugin.invoke("GoGreeterService",
                              "/example.v1.GoGreeterService/Bar", req);

    auto msg = decode_hello_message(resp);
    if (msg == "<parse error>" || msg.empty()) {
        std::cout << "FAIL: bad response" << std::endl;
        failed++;
        return;
    }
    std::cout << "OK (" << msg << ")" << std::endl;
    passed++;
}

void test_server_stream(synurang::PluginHost& plugin) {
    std::cout << "  [2/4] Server Streaming... " << std::flush;

    auto stream = plugin.open_stream("GoGreeterService",
                                     "/example.v1.GoGreeterService/BarServerStream");

    // Send request, then close send side
    stream->send(encode_hello_request("StreamTest"));
    stream->close_send();

    // Recv loop until EOF
    int count = 0;
    bool eof = false;
    while (!eof) {
        auto data = stream->recv(eof);
        if (!eof) {
            auto msg = decode_hello_message(data);
            if (msg == "<parse error>") {
                std::cout << "FAIL: bad message at index " << count << std::endl;
                failed++;
                stream->close();
                return;
            }
            count++;
        }
    }
    stream->close();

    if (count == 0) {
        std::cout << "FAIL: received 0 messages" << std::endl;
        failed++;
        return;
    }
    std::cout << "OK (" << count << " messages)" << std::endl;
    passed++;
}

void test_client_stream(synurang::PluginHost& plugin) {
    std::cout << "  [3/4] Client Streaming... " << std::flush;

    auto stream = plugin.open_stream("GoGreeterService",
                                     "/example.v1.GoGreeterService/BarClientStream");

    // Send 3 messages
    for (int i = 0; i < 3; i++) {
        stream->send(encode_hello_request("Msg" + std::to_string(i)));
    }
    stream->close_send();

    // Receive single response
    bool eof = false;
    auto resp = stream->recv(eof);
    stream->close();

    if (eof) {
        std::cout << "FAIL: unexpected EOF" << std::endl;
        failed++;
        return;
    }

    auto msg = decode_hello_message(resp);
    if (msg == "<parse error>" || msg.empty()) {
        std::cout << "FAIL: bad response" << std::endl;
        failed++;
        return;
    }
    std::cout << "OK (" << msg << ")" << std::endl;
    passed++;
}

void test_bidi_stream(synurang::PluginHost& plugin) {
    std::cout << "  [4/4] Bidi Streaming... " << std::flush;

    auto stream = plugin.open_stream("GoGreeterService",
                                     "/example.v1.GoGreeterService/BarBidiStream");

    // Send in a separate thread
    std::thread sender([&stream]() {
        for (int i = 0; i < 3; i++) {
            stream->send(encode_hello_request("Ping" + std::to_string(i)));
        }
        stream->close_send();
    });

    // Recv on current thread
    int count = 0;
    bool eof = false;
    while (!eof) {
        auto data = stream->recv(eof);
        if (!eof) count++;
    }

    sender.join();
    stream->close();

    if (count == 0) {
        std::cout << "FAIL: received 0 messages" << std::endl;
        failed++;
        return;
    }
    std::cout << "OK (" << count << " echoed)" << std::endl;
    passed++;
}

// =============================================================================
// Main
// =============================================================================

int main(int argc, char* argv[]) {
    std::string plugin_path = "bin/libplugin_go.so";
    if (argc > 1) {
        plugin_path = argv[1];
    }

    std::cout << "═══════════════════════════════════════════════════════════════" << std::endl;
    std::cout << "  C++ FFI API Test (No gRPC — all 4 RPC types)" << std::endl;
    std::cout << "═══════════════════════════════════════════════════════════════" << std::endl;

    if (!std::filesystem::exists(plugin_path)) {
        std::cerr << "Plugin not found: " << plugin_path << std::endl;
        return 1;
    }

    try {
        auto plugin = synurang::PluginHost::load(plugin_path);

        test_unary(plugin);
        test_server_stream(plugin);
        test_client_stream(plugin);
        test_bidi_stream(plugin);

        plugin.close();
    } catch (const std::exception& e) {
        std::cerr << "Fatal: " << e.what() << std::endl;
        return 1;
    }

    std::cout << std::endl;
    std::cout << "═══════════════════════════════════════════════════════════════" << std::endl;
    std::cout << "  Results: " << passed << " passed, " << failed << " failed" << std::endl;
    std::cout << "═══════════════════════════════════════════════════════════════" << std::endl;

    return failed > 0 ? 1 : 0;
}
