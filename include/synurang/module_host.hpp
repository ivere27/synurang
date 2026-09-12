#ifndef SYNURANG_MODULE_HOST_HPP_
#define SYNURANG_MODULE_HOST_HPP_

#include "module_host.h"
#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <exception>
#include <future>
#include <limits>
#include <memory>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <string>
#include <thread>
#include <unordered_map>
#include <utility>
#include <vector>

namespace synurang {

using ModuleBytes = std::vector<std::uint8_t>;

namespace module_detail {
struct Signal {
    std::mutex mutex;
    std::condition_variable changed;
    std::uint64_t generation = 0;
    std::uint64_t version() { std::lock_guard<std::mutex> lock(mutex); return generation; }
    void wake() { std::lock_guard<std::mutex> lock(mutex); ++generation; changed.notify_all(); }
    void wait(std::uint64_t seen, std::optional<std::chrono::steady_clock::time_point> deadline = {}) {
        std::unique_lock<std::mutex> lock(mutex);
        if (deadline) changed.wait_until(lock, *deadline, [&] { return generation != seen; });
        else changed.wait(lock, [&] { return generation != seen; });
    }
};
}

class ModuleCancellationToken {
public:
    void cancel() {
        std::lock_guard<std::mutex> lock(mutex_);
        cancelled_.store(true, std::memory_order_release);
        for (auto& weak : hosts_) if (auto signal = weak.lock()) signal->wake();
    }
    bool is_cancelled() const { return cancelled_.load(std::memory_order_acquire); }
    void subscribe(const std::shared_ptr<module_detail::Signal>& signal) {
        std::lock_guard<std::mutex> lock(mutex_);
        hosts_.erase(std::remove_if(hosts_.begin(), hosts_.end(), [](const auto& host) { return host.expired(); }), hosts_.end());
        for (const auto& host : hosts_) if (host.lock() == signal) return;
        hosts_.push_back(signal);
        if (is_cancelled()) signal->wake();
    }
private:
    std::atomic_bool cancelled_{false};
    std::mutex mutex_;
    std::vector<std::weak_ptr<module_detail::Signal>> hosts_;
};

class ModuleError : public std::runtime_error {
public:
    ModuleError(std::int32_t code, const std::string& message, ModuleBytes details = {})
        : std::runtime_error(message), code_(code), details_(std::move(details)) {}
    std::int32_t code() const noexcept { return code_; }
    const ModuleBytes& details() const noexcept { return details_; }
private:
    std::int32_t code_;
    ModuleBytes details_;
};

struct ModuleCallOptions {
    std::optional<std::chrono::milliseconds> timeout;
    std::shared_ptr<ModuleCancellationToken> cancelled;
};

class ModuleRequestClosedError : public std::runtime_error {
public:
    ModuleRequestClosedError() : std::runtime_error("RPC request side is closed") {}
};

struct ModuleRead {
    enum class Kind { pending, message, finished };
    Kind kind = Kind::pending;
    ModuleBytes data;
};

namespace module_detail {
struct CallState;
struct HostState {
    explicit HostState(SynurangHost* pointer) : pointer(pointer) {
        synurang_host_set_wakeup(pointer, [](void* data) { static_cast<Signal*>(data)->wake(); }, signal.get());
        try { worker = std::thread([this] { run(); }); }
        catch (...) { synurang_host_set_wakeup(pointer, nullptr, nullptr); throw; }
    }
    ~HostState() noexcept;
    void close();
    void run();
    // Call destruction may reenter the host while an operation holds its lock.
    // Foreign calls are still serialized across OS threads.
    std::recursive_mutex mutex;
    std::condition_variable_any closed;
    std::condition_variable_any progress;
    std::uint64_t generation = 0;
    std::shared_ptr<Signal> signal = std::make_shared<Signal>();
    std::thread worker;
    SynurangHost* pointer;
    bool closing = false;
    bool shutdown_complete = false;
    std::exception_ptr shutdown_error;
    // Calls erase themselves under mutex before their fields are destroyed.
    // The worker never takes the last owning call/host reference.
    std::unordered_map<std::uint64_t, CallState*> calls;
};

struct CallState {
    CallState(std::shared_ptr<HostState> host, std::uint64_t id, const ModuleCallOptions& options)
        : host(std::move(host)), id(id), cancelled(options.cancelled) {
        if (cancelled) cancelled->subscribe(this->host->signal);
        if (options.timeout) {
            const auto now = std::chrono::steady_clock::now();
            const auto limit = std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::steady_clock::time_point::max() - now);
            deadline = *options.timeout >= limit ? std::chrono::steady_clock::time_point::max() : now + *options.timeout;
        }
    }
    ~CallState() noexcept { try { std::lock_guard<std::recursive_mutex> lock(host->mutex); close_locked(); } catch (...) {} }

