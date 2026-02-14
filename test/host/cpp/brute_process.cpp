// C++ Process-Mode Brute-Force Chaos Test
//
// Multi-threaded stress test that uses a C++ parent process host to start
// Go/C++/Rust child processes and hammer them with randomized gRPC operations.
//
// Gated by SYNURANG_BRUTE=1 environment variable.
//
// Environment variables:
//   SYNURANG_BRUTE=1                - required to run
//   SYNURANG_BRUTE_DURATION         - total duration (default: 60s)
//   SYNURANG_BRUTE_WORKERS          - worker thread count (default: 4)
//   SYNURANG_BRUTE_MAX_FD_DELTA     - max FD increase (default: 48)
//   SYNURANG_BRUTE_MAX_RSS_MB_DELTA - max RSS increase MB (default: 256)

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <dirent.h>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <memory>
#include <random>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

#include <unistd.h>
#include <signal.h>

#include <grpcpp/grpcpp.h>

#include "example.grpc.pb.h"
#include "synurang/process_host.hpp"

using example::v1::GoGreeterService;
using example::v1::HelloRequest;
using example::v1::HelloResponse;

// ---------------------------------------------------------------------------
// Resource snapshot (Linux /proc/self)
// ---------------------------------------------------------------------------

struct ResourceSnapshot {
    int fd_count = -1;
    int64_t rss_bytes = -1;
};

static ResourceSnapshot capture_resources() {
    ResourceSnapshot s;

    DIR* dir = opendir("/proc/self/fd");
    if (dir) {
        int count = 0;
        while (readdir(dir)) {
            count++;
        }
        closedir(dir);
        s.fd_count = count - 2;  // subtract . and ..
    }

    std::ifstream statm("/proc/self/statm");
    if (statm.is_open()) {
        int64_t virt = 0;
        int64_t rss_pages = 0;
        statm >> virt >> rss_pages;
        s.rss_bytes = rss_pages * sysconf(_SC_PAGESIZE);
    }

    return s;
}

// ---------------------------------------------------------------------------
// Env helpers
// ---------------------------------------------------------------------------

static int env_int(const char* key, int fallback) {
    const char* val = std::getenv(key);
    if (!val || val[0] == '\0') {
        return fallback;
    }
    return std::atoi(val);
}

static int64_t env_duration_secs(const char* key, int64_t fallback_secs) {
    const char* val = std::getenv(key);
    if (!val || val[0] == '\0') {
        return fallback_secs;
    }

    std::string s(val);
    if (s.back() == 's') {
        return std::max<int64_t>(1, std::stoll(s.substr(0, s.size() - 1)));
    }
    if (s.back() == 'm') {
        return std::max<int64_t>(1, std::stoll(s.substr(0, s.size() - 1)) * 60);
    }
    return std::max<int64_t>(1, std::stoll(s));
}

static std::string to_lower(std::string s) {
    std::transform(s.begin(), s.end(), s.begin(), [](unsigned char c) {
        return static_cast<char>(std::tolower(c));
    });
    return s;
}

// ---------------------------------------------------------------------------
// Error classification
// ---------------------------------------------------------------------------

struct RpcError : public std::runtime_error {
    grpc::StatusCode code;

    explicit RpcError(const grpc::Status& status, const std::string& where)
        : std::runtime_error(
              where + " failed (code=" +
              std::to_string(static_cast<int>(status.error_code())) +
              "): " + status.error_message()),
          code(status.error_code()) {}
};

static bool is_expected_message(const std::string& raw) {
    const std::string msg = to_lower(raw);
    return msg.find("canceled") != std::string::npos ||
           msg.find("cancelled") != std::string::npos ||
           msg.find("deadline exceeded") != std::string::npos ||
           msg.find("connection reset") != std::string::npos ||
           msg.find("broken pipe") != std::string::npos ||
           msg.find("transport") != std::string::npos ||
           msg.find("socket closed") != std::string::npos ||
           msg.find("eof") != std::string::npos;
}

static bool is_expected_status_code(grpc::StatusCode code) {
    switch (code) {
    case grpc::StatusCode::CANCELLED:
    case grpc::StatusCode::DEADLINE_EXCEEDED:
    case grpc::StatusCode::UNAVAILABLE:
    case grpc::StatusCode::ABORTED:
        return true;
    default:
        return false;
    }
}

