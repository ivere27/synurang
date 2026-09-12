#include "synurang/module_host.hpp"
#include <cstdlib>
#include <functional>
#include <filesystem>
#include <fstream>
#include <iostream>

using synurang::ModuleBytes;
using synurang::ModuleCallOptions;
using synurang::ModuleError;
using synurang::ModuleHost;
using namespace std::chrono_literals;
static const std::string prefix = "/synurang.test.Calls/";
extern "C" const SynurangApi* Synurang_GetApi(void);

static ModuleBytes encode(std::int32_t value) {
    if (value == 0) return {};
    ModuleBytes bytes{8};
    auto n = static_cast<std::uint64_t>(static_cast<std::int64_t>(value));
    while (n >= 128) { bytes.push_back(static_cast<std::uint8_t>((n & 127) | 128)); n >>= 7; }
    bytes.push_back(static_cast<std::uint8_t>(n));
    return bytes;
}
static std::int32_t decode(const ModuleBytes& bytes) {
    if (bytes.empty()) return 0;
    if (bytes.front() != 8) throw std::runtime_error("Invalid Value protobuf");
    std::uint64_t n = 0;
    unsigned shift = 0;
    for (std::size_t i = 1; i < bytes.size(); ++i) {
        n |= static_cast<std::uint64_t>(bytes[i] & 127) << shift;
        if (bytes[i] < 128) return static_cast<std::int32_t>(n);
        shift += 7;
    }
    throw std::runtime_error("Invalid Value protobuf");
}
template <typename T, typename U> static void equal(const T& actual, const U& expected) {
    if (actual != expected) throw std::runtime_error("Conformance value mismatch");
}
static void rejects(std::int32_t code, const std::function<void()>& operation, bool details = false) {
    try { operation(); }
    catch (const ModuleError& error) {
        equal(error.code(), code);
        if (details) equal(error.details().empty(), false);
        return;
    }
    throw std::runtime_error("Expected RPC status " + std::to_string(code));
}
static ModuleCallOptions timeout(std::chrono::milliseconds value) { ModuleCallOptions options; options.timeout = value; return options; }

static void retirement_waits_for_notification() {
    struct Probe {
        std::mutex mutex;
        std::condition_variable condition;
        std::atomic<unsigned> polls{0};
        SynurangWakeupFn wakeup = nullptr;
        void* data = nullptr;
        bool closing = false, retired = false;
    };
    static Probe probe;
    auto api = *Synurang_GetApi();
    api.create = [](const SynurangRuntimeOptions* options) {
        probe.wakeup = options->wakeup;
        probe.data = options->wakeup_user_data;
        return reinterpret_cast<SynurangInstance*>(&probe);
    };
    api.destroy = [](SynurangInstance*) -> int {
        std::lock_guard<std::mutex> lock(probe.mutex);
        probe.closing = true;
        probe.condition.notify_all();
        return probe.retired ? SYNURANG_OK : SYNURANG_PENDING;
    };
    api.poll = [](SynurangInstance*, std::uint32_t) { ++probe.polls; return 0u; };
    api.has_work = [](SynurangInstance*) { return 0; };
    auto host = ModuleHost::linked(&api);
    auto closing = host.close_async();
    bool began;
    {
        std::unique_lock<std::mutex> lock(probe.mutex);
        began = probe.condition.wait_for(lock, 1s, [] { return probe.closing; });
    }
    const auto pending = closing.wait_for(30ms);
    const auto polls = probe.polls.load();
    {
        std::lock_guard<std::mutex> lock(probe.mutex);
        probe.retired = true;
        probe.wakeup(probe.data);
    }
    equal(closing.wait_for(1s), std::future_status::ready);
    closing.get();
    equal(began, true);
    equal(pending, std::future_status::timeout);
    equal(polls <= 3, true); // Initial/close notifications, no self-triggered retry loop.
    std::cout << "C++ pending destruction waits for a producer notification\n";
}