    void cancel_locked(std::int32_t code) {
        if (released || finished || error) return;
        error.emplace(code, code == 4 ? "Deadline exceeded" : "Call cancelled");
        (void)synurang_host_cancel(host->pointer, id, code);
        host->signal->wake();
        ++host->generation;
        host->progress.notify_all();
    }
    void check_locked() {
        if (cancelled && cancelled->is_cancelled()) cancel_locked(1);
        if (deadline && std::chrono::steady_clock::now() >= *deadline) cancel_locked(4);
        if (error) throw *error;
        if (released || host->pointer == nullptr) throw ModuleError(1, "Call closed");
    }
    void close_locked() {
        if (released) return;
        if (!finished) cancel_locked(1);
        synurang_host_release(host->pointer, id);
        host->signal->wake();
        ++host->generation;
        host->progress.notify_all();
        released = true;
        host->calls.erase(id);
    }
    ModuleRead read_locked() {
        check_locked();
        if (finished) return {ModuleRead::Kind::finished, {}};
        if (pending) {
            auto response = std::move(*pending);
            pending.reset();
            return {ModuleRead::Kind::message, std::move(response)};
        }
        SynurangReadResult result{};
        const int status = synurang_host_receive(host->pointer, id, &result);
        struct Buffer {
            SynurangHost* host;
            std::uint8_t* data;
            ~Buffer() { if (data != nullptr) synurang_host_free(host, data); }
        } owned{host->pointer, result.data};
        if (status != 0) throw ModuleError(13, "Module receive failed: " + std::to_string(status));
        ModuleBytes bytes;
        if (result.size != 0) {
            if (result.data == nullptr) throw ModuleError(13, "Module returned a null buffer");
            bytes.assign(result.data, result.data + result.size);
        }
        if (result.kind == SYNURANG_READ_PENDING) return {};
        if (result.kind == SYNURANG_READ_MESSAGE) return {ModuleRead::Kind::message, std::move(bytes)};
        if (result.kind != SYNURANG_READ_FINISHED) throw ModuleError(13, "Invalid module read kind");
        finished = true;
        if (result.code != 0) {
            error.emplace(result.code, "RPC failed (" + std::to_string(result.code) + ")", std::move(bytes));
            throw *error;
        }
        return {ModuleRead::Kind::finished, {}};
    }
    [[noreturn]] void closed_input_locked(int status) {
        (void)status;
        // Peek only once. The receiver still owns any buffered response and
        // fetching a terminal status must not run an unbounded producer here.
        if (!pending && !finished && !error) {
            auto result = read_locked();
            if (result.kind == ModuleRead::Kind::message) pending = std::move(result.data);
        }
        throw ModuleRequestClosedError();
    }
    bool send_locked(const ModuleBytes& bytes) {
        check_locked();
        if (bytes.size() > std::numeric_limits<std::uint32_t>::max()) throw ModuleError(3, "Message too large");
        const int status = synurang_host_send(host->pointer, id, bytes.data(), static_cast<std::uint32_t>(bytes.size()));
        if (status == 0) return true;
        if (status == SYNURANG_WOULD_BLOCK || status == SYNURANG_PENDING) return false;
        closed_input_locked(status);
    }
    std::shared_ptr<HostState> host;
    std::uint64_t id;
    std::shared_ptr<ModuleCancellationToken> cancelled;
    std::optional<std::chrono::steady_clock::time_point> deadline;
    std::optional<ModuleError> error;
    std::optional<ModuleBytes> pending;
    bool released = false;
    bool finished = false;
    std::mutex sender;
    std::mutex receiver;
};

inline void HostState::run() {
    for (;;) {
        const auto seen = signal->version();
        std::optional<std::chrono::steady_clock::time_point> deadline;
        bool ready;
        {
            std::lock_guard<std::recursive_mutex> lock(mutex);
            if (pointer == nullptr || shutdown_complete) return;
            for (const auto& item : calls) {
                auto* call = item.second;
                try { call->check_locked(); } catch (const ModuleError&) {}
                if (!call->error && !call->finished && call->deadline && (!deadline || *call->deadline < *deadline))
                    deadline = call->deadline;
            }
            (void)synurang_host_poll(pointer, 64);
            ready = synurang_host_has_work(pointer) != 0;
            ++generation;
            progress.notify_all();
        }
        if (ready) std::this_thread::yield();
        else signal->wait(seen, deadline);
    }
}

inline void HostState::close() {
    std::unique_lock<std::recursive_mutex> lock(mutex);
    if (closing) {
        closed.wait(lock, [&] { return shutdown_complete; });
        if (shutdown_error) std::rethrow_exception(shutdown_error);
        return;
    }
    closing = true;
    try {
        while (!calls.empty()) {
            calls.begin()->second->close_locked();
        }
        signal->wake();
        while (pointer != nullptr) {
            const auto seen = generation;
            const int status = synurang_host_destroy(pointer);
            if (status == 0) { pointer = nullptr; break; }
            if (status != SYNURANG_PENDING) throw ModuleError(13, "Module shutdown failed: " + std::to_string(status));
            progress.wait(lock, [&] { return generation != seen; });
        }
    } catch (...) {
        shutdown_error = std::current_exception();
        if (pointer != nullptr) synurang_host_set_wakeup(pointer, nullptr, nullptr);
    }
    shutdown_complete = true;
    signal->wake();
    ++generation;
    progress.notify_all();
    closed.notify_all();
    lock.unlock();
    if (worker.joinable()) worker.join();
    if (shutdown_error) std::rethrow_exception(shutdown_error);
}
inline HostState::~HostState() noexcept { try { close(); } catch (...) {} }
} // namespace module_detail

