// Synurang C++ Process Host
//
// This header allows C++ applications to spawn child processes (Go, Rust, C++)
// and communicate via gRPC over IPC.
//
// Usage:
//   #include <synurang/process_host.hpp>
//
//   auto channel = synurang::ProcessHost::start("./child-process");
//   // Use channel with gRPC stubs...
//   channel->shutdown();

#ifndef SYNURANG_PROCESS_HOST_HPP
#define SYNURANG_PROCESS_HOST_HPP

#include <string>
#include <vector>
#include <memory>
#include <mutex>
#include <cstdint>

#ifdef _WIN32
#include <windows.h>
#else
#include <sys/types.h>
#endif

#include <grpcpp/grpcpp.h>

namespace synurang {

// Environment variable name for IPC address
constexpr const char* ENV_VAR_IPC = "SYNURANG_IPC";

// Process handle wrapper
class ProcessHost {
public:
    // Start a child process and return a gRPC channel to communicate with it.
    // The child will receive the IPC address via SYNURANG_IPC environment variable.
    //
    // On Unix: Uses socketpair, passes FD number in SYNURANG_IPC
    // On Windows: Uses TCP loopback (gRPC C++ doesn't support named pipes)
    //             Child must print "SYNURANG_PORT:<port>" to stdout after binding.
    static std::shared_ptr<ProcessHost> start(
        const std::string& executable,
        const std::vector<std::string>& args = {}
    );

    // Get the gRPC channel for creating service stubs
    std::shared_ptr<grpc::Channel> channel() const { return channel_; }

    // Kill the child process
    void terminate();

    // Wait for the child process to exit
    int wait();

    // Check if the child is still running
    bool is_running() const;

    ~ProcessHost();

    // No copy
    ProcessHost(const ProcessHost&) = delete;
    ProcessHost& operator=(const ProcessHost&) = delete;

private:
    ProcessHost() = default;

    std::shared_ptr<grpc::Channel> channel_;
    mutable std::mutex pid_mu_;

#ifdef _WIN32
    HANDLE process_handle_ = nullptr;
    HANDLE stdout_handle_ = nullptr;  // For reading child's port output
#else
    pid_t pid_ = -1;
    int parent_fd_ = -1;
#endif
};

// Child-side: Get the IPC file descriptor for Unix socketpair.
// Call this from the child process on Unix/Linux/macOS.
//
// Unix Usage (socketpair - no listener needed):
//   #include <grpcpp/server_posix.h>
//   int fd = synurang::get_ipc_fd();
//   grpc::ServerBuilder builder;
//   builder.RegisterService(&my_service);
//   auto server = builder.BuildAndStart();
//   grpc::AddInsecureChannelFromFd(server.get(), fd);  // Already-connected socket
//   server->Wait();
//
// Windows Usage (TCP loopback):
//   std::string addr = synurang::new_ipc_listener();  // Returns "127.0.0.1:0"
//   grpc::ServerBuilder builder;
//   int selected_port = 0;
//   builder.AddListeningPort(addr, grpc::InsecureServerCredentials(), &selected_port);
//   builder.RegisterService(&my_service);
//   auto server = builder.BuildAndStart();
//   std::cout << "SYNURANG_PORT:" << selected_port << std::endl;  // Required!
//   server->Wait();

// Unix: Get the IPC file descriptor from SYNURANG_IPC env var.
// Use with grpc::AddInsecureChannelFromFd() for socketpair.
int get_ipc_fd();

// Windows: Get the listener address for gRPC. Returns "127.0.0.1:0".
// Use with builder.AddListeningPort(). Child must print "SYNURANG_PORT:<port>" after binding.
std::string new_ipc_listener();

} // namespace synurang

#endif // SYNURANG_PROCESS_HOST_HPP
