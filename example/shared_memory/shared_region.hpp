#ifndef SYNURANG_EXAMPLE_SHARED_REGION_HPP
#define SYNURANG_EXAMPLE_SHARED_REGION_HPP
#include <cerrno>
#include <cstdint>
#include <fcntl.h>
#include <random>
#include <stdexcept>
#include <string>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

class SharedRegion {
public:
    explicit SharedRegion(std::size_t size) : size_(size) {
        std::random_device random;
        for (int attempt = 0; attempt < 8; ++attempt) {
            name_ = "/synurang_shm_" + std::to_string(getpid()) + "_" + std::to_string(random());
            const int fd = shm_open(name_.c_str(), O_CREAT | O_EXCL | O_RDWR, 0600);
            if (fd < 0) {
                if (errno == EEXIST) continue;
                throw std::runtime_error("shm_open failed");
            }
            if (ftruncate(fd, static_cast<off_t>(size_)) != 0) {
                close(fd);
                shm_unlink(name_.c_str());
                throw std::runtime_error("ftruncate failed");
            }
            void* mapping = mmap(nullptr, size_, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
            close(fd);
            if (mapping == MAP_FAILED) {
                shm_unlink(name_.c_str());
                throw std::runtime_error("mmap failed");
            }
            data_ = static_cast<std::uint8_t*>(mapping);
            return;
        }
        throw std::runtime_error("Could not create a unique shared-memory name");
    }
    ~SharedRegion() {
        munmap(data_, size_);
        shm_unlink(name_.c_str());
    }
    SharedRegion(const SharedRegion&) = delete;
    SharedRegion& operator=(const SharedRegion&) = delete;
    const std::string& name() const { return name_; }
    std::uint8_t* data() const { return data_; }
    std::size_t size() const { return size_; }
private:
    std::string name_;
    std::size_t size_;
    std::uint8_t* data_ = nullptr;
};
#endif
