#include "frame_queue_lite.h"
#include "shared_region.hpp"
#include <synurang/module_host.hpp>

#include <algorithm>
#include <cmath>
#include <condition_variable>
#include <ctime>
#include <deque>
#include <exception>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

using Clock = std::chrono::steady_clock;
using Result = SynurangExampleShmFrameResult;
constexpr std::uint32_t width = 96, height = 64, box = 12, guard = 32;
constexpr std::size_t pixels = width * height * 3, stride = pixels + guard;
constexpr auto processed = SYNURANG_EXAMPLE_SHM_FRAME_EVENT_PROCESSED;
constexpr auto dropped = SYNURANG_EXAMPLE_SHM_FRAME_EVENT_DROPPED;

static void require(bool value, const char* message) {
    if (!value) throw std::runtime_error(message);
}
static std::uint64_t now_ns() {
    // Use the same POSIX monotonic clock as C and Python for timestamp checks.
    timespec time{};
    clock_gettime(CLOCK_MONOTONIC, &time);
    return static_cast<std::uint64_t>(time.tv_sec) * 1000000000 + time.tv_nsec;
}
struct Options {
    std::filesystem::path build, output;
    std::string policy = "fifo", scenario = "tracking";
    int frames = 60, work_ms = 40, slots = 16, input_capacity = 8, output_capacity = 4;
    int batch_size = 4, batch_wait_ms = 50, consumer_delay_ms = 0;
    double fps = 60;
};
static bool defect_for(std::uint64_t id, const Options& options) {
    return options.scenario == "inspection" && (id % 7 == 6 || id % 7 == 0);
}
static void produce(const SharedRegion& region, std::uint32_t slot, std::uint64_t id, const Options& options) {
    auto* data = region.data() + slot * stride;
    std::fill_n(data, pixels, 20);
    std::fill_n(data + pixels, guard, 0xCD);
    const auto x = id * 3 % (width - box + 1), y = id * 2 % (height - box + 1);
    for (auto row = y; row < y + box; ++row)
        for (auto col = x; col < x + box; ++col) data[(row * width + col) * 3] = 220;
    if (defect_for(id, options)) {
        for (auto row = y + 5; row < y + 7; ++row) {
            for (auto col = x + 5; col < x + 7; ++col) {
                auto* p = data + (row * width + col) * 3;
                p[0] = 20; p[2] = 240;
            }
        }
    }
}
static void verify(const SharedRegion& region, const Result& result, const Options& options) {
    const auto x = result.field_frame_id * 3 % (width - box + 1);
    const auto y = result.field_frame_id * 2 % (height - box + 1);
    const bool annotated = result.field_event == processed;
    const bool defect = defect_for(result.field_frame_id, options);
    if (annotated) {
        require(result.field_detected && result.field_x == x && result.field_y == y &&
                result.field_width == box && result.field_height == box, "Incorrect bounding box");
        require(static_cast<bool>(result.field_defect) == defect, "Incorrect defect detection");
    }
    const auto* data = region.data() + result.field_slot * stride;
    for (std::uint32_t row = 0; row < height; ++row) {
        for (std::uint32_t col = 0; col < width; ++col) {
            int red = 20, green = 20, blue = 20;
            if (col >= x && col < x + box && row >= y && row < y + box) {
                red = 220;
                if (defect && col >= x + 5 && col < x + 7 && row >= y + 5 && row < y + 7) {
                    red = 20; blue = 240;
                }
                if (annotated && (col == x || col == x + box - 1 || row == y || row == y + box - 1)) {
                    red = defect ? 255 : 0; green = 255; blue = 0;
                }
            }
            const auto* p = data + (row * width + col) * 3;
            require(p[0] == red && p[1] == green && p[2] == blue, "Incorrect shared pixel or premature slot reuse");
        }
    }
    for (std::size_t i = pixels; i < stride; ++i) require(data[i] == 0xCD, "Slot guard modified");
}
static synurang::ModuleBytes encode(const SynurangExampleShmQueueRequest& request) {
    std::uint8_t* bytes = nullptr;
    std::size_t size = 0;
    auto status = synurang_example_shm_queue_request_encode(&request, &bytes, &size);
    std::unique_ptr<std::uint8_t, decltype(&std::free)> owned(bytes, &std::free);
    require(status == SYNURANG_LITE_OK, "Cannot encode queue descriptor");
    return {bytes, bytes + size};
}
static Result decode(const synurang::ModuleBytes& bytes) {
    Result result;
    synurang_example_shm_frame_result_init(&result);
    require(synurang_example_shm_frame_result_decode(&result, bytes.data(), bytes.size()) == SYNURANG_LITE_OK,
            "Cannot decode frame result");
    return result; // Scalar-only message, with no owned allocations.
}
static void configure(const synurang::ModuleCall& call, const SharedRegion& region, const Options& o) {
    SynurangExampleShmQueueConfig config;
    SynurangExampleShmQueueRequest request;
    synurang_example_shm_queue_config_init(&config);
    synurang_example_shm_queue_request_init(&request);
    config.field_name.data = reinterpret_cast<std::uint8_t*>(const_cast<char*>(region.name().data()));
    config.field_name.len = region.name().size();
    config.field_width = width; config.field_height = height;
    config.field_slot_stride = stride; config.field_slot_count = o.slots;
    config.field_policy = o.policy == "fifo" ? SYNURANG_EXAMPLE_SHM_QUEUE_POLICY_FIFO :
                          o.policy == "latest" ? SYNURANG_EXAMPLE_SHM_QUEUE_POLICY_LATEST :
                                                 SYNURANG_EXAMPLE_SHM_QUEUE_POLICY_BATCH;
    config.field_input_capacity = o.input_capacity; config.field_output_capacity = o.output_capacity;
    config.field_batch_size = o.batch_size; config.field_batch_wait_ms = o.batch_wait_ms;
    config.field_simulate_work_ms = o.work_ms;
    request.which_value = 1; request.field_config = &config;
    call.send(encode(request)); // Stack/name pointers are borrowed by encode, never freed as messages.
    auto ready = call.receive();
    require(ready && decode(*ready).field_event == SYNURANG_EXAMPLE_SHM_FRAME_EVENT_READY, "Missing READY");
}
struct Event { Result result; std::uint64_t received; };
static double percentile(std::vector<double> values, double fraction) {
    if (values.empty()) return 0;
    std::sort(values.begin(), values.end());
    return values[static_cast<std::size_t>(std::ceil(values.size() * fraction)) - 1];
}