/// Shared RAII call handle. Send and receive can execute concurrently. Blocking
/// helpers sleep outside the instance lock; try_* are for external event loops.
class ModuleCall {
public:
    bool try_send(const ModuleBytes& bytes) const {
        std::unique_lock<std::mutex> direction(state_->sender, std::try_to_lock);
        if (!direction.owns_lock()) return false;
        std::lock_guard<std::recursive_mutex> lock(state_->host->mutex);
        return state_->send_locked(bytes);
    }
    void send(const ModuleBytes& bytes) const {
        std::lock_guard<std::mutex> direction(state_->sender);
        std::unique_lock<std::recursive_mutex> lock(state_->host->mutex);
        while (true) {
            const auto seen = state_->host->generation;
            if (state_->send_locked(bytes)) return;
            state_->host->progress.wait(lock, [&] { return state_->host->generation != seen; });
        }
    }
    void half_close() const {
        std::lock_guard<std::mutex> direction(state_->sender);
        std::lock_guard<std::recursive_mutex> lock(state_->host->mutex);
        state_->check_locked();
        const int status = synurang_host_half_close(state_->host->pointer, state_->id);
        if (status != 0) state_->closed_input_locked(status);
    }
    ModuleRead try_receive() const {
        std::unique_lock<std::mutex> direction(state_->receiver, std::try_to_lock);
        if (!direction.owns_lock()) return {};
        std::lock_guard<std::recursive_mutex> lock(state_->host->mutex);
        return state_->read_locked();
    }
    std::optional<ModuleBytes> receive() const {
        std::lock_guard<std::mutex> direction(state_->receiver);
        std::unique_lock<std::recursive_mutex> lock(state_->host->mutex);
        while (true) {
            const auto seen = state_->host->generation;
            auto result = state_->read_locked();
            if (result.kind == ModuleRead::Kind::message) return std::move(result.data);
            if (result.kind == ModuleRead::Kind::finished) return std::nullopt;
            state_->host->progress.wait(lock, [&] { return state_->host->generation != seen; });
        }
    }
    std::future<void> send_async(ModuleBytes bytes) const {
        return std::async(std::launch::async, [call = *this, bytes = std::move(bytes)] { call.send(bytes); });
    }
    std::future<std::optional<ModuleBytes>> receive_async() const {
        return std::async(std::launch::async, [call = *this] { return call.receive(); });
    }
    void cancel(std::int32_t code = 1) const {
        if (code < 1 || code > 16) throw std::invalid_argument("Invalid RPC cancellation status");
        std::lock_guard<std::recursive_mutex> lock(state_->host->mutex);
        state_->cancel_locked(code);
    }
    void close() const {
        std::lock_guard<std::recursive_mutex> lock(state_->host->mutex);
        state_->close_locked();
    }
private:
    friend class ModuleHost;
    explicit ModuleCall(std::shared_ptr<module_detail::CallState> state) : state_(std::move(state)) {}
    std::shared_ptr<module_detail::CallState> state_;
};