static void release_backlog() {
    const char* module = std::getenv("SYNURANG_TEST_RELEASE_MODULE");
    if (module == nullptr) return;
    auto marker = std::filesystem::temp_directory_path() /
        ("synurang-cpp-release-" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
    const auto path = marker.string();
    auto host = ModuleHost::load(module);
    auto target = host.open("/test.Release/Watch", false, true);
    target.send(ModuleBytes(path.begin(), path.end()));
    equal(target.receive()->empty(), true);
    std::vector<synurang::ModuleCall> peers;
    for (int i = 0; i < 512; ++i) peers.push_back(host.open("/test.Release/Watch", false, true));
    target.close();
    std::string events;
    const auto deadline = std::chrono::steady_clock::now() + 2s;
    do {
        std::ifstream input(marker);
        events.assign(std::istreambuf_iterator<char>(input), {});
        if (events == "CD") break;
        std::this_thread::sleep_for(5ms);
    } while (std::chrono::steady_clock::now() < deadline);
    equal(events, std::string("CD"));
    host.close();
    std::filesystem::remove(marker);
    std::cout << "C++ release drains through a ready queue backlog\n";
}

static void conformance(const std::function<ModuleHost()>& create) {
    auto host = create(), other = create();
    equal(decode(host.unary(prefix + "Unary", encode(0))), 0);
    equal(decode(host.unary_async(prefix + "Unary", encode(42)).get()), 42);
    {
        auto stream = host.open(prefix + "Server", false, true);
        stream.send(encode(50)); stream.half_close();
        std::int32_t count = 0;
        while (auto response = stream.receive()) equal(decode(*response), count++);
        equal(count, 50);
    }
    {
        auto stream = host.open(prefix + "Client", true, false);
        for (std::int32_t n = 0; n < 50; ++n) stream.send(encode(n));
        stream.half_close();
        auto response = stream.receive(); equal(response.has_value(), true);
        equal(decode(*response), 1225); equal(stream.receive().has_value(), false);
    }
    {
        auto stream = host.open(prefix + "Server", false, true);
        stream.send(encode(100)); stream.half_close();
        try { stream.send({}); throw std::runtime_error("Expected closed request side"); }
        catch (const synurang::ModuleRequestClosedError&) {}
        for (std::int32_t n = 0; n < 100; ++n) equal(decode(*stream.receive()), n);
        equal(stream.receive().has_value(), false);
    }
    {
        auto stream = host.open(prefix + "Bidi", true, true);
        for (std::int32_t n = 0; n < 30; ++n) {
            stream.send(encode(n));
            equal(decode(*stream.receive()), n); // Interactive before half-close.
        }
        auto sender = std::async(std::launch::async, [stream] {
            for (std::int32_t n = 0; n < 500; ++n) stream.send(encode(n));
            stream.half_close();
        });
        auto receiver = std::async(std::launch::async, [stream] {
            for (std::int32_t n = 0; n < 500; ++n) equal(decode(*stream.receive()), n);
            equal(stream.receive().has_value(), false);
        });
        sender.get(); receiver.get();
    }
    {
        // External event-loop integration uses pending separately from empty protobuf.
        auto call = host.open(prefix + "Unary", false, false);
        equal(call.try_receive().kind, synurang::ModuleRead::Kind::pending);
        while (!call.try_send({})) host.poll();
        call.half_close();
        synurang::ModuleRead result;
        do { result = call.try_receive(); } while (result.kind == synurang::ModuleRead::Kind::pending);
        equal(result.kind, synurang::ModuleRead::Kind::message); equal(result.data.empty(), true);
        equal(call.receive().has_value(), false);
    }
    std::vector<std::future<ModuleBytes>> tasks;
    for (std::int32_t n = 0; n < 25; ++n) tasks.push_back(host.unary_async(prefix + "Unary", encode(n)));
    for (std::int32_t n = 0; n < 25; ++n) equal(decode(tasks[static_cast<std::size_t>(n)].get()), n);
    equal(decode(other.unary(prefix + "Unary", encode(123))), 123);
    rejects(7, [&] { (void)host.unary(prefix + "Fail", {}); }, true);
    rejects(7, [&] { (void)host.unary(prefix + "Unary", encode(-1)); }, true);
    {
        auto call = host.open("/unknown.Service/Method", false, false);
        rejects(12, [&] { (void)call.receive(); });
    }
    {
        auto call = host.open(prefix + "Wait", false, false);
        call.send_async({}).get(); call.half_close();
        auto waiting = call.receive_async();
        std::this_thread::sleep_for(10ms);
        call.cancel();
        rejects(1, [&] { (void)waiting.get(); });
    }
    rejects(4, [&] { (void)host.unary(prefix + "Wait", {}, timeout(20ms)); });
    rejects(4, [&] { (void)host.unary(prefix + "Wait", {}, timeout(0ms)); });
    {
        ModuleCallOptions options;
        options.cancelled = std::make_shared<synurang::ModuleCancellationToken>();
        auto waiting = host.unary_async(prefix + "Wait", {}, options);
        std::this_thread::sleep_for(10ms); options.cancelled->cancel();
        rejects(1, [&] { (void)waiting.get(); });
        rejects(1, [&] { (void)host.unary(prefix + "Wait", {}, options); });
    }
    {
        auto stream = host.open(prefix + "Server", false, true);
        stream.send(encode(10000)); stream.half_close(); equal(decode(*stream.receive()), 0);
        // Last call owner releases the producer without explicitly draining output.
    }
    auto waiting = host.unary_async(prefix + "Wait", {});
    std::this_thread::sleep_for(5ms);
    auto first_close = host.close_async();
    auto second_close = host.close_async();
    first_close.get(); second_close.get();
    rejects(1, [&] { (void)waiting.get(); });
    rejects(14, [&] { (void)host.unary(prefix + "Unary", {}); });
    equal(decode(other.unary(prefix + "Unary", encode(9))), 9);
}

int main(int argc, char** argv) {
    try {
        retirement_waits_for_notification();
        release_backlog();
        if (argc < 2) throw std::runtime_error("Pass native module paths");
        for (int i = 1; i < argc; ++i) {
            const std::string path = argv[i];
            conformance([&] { return ModuleHost::load(path); });
            std::cout << "C++ module host conformance passed: " << path << '\n';
        }
        conformance([] { return ModuleHost::linked(Synurang_GetApi()); });
        std::cout << "C++ statically linked module host conformance passed\n";
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return EXIT_FAILURE;
    }
}