static void run(const Options& o) {
    SharedRegion region(static_cast<std::size_t>(o.slots) * stride);
    auto host = synurang::ModuleHost::load((o.build / "backend.so").string());
    synurang::ModuleCallOptions call_options;
    const double timeout_ms = std::max(10000.0, o.frames * ((o.fps ? 1000 / o.fps : 0) +
                                                         o.work_ms + o.consumer_delay_ms + 100) + 5000);
    call_options.timeout = std::chrono::milliseconds(static_cast<long long>(std::ceil(timeout_ms)));
    auto call = host.open("/synurang.example.shm.FrameQueue/Run", true, true, call_options);
    const auto started = now_ns();
    configure(call, region, o);
    if (!o.output.empty()) std::filesystem::create_directories(o.output);
    std::mutex mutex;
    std::condition_variable changed;
    bool stop = false;
    std::deque<std::uint32_t> available;
    struct Owner { std::uint64_t id = 0, captured = 0; };
    std::vector<Owner> owners(o.slots);
    std::vector<Event> events;
    std::vector<double> latencies;
    std::exception_ptr producer_error;
    Result summary{};
    for (int i = 0; i < o.slots; ++i) available.push_back(i);
    std::thread producer([&] {
        try {
            auto next_capture = Clock::now();
            for (int id = 1; id <= o.frames; ++id) {
                std::uint32_t slot;
                {
                    std::unique_lock<std::mutex> lock(mutex);
                    if (changed.wait_until(lock, next_capture, [&] { return stop; })) return;
                    changed.wait(lock, [&] { return stop || !available.empty(); });
                    if (stop) return;
                    slot = available.front(); available.pop_front();
                }
                const auto captured = now_ns();
                next_capture = Clock::now() + std::chrono::duration_cast<Clock::duration>(
                    std::chrono::duration<double>(o.fps ? 1 / o.fps : 0));
                produce(region, slot, id, o);
                {
                    std::lock_guard<std::mutex> lock(mutex);
                    owners[slot] = {static_cast<std::uint64_t>(id), captured};
                }
                SynurangExampleShmFrame frame;
                SynurangExampleShmQueueRequest request;
                synurang_example_shm_frame_init(&frame);
                synurang_example_shm_queue_request_init(&request);
                frame.field_slot = slot; frame.field_frame_id = id; frame.field_captured_ns = captured;
                request.which_value = 2; request.field_frame = &frame;
                call.send(encode(request));
            }
            call.half_close();
        } catch (...) {
            producer_error = std::current_exception();
            { std::lock_guard<std::mutex> lock(mutex); stop = true; }
            changed.notify_all();
            call.cancel();
        }
    });
    try {
        while (auto bytes = call.receive()) {
            const auto received = now_ns();
            const auto result = decode(*bytes);
            if (result.field_event == SYNURANG_EXAMPLE_SHM_FRAME_EVENT_SUMMARY) {
                require(!summary.field_event, "Duplicate SUMMARY");
                summary = result;
                continue;
            }
            require(!summary.field_event && (result.field_event == processed || result.field_event == dropped), "Invalid event");
            require(result.field_slot < owners.size() && result.field_frame_id == events.size() + 1, "Duplicate or out-of-order return");
            {
                std::lock_guard<std::mutex> lock(mutex);
                require(owners[result.field_slot].id == result.field_frame_id &&
                        owners[result.field_slot].captured == result.field_captured_ns, "Invalid slot return");
            }
            verify(region, result, o);
            if (result.field_event == processed) {
                require(result.field_captured_ns <= result.field_started_ns && result.field_started_ns <= result.field_completed_ns &&
                        result.field_completed_ns <= received, "Invalid timestamps");
                latencies.push_back(static_cast<double>(received - result.field_captured_ns) / 1e6);
                if (!o.output.empty() && result.field_frame_id == static_cast<std::uint64_t>(o.frames)) {
                    std::ofstream image(o.output / ("cpp_" + o.policy + "_" + o.scenario + ".ppm"), std::ios::binary);
                    image << "P6\n" << width << ' ' << height << "\n255\n";
                    image.write(reinterpret_cast<const char*>(region.data() + result.field_slot * stride), pixels);
                    require(static_cast<bool>(image), "Cannot save annotated PPM");
                }
            }
            events.push_back({result, received});
            {
                std::lock_guard<std::mutex> lock(mutex);
                owners[result.field_slot] = {};
                available.push_back(result.field_slot);
            }
            changed.notify_all();
            if (o.consumer_delay_ms) std::this_thread::sleep_for(std::chrono::milliseconds(o.consumer_delay_ms));
        }
        producer.join();
        if (producer_error) std::rethrow_exception(producer_error);
        require(summary.field_event && events.size() == static_cast<std::size_t>(o.frames) &&
                summary.field_processed + summary.field_dropped == events.size() &&
                summary.field_processed == latencies.size() && available.size() == owners.size(), "Missing slot returns");
        if (o.policy != "latest") require(summary.field_dropped == 0, "Lossless policy dropped a frame");
        for (const auto& owner : owners) require(owner.id == 0, "Outstanding buffer at shutdown");
    } catch (...) {
        { std::lock_guard<std::mutex> lock(mutex); stop = true; }
        changed.notify_all();
        call.cancel();
        if (producer.joinable()) producer.join();
        host.close(); // Worker joins before region unmaps, even without ACKs.
        throw;
    }
    host.close();
    int defects = 0, missed = 0;
    std::uint32_t max_batch = 0;
    for (const auto& event : events) {
        defects += event.result.field_defect != 0;
        missed += event.result.field_event == dropped && defect_for(event.result.field_frame_id, o);
        max_batch = std::max(max_batch, event.result.field_batch_size);
    }
    const double p50 = percentile(latencies, .5), p95 = percentile(latencies, .95);
    if (!o.output.empty()) {
        std::ofstream json(o.output / ("cpp_" + o.policy + "_" + o.scenario + ".json"));
        json << std::fixed << std::setprecision(3) << "{\"caller\":\"C++\",\"policy\":\"" << o.policy
             << "\",\"scenario\":\"" << o.scenario << "\",\"frames\":" << o.frames
             << ",\"processed\":" << summary.field_processed << ",\"dropped\":" << summary.field_dropped
             << ",\"batches\":" << summary.field_batches << ",\"max_batch_size\":" << max_batch
             << ",\"detected_defects\":" << defects << ",\"missed_defects\":" << missed
             << ",\"input_high_water\":" << summary.field_input_high_water
             << ",\"output_high_water\":" << summary.field_output_high_water
             << ",\"outstanding\":0,\"latency_p50_ms\":" << p50 << ",\"latency_p95_ms\":" << p95 << ",\"events\":[";
        bool first = true;
        for (const auto& event : events) {
            const auto& r = event.result;
            json << (first ? "" : ",") << "{\"id\":" << r.field_frame_id << ",\"slot\":" << r.field_slot
                 << ",\"status\":\"" << (r.field_event == processed ? "PROCESSED" : "DROPPED")
                 << "\",\"captured_ms\":" << static_cast<double>(r.field_captured_ns - started) / 1e6
                 << ",\"received_ms\":" << static_cast<double>(event.received - started) / 1e6
                 << ",\"completed_ms\":" << static_cast<double>(r.field_completed_ns - started) / 1e6
                 << ",\"batch_id\":" << r.field_batch_id << ",\"batch_size\":" << r.field_batch_size
                 << ",\"x\":" << r.field_x << ",\"y\":" << r.field_y
                 << ",\"defect\":" << (r.field_defect ? "true" : "false") << '}';
            first = false;
        }
        json << "]}\n";
        require(static_cast<bool>(json), "Cannot save queue report");
    }
    std::cout << std::fixed << std::setprecision(1) << "C++ " << o.policy << ' ' << o.scenario
              << ": processed=" << summary.field_processed << " dropped=" << summary.field_dropped
              << " latency p50/p95=" << p50 << '/' << p95 << " ms batch<=" << max_batch
              << " defects=" << defects << " missed=" << missed << " outstanding=0\n";
}

