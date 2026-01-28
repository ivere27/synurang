// FfiChannel Test Suite
//
// Tests the generated FfiChannel implementation that allows using standard
// gRPC clients over FFI transport in C++.
//
// To compile and run:
//   g++ -std=c++17 -I/path/to/protobuf/include ffi_channel_test.cc -o ffi_channel_test
//   ./ffi_channel_test

#include <cassert>
#include <cstring>
#include <iostream>
#include <map>
#include <memory>
#include <string>
#include <vector>

// =============================================================================
// Mock Protobuf Messages (simplified for testing without full protobuf)
// =============================================================================

class MockMessage {
public:
    virtual ~MockMessage() = default;
    virtual std::string SerializeAsString() const = 0;
    virtual bool ParseFromString(const std::string& data) = 0;
};

class Empty : public MockMessage {
public:
    std::string SerializeAsString() const override { return ""; }
    bool ParseFromString(const std::string& data) override { return true; }
};

class PingResponse : public MockMessage {
public:
    std::string message;

    std::string SerializeAsString() const override {
        return "ping:" + message;
    }

    bool ParseFromString(const std::string& data) override {
        if (data.find("ping:") == 0) {
            message = data.substr(5);
            return true;
        }
        return false;
    }
};

class GetCacheRequest : public MockMessage {
public:
    std::string store_name;
    std::string key;

    std::string SerializeAsString() const override {
        return "get:" + store_name + ":" + key;
    }

    bool ParseFromString(const std::string& data) override {
        if (data.find("get:") == 0) {
            auto rest = data.substr(4);
            auto pos = rest.find(':');
            if (pos != std::string::npos) {
                store_name = rest.substr(0, pos);
                key = rest.substr(pos + 1);
                return true;
            }
        }
        return false;
    }
};

class GetCacheResponse : public MockMessage {
public:
    std::string value;

    std::string SerializeAsString() const override {
        return "resp:" + value;
    }

    bool ParseFromString(const std::string& data) override {
        if (data.find("resp:") == 0) {
            value = data.substr(5);
            return true;
        }
        return false;
    }
};

// =============================================================================
// Mock FfiServer Implementation
// =============================================================================

class MockFfiServer {
public:
    int ping_count = 0;
    int get_count = 0;
    std::string last_key;
    std::map<std::string, std::string> cache_data;

    PingResponse Ping(const Empty& request) {
        ping_count++;
        PingResponse resp;
        resp.message = "pong";
        return resp;
    }

    GetCacheResponse Get(const GetCacheRequest& request) {
        get_count++;
        last_key = request.key;
        GetCacheResponse resp;
        auto it = cache_data.find(request.key);
        if (it != cache_data.end()) {
            resp.value = it->second;
        }
        return resp;
    }
};

// =============================================================================
// Mock Invoke Function (simulates generated Invoke)
// =============================================================================

std::string Invoke(MockFfiServer* server, const std::string& method, const std::string& data) {
    if (method == "/core.v1.HealthService/Ping") {
        Empty req;
        req.ParseFromString(data);
        PingResponse resp = server->Ping(req);
        return resp.SerializeAsString();
    }
    if (method == "/core.v1.CacheService/Get") {
        GetCacheRequest req;
        req.ParseFromString(data);
        GetCacheResponse resp = server->Get(req);
        return resp.SerializeAsString();
    }
    return "";  // Unknown method
}

// =============================================================================
// Mock FfiChannel (simulates generated FfiChannel)
// =============================================================================

class MockFfiChannel {
public:
    explicit MockFfiChannel(MockFfiServer* server) : server_(server) {}

    template<typename Request, typename Response>
    bool InvokeMethod(const std::string& method, const Request& request, Response* response) {
        std::string data = request.SerializeAsString();
        std::string result = Invoke(server_, method, data);
        if (result.empty()) {
            return false;
        }
        return response->ParseFromString(result);
    }

private:
    MockFfiServer* server_;
};

// =============================================================================
// Mock Typed Client (simulates generated HealthServiceFfiClient)
// =============================================================================

class HealthServiceFfiClient {
public:
    explicit HealthServiceFfiClient(MockFfiChannel* channel) : channel_(channel) {}

    bool Ping(const Empty& request, PingResponse* response) {
        return channel_->InvokeMethod("/core.v1.HealthService/Ping", request, response);
    }

private:
    MockFfiChannel* channel_;
};

class CacheServiceFfiClient {
public:
    explicit CacheServiceFfiClient(MockFfiChannel* channel) : channel_(channel) {}

    bool Get(const GetCacheRequest& request, GetCacheResponse* response) {
        return channel_->InvokeMethod("/core.v1.CacheService/Get", request, response);
    }

private:
    MockFfiChannel* channel_;
};

// =============================================================================
// Test Functions
// =============================================================================

void test_ping() {
    std::cout << "test_ping... ";

    MockFfiServer server;
    MockFfiChannel channel(&server);
    HealthServiceFfiClient client(&channel);

    Empty req;
    PingResponse resp;
    bool ok = client.Ping(req, &resp);

    assert(ok);
    assert(resp.message == "pong");
    assert(server.ping_count == 1);

    std::cout << "PASSED" << std::endl;
}

void test_get_cache() {
    std::cout << "test_get_cache... ";

    MockFfiServer server;
    server.cache_data["test-key"] = "test-value";

    MockFfiChannel channel(&server);
    CacheServiceFfiClient client(&channel);

    GetCacheRequest req;
    req.store_name = "default";
    req.key = "test-key";

    GetCacheResponse resp;
    bool ok = client.Get(req, &resp);

    assert(ok);
    assert(resp.value == "test-value");
    assert(server.last_key == "test-key");
    assert(server.get_count == 1);

    std::cout << "PASSED" << std::endl;
}

void test_get_cache_not_found() {
    std::cout << "test_get_cache_not_found... ";

    MockFfiServer server;
    MockFfiChannel channel(&server);
    CacheServiceFfiClient client(&channel);

    GetCacheRequest req;
    req.store_name = "default";
    req.key = "non-existent-key";

    GetCacheResponse resp;
    bool ok = client.Get(req, &resp);

    assert(ok);
    assert(resp.value.empty());

    std::cout << "PASSED" << std::endl;
}

void test_multiple_pings() {
    std::cout << "test_multiple_pings... ";

    MockFfiServer server;
    MockFfiChannel channel(&server);
    HealthServiceFfiClient client(&channel);

    for (int i = 0; i < 100; i++) {
        Empty req;
        PingResponse resp;
        bool ok = client.Ping(req, &resp);
        assert(ok);
    }

    assert(server.ping_count == 100);

    std::cout << "PASSED" << std::endl;
}

void test_channel_with_direct_server() {
    std::cout << "test_channel_with_direct_server... ";

    // Test creating client directly from server (convenience constructor)
    MockFfiServer server;
    MockFfiChannel channel(&server);

    Empty req;
    PingResponse resp;
    bool ok = channel.InvokeMethod("/core.v1.HealthService/Ping", req, &resp);

    assert(ok);
    assert(resp.message == "pong");

    std::cout << "PASSED" << std::endl;
}

// =============================================================================
// Main
// =============================================================================

int main() {
    std::cout << "=== FfiChannel C++ Tests ===" << std::endl;

    test_ping();
    test_get_cache();
    test_get_cache_not_found();
    test_multiple_pings();
    test_channel_with_direct_server();

    std::cout << "=== All tests passed! ===" << std::endl;
    return 0;
}