/// C++17 raw protobuf transport for the new module ABI. Link only module_host.c
/// (or its shared library); provider runtimes remain inside their own modules.
class ModuleHost {
public:
    static ModuleHost load(const std::string& path, const std::string& symbol = "Synurang_GetApi") {
        return from_pointer(synurang_host_load(path.c_str(), symbol.c_str(), nullptr));
    }
    // The caller owns a statically linked API table/code through host shutdown.
    static ModuleHost linked(const SynurangApi* api) { return from_pointer(synurang_host_linked(api, nullptr)); }
    ModuleCall open(const std::string& path, bool request_stream, bool response_stream,
                    const ModuleCallOptions& options = {}) const {
        if (options.timeout && options.timeout->count() < 0) throw std::invalid_argument("Negative call timeout");
        std::lock_guard<std::recursive_mutex> lock(state_->mutex);
        if (state_->closing) throw ModuleError(14, "Module is closed");
        SynurangCallOptions native{};
        native.struct_size = sizeof(native);
        native.request_stream = request_stream ? 1u : 0u;
        native.response_stream = response_stream ? 1u : 0u;
        native.timeout_ms = options.timeout ? static_cast<std::uint64_t>(options.timeout->count()) : UINT64_MAX;
        const auto id = synurang_host_open(state_->pointer, path.c_str(), &native);
        if (id == 0) throw ModuleError(13, "Module could not open call");
        try {
            auto call = std::make_shared<module_detail::CallState>(state_, id, options);
            state_->calls.emplace(id, call.get());
            state_->signal->wake();
            return ModuleCall(std::move(call));
        } catch (...) { synurang_host_release(state_->pointer, id); throw; }
    }
    ModuleBytes unary(const std::string& path, const ModuleBytes& request, const ModuleCallOptions& options = {}) const {
        auto call = open(path, false, false, options);
        call.send(request);
        call.half_close();
        auto response = call.receive();
        if (!response) throw ModuleError(13, "Missing unary response");
        if (call.receive()) throw ModuleError(13, "Multiple unary responses");
        return std::move(*response);
    }
    std::future<ModuleBytes> unary_async(std::string path, ModuleBytes request, ModuleCallOptions options = {}) const {
        return std::async(std::launch::async, [host = *this, path = std::move(path), request = std::move(request), options = std::move(options)] {
            return host.unary(path, request, options);
        });
    }
    std::uint32_t poll(std::uint32_t budget = 64) const {
        std::lock_guard<std::recursive_mutex> lock(state_->mutex);
        if (state_->closing) throw ModuleError(14, "Module is closed");
        for (const auto& item : state_->calls) {
            try { item.second->check_locked(); } catch (const ModuleError&) { /* Published by this call's next operation. */ }
        }
        return synurang_host_poll(state_->pointer, budget);
    }
    void close() const { state_->close(); }
    std::future<void> close_async() const { return std::async(std::launch::async, [host = *this] { host.close(); }); }
private:
    explicit ModuleHost(std::shared_ptr<module_detail::HostState> state) : state_(std::move(state)) {}
    static ModuleHost from_pointer(SynurangHost* pointer) {
        if (pointer == nullptr) throw std::runtime_error(synurang_host_error());
        try { return ModuleHost(std::make_shared<module_detail::HostState>(pointer)); }
        catch (...) {
            module_detail::Signal signal;
            synurang_host_set_wakeup(pointer, [](void* data) { static_cast<module_detail::Signal*>(data)->wake(); }, &signal);
            for (;;) {
                const auto seen = signal.version();
                (void)synurang_host_poll(pointer, 64);
                const int status = synurang_host_destroy(pointer);
                if (status == 0) break;
                if (status != SYNURANG_PENDING) { synurang_host_set_wakeup(pointer, nullptr, nullptr); break; }
                if (synurang_host_has_work(pointer)) std::this_thread::yield();
                else signal.wait(seen);
            }
            throw;
        }
    }
    std::shared_ptr<module_detail::HostState> state_;
};

} // namespace synurang
#endif