static bool is_expected_rpc_error(const RpcError& e) {
    return is_expected_status_code(e.code) || is_expected_message(e.what());
}

static void throw_if_not_ok(const grpc::Status& status, const std::string& where) {
    if (!status.ok()) {
        throw RpcError(status, where);
    }
}

// ---------------------------------------------------------------------------
// Child specs
// ---------------------------------------------------------------------------

struct ChildSpec {
    std::string name;
    std::string path;
};

static std::string with_exe_suffix(const std::string& path) {
#ifdef _WIN32
    return path + ".exe";
#else
    return path;
#endif
}

static std::vector<ChildSpec> process_child_specs() {
    return {
        {"Go", with_exe_suffix("bin/process_child")},
        {"C++", with_exe_suffix("bin/process_child_cpp")},
        {"Rust", with_exe_suffix("bin/process_child_rust")},
    };
}

// ---------------------------------------------------------------------------
// Operation helpers
// ---------------------------------------------------------------------------

static int random_timeout_ms(std::mt19937& rng) {
    const int n = std::uniform_int_distribution<int>(0, 99)(rng);
    if (n < 15) {
        return std::uniform_int_distribution<int>(2, 5)(rng);
    }
    if (n < 65) {
        return std::uniform_int_distribution<int>(20, 99)(rng);
    }
    return std::uniform_int_distribution<int>(100, 450)(rng);
}

static void apply_deadline(grpc::ClientContext& ctx, std::mt19937& rng) {
    ctx.set_deadline(
        std::chrono::system_clock::now() +
        std::chrono::milliseconds(random_timeout_ms(rng)));
}

static void op_unary(
    GoGreeterService::Stub& stub,
    std::mt19937& rng,
    int worker_id,
    const std::string& child_name
) {
    grpc::ClientContext ctx;
    apply_deadline(ctx, rng);

    HelloRequest req;
    const std::string name = "u-" + child_name + "-" + std::to_string(worker_id) + "-" +
                             std::to_string(static_cast<uint64_t>(rng()));
    req.set_name(name);

    HelloResponse resp;
    const grpc::Status status = stub.Bar(&ctx, req, &resp);
    throw_if_not_ok(status, "Bar");

    if (resp.message().empty()) {
        throw std::runtime_error("unary empty response");
    }
    if (resp.message().find(name) == std::string::npos) {
        throw std::runtime_error("unary response missing request marker");
    }
}

static void op_server_stream(
    GoGreeterService::Stub& stub,
    std::mt19937& rng,
    int worker_id,
    const std::string& child_name
) {
    grpc::ClientContext ctx;
    apply_deadline(ctx, rng);

    HelloRequest req;
    req.set_name("ss-" + child_name + "-" + std::to_string(worker_id) + "-" +
                 std::to_string(static_cast<uint64_t>(rng())));

    auto reader = stub.BarServerStream(&ctx, req);
    if (!reader) {
        throw std::runtime_error("BarServerStream returned null reader");
    }

    const int target = std::uniform_int_distribution<int>(1, 5)(rng);
    int received = 0;
    HelloResponse resp;
    for (int i = 0; i < target; i++) {
        if (!reader->Read(&resp)) {
            break;
        }
        if (resp.message().empty()) {
            throw std::runtime_error("server-stream empty message");
        }
        received++;
    }

    if (std::uniform_int_distribution<int>(0, 99)(rng) < 40) {
        while (reader->Read(&resp)) {
            received++;
        }
    }

    const grpc::Status status = reader->Finish();
    throw_if_not_ok(status, "BarServerStream Finish");

    if (received == 0) {
        throw std::runtime_error("server-stream returned zero messages");
    }
}

static void op_client_stream(
    GoGreeterService::Stub& stub,
    std::mt19937& rng,
    int worker_id,
    const std::string& child_name
) {
    grpc::ClientContext ctx;
    apply_deadline(ctx, rng);

    HelloResponse resp;
    auto writer = stub.BarClientStream(&ctx, &resp);
    if (!writer) {
        throw std::runtime_error("BarClientStream returned null writer");
    }

    const int count = std::uniform_int_distribution<int>(1, 20)(rng);
    for (int i = 0; i < count; i++) {
        HelloRequest req;
        req.set_name("cs-" + child_name + "-" + std::to_string(worker_id) + "-" +
                     std::to_string(i) + "-" + std::to_string(static_cast<uint64_t>(rng())));
        if (!writer->Write(req)) {
            break;
        }
    }

    writer->WritesDone();
    const grpc::Status status = writer->Finish();
    throw_if_not_ok(status, "BarClientStream Finish");

    if (resp.message().empty()) {
        throw std::runtime_error("client-stream empty response");
    }
}

