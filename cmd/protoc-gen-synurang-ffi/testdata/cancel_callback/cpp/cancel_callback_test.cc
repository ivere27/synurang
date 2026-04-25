// =============================================================================
// Hard cancel-callback suite (C++)
//
// Drives only the public C ABI exported by the generated FFI plugin and
// touches only the public PluginStream::OnCancel surface. Does NOT #include
// the generated .cc file; links against it instead, so internal helpers
// (register_cancel_callback, close_stream_context, StreamContext) stay
// invisible to the test.
// =============================================================================

#include "example_ffi_plugin.h"
#include "example.pb.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

extern "C" {
void Synurang_Free(void* ptr);
uint64_t Synurang_Stream_GoGreeterService_Open(const char* method);
int Synurang_Stream_Send(uint64_t handle, const char* data, int data_len);
char* Synurang_Stream_Recv(uint64_t handle, int* resp_len, int* status);
void Synurang_Stream_CloseSend(uint64_t handle);
void Synurang_Stream_Close(uint64_t handle);
}

using example::v1::DownloadFileRequest;
using example::v1::FileChunk;
using example::v1::FileStatus;
using example::v1::GoGreeterServicePlugin;
using example::v1::GoroutinesRequest;
using example::v1::GoroutinesResponse;
using example::v1::HelloRequest;
using example::v1::HelloResponse;
using example::v1::PluginStream;
using example::v1::TriggerRequest;

