// C++ Host Brute-Force Chaos Test
//
// Multi-threaded stress test that loads all 3 plugin languages (Go, C++, Rust)
// and hammers them with randomized RPC operations + chaos edge cases.
//
// Gated by SYNURANG_BRUTE=1 environment variable.
//
// Environment variables:
//   SYNURANG_BRUTE=1              — required to run
//   SYNURANG_BRUTE_DURATION       — total duration (default: 60s)
//   SYNURANG_BRUTE_WORKERS        — thread count (default: 4)
//   SYNURANG_BRUTE_MAX_FD_DELTA   — max FD increase (default: 48)
//   SYNURANG_BRUTE_MAX_RSS_MB_DELTA — max RSS increase MB (default: 256)

#include <iostream>
#include <string>
#include <vector>
#include <thread>
#include <atomic>
#include <chrono>
#include <random>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <dirent.h>
#include <unistd.h>
#include <signal.h>

#include "synurang/plugin_host.hpp"

// ---------------------------------------------------------------------------
// Proto helpers (same as main.cpp)
// ---------------------------------------------------------------------------

static std::vector<uint8_t> make_hello_request(const std::string& name) {
    std::vector<uint8_t> data;
    if (name.empty()) {
        return data;
    }
    // Protobuf varint length encoding for strings > 127 bytes
    size_t len = name.size();
    data.push_back(0x0a); // field 1, wire type 2
    if (len < 128) {
        data.push_back(static_cast<uint8_t>(len));
    } else {
        // Varint encoding for lengths >= 128
        size_t remaining = len;
        while (remaining >= 128) {
            data.push_back(static_cast<uint8_t>((remaining & 0x7f) | 0x80));
            remaining >>= 7;
        }
        data.push_back(static_cast<uint8_t>(remaining));
    }
    data.insert(data.end(), name.begin(), name.end());
    return data;
}