static void op_bidi_stream(
    GoGreeterService::Stub& stub,
    std::mt19937& rng,
    int worker_id,
    const std::string& child_name
) {
    grpc::ClientContext ctx;
    apply_deadline(ctx, rng);

    auto stream = stub.BarBidiStream(&ctx);
    if (!stream) {
        throw std::runtime_error("BarBidiStream returned null stream");
    }

    const int count = std::uniform_int_distribution<int>(1, 12)(rng);
    int received = 0;
    for (int i = 0; i < count; i++) {
        HelloRequest req;
        const std::string name = "bs-" + child_name + "-" + std::to_string(worker_id) + "-" +
                                 std::to_string(i) + "-" + std::to_string(static_cast<uint64_t>(rng()));
        req.set_name(name);

        if (!stream->Write(req)) {
            break;
        }

        HelloResponse resp;
        if (!stream->Read(&resp)) {
            break;
        }
        if (resp.message().empty()) {
            throw std::runtime_error("bidi empty response");
        }
        received++;
    }

    stream->WritesDone();
    const grpc::Status status = stream->Finish();
    throw_if_not_ok(status, "BarBidiStream Finish");

    if (received == 0) {
        throw std::runtime_error("bidi received zero responses");
    }
}

// ---------------------------------------------------------------------------
// Chaos operations
// ---------------------------------------------------------------------------

static void chaos_open_and_abandon(GoGreeterService::Stub& stub, std::mt19937& rng) {
    grpc::ClientContext ctx;
    ctx.set_deadline(
        std::chrono::system_clock::now() +
        std::chrono::milliseconds(std::uniform_int_distribution<int>(20, 80)(rng)));
    HelloRequest req;
    req.set_name("chaos-abandon");
    auto reader = stub.BarServerStream(&ctx, req);
    (void)reader;
}

static void chaos_double_close(GoGreeterService::Stub& stub, std::mt19937& rng) {
    grpc::ClientContext ctx;
    apply_deadline(ctx, rng);
    auto stream = stub.BarBidiStream(&ctx);
    if (!stream) {
        throw std::runtime_error("chaos_double_close: null stream");
    }

    HelloRequest req;
    req.set_name("chaos-double-close");
    stream->Write(req);

    std::thread canceller([&ctx]() {
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
        ctx.TryCancel();
    });

    // Keep stream sequencing valid for gRPC sync API: close send side once,
    // then race cancellation with read/finish.
    stream->WritesDone();
    HelloResponse resp;
    (void)stream->Read(&resp);
    const grpc::Status status = stream->Finish();
    if (canceller.joinable()) {
        canceller.join();
    }
    throw_if_not_ok(status, "chaos_double_close Finish");
}

static void chaos_send_after_close_send(
    GoGreeterService::Stub& stub,
    std::mt19937& rng,
    int worker_id
) {
    grpc::ClientContext ctx;
    apply_deadline(ctx, rng);

    HelloResponse resp;
    auto writer = stub.BarClientStream(&ctx, &resp);
    if (!writer) {
        throw std::runtime_error("chaos_send_after_close_send: null writer");
    }

    HelloRequest req;
    req.set_name("chaos-sac-" + std::to_string(worker_id));
    writer->Write(req);
    writer->WritesDone();

    const grpc::Status status = writer->Finish();
    throw_if_not_ok(status, "chaos_send_after_close_send Finish");
}

static void chaos_recv_after_cancel(GoGreeterService::Stub& stub, std::mt19937& rng) {
    grpc::ClientContext ctx;
    apply_deadline(ctx, rng);

    HelloRequest req;
    req.set_name("chaos-rac");
    auto reader = stub.BarServerStream(&ctx, req);
    if (!reader) {
        throw std::runtime_error("chaos_recv_after_cancel: null reader");
    }

    HelloResponse resp;
    (void)reader->Read(&resp);
    ctx.TryCancel();
    (void)reader->Read(&resp);

    const grpc::Status status = reader->Finish();
    throw_if_not_ok(status, "chaos_recv_after_cancel Finish");
}