namespace {

constexpr const char* kBidi = "/example.v1.GoGreeterService/BarBidiStream";

// One-shot signal handler→driver.
struct Gate {
    std::mutex m;
    std::condition_variable cv;
    bool fired = false;
    void Signal() {
        {
            std::lock_guard<std::mutex> g(m);
            fired = true;
        }
        cv.notify_all();
    }
    void Wait() {
        std::unique_lock<std::mutex> g(m);
        cv.wait(g, [&] { return fired; });
    }
};

using BidiBody = std::function<void(PluginStream<HelloRequest, HelloResponse>*)>;

std::mutex g_scenario_mu;
BidiBody g_scenario;

void InstallScenario(BidiBody body) {
    std::lock_guard<std::mutex> g(g_scenario_mu);
    g_scenario = std::move(body);
}

BidiBody TakeScenario() {
    std::lock_guard<std::mutex> g(g_scenario_mu);
    BidiBody b = g_scenario;
    return b;
}

// Test plugin: only BarBidiStream is exercised.
class TestPlugin : public GoGreeterServicePlugin {
public:
    HelloResponse Bar(const HelloRequest&) override { return HelloResponse{}; }
    void BarServerStream(const HelloRequest&,
                         PluginStream<HelloRequest, HelloResponse>*) override {}
    HelloResponse BarClientStream(PluginStream<HelloRequest, HelloResponse>*) override { return HelloResponse{}; }
    void BarBidiStream(PluginStream<HelloRequest, HelloResponse>* stream) override {
        auto body = TakeScenario();
        if (body) body(stream);
    }
    FileStatus UploadFile(PluginStream<FileChunk, FileStatus>*) override { return FileStatus{}; }
    void DownloadFile(const DownloadFileRequest&, PluginStream<DownloadFileRequest, FileChunk>*) override {}
    void BidiFile(PluginStream<FileChunk, FileChunk>*) override {}
    HelloResponse Trigger(const TriggerRequest&) override { return HelloResponse{}; }
    GoroutinesResponse GetGoroutines(const GoroutinesRequest&) override { return GoroutinesResponse{}; }
};

TestPlugin g_plugin;

uint64_t OpenBidi() {
    uint64_t h = Synurang_Stream_GoGreeterService_Open(kBidi);
    if (h == 0) {
        std::fprintf(stderr, "Stream_Open returned 0\n");
        std::exit(2);
    }
    return h;
}

void DrainUntilEof(uint64_t h) {
    for (;;) {
        int resp_len = 0;
        int status = 0;
        char* p = Synurang_Stream_Recv(h, &resp_len, &status);
        if (p) Synurang_Free(p);
        if (status != 0) return;
    }
}

int SendDummy(uint64_t h) {
    return Synurang_Stream_Send(h, "", 0);
}

#define EXPECT(cond, msg)                                                  \
    do {                                                                   \
        if (!(cond)) {                                                     \
            std::fprintf(stderr, "FAIL: %s (%s:%d)\n", (msg), __FILE__,    \
                         __LINE__);                                        \
            std::exit(1);                                                  \
        }                                                                  \
    } while (0)

#define EXPECT_EQ(a, b, msg)                                                                              \
    do {                                                                                                  \
        auto _a = (a);                                                                                    \
        auto _b = (b);                                                                                    \
        if (!(_a == _b)) {                                                                                \
            std::fprintf(stderr, "FAIL: %s — got %lld want %lld (%s:%d)\n", (msg),                        \
                         static_cast<long long>(_a), static_cast<long long>(_b), __FILE__, __LINE__);     \
            std::exit(1);                                                                                 \
        }                                                                                                 \
    } while (0)

// =============================================================================

void S1_BasicCancelWiring() {
    auto fired = std::make_shared<std::atomic<int>>(0);
    auto ready = std::make_shared<Gate>();
    InstallScenario([fired, ready](PluginStream<HelloRequest, HelloResponse>* stream) {
        stream->OnCancel([fired]() { fired->fetch_add(1); });
        ready->Signal();
        HelloRequest req;
        while (stream->Recv(&req)) {}
    });
    uint64_t h = OpenBidi();
    ready->Wait();
    Synurang_Stream_Close(h);
    EXPECT_EQ(fired->load(), 1, "S1: cancel callback fires exactly once");
}

void S2_RegistrationOrder() {
    constexpr int N = 8;
    auto order = std::make_shared<std::vector<int>>();
    auto order_mu = std::make_shared<std::mutex>();
    auto ready = std::make_shared<Gate>();
    InstallScenario([order, order_mu, ready](PluginStream<HelloRequest, HelloResponse>* stream) {
        for (int i = 0; i < N; ++i) {
            stream->OnCancel([order, order_mu, i]() {
                std::lock_guard<std::mutex> g(*order_mu);
                order->push_back(i);
            });
        }
        ready->Signal();
        HelloRequest req;
        while (stream->Recv(&req)) {}
    });
    uint64_t h = OpenBidi();
    ready->Wait();
    Synurang_Stream_Close(h);
    EXPECT_EQ(static_cast<int>(order->size()), N, "S2: all callbacks fired");
    for (int i = 0; i < N; ++i) {
        EXPECT_EQ((*order)[i], i, "S2: registration-order firing");
    }
}

void S3_DoubleCloseIdempotent() {
    auto fired = std::make_shared<std::atomic<int>>(0);
    auto ready = std::make_shared<Gate>();
    InstallScenario([fired, ready](PluginStream<HelloRequest, HelloResponse>* stream) {
        stream->OnCancel([fired]() { fired->fetch_add(1); });
        ready->Signal();
        HelloRequest req;
        while (stream->Recv(&req)) {}
    });
    uint64_t h = OpenBidi();
    ready->Wait();
    Synurang_Stream_Close(h);
    Synurang_Stream_Close(h);  // handle gone; must be no-op
    EXPECT_EQ(fired->load(), 1, "S3: second Close must not refire");
}

void S4_NaturalFinishDropsCallbacks() {
    auto fired = std::make_shared<std::atomic<int>>(0);
    InstallScenario([fired](PluginStream<HelloRequest, HelloResponse>* stream) {
        stream->OnCancel([fired]() { fired->fetch_add(1); });
        // return immediately → close_stream_context(ctx, false) drops callbacks
    });
    uint64_t h = OpenBidi();
    DrainUntilEof(h);
    EXPECT_EQ(fired->load(), 0, "S4: natural finish must not fire");
    Synurang_Stream_Close(h);
    EXPECT_EQ(fired->load(), 0, "S4: post-finish Close must not refire");
}

void S5_LateRegistrationFiresInline() {
    auto initial = std::make_shared<std::atomic<int>>(0);
    auto late = std::make_shared<std::atomic<int>>(0);
    auto late_tid = std::make_shared<std::atomic<uint64_t>>(0);
    auto ready = std::make_shared<Gate>();
    auto driver_tid = std::hash<std::thread::id>{}(std::this_thread::get_id());
    InstallScenario([initial, late, late_tid, ready](PluginStream<HelloRequest, HelloResponse>* stream) {
        for (int i = 0; i < 3; ++i) {
            stream->OnCancel([initial]() { initial->fetch_add(1); });
        }
        ready->Signal();
        HelloRequest req;
        while (stream->Recv(&req)) {}
        // cancelled now; this registration must fire on this thread
        stream->OnCancel([late, late_tid]() {
            late_tid->store(std::hash<std::thread::id>{}(std::this_thread::get_id()));
            late->fetch_add(1);
        });
    });
    uint64_t h = OpenBidi();
    ready->Wait();
    Synurang_Stream_Close(h);
    EXPECT_EQ(initial->load(), 3, "S5: initial callbacks fired");
    EXPECT_EQ(late->load(), 1, "S5: late callback fired");
    EXPECT(late_tid->load() != 0 && late_tid->load() != driver_tid,
           "S5: late callback must run on handler thread, not driver");
}

void S6_ConcurrentRegisterVsClose() {
    constexpr int W = 16;
    constexpr int PER_WORKER = 64;
    auto fired = std::make_shared<std::atomic<int>>(0);
    auto ready = std::make_shared<Gate>();
    auto go = std::make_shared<std::atomic<bool>>(false);
    InstallScenario([fired, ready, go](PluginStream<HelloRequest, HelloResponse>* stream) {
        // Spawn W parked workers that race against driver's Close.
        std::vector<std::thread> ts;
        ts.reserve(W);
        for (int w = 0; w < W; ++w) {
            ts.emplace_back([stream, fired, go]() {
                while (!go->load(std::memory_order_acquire)) {
                    std::this_thread::yield();
                }
                for (int i = 0; i < PER_WORKER; ++i) {
                    stream->OnCancel([fired]() { fired->fetch_add(1); });
                }
            });
        }
        ready->Signal();
        go->store(true, std::memory_order_release);
        HelloRequest req;
        while (stream->Recv(&req)) {}
        for (auto& t : ts) t.join();
    });
    uint64_t h = OpenBidi();
    ready->Wait();
    // Tiny jitter so some registrations queue before Close lands.
    std::this_thread::sleep_for(std::chrono::microseconds(50));
    Synurang_Stream_Close(h);
    EXPECT_EQ(fired->load(), W * PER_WORKER,
              "S6: concurrent register vs Close must fire every callback exactly once");
}

void S7_CrossStreamIsolation() {
    auto fa = std::make_shared<std::atomic<int>>(0);
    auto fb = std::make_shared<std::atomic<int>>(0);
    auto ra = std::make_shared<Gate>();
    auto rb = std::make_shared<Gate>();
    auto which = std::make_shared<std::atomic<int>>(0);
    InstallScenario([fa, fb, ra, rb, which](PluginStream<HelloRequest, HelloResponse>* stream) {
        int idx = which->fetch_add(1);
        if (idx == 0) {
            stream->OnCancel([fa]() { fa->fetch_add(1); });
            ra->Signal();
        } else {
            stream->OnCancel([fb]() { fb->fetch_add(1); });
            rb->Signal();
        }
        HelloRequest req;
        while (stream->Recv(&req)) {}
    });
    uint64_t ha = OpenBidi();
    ra->Wait();
    uint64_t hb = OpenBidi();
    rb->Wait();
    Synurang_Stream_Close(ha);
    EXPECT_EQ(fa->load(), 1, "S7: A fired");
    EXPECT_EQ(fb->load(), 0, "S7: B must not fire when A closes");
    Synurang_Stream_Close(hb);
    EXPECT_EQ(fb->load(), 1, "S7: B fired on its own close");
}

void S8_SendRecvAfterCloseIsSafe() {
    auto ready = std::make_shared<Gate>();
    InstallScenario([ready](PluginStream<HelloRequest, HelloResponse>* stream) {
        ready->Signal();
        HelloRequest req;
        while (stream->Recv(&req)) {}
    });
    uint64_t h = OpenBidi();
    ready->Wait();
    Synurang_Stream_Close(h);
    EXPECT_EQ(SendDummy(h), -1, "S8: Send after Close must return -1");
    int resp_len = 0;
    int status = 0;
    char* p = Synurang_Stream_Recv(h, &resp_len, &status);
    if (p) Synurang_Free(p);
    EXPECT_EQ(status, -1, "S8: Recv after Close must report stream-not-found");
}

void S9_CallbackSyncBeforeCloseReturns() {
    auto started = std::make_shared<std::atomic<int>>(0);
    auto finished = std::make_shared<std::atomic<int>>(0);
    auto ready = std::make_shared<Gate>();
    InstallScenario([started, finished, ready](PluginStream<HelloRequest, HelloResponse>* stream) {
        stream->OnCancel([started, finished]() {
            started->fetch_add(1);
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
            finished->fetch_add(1);
        });
        ready->Signal();
        HelloRequest req;
        while (stream->Recv(&req)) {}
    });
    uint64_t h = OpenBidi();
    ready->Wait();
    Synurang_Stream_Close(h);
    EXPECT_EQ(started->load(), 1, "S9: callback started");
    EXPECT_EQ(finished->load(), 1, "S9: callback completed before Close returned");
}

void S10_CloseBlocksUntilWorkerJoins() {
    auto exited = std::make_shared<std::atomic<int>>(0);
    auto ready = std::make_shared<Gate>();
    InstallScenario([exited, ready](PluginStream<HelloRequest, HelloResponse>* stream) {
        ready->Signal();
        HelloRequest req;
        while (stream->Recv(&req)) {}
        std::this_thread::sleep_for(std::chrono::milliseconds(30));
        exited->fetch_add(1);
    });
    uint64_t h = OpenBidi();
    ready->Wait();
    auto t0 = std::chrono::steady_clock::now();
    Synurang_Stream_Close(h);
    auto elapsed = std::chrono::steady_clock::now() - t0;
    EXPECT_EQ(exited->load(), 1, "S10: Close must wait until handler exits");
    EXPECT(elapsed >= std::chrono::milliseconds(25), "S10: Close returned too early");
}

}  // namespace

int main() {
    example::v1::RegisterGoGreeterServicePlugin(&g_plugin);

    S1_BasicCancelWiring();
    S2_RegistrationOrder();
    S3_DoubleCloseIdempotent();
    S4_NaturalFinishDropsCallbacks();
    S5_LateRegistrationFiresInline();
    S6_ConcurrentRegisterVsClose();
    S7_CrossStreamIsolation();
    S8_SendRecvAfterCloseIsSafe();
    S9_CallbackSyncBeforeCloseReturns();
    S10_CloseBlocksUntilWorkerJoins();

    std::printf("[cpp] cancel-callback hard suite OK\n");
    return 0;
}