int main(int argc, char** argv) {
    try {
        require(argc >= 2 && argc % 2 == 0,
                "Usage: cpp_queue_caller BUILD [--policy fifo|latest|batch] [--scenario tracking|inspection] "
                "[--frames N] [--fps N] [--work-ms N] [--slots N] [--input-capacity N] [--output-capacity N] "
                "[--batch-size N] [--batch-wait-ms N] [--consumer-delay-ms N] [--output DIR]");
        Options options;
        options.build = argv[1];
        for (int i = 2; i < argc; i += 2) {
            const std::string key = argv[i], value = argv[i + 1];
            if (key == "--policy") options.policy = value;
            else if (key == "--scenario") options.scenario = value;
            else if (key == "--output") options.output = value;
            else if (key == "--fps") options.fps = std::stod(value);
            else if (key == "--frames") options.frames = std::stoi(value);
            else if (key == "--work-ms") options.work_ms = std::stoi(value);
            else if (key == "--slots") options.slots = std::stoi(value);
            else if (key == "--input-capacity") options.input_capacity = std::stoi(value);
            else if (key == "--output-capacity") options.output_capacity = std::stoi(value);
            else if (key == "--batch-size") options.batch_size = std::stoi(value);
            else if (key == "--batch-wait-ms") options.batch_wait_ms = std::stoi(value);
            else if (key == "--consumer-delay-ms") options.consumer_delay_ms = std::stoi(value);
            else throw std::runtime_error("Unknown option: " + key);
        }
        require(options.policy == "fifo" || options.policy == "latest" || options.policy == "batch", "Invalid policy");
        require(options.scenario == "tracking" || options.scenario == "inspection", "Invalid scenario");
        require(options.frames >= 1 && options.frames <= 10000 && options.slots >= 1 && options.slots <= 64 &&
                std::isfinite(options.fps) && (options.fps == 0 || (options.fps >= .1 && options.fps <= 10000)) &&
                options.work_ms >= 0 && options.work_ms <= 1000 &&
                options.consumer_delay_ms >= 0 && options.consumer_delay_ms <= 1000, "Invalid rate, count or delay");
        run(options);
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return EXIT_FAILURE;
    }
}