static void chaos_concurrent_send_recv(
    GoGreeterService::Stub& stub,
    std::mt19937& rng,
    int worker_id
) {
    grpc::ClientContext ctx;
    apply_deadline(ctx, rng);

    auto stream = stub.BarBidiStream(&ctx);
    if (!stream) {
        throw std::runtime_error("chaos_concurrent_send_recv: null stream");
    }

    const int count = std::uniform_int_distribution<int>(3, 7)(rng);
    std::thread sender([&]() {
        for (int i = 0; i < count; i++) {
            HelloRequest req;
            req.set_name("chaos-csr-" + std::to_string(worker_id) + "-" + std::to_string(i));
            if (!stream->Write(req)) {
                break;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
        stream->WritesDone();
    });

    HelloResponse resp;
    int reads = 0;
    while (reads < count && stream->Read(&resp)) {
        reads++;
    }

    if (sender.joinable()) {
        sender.join();
    }

    const grpc::Status status = stream->Finish();
    throw_if_not_ok(status, "chaos_concurrent_send_recv Finish");
}

static void chaos_boundary_payloads(
    GoGreeterService::Stub& stub,
    std::mt19937& rng,
    int worker_id
) {
    grpc::ClientContext ctx;
    ctx.set_deadline(
        std::chrono::system_clock::now() +
        std::chrono::milliseconds(std::uniform_int_distribution<int>(500, 1500)(rng)));

    std::string name;
    std::string language;
    switch (std::uniform_int_distribution<int>(0, 2)(rng)) {
    case 0:
        name = "";
        language = "en";
        break;
    case 1:
        name = "x";
        language = "w" + std::to_string(worker_id);
        break;
    default: {
        const int size = std::uniform_int_distribution<int>(64 * 1024, 256 * 1024)(rng);
        name = "boundary";
        language = std::string(static_cast<size_t>(size), 'B');
        break;
    }
    }

    HelloRequest req;
    req.set_name(name);
    req.set_language(language);

    HelloResponse resp;
    const grpc::Status status = stub.Bar(&ctx, req, &resp);
    throw_if_not_ok(status, "chaos_boundary_payloads Bar");
}

static void chaos_mismatched_bidi(
    GoGreeterService::Stub& stub,
    std::mt19937& rng,
    int worker_id
) {
    grpc::ClientContext ctx;
    apply_deadline(ctx, rng);

    auto stream = stub.BarBidiStream(&ctx);
    if (!stream) {
        throw std::runtime_error("chaos_mismatched_bidi: null stream");
    }

    const int send_count = std::uniform_int_distribution<int>(3, 10)(rng);
    for (int i = 0; i < send_count; i++) {
        HelloRequest req;
        req.set_name("chaos-mm-" + std::to_string(worker_id) + "-" + std::to_string(i));
        if (!stream->Write(req)) {
            break;
        }
    }

    const int recv_count = std::uniform_int_distribution<int>(1, std::max(1, send_count - 1))(rng);
    HelloResponse resp;
    for (int i = 0; i < recv_count; i++) {
        if (!stream->Read(&resp)) {
            break;
        }
    }

    ctx.TryCancel();
    stream->WritesDone();
    const grpc::Status status = stream->Finish();
    throw_if_not_ok(status, "chaos_mismatched_bidi Finish");
}

static void chaos_immediate_cancel(GoGreeterService::Stub& stub, std::mt19937& rng) {
    grpc::ClientContext ctx;
    apply_deadline(ctx, rng);
    ctx.TryCancel();

    HelloRequest req;
    req.set_name("chaos-immediate-cancel");
    HelloResponse resp;
    const grpc::Status status = stub.Bar(&ctx, req, &resp);
    throw_if_not_ok(status, "chaos_immediate_cancel Bar");
}

static void run_chaos_op(
    GoGreeterService::Stub& stub,
    std::mt19937& rng,
    int worker_id
) {
    const int x = std::uniform_int_distribution<int>(0, 99)(rng);
    if (x < 15) {
        chaos_open_and_abandon(stub, rng);
    } else if (x < 30) {
        chaos_double_close(stub, rng);
    } else if (x < 43) {
        chaos_send_after_close_send(stub, rng, worker_id);
    } else if (x < 56) {
        chaos_recv_after_cancel(stub, rng);
    } else if (x < 70) {
        chaos_concurrent_send_recv(stub, rng, worker_id);
    } else if (x < 82) {
        chaos_boundary_payloads(stub, rng, worker_id);
    } else if (x < 92) {
        chaos_mismatched_bidi(stub, rng, worker_id);
    } else {
        chaos_immediate_cancel(stub, rng);
    }
}

static void run_random_op(
    GoGreeterService::Stub& stub,
    std::mt19937& rng,
    int worker_id,
    const std::string& child_name
) {
    const int x = std::uniform_int_distribution<int>(0, 99)(rng);
    if (x < 40) {
        op_unary(stub, rng, worker_id, child_name);
    } else if (x < 62) {
        op_server_stream(stub, rng, worker_id, child_name);
    } else if (x < 78) {
        op_client_stream(stub, rng, worker_id, child_name);
    } else if (x < 88) {
        op_bidi_stream(stub, rng, worker_id, child_name);
    } else {
        run_chaos_op(stub, rng, worker_id);
    }
}

// ---------------------------------------------------------------------------
// Phase runner
// ---------------------------------------------------------------------------

struct PhaseResult {
    std::string child_name;
    bool pass = false;
    bool crashed = false;
    bool warmup_ok = false;
    int64_t ops = 0;
    int64_t expected_errors = 0;
    int64_t unexpected_errors = 0;
    int fd_delta = 0;
    int64_t rss_delta_mb = 0;
};

static bool warmup_unary(GoGreeterService::Stub& stub, const std::string& child_name) {
    for (int attempt = 0; attempt < 60; attempt++) {
        grpc::ClientContext ctx;
        ctx.set_deadline(std::chrono::system_clock::now() + std::chrono::milliseconds(500));

        HelloRequest req;
        req.set_name("warmup-" + child_name + "-" + std::to_string(attempt));
        HelloResponse resp;
        const grpc::Status status = stub.Bar(&ctx, req, &resp);
        if (status.ok()) {
            if (!resp.message().empty()) {
                return true;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(25));
            continue;
        }

        if (!is_expected_status_code(status.error_code()) &&
            !is_expected_message(status.error_message())) {
            throw RpcError(status, "warmup Bar");
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(25));
    }
    return false;
}

static PhaseResult run_child_phase(
    const ChildSpec& spec,
    int64_t duration_secs,
    int workers,
    int max_fd_delta,
    int max_rss_mb_delta
) {
    PhaseResult res;
    res.child_name = spec.name;

    if (!std::filesystem::exists(spec.path)) {
        std::cerr << "  FATAL [" << spec.name << "]: child not found: " << spec.path
                  << " (run `make build_process_all` first)" << std::endl;
        res.unexpected_errors = 1;
        return res;
    }

    std::shared_ptr<synurang::ProcessHost> proc;
    try {
        proc = synurang::ProcessHost::start(spec.path, {});
        // Give it a moment to start the listener
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    } catch (const std::exception& e) {
        std::cerr << "  FATAL [" << spec.name << "]: ProcessHost::start failed: " << e.what() << std::endl;
        res.unexpected_errors = 1;
        return res;
    }

    const auto channel = proc->channel();
    if (!channel) {
        std::cerr << "  FATAL [" << spec.name << "]: null channel from process host" << std::endl;
        res.unexpected_errors = 1;
        proc->terminate();
        return res;
    }

    bool warmup_ok = false;
    try {
        auto warmup_stub = GoGreeterService::NewStub(channel);
        warmup_ok = warmup_unary(*warmup_stub, spec.name);
    } catch (const std::exception& e) {
        std::cerr << "  FATAL [" << spec.name << "]: warmup failed unexpectedly: " << e.what()
                  << std::endl;
        res.unexpected_errors = 1;
        proc->terminate();
        return res;
    }
    if (!warmup_ok) {
        std::cerr << "  WARN  [" << spec.name
                  << "]: warmup did not get a successful unary response before phase"
                  << std::endl;
    }
    res.warmup_ok = warmup_ok;

    std::this_thread::sleep_for(std::chrono::milliseconds(40));
    const ResourceSnapshot baseline = capture_resources();

    std::atomic<int64_t> ops{warmup_ok ? 1 : 0};
    std::atomic<int64_t> expected_errors{0};
    std::atomic<int64_t> unexpected_errors{0};
    std::atomic<bool> stop_all{false};
    std::atomic<bool> stop_monitor{false};
    std::atomic<bool> crashed{false};

    const auto phase_deadline = std::chrono::steady_clock::now() + std::chrono::seconds(duration_secs);

    std::thread monitor([&]() {
        while (!stop_monitor.load(std::memory_order_relaxed) &&
               !stop_all.load(std::memory_order_relaxed)) {
            if (!proc->is_running()) {
                crashed.store(true, std::memory_order_relaxed);
                stop_all.store(true, std::memory_order_relaxed);
                return;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
    });

    std::vector<std::thread> threads;
    threads.reserve(static_cast<size_t>(workers));
    for (int w = 0; w < workers; w++) {
        threads.emplace_back([&, w]() {
            auto stub = GoGreeterService::NewStub(channel);
            std::mt19937 rng(static_cast<unsigned>(
                std::chrono::steady_clock::now().time_since_epoch().count() + static_cast<uint64_t>(w) * 100103ULL));

            while (std::chrono::steady_clock::now() < phase_deadline &&
                   !stop_all.load(std::memory_order_relaxed)) {
                try {
                    run_random_op(*stub, rng, w, spec.name);
                    ops.fetch_add(1, std::memory_order_relaxed);
                } catch (const RpcError& e) {
                    if (is_expected_rpc_error(e)) {
                        expected_errors.fetch_add(1, std::memory_order_relaxed);
                    } else {
                        const int64_t prev = unexpected_errors.fetch_add(1, std::memory_order_relaxed);
                        if (prev < 5) {
                            std::cerr << "  UNEXPECTED RPC [" << spec.name << ", worker " << w
                                      << "]: " << e.what() << std::endl;
                        }
                        stop_all.store(true, std::memory_order_relaxed);
                        return;
                    }
                } catch (const std::exception& e) {
                    if (is_expected_message(e.what())) {
                        expected_errors.fetch_add(1, std::memory_order_relaxed);
                    } else {
                        const int64_t prev = unexpected_errors.fetch_add(1, std::memory_order_relaxed);
                        if (prev < 5) {
                            std::cerr << "  UNEXPECTED ERR [" << spec.name << ", worker " << w
                                      << "]: " << e.what() << std::endl;
                        }
                        stop_all.store(true, std::memory_order_relaxed);
                        return;
                    }
                }

                std::this_thread::sleep_for(std::chrono::milliseconds(
                    std::uniform_int_distribution<int>(1, 5)(rng)));
            }
        });
    }

    for (auto& t : threads) {
        t.join();
    }

    stop_monitor.store(true, std::memory_order_relaxed);
    if (monitor.joinable()) {
        monitor.join();
    }

    if (crashed.load(std::memory_order_relaxed)) {
        res.crashed = true;
        unexpected_errors.fetch_add(1, std::memory_order_relaxed);
        std::cerr << "  UNEXPECTED [" << spec.name << "]: child process exited during phase" << std::endl;
    }

    proc->terminate();
    std::this_thread::sleep_for(std::chrono::milliseconds(80));
    const ResourceSnapshot final_res = capture_resources();

    res.ops = ops.load(std::memory_order_relaxed);
    res.expected_errors = expected_errors.load(std::memory_order_relaxed);
    res.unexpected_errors = unexpected_errors.load(std::memory_order_relaxed);

    if (baseline.fd_count >= 0 && final_res.fd_count >= 0) {
        res.fd_delta = final_res.fd_count - baseline.fd_count;
    }
    if (baseline.rss_bytes >= 0 && final_res.rss_bytes >= 0) {
        res.rss_delta_mb = (final_res.rss_bytes - baseline.rss_bytes) / (1024 * 1024);
    }

    res.pass = true;
    if (res.unexpected_errors > 0 || res.crashed) {
        res.pass = false;
    }
    if (baseline.fd_count >= 0 && final_res.fd_count >= 0 && res.fd_delta > max_fd_delta) {
        res.pass = false;
    }
    if (baseline.rss_bytes >= 0 && final_res.rss_bytes >= 0 && res.rss_delta_mb > max_rss_mb_delta) {
        res.pass = false;
    }

    std::cout << "  [" << spec.name << "] ops=" << res.ops
              << " expected_errs=" << res.expected_errors
              << " unexpected_errs=" << res.unexpected_errors
              << " warmup_ok=" << (res.warmup_ok ? "yes" : "no")
              << " fd_delta=" << res.fd_delta
              << " rss_delta_mb=" << res.rss_delta_mb
              << " crashed=" << (res.crashed ? "yes" : "no")
              << std::endl;

    return res;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

int main() {
#ifndef _WIN32
    signal(SIGPIPE, SIG_IGN);
#endif
    const char* brute = std::getenv("SYNURANG_BRUTE");
    if (!brute || std::string(brute) != "1") {
        std::cout << "SKIP: set SYNURANG_BRUTE=1 to run C++ process host brute-force test" << std::endl;
        return 0;
    }

    const int64_t total_duration_secs = env_duration_secs("SYNURANG_BRUTE_DURATION", 60);
    const int workers = std::max(1, env_int("SYNURANG_BRUTE_WORKERS", 4));
    const int max_fd_delta = env_int("SYNURANG_BRUTE_MAX_FD_DELTA", 48);
    const int max_rss_mb_delta = env_int("SYNURANG_BRUTE_MAX_RSS_MB_DELTA", 256);

    const auto specs = process_child_specs();
    const int64_t per_child_secs = std::max<int64_t>(1, total_duration_secs / static_cast<int64_t>(specs.size()));

    std::cout << "═══════════════════════════════════════════════════════════════" << std::endl;
    std::cout << "  C++ Process Host Brute-Force Chaos Test" << std::endl;
    std::cout << "  total_duration=" << total_duration_secs << "s"
              << " per_child=" << per_child_secs << "s"
              << " workers=" << workers
              << " max_fd_delta=" << max_fd_delta
              << " max_rss_mb_delta=" << max_rss_mb_delta
              << std::endl;
    std::cout << "═══════════════════════════════════════════════════════════════" << std::endl;

    int exit_code = 0;
    int64_t total_ops = 0;
    int64_t total_expected = 0;
    int64_t total_unexpected = 0;

    for (const auto& spec : specs) {
        std::cout << "\n▶ Process child: " << spec.name << " (" << spec.path << ")" << std::endl;
        const PhaseResult phase = run_child_phase(
            spec,
            per_child_secs,
            workers,
            max_fd_delta,
            max_rss_mb_delta);

        total_ops += phase.ops;
        total_expected += phase.expected_errors;
        total_unexpected += phase.unexpected_errors;
        if (!phase.pass) {
            exit_code = 1;
            if (phase.ops == 0 && phase.warmup_ok) {
                std::cerr << "  FAIL [" << spec.name << "]: zero successful operations" << std::endl;
            }
            if (phase.fd_delta > max_fd_delta) {
                std::cerr << "  FAIL [" << spec.name << "]: FD leak suspected: delta="
                          << phase.fd_delta << " allowed=" << max_fd_delta << std::endl;
            }
            if (phase.rss_delta_mb > max_rss_mb_delta) {
                std::cerr << "  FAIL [" << spec.name << "]: RSS leak suspected: delta="
                          << phase.rss_delta_mb << "MB allowed=" << max_rss_mb_delta << "MB" << std::endl;
            }
        }
    }

    if (total_ops == 0) {
        std::cerr << "FAIL: zero successful operations across all process children" << std::endl;
        exit_code = 1;
    }

    std::cout << "\n═══════════════════════════════════════════════════════════════" << std::endl;
    std::cout << "  Aggregate Results:" << std::endl;
    std::cout << "    ops:              " << total_ops << std::endl;
    std::cout << "    expected_errors:  " << total_expected << std::endl;
    std::cout << "    unexpected_errors:" << total_unexpected << std::endl;
    std::cout << "═══════════════════════════════════════════════════════════════" << std::endl;

    if (exit_code == 0) {
        std::cout << "PASS" << std::endl;
    }

    return exit_code;
}
