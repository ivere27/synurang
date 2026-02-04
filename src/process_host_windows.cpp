// Synurang C++ Process Host - Windows Implementation
//
// Uses TCP loopback for IPC on Windows (gRPC C++ doesn't support named pipes).
// Child binds to port 0, reports actual port via stdout as "SYNURANG_PORT:<port>".

#include "synurang/process_host.hpp"

#ifdef _WIN32

#include <stdexcept>
#include <string>
#include <sstream>

namespace synurang {

// Marker prefix for child to report its listening port
static const char* PORT_MARKER = "SYNURANG_PORT:";

std::shared_ptr<ProcessHost> ProcessHost::start(
    const std::string& executable,
    const std::vector<std::string>& args
) {
    // Create pipe for reading child's stdout
    HANDLE stdout_read = nullptr;
    HANDLE stdout_write = nullptr;
    SECURITY_ATTRIBUTES sa = {};
    sa.nLength = sizeof(sa);
    sa.bInheritHandle = TRUE;

    if (!CreatePipe(&stdout_read, &stdout_write, &sa, 0)) {
        throw std::runtime_error("CreatePipe failed: " + std::to_string(GetLastError()));
    }

    // Ensure read handle is not inherited
    SetHandleInformation(stdout_read, HANDLE_FLAG_INHERIT, 0);

    // Build command line
    std::string cmd_line = executable;
    for (const auto& arg : args) {
        cmd_line += " " + arg;
    }

    // Build environment block for child process
    // Format: VAR1=VALUE1\0VAR2=VALUE2\0...\0\0
    std::string env_block;

    // Copy current environment
    char* current_env = GetEnvironmentStringsA();
    if (current_env) {
        const char* p = current_env;
        while (*p) {
            std::string var(p);
            // Skip if it's the variable we're setting
            if (var.find(std::string(ENV_VAR_IPC) + "=") != 0) {
                env_block += var;
                env_block += '\0';
            }
            p += var.length() + 1;
        }
        FreeEnvironmentStringsA(current_env);
    }

    // Add our IPC variable - child picks its own port
    env_block += std::string(ENV_VAR_IPC) + "=tcp://127.0.0.1:0";
    env_block += '\0';
    env_block += '\0';  // Double null terminator

    // Start child process with redirected stdout
    STARTUPINFOA si = {};
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdOutput = stdout_write;
    si.hStdError = GetStdHandle(STD_ERROR_HANDLE);
    si.hStdInput = GetStdHandle(STD_INPUT_HANDLE);

    PROCESS_INFORMATION pi = {};

    if (!CreateProcessA(
        nullptr,
        const_cast<char*>(cmd_line.c_str()),
        nullptr,
        nullptr,
        TRUE,   // Inherit handles
        0,
        const_cast<char*>(env_block.c_str()),
        nullptr,
        &si,
        &pi
    )) {
        CloseHandle(stdout_read);
        CloseHandle(stdout_write);
        throw std::runtime_error("CreateProcess failed: " + std::to_string(GetLastError()));
    }

    CloseHandle(pi.hThread);
    CloseHandle(stdout_write);  // Close write end in parent

    // Read stdout to find the port marker
    int port = 0;
    std::string buffer;
    char ch;
    DWORD bytes_read;
    auto start_time = GetTickCount64();
    const DWORD timeout_ms = 10000;  // 10 second timeout

    while (GetTickCount64() - start_time < timeout_ms) {
        // Check if child is still alive
        DWORD exit_code;
        if (GetExitCodeProcess(pi.hProcess, &exit_code) && exit_code != STILL_ACTIVE) {
            CloseHandle(stdout_read);
            CloseHandle(pi.hProcess);
            throw std::runtime_error("Child process exited with code " + std::to_string(exit_code) + " before reporting port");
        }

        // Try to read
        DWORD available = 0;
        if (PeekNamedPipe(stdout_read, nullptr, 0, nullptr, &available, nullptr) && available > 0) {
            if (ReadFile(stdout_read, &ch, 1, &bytes_read, nullptr) && bytes_read > 0) {
                if (ch == '\n' || ch == '\r') {
                    // Check if this line contains the port marker
                    size_t pos = buffer.find(PORT_MARKER);
                    if (pos != std::string::npos) {
                        std::string port_str = buffer.substr(pos + strlen(PORT_MARKER));
                        port = std::stoi(port_str);
                        break;
                    }
                    buffer.clear();
                } else {
                    buffer += ch;
                }
            }
        } else {
            Sleep(10);  // Brief sleep to avoid busy-waiting
        }
    }

    if (port <= 0) {
        CloseHandle(stdout_read);
        TerminateProcess(pi.hProcess, 1);
        CloseHandle(pi.hProcess);
        throw std::runtime_error("Child process did not report listening port within timeout. "
                                 "Ensure child prints \"SYNURANG_PORT:<port>\" to stdout after binding.");
    }

    // Connect to child's gRPC server via TCP loopback
    std::string target = "127.0.0.1:" + std::to_string(port);
    auto channel = grpc::CreateChannel(target, grpc::InsecureChannelCredentials());

    // Wait for channel to be ready
    auto deadline = std::chrono::system_clock::now() + std::chrono::seconds(5);
    if (!channel->WaitForConnected(deadline)) {
        CloseHandle(stdout_read);
        TerminateProcess(pi.hProcess, 1);
        CloseHandle(pi.hProcess);
        throw std::runtime_error("Failed to connect to child gRPC server on port " + std::to_string(port));
    }

    auto host = std::shared_ptr<ProcessHost>(new ProcessHost());
    host->channel_ = channel;
    host->process_handle_ = pi.hProcess;
    host->stdout_handle_ = stdout_read;
    return host;
}

ProcessHost::~ProcessHost() {
    terminate();
    if (stdout_handle_) {
        CloseHandle(stdout_handle_);
    }
    if (process_handle_) {
        CloseHandle(process_handle_);
    }
}

void ProcessHost::terminate() {
    if (process_handle_ && is_running()) {
        TerminateProcess(process_handle_, 1);
        WaitForSingleObject(process_handle_, INFINITE);
    }
}

int ProcessHost::wait() {
    if (!process_handle_) {
        return -1;
    }
    WaitForSingleObject(process_handle_, INFINITE);
    DWORD exit_code;
    GetExitCodeProcess(process_handle_, &exit_code);
    return static_cast<int>(exit_code);
}

bool ProcessHost::is_running() const {
    if (!process_handle_) {
        return false;
    }
    DWORD exit_code;
    if (GetExitCodeProcess(process_handle_, &exit_code)) {
        return exit_code == STILL_ACTIVE;
    }
    return false;
}

int get_ipc_fd() {
    // On Windows, we use TCP loopback, not socketpair.
    // Use new_ipc_listener() with AddListeningPort() instead.
    throw std::runtime_error(
        "get_ipc_fd() is not supported on Windows. "
        "Use new_ipc_listener() with AddListeningPort() for TCP loopback.");
}

std::string new_ipc_listener() {
    const char* ipc_addr = getenv(ENV_VAR_IPC);
    if (!ipc_addr) {
        throw std::runtime_error("SYNURANG_IPC environment variable not set");
    }

    // Return localhost:0 for gRPC to bind to an available port
    // Child must print "SYNURANG_PORT:<actual_port>" after binding
    return "127.0.0.1:0";
}

} // namespace synurang

#endif // _WIN32