static std::string extract_message(const std::vector<uint8_t>& data) {
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

// ---------------------------------------------------------------------------
// Resource snapshot (Linux /proc/self)
// ---------------------------------------------------------------------------

struct ResourceSnapshot {
    int fd_count = -1;
    int64_t rss_bytes = -1;
};

static ResourceSnapshot capture_resources() {
    ResourceSnapshot s;

    // FD count
    DIR* dir = opendir("/proc/self/fd");
    if (dir) {
        int count = 0;
        while (readdir(dir)) count++;
        closedir(dir);
        s.fd_count = count - 2; // subtract . and ..
    }

    // RSS from /proc/self/statm (field 2 = resident pages)
    std::ifstream statm("/proc/self/statm");
    if (statm.is_open()) {
        int64_t virt = 0, rss_pages = 0;
        statm >> virt >> rss_pages;
        s.rss_bytes = rss_pages * sysconf(_SC_PAGESIZE);
    }

    return s;
}

// ---------------------------------------------------------------------------
// Environment variable helpers
// ---------------------------------------------------------------------------

static int env_int(const char* key, int fallback) {
    const char* val = std::getenv(key);
    if (!val || val[0] == '\0') return fallback;
    return std::atoi(val);
}

static int64_t env_duration_secs(const char* key, int64_t fallback_secs) {
    const char* val = std::getenv(key);
    if (!val || val[0] == '\0') return fallback_secs;
    std::string s(val);
    // Parse formats: "60s", "2m", "60" (assume seconds)
    if (s.back() == 's') {
        return std::stoll(s.substr(0, s.size() - 1));
    } else if (s.back() == 'm') {
        return std::stoll(s.substr(0, s.size() - 1)) * 60;
    }
    return std::stoll(s);
}

// ---------------------------------------------------------------------------
// Error classification
// ---------------------------------------------------------------------------

static bool is_expected_error(const std::exception& e) {
    std::string msg = e.what();
    // PluginClosedError
    if (dynamic_cast<const synurang::PluginClosedError*>(&e)) return true;
    // Known error patterns
    if (msg.find("plugin is closed") != std::string::npos) return true;
    if (msg.find("stream send failed") != std::string::npos) return true;
    if (msg.find("Stream send failed") != std::string::npos) return true;
    if (msg.find("Empty stream response") != std::string::npos) return true;
    if (msg.find("Empty response") != std::string::npos) return true;
    if (msg.find("stream is closed") != std::string::npos) return true;
    if (msg.find("Stream error") != std::string::npos) return true;
    if (msg.find("Plugin returned null") != std::string::npos) return true;
    return false;
}

// ---------------------------------------------------------------------------
// Plugin info
// ---------------------------------------------------------------------------

struct PluginInfo {
    std::string name;
    synurang::PluginHost host;
};

// ---------------------------------------------------------------------------
// Operation implementations
// ---------------------------------------------------------------------------

static const std::string SERVICE = "GoGreeterService";
static const std::string METHOD_UNARY = "/example.v1.GoGreeterService/Bar";
static const std::string METHOD_SERVER_STREAM = "/example.v1.GoGreeterService/BarServerStream";
static const std::string METHOD_CLIENT_STREAM = "/example.v1.GoGreeterService/BarClientStream";
static const std::string METHOD_BIDI = "/example.v1.GoGreeterService/BarBidiStream";

static void op_unary(PluginInfo& pi, std::mt19937& rng, int worker_id) {
    std::string name = "u-" + pi.name + "-" + std::to_string(worker_id) + "-" + std::to_string(rng());
    auto req = make_hello_request(name);
    auto resp = pi.host.invoke(SERVICE, METHOD_UNARY, req);
    auto msg = extract_message(resp);
    if (msg.find(name.substr(0, 20)) == std::string::npos && name.size() <= 127) {
        throw std::runtime_error("unary response mismatch");
    }
}

static void op_server_stream(PluginInfo& pi, std::mt19937& rng, int worker_id) {
    std::string name = "ss-" + pi.name + "-" + std::to_string(worker_id) + "-" + std::to_string(rng());
    auto stream = pi.host.open_stream(SERVICE, METHOD_SERVER_STREAM);
    stream->send(make_hello_request(name));
    stream->close_send();

    std::uniform_int_distribution<int> target_dist(1, 5);
    int target = target_dist(rng);
    int received = 0;

    for (int i = 0; i < target; i++) {
        bool eof = false;
        stream->recv(eof);
        if (eof) break;
        received++;
    }

    // Sometimes drain fully
    if (std::uniform_int_distribution<int>(0, 99)(rng) < 40) {
        bool eof = false;
        while (!eof) {
            stream->recv(eof);
            if (!eof) received++;
        }
    }

    if (received == 0) {
        throw std::runtime_error("server-stream returned zero messages");
    }
}

static void op_client_stream(PluginInfo& pi, std::mt19937& rng, int worker_id) {
    auto stream = pi.host.open_stream(SERVICE, METHOD_CLIENT_STREAM);

    std::uniform_int_distribution<int> count_dist(1, 20);
    int count = count_dist(rng);
    for (int i = 0; i < count; i++) {
        std::string name = "cs-" + pi.name + "-" + std::to_string(worker_id) + "-" + std::to_string(i);
        stream->send(make_hello_request(name));
    }
    stream->close_send();

    bool eof = false;
    auto resp = stream->recv(eof);
    if (eof) {
        throw std::runtime_error("client-stream got immediate EOF");
    }
    auto msg = extract_message(resp);
    if (msg.empty()) {
        throw std::runtime_error("client-stream empty response");
    }
}

static void op_bidi_stream(PluginInfo& pi, std::mt19937& rng, int worker_id) {
    auto stream = pi.host.open_stream(SERVICE, METHOD_BIDI);

    std::uniform_int_distribution<int> count_dist(1, 12);
    int count = count_dist(rng);
    int received = 0;

    for (int i = 0; i < count; i++) {
        std::string name = "bs-" + pi.name + "-" + std::to_string(worker_id) + "-" + std::to_string(i);
        stream->send(make_hello_request(name));

        bool eof = false;
        auto resp = stream->recv(eof);
        if (eof) break;
        received++;
    }
    stream->close_send();

    if (received == 0) {
        throw std::runtime_error("bidi received zero responses");
    }
}

// ---------------------------------------------------------------------------
// Chaos operations
// ---------------------------------------------------------------------------

// Open stream, don't send/recv, let destructor clean up
static void chaos_open_and_abandon(PluginInfo& pi, std::mt19937& rng) {
    auto stream = pi.host.open_stream(SERVICE, METHOD_BIDI);
    // Destructor will close
}

// Call close() multiple times — must be idempotent
static void chaos_double_close(PluginInfo& pi, std::mt19937& rng) {
    auto stream = pi.host.open_stream(SERVICE, METHOD_BIDI);
    stream->send(make_hello_request("chaos-dc"));
    stream->close();
    stream->close();
    stream->close();
}

// send() after close_send() — must get exception, not crash
static void chaos_send_after_close_send(PluginInfo& pi, std::mt19937& rng, int worker_id) {
    auto stream = pi.host.open_stream(SERVICE, METHOD_CLIENT_STREAM);
    std::string name = "chaos-sac-" + std::to_string(worker_id);
    stream->send(make_hello_request(name));
    stream->close_send();

    // Attempt send after close_send — should error or silently succeed
    try {
        stream->send(make_hello_request("after-close"));
    } catch (const std::exception&) {
        // Expected
    }
}

// recv() after close() — must get exception, not crash
static void chaos_recv_after_close(PluginInfo& pi, std::mt19937& rng) {
    auto stream = pi.host.open_stream(SERVICE, METHOD_SERVER_STREAM);
    stream->send(make_hello_request("chaos-rac"));
    stream->close_send();

    // Read one, then close and try to recv
    bool eof = false;
    try { stream->recv(eof); } catch (...) {}
    stream->close();

    try {
        stream->recv(eof);
    } catch (const std::exception&) {
        // Expected
    }
}

// Open and close many streams rapidly
static void chaos_rapid_stream_cycling(PluginInfo& pi, std::mt19937& rng) {
    std::uniform_int_distribution<int> count_dist(5, 20);
    int count = count_dist(rng);
    for (int i = 0; i < count; i++) {
        try {
            auto stream = pi.host.open_stream(SERVICE, METHOD_BIDI);
            stream->close();
        } catch (const std::exception&) {
            // Expected during rapid cycling
        }
    }
}

// Boundary payloads: empty, single byte, large (64-256KB)
static void chaos_boundary_payloads(PluginInfo& pi, std::mt19937& rng, int worker_id) {
    std::string name;
    switch (std::uniform_int_distribution<int>(0, 2)(rng)) {
    case 0:
        name = "";
        break;
    case 1:
        name = "x";
        break;
    case 2: {
        std::uniform_int_distribution<int> size_dist(64 * 1024, 256 * 1024);
        int size = size_dist(rng);
        name = std::string(size, 'B');
        break;
    }
    }
    auto req = make_hello_request(name);
    auto resp = pi.host.invoke(SERVICE, METHOD_UNARY, req);
    // Just verify no crash
}

// Send N, recv M<N, then drop
static void chaos_mismatched_bidi(PluginInfo& pi, std::mt19937& rng, int worker_id) {
    auto stream = pi.host.open_stream(SERVICE, METHOD_BIDI);

    std::uniform_int_distribution<int> send_dist(3, 10);
    int send_count = send_dist(rng);
    for (int i = 0; i < send_count; i++) {
        std::string name = "chaos-mm-" + std::to_string(worker_id) + "-" + std::to_string(i);
        stream->send(make_hello_request(name));
    }

    // Receive fewer than sent
    std::uniform_int_distribution<int> recv_dist(1, send_count - 1);
    int recv_count = recv_dist(rng);
    for (int i = 0; i < recv_count; i++) {
        bool eof = false;
        try { stream->recv(eof); } catch (...) { break; }
        if (eof) break;
    }
    // Abandon — destructor will clean up
}

// Open stream, immediately close before any I/O
static void chaos_immediate_close(PluginInfo& pi, std::mt19937& rng) {
    auto stream = pi.host.open_stream(SERVICE, METHOD_BIDI);
    stream->close();
}

static void run_chaos(PluginInfo& pi, std::mt19937& rng, int worker_id) {
    int x = std::uniform_int_distribution<int>(0, 99)(rng);
    if (x < 15) {
        chaos_open_and_abandon(pi, rng);
    } else if (x < 30) {
        chaos_double_close(pi, rng);
    } else if (x < 45) {
        chaos_send_after_close_send(pi, rng, worker_id);
    } else if (x < 60) {
        chaos_recv_after_close(pi, rng);
    } else if (x < 74) {
        chaos_rapid_stream_cycling(pi, rng);
    } else if (x < 86) {
        chaos_boundary_payloads(pi, rng, worker_id);
    } else if (x < 94) {
        chaos_mismatched_bidi(pi, rng, worker_id);
    } else {
        chaos_immediate_close(pi, rng);
    }
}

// ---------------------------------------------------------------------------
// Main operation router
// ---------------------------------------------------------------------------

static void run_random_op(PluginInfo& pi, std::mt19937& rng, int worker_id) {
    int x = std::uniform_int_distribution<int>(0, 99)(rng);
    if (x < 40) {
        op_unary(pi, rng, worker_id);
    } else if (x < 62) {
        op_server_stream(pi, rng, worker_id);
    } else if (x < 78) {
        op_client_stream(pi, rng, worker_id);
    } else if (x < 88) {
        op_bidi_stream(pi, rng, worker_id);
    } else {
        run_chaos(pi, rng, worker_id);
    }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

int main() {
#ifndef _WIN32
    signal(SIGPIPE, SIG_IGN);
#endif
    const char* brute_env = std::getenv("SYNURANG_BRUTE");
    if (!brute_env || std::string(brute_env) != "1") {
        std::cout << "SKIP: set SYNURANG_BRUTE=1 to run C++ host brute-force test" << std::endl;
        return 0;
    }

    int64_t duration_secs = env_duration_secs("SYNURANG_BRUTE_DURATION", 60);
    int workers = env_int("SYNURANG_BRUTE_WORKERS", 4);
    int max_fd_delta = env_int("SYNURANG_BRUTE_MAX_FD_DELTA", 48);
    int max_rss_mb_delta = env_int("SYNURANG_BRUTE_MAX_RSS_MB_DELTA", 256);

    std::cout << "═══════════════════════════════════════════════════════════════" << std::endl;
    std::cout << "  C++ Host Brute-Force Chaos Test" << std::endl;
    std::cout << "  duration=" << duration_secs << "s workers=" << workers
              << " max_fd_delta=" << max_fd_delta
              << " max_rss_mb_delta=" << max_rss_mb_delta << std::endl;
    std::cout << "═══════════════════════════════════════════════════════════════" << std::endl;

    // Load all 3 plugins
    struct PluginSpec {
        std::string name;
        std::string path;
    };
    std::vector<PluginSpec> specs = {
        {"Go", "bin/libplugin_go.so"},
        {"C++", "bin/libplugin_cpp.so"},
        {"Rust", "bin/libplugin_rust.so"},
    };

    std::vector<PluginInfo> plugins;
    for (auto& spec : specs) {
        if (!std::filesystem::exists(spec.path)) {
            std::cerr << "FATAL: plugin not found: " << spec.path
                      << " (run `make build_plugin_all` first)" << std::endl;
            return 1;
        }
        try {
            plugins.push_back({spec.name, synurang::PluginHost::load(spec.path)});
            std::cout << "  Loaded " << spec.name << " plugin: " << spec.path << std::endl;
        } catch (const std::exception& e) {
            std::cerr << "FATAL: failed to load " << spec.name << " plugin: " << e.what() << std::endl;
            return 1;
        }
    }

    // Stabilize and capture baseline
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
    auto baseline = capture_resources();
    std::cout << "  Baseline: fd=" << baseline.fd_count
              << " rss_mb=" << (baseline.rss_bytes / (1024 * 1024)) << std::endl;

    // Counters
    std::atomic<int64_t> ops{0};
    std::atomic<int64_t> expected_errors{0};
    std::atomic<int64_t> unexpected_errors{0};

    auto start = std::chrono::steady_clock::now();
    auto deadline = start + std::chrono::seconds(duration_secs);

    // Launch worker threads
    std::vector<std::thread> threads;
    for (int w = 0; w < workers; w++) {
        threads.emplace_back([&, w]() {
            std::mt19937 rng(static_cast<unsigned>(
                std::chrono::steady_clock::now().time_since_epoch().count() + w * 100103));

            while (std::chrono::steady_clock::now() < deadline) {
                // Pick random plugin
                auto& pi = plugins[std::uniform_int_distribution<int>(0, plugins.size() - 1)(rng)];

                try {
                    run_random_op(pi, rng, w);
                    ops.fetch_add(1, std::memory_order_relaxed);
                } catch (const std::exception& e) {
                    if (is_expected_error(e)) {
                        expected_errors.fetch_add(1, std::memory_order_relaxed);
                    } else {
                        int64_t prev = unexpected_errors.fetch_add(1, std::memory_order_relaxed);
                        if (prev < 5) {
                            std::cerr << "  UNEXPECTED ERROR [worker " << w << "]: " << e.what() << std::endl;
                        }
                    }
                }

                // Small sleep to avoid pure spin
                std::this_thread::sleep_for(std::chrono::milliseconds(
                    std::uniform_int_distribution<int>(1, 5)(rng)));
            }
        });
    }

    // Progress reporting thread
    std::thread reporter([&]() {
        while (std::chrono::steady_clock::now() < deadline) {
            std::this_thread::sleep_for(std::chrono::seconds(10));
            if (std::chrono::steady_clock::now() >= deadline) break;
            auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(
                std::chrono::steady_clock::now() - start).count();
            std::cout << "  [" << elapsed << "s] ops=" << ops.load()
                      << " expected_errs=" << expected_errors.load()
                      << " unexpected_errs=" << unexpected_errors.load() << std::endl;
        }
    });

    for (auto& t : threads) t.join();
    reporter.join();

    auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(
        std::chrono::steady_clock::now() - start).count();

    // Close all plugins
    for (auto& pi : plugins) {
        pi.host.close();
    }

    // Stabilize and capture final resources
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
    auto final_res = capture_resources();

    // Report
    std::cout << "\n═══════════════════════════════════════════════════════════════" << std::endl;
    std::cout << "  Results (" << elapsed << "s):" << std::endl;
    std::cout << "    ops:              " << ops.load() << std::endl;
    std::cout << "    expected_errors:  " << expected_errors.load() << std::endl;
    std::cout << "    unexpected_errors:" << unexpected_errors.load() << std::endl;
    std::cout << "    fd:  baseline=" << baseline.fd_count << " final=" << final_res.fd_count
              << " delta=" << (final_res.fd_count - baseline.fd_count) << std::endl;
    std::cout << "    rss: baseline=" << (baseline.rss_bytes / (1024 * 1024))
              << "MB final=" << (final_res.rss_bytes / (1024 * 1024))
              << "MB delta=" << ((final_res.rss_bytes - baseline.rss_bytes) / (1024 * 1024)) << "MB" << std::endl;
    std::cout << "═══════════════════════════════════════════════════════════════" << std::endl;

    // Check for failures
    int exit_code = 0;

    if (unexpected_errors.load() > 0) {
        std::cerr << "FAIL: " << unexpected_errors.load() << " unexpected errors" << std::endl;
        exit_code = 1;
    }

    if (baseline.fd_count >= 0 && final_res.fd_count >= 0) {
        int fd_delta = final_res.fd_count - baseline.fd_count;
        if (fd_delta > max_fd_delta) {
            std::cerr << "FAIL: FD leak suspected: delta=" << fd_delta
                      << " allowed=" << max_fd_delta << std::endl;
            exit_code = 1;
        }
    }

    if (baseline.rss_bytes >= 0 && final_res.rss_bytes >= 0) {
        int64_t rss_delta_mb = (final_res.rss_bytes - baseline.rss_bytes) / (1024 * 1024);
        if (rss_delta_mb > max_rss_mb_delta) {
            std::cerr << "FAIL: RSS leak suspected: delta=" << rss_delta_mb
                      << "MB allowed=" << max_rss_mb_delta << "MB" << std::endl;
            exit_code = 1;
        }
    }

    if (ops.load() == 0) {
        std::cerr << "FAIL: zero successful operations" << std::endl;
        exit_code = 1;
    }

    if (exit_code == 0) {
        std::cout << "PASS" << std::endl;
    }

    return exit_code;
}
