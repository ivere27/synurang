# Synurang

> "The gRPC-over-FFI bridge for Go and Flutter"

**Synurang** is a high-performance bridge connecting **Flutter** and **Go** using **gRPC over FFI**.

It decouples the **Transport Layer** from the **Application Layer**, enabling hybrid apps where the UI lives in Flutter and the business logic runs natively in Go—without the overhead of standard platform channels.

> **Note:** This project serves as the underlying engine for **Synura**, a content viewer application. While Synura is the product, **Synurang** is the reusable infrastructure.

**Synura:**
- Play Store: https://play.google.com/store/apps/details?id=io.tempage.synura
- Docs & API: https://github.com/tempage/synura

---

## ⚡ Why Synurang?

**Stop choosing between Performance and Productivity.**

Synurang combines the native speed of Go with the reactive beauty of Flutter, without the fragility of Platform Channels or the overhead of running a local HTTP server.

| Feature | Platform Channels | Localhost HTTP (Sidecar) | Synurang (FFI) |
| :--- | :--- | :--- | :--- |
| **Transport** | OS Messaging | TCP/IP Loopback | **Direct Memory** |
| **Typing** | Loose (Map/JSON) | Loose (JSON) | **Strict (Protobuf)** |
| **Performance** | Slow | Medium | **Native Speed** |
| **Streaming** | Difficult | Chunked | **Native gRPC Streams** |
| **Bidirectional** | Complex | WebSocket | **Native gRPC Bidi** |

---

## 🏗 Architecture & Philosophy

Synurang enforces a strict architectural separation:

1.  **VIEW (Flutter)**: Responsible **only** for rendering the UI and handling user input. It should contain *zero* complex business logic.
2.  **LOGIC (Go)**: The "Brain" of the application. Handles database access (SQLite), complex parsing, networking, and state calculation.
3.  **TRANSPORT (Synurang)**: The spinal cord connecting the two. It moves data using **Protobuf** messages over direct FFI calls, avoiding the overhead of HTTP/TCP or Platform Channels.

```ascii
┌──────────────────────┐          ┌──────────────────────┐
│  Flutter (UI/View)   │          │    Go (Logic/Data)   │
│                      │          │                      │
│  [ Widget Tree ]     │          │  [ Business Logic ]  │
│         │            │          │           │          │
│  [ Dart Client ]     │          │   [ gRPC Server ]    │
│  [ gRPC Server ] ◄───┼──FFI─────┼───► [ gRPC Client ]  │
└─────────┬────────────┘          └───────────┬──────────┘
          │                                   │
          │         Synurang Bridge           │
          │     (Direct FFI / Protobuf)       │
          └───────────────────────────────────┘
```

