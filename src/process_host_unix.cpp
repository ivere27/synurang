// Synurang C++ Process Host - Unix Implementation
//
// Uses socketpair for IPC on Linux/macOS/Android/iOS.
// gRPC C++ supports fd-based channels via CreateInsecureChannelFromFd.

#include "synurang/process_host.hpp"

#ifndef _WIN32

#include <grpcpp/create_channel_posix.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>
#include <signal.h>
#include <fcntl.h>
#include <cstring>
#include <cstdlib>
#include <stdexcept>

namespace synurang {

std::shared_ptr<ProcessHost> ProcessHost::start(
    const std::string& executable,
    const std::vector<std::string>& args
) {
    // Create socketpair
    int fds[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, fds) < 0) {
        throw std::runtime_error("socketpair failed: " + std::string(strerror(errno)));
    }

    int parent_fd = fds[0];
    int child_fd = fds[1];

    pid_t pid = fork();
    if (pid < 0) {
        close(parent_fd);
        close(child_fd);
        throw std::runtime_error("fork failed: " + std::string(strerror(errno)));
    }

    if (pid == 0) {
        // Child process
        close(parent_fd);

        // Dup the child fd to fd 3 (first available after stdin/stdout/stderr)
        if (child_fd != 3) {
            if (dup2(child_fd, 3) < 0) {
                _exit(1);
            }
            close(child_fd);
        }

        // Set environment variable
        setenv(ENV_VAR_IPC, "3", 1);

        // Build argv
        std::vector<char*> argv;
        argv.push_back(const_cast<char*>(executable.c_str()));
        for (const auto& arg : args) {
            argv.push_back(const_cast<char*>(arg.c_str()));
        }
        argv.push_back(nullptr);

        execvp(executable.c_str(), argv.data());
        _exit(1);  // exec failed
    }

    // Parent process
    close(child_fd);

    // Ensure blocking mode (some gRPC versions prefer it for the initial handshake on FDs)
    int flags = fcntl(parent_fd, F_GETFL, 0);
    fcntl(parent_fd, F_SETFL, flags & ~O_NONBLOCK);

    // Create gRPC channel from file descriptor
    // gRPC takes ownership of the fd
    auto channel = grpc::CreateInsecureChannelFromFd("", parent_fd);

    auto host = std::shared_ptr<ProcessHost>(new ProcessHost());
    host->channel_ = channel;
    host->pid_ = pid;
    host->parent_fd_ = -1;  // gRPC owns the fd now
    return host;
}

ProcessHost::~ProcessHost() {
    terminate();
    if (parent_fd_ >= 0) {
        close(parent_fd_);
    }
}

void ProcessHost::terminate() {
    std::lock_guard<std::mutex> lock(pid_mu_);
    if (pid_ > 0) {
        kill(pid_, SIGTERM);
        // Try to clean up, but don't hang indefinitely if child is stuck
        int status;
        for (int i = 0; i < 5; i++) {
            if (waitpid(pid_, &status, WNOHANG) > 0) {
                pid_ = -1;
                return;
            }
            usleep(10000); // 10ms
        }
        // Force kill if still running
        kill(pid_, SIGKILL);
        waitpid(pid_, &status, 0);
        pid_ = -1;
    }
}

int ProcessHost::wait() {
    std::lock_guard<std::mutex> lock(pid_mu_);
    if (pid_ <= 0) {
        return -1;
    }
    int status;
    waitpid(pid_, &status, 0);
    pid_ = -1;
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

bool ProcessHost::is_running() const {
    std::lock_guard<std::mutex> lock(pid_mu_);
    if (pid_ <= 0) {
        return false;
    }
    // Use kill(0) to check if process exists
    return kill(pid_, 0) == 0;
}

int get_ipc_fd() {
    const char* fd_str = getenv(ENV_VAR_IPC);
    if (!fd_str) {
        throw std::runtime_error("SYNURANG_IPC environment variable not set");
    }
    return std::stoi(fd_str);
}

std::string new_ipc_listener() {
    // On Unix, socketpair provides already-connected sockets.
    // Use get_ipc_fd() + grpc::AddInsecureChannelFromFd() instead.
    throw std::runtime_error(
        "new_ipc_listener() is not supported on Unix. "
        "Use get_ipc_fd() with grpc::AddInsecureChannelFromFd() for socketpair.");
}

} // namespace synurang

#endif // !_WIN32
