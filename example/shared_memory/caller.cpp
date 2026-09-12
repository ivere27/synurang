#include "shared_memory_lite.h"
#include "shared_region.hpp"
#include "synurang/module_host.hpp"

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>

static synurang::ModuleBytes request(const SharedRegion& region, std::uint64_t offset,
                                    std::uint64_t length, std::uint32_t mask,
                                    std::uint64_t request_id) {
    SynurangExampleShmBufferRequest message;
    synurang_example_shm_buffer_request_init(&message);
    auto status = synurang_lite_bytes_assign(message._allocator, &message.field_name,
                                           region.name().data(), region.name().size());
    message.field_offset = offset;
    message.field_length = length;
    message.field_xor_mask = mask;
    message.field_request_id = request_id;
    std::uint8_t* bytes = nullptr;
    std::size_t size = 0;
    if (status == SYNURANG_LITE_OK)
        status = synurang_example_shm_buffer_request_encode(&message, &bytes, &size);
    synurang_example_shm_buffer_request_free(&message);
    std::unique_ptr<std::uint8_t, decltype(&std::free)> owned(bytes, &std::free);
    if (status != SYNURANG_LITE_OK) throw std::runtime_error("Cannot encode descriptor");
    return {bytes, bytes + size};
}

static void require(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}

static void run(const char* module) {
    constexpr std::size_t length = 64 * 1024, offset = 37;
    constexpr std::uint8_t guard = 0xCD;
    // Reverse destruction order keeps shared memory alive through host cleanup,
    // even if a call fails before it delivers an ACK.
    SharedRegion region(offset + length + 19);
    {
        auto host = synurang::ModuleHost::load(module);
        for (std::uint64_t id = 1; id <= 2; ++id) {
            const std::uint8_t mask = id == 1 ? 0x5A : 0xA5;
            std::fill_n(region.data(), region.size(), guard);
            for (std::size_t i = 0; i < length; ++i)
                region.data()[offset + i] = static_cast<std::uint8_t>(i);
            const auto descriptor = request(region, offset, length, mask, id);
            synurang::ModuleCallOptions options;
            options.timeout = std::chrono::seconds(5);
            const auto reply = host.unary("/synurang.example.shm.SharedMemory/Process", descriptor, options);
            SynurangExampleShmBufferDone done;
            synurang_example_shm_buffer_done_init(&done);
            const auto status = synurang_example_shm_buffer_done_decode(&done, reply.data(), reply.size());
            const auto done_id = done.field_request_id;
            const auto processed = done.field_bytes_processed;
            const auto checksum = done.field_checksum;
            synurang_example_shm_buffer_done_free(&done);
            require(status == SYNURANG_LITE_OK && done_id == id && processed == length, "Invalid completion");
            std::uint64_t actual_checksum = 0;
            for (std::size_t i = 0; i < length; ++i) {
                const auto value = region.data()[offset + i];
                require(value == (static_cast<std::uint8_t>(i) ^ mask), "Payload was not updated in place");
                actual_checksum += value;
            }
            require(checksum == actual_checksum, "Checksum mismatch");
            for (std::size_t i = 0; i < offset; ++i)
                require(region.data()[i] == guard, "Prefix guard modified");
            for (std::size_t i = offset + length; i < region.size(); ++i)
                require(region.data()[i] == guard, "Suffix guard modified");
            std::cout << "C++: ACK " << id << ", payload=" << length
                      << " B, protobuf request=" << descriptor.size() << " B, checksum="
                      << checksum << "; in-place update verified\n";
            // ACK + successful terminal allow this same region to be reused.
        }
        host.close();
    }
}

int main(int argc, char** argv) {
    try {
        if (argc != 2) throw std::runtime_error("Usage: cpp_caller /path/to/backend.so");
        run(argv[1]);
        std::cout << "C++: host closed, shared memory unmapped and unlinked\n";
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return EXIT_FAILURE;
    }
}