> [!IMPORTANT]
> **In-Process by Default:** The Go "backend" runs **inside the same process** as your Flutter app via FFI—compiled into a shared library (`.so`/`.dylib`). The term "gRPC" refers to the **protocol semantics** (typed messages, streaming), not network transport. However, Synurang also supports **UDS** (Unix Domain Socket for IPC) and **TCP** (for remote debugging or distributed setups). See [UDS & TCP "Side Doors"](#-uds--tcp-side-doors) below.

### 🖥️ Desktop-First Development

This architecture empowers a **Desktop-First** workflow. You can develop and test the entire application (Logic + UI) on Linux, macOS, or Windows. Since the Go backend runs identically on desktop and mobile:
*   **Iterate Fast:** Develop core features on your desktop without slow emulator/device builds.
*   **Seamless Porting:** Deploy to Android/iOS with confidence, knowing the logic layer is identical.
*   **Hybrid Debugging:** Run the Logic layer on your desktop while connecting a mobile UI to it (via TCP) for granular debugging.

### 📜 API-First Design

By defining your data contracts in `.proto` files *before* writing a single line of code, Synurang enforces a disciplined **API-First** workflow.
*   **Clear Contracts:** The Protobuf definition is the single source of truth for both frontend and backend developers.
*   **Type Safety:** Generated Dart and Go code ensures that your UI and Logic always speak the same language.
*   **Scenario-Based Design:** You can design and mock your APIs for specific user stories (e.g., "Offline Mode", "Video Streaming") without worrying about implementation details initially.

### 🧪 Experimental C++ Support

Synurang includes experimental support for **C++** backends.
*   **Code Generation:** The `protoc-gen-synurang-ffi` plugin supports `--lang=cpp` to generate C++ dispatchers.
*   **Runtime:** A C++ runtime header (`synurang.hpp`) provides the interface for implementing services.
*   **Note:** C++ support requires a manual build setup (CMake) for `grpc++` dependencies.

### 🦀 Experimental Rust Support

Synurang also includes experimental support for **Rust** backends.
*   **Code Generation:** The `protoc-gen-synurang-ffi` plugin supports `--lang=rust` to generate Rust dispatchers and a `GeneratedService` trait.
*   **Runtime:** A Rust runtime library (`synurang`) provides the FFI interface and service registration mechanism.
*   **Note:** Rust support requires a manual build setup (Cargo) for dependencies.

---

## 💡 Common Use Cases

### 1. High-Performance Data Processing
Offload heavy computational tasks like image processing, cryptography, or complex data analysis to Go. Go's efficient memory model and goroutines provide superior performance compared to Dart isolates for raw compute.

### 2. Embedded Database Management
Run a robust database engine (like SQLite, DuckDB, or specialized Go-based DBs) entirely within the Go runtime. Your Flutter UI can query data via strictly typed gRPC methods, while Go handles the complex persistence logic, migrations, and concurrency.

### 3. System-Level Integration
Use Go's `cgo` capabilities to interface with legacy C/C++ libraries or OS-specific APIs that might be cumbersome to access directly from Dart. Wrap these interactions in a clean gRPC API for your Flutter frontend.

---

## 🚀 Key Features

*   **⚡ Direct Memory Access**: Request payloads use zero-copy via `unsafe.Slice`; responses are copied once via C malloc. See [Memory Model](#-memory-model).
*   **📡 Full gRPC Support**: Supports Unary, Server Streaming, Client Streaming, and Bidirectional Streaming RPCs.
*   **🔄 Bidirectional Communication**:
    *   **Flutter -> Go**: Standard client calls.
    *   **Go -> Flutter**: Dart acts as a **gRPC Server** via reverse-FFI callbacks, allowing Go to push updates or request UI state.
*   **🧵 Thread Safety**: Automatically manages Dart **Isolates** and Go **Goroutines** to ensure the UI thread never blocks.
*   **🛠 Code Generation**: Includes `protoc-gen-synurang-ffi` to auto-generate type-safe bindings from your `.proto` files.
*   **💾 Built-in Caching**: High-performance L2 cache implementation using SQLite (via Go) exposed directly to Dart.

### Supported RPC Types

| Type | Go Method | Generated Dart Client | FFI Streaming |
|------|-----------|----------------------|---------------|
| Unary | `Bar()` | `GoGreeterServiceFfi.Bar()` | ✅ `Future<T>` |
| Server Stream | `BarServerStream()` | `GoGreeterServiceFfi.BarServerStream()` | ✅ `Stream<T>` |
| Client Stream | `BarClientStream()` | `GoGreeterServiceFfi.BarClientStream()` | ✅ `Future<T>(Stream)` |
| Bidi Stream | `BarBidiStream()` | `GoGreeterServiceFfi.BarBidiStream()` | ✅ `Stream<T>(Stream)` |

### 🧠 Memory Model

Synurang's FFI layer minimizes copies where possible. The memory behavior varies by backend language:

#### Go Backend

The protoc plugin generates **two invoke functions** for flexibility:

| Function | Returns | FFI Mode | TCP/UDS Mode |
|----------|---------|----------|--------------|
| `Invoke(...)` | `[]byte` | ✅ Works (1 copy via `C.CBytes`) | ✅ Works |
| `InvokeFfi(...)` | `unsafe.Pointer` | ✅ Zero-copy | ❌ Not applicable |

**Memory behavior:**

| Operation | Direction | Zero-Copy? | Mechanism |
|-----------|-----------|------------|----------|
| Unary Request | Dart → Go | ✅ Yes | `unsafe.Slice` – Go reads Dart's memory directly |
| Unary Response | Go → Dart | ✅ Yes | `C.malloc` + direct serialize via `InvokeFfi` |
| Cache Put | Dart → Go | ✅ Yes | `unsafe.Slice` – synchronous write, no copy |
| Cache Get | Go → Dart | ❌ No | `C.CBytes` – malloc + copy |
| Stream Data (in) | Dart → Go | ⚠️ Option | `C.GoBytes` (safe) or `unsafe.Slice` (zero-copy) |
| Stream Data (out) | Go → Dart | ⚠️ Option | `SendFromStream` (1 copy) or `SendFromStreamFfi` (zero-copy) |

> [!NOTE]
> **Stream Input Zero-Copy**: By default, `SendStreamData` in `cmd/server/main.go` uses `C.GoBytes` (safe, 1 copy). To enable zero-copy, replace it with `unsafe.Slice`—but only if you guarantee the data is not accessed after the function returns. See the commented code in `SendStreamData` for the zero-copy option.

> [!TIP]
> **Both work for FFI!** Use `InvokeFfi` for zero-copy performance with large payloads. Use `Invoke` + `C.CBytes` when you prefer simpler code (the copy overhead is negligible for small messages). See `example/cmd/server/main.go` for both patterns.
>
> **Summary:** Use `InvokeFfi` for maximum performance. Use `Invoke` for code reuse between FFI and TCP/UDS modes.

> [!WARNING]
> **Trade-off:** Zero-copy eliminates GC overhead for high performance but requires strict manual memory management, as any violation causes immediate application crashes.

#### Rust Backend (Experimental)

| Operation | Direction | Zero-Copy? | Mechanism |
|-----------|-----------|------------|----------|
| Unary Request | Dart → Rust | ✅ Yes | `slice::from_raw_parts` – view of Dart's memory |
| Unary Response | Rust → Dart | ✅ Yes | `Vec::leak()` – ownership transferred, no copy |

Rust achieves **full zero-copy** because it has manual memory control. The `Vec` is leaked (not freed), and Dart calls `FreeFfiData` which reconstructs and drops the Vec properly.

#### C++ Backend (Experimental)

| Operation | Direction | Zero-Copy? | Mechanism |
|-----------|-----------|------------|----------|
| Unary Request | Dart → C++ | ✅ Yes | Direct pointer access |
| Unary Response | C++ → Dart | ✅ Yes | Returns `malloc`'d pointer directly |

C++ allocates response data directly in C heap, so the FFI layer just passes the pointer. Dart frees it via `FreeFfiData`.

---

## 🔌 UDS & TCP "Side Doors"

While the primary communication happens via **Direct FFI**, `synurang` can also expose standard network interfaces for specific use cases:

### 1. Unix Domain Socket (UDS)
**Use Case: Local IPC & Extension Isolation**
Useful when running unstable code (like third-party extensions) in separate processes. These external processes can communicate with the main Go engine via UDS without crashing the main application if they fail.

### 2. TCP Server
**Use Case: Independent Debugging (UI & Logic)**
Enables the **Dart (UI server)** and **Golang (Logic server)** to be debugged independently.
*   **Debug Logic:** Connect to the Go backend via TCP (e.g., via `adb forward`) to test business logic in isolation using tools like `grpcurl` or Postman.
*   **Debug UI:** Verify the View layer by mocking backend responses or triggering UI events remotely, without needing the full backend state.

### Testing UDS/TCP Transports

**Dart Console Example** (spawns Go server process in UDS/TCP modes):
```bash
# FFI mode (default) - embedded Go via shared library
make run_console_example

# TCP mode - spawns separate Go server process
dart run example/console_main.dart --mode=tcp --port=18000

# UDS mode - spawns separate Go server process  
dart run example/console_main.dart --mode=uds --socket=/tmp/synurang.sock
```

**Go CLI Client** (for testing from command line):
```bash
# Test Go server via TCP
go run example/cmd/client/main.go --target=go --transport=tcp --addr=localhost:18000

# Test Go server via UDS
go run example/cmd/client/main.go --target=go --transport=uds --socket=/tmp/synurang.sock

# Test Flutter server via TCP
go run example/cmd/client/main.go --target=flutter --transport=tcp --addr=localhost:10050

# Test Flutter server via UDS
go run example/cmd/client/main.go --target=flutter --transport=uds --socket=/tmp/flutter_view.sock
```

**Flutter GUI Example** (interactive transport testing):
```bash
# Build shared libraries and run Flutter app
make run_flutter_example
```
Use the toggle buttons in the header (Go UDS, Go TCP, Flutter UDS, Flutter TCP) to switch transports. The "ALL (Mixed)" button runs comprehensive tests across all transport combinations.

---

## 📦 Installation & Quick Start

### Prerequisites

```bash
# Install Go (1.21+)
# Install Flutter (3.10+)
# Install protoc

# For Linux
sudo apt install protobuf-compiler

# Install Go protoc plugins
go install google.golang.org/protobuf/cmd/protoc-gen-go@latest
go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@latest

# Install Dart protoc plugin
dart pub global activate protoc_plugin
```

### Setup in Project

Add `synurang` to your `pubspec.yaml`:

```yaml
dependencies:
  synurang:
    path: ./synurang # or git url
```

Ensure your Go module requires the backend package.

---

## 🛠 Development Workflow

### 1. Define your Protocol (`api/service.proto`)

```protobuf
syntax = "proto3";
package api;

service UserService {
  rpc GetProfile(UserId) returns (UserProfile);
  rpc WatchNotifications(UserId) returns (stream Notification);
}
```

### 2. Generate Code

Use the provided makefile target or `protoc` plugin to generate the glue code:

```bash
# Generates *_ffi.pb.dart and *_ffi.pb.go
make proto
```

### 3. Implement Logic (Go)

Implement the generated interface in your Go backend.

```go
type UserServer struct {}

func (s *UserServer) GetProfile(ctx context.Context, req *api.UserId) (*api.UserProfile, error) {
    // Database logic here...
    return &api.UserProfile{Name: "Alice"}, nil
}
```

### 4. Call from View (Dart)

Use the generated static methods to call your backend.

```dart
// Unary Call
final profile = await UserServiceFfi.GetProfile(UserId(id: 123));

// Streaming Call
final stream = UserServiceFfi.WatchNotifications(UserId(id: 123));
stream.listen((notification) {
  print("New notification: ${notification.message}");
});
```

---

## 📚 API Reference

### Dart API (`package:synurang/synurang.dart`)

#### Server Management

*   **`startGrpcServerAsync({ ... })`**: Starts the embedded Go server on a background isolate.
    *   `storagePath`: Path to persist data.
    *   `enableCache`: Enable the internal SQLite cache.
*   **`stopGrpcServerAsync()`**: Gracefully stops the server.
*   **`invokeBackendAsync(method, data)`**: Raw FFI invocation (mostly used by generated code).

#### Cache API

Direct access to the Go-managed SQLite cache.

*   **`cacheGetRaw(store, key)`**: Retrieve data.
*   **`cachePutRaw(store, key, data, ttl)`**: Store data with expiration.
*   **`cachePutPtr(...)`**: Store data from a C-pointer (Zero-Copy).

### Go API (`package:synurang/pkg/service`)

#### Configuration

*   **`NewCoreService(config)`**: Creates the main service hub.
*   **`NewGrpcServer(core, config, registrars...)`**: Creates the gRPC server and registers your custom services.

#### Streaming Handlers

*   **`RegisterServerStreamHandler`**: Register a callback for server-side streaming.
*   **`RegisterBidiStreamHandler`**: Register a callback for bidirectional streaming.

## 📂 Directory Structure

```
synurang/
├── api/core.proto           # Core Protocol definitions
├── cmd/server/main.go       # Go main with FFI exports
├── example/                 # Example Flutter Application
│   ├── api/example.proto    # Example service definitions
│   ├── cmd/                  # Go CLI tools
│   ├── lib/main.dart        # Flutter Example App
│   └── test/                # Integration tests
├── pkg/
│   ├── api/                 # Generated Go proto
│   └── service/             # Go service implementations
│       ├── cache.go         # SQLite cache service
│       ├── server.go        # gRPC server setup
│       └── stream_handler.go # FFI stream protocol
├── src/                     # Shared libraries (.so/.dylib output)
├── lib/
│   ├── synurang.dart        # Main Dart entry point
│   └── src/generated/       # Generated Dart proto
├── makefile
└── pubspec.yaml
```

---

## ⚖️ License

MIT License. See [LICENSE](LICENSE) for details.
