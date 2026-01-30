# Synurang

> "The gRPC-over-FFI bridge for Go and Flutter"

**Synurang** is a high-performance bridge connecting **Flutter** and **Go** using **gRPC over FFI**.

**Primary use cases:**
- **Flutter <-> Go**: Native mobile/desktop apps with embedded Go logic
- **In-Process Microservices**: Ship proprietary gRPC services as shared libraries

**Experimental:**
- **C++ / Rust**: Native backend support (experimental)

Synurang decouples the **Transport Layer** from the **Application Layer**, enabling hybrid apps and high-performance IPC—without the overhead of standard platform channels or network transport.

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
*   **Code Generation:** The plugin `cmd/protoc-gen-synurang-ffi` generates the client-side glue code that calls the backend via FFI.
*   **Note:** Rust support requires a manual build setup (Cargo) for dependencies.

### 🧪 Go-to-Go FFI (Embedded)

Synurang also supports **Go-to-Go** communication via `FfiClientConn`. This enables building libraries that can work both as **standalone gRPC servers** or be **embedded directly** into the caller—using the same gRPC client interface.

```go
// Same client code works for both embedded and remote
conn := api.NewFfiClientConn(embeddedServer)  // Embedded mode
// OR: conn, _ := grpc.Dial("localhost:50051") // Remote mode

client := pb.NewMyServiceClient(conn)
resp, err := client.MyMethod(ctx, req)  // Same API, different transport
```

### 🔄 Three Transports, One Interface

Synurang enables **drop-in replacement** across three transport modes using the standard `grpc.ClientConnInterface`. Write your client code once, switch transports without changing business logic:

```go
// Transport 1: FFI with Source (in-process, zero-copy)
conn := api.NewFfiClientConn(embeddedServer)

// Transport 2: TCP/UDS (standard gRPC over network)
conn, _ := grpc.Dial("localhost:50051", grpc.WithInsecure())

// Transport 3: Plugin FFI (in-process, binary shared library)
plugin, _ := synurang.LoadPlugin("./plugin.so")
conn := synurang.NewPluginClientConn(plugin, "MyService")

// Same client code for ALL transports - including streaming!
client := pb.NewMyServiceClient(conn)
resp, err := client.MyMethod(ctx, req)

// Streaming works identically across all transports
stream, _ := client.ServerStream(ctx, req)
for {
    msg, err := stream.Recv()
    if err == io.EOF { break }
    // process msg
}
```

| Transport | Use Case | Performance | Source Required |
|-----------|----------|-------------|-----------------|
| FFI with Source | Embedded libraries | Zero-copy | Yes |
| TCP/UDS | Remote/debug | Network overhead | No |
| Plugin FFI | Proprietary plugins | Near zero-copy | No (binary only) |

### 🧩 In-Process Microservice (Shared Library Plugin)

Synurang supports **In-Process Microservices** — ship proprietary gRPC services as shared libraries (`.so`/`.dll`) that can be dynamically loaded by host applications.

**Use Case:** You have an open-source Go project and want to distribute **closed-source business logic** as a compiled binary. The host loads your plugin and communicates via standard gRPC interfaces — no network overhead, no source code exposure.

```
┌─────────────────────────────────────────┐
│ Host Process (Open Source)              │
│                                         │
│  ┌──────────┐      ┌──────────────────┐ │
│  │ Host App │ ◄──► │ In-Process       │ │
│  │          │ gRPC │ Microservice     │ │
│  │          │ API  │ (plugin.so)      │ │
│  └──────────┘      │ [Proprietary]    │ │
│                    └──────────────────┘ │
└─────────────────────────────────────────┘
```

**Key Benefits:**
*   **Ship Proprietary Logic:** Distribute closed-source implementations as compiled binaries.
*   **gRPC Interface:** Same proto/gRPC contracts — familiar API, type-safe.
*   **Drop-in Replacement:** Use `PluginClientConn` with standard gRPC clients — same code works across FFI, TCP, and Plugin transports.
*   **Full Streaming Support:** Server streaming, client streaming, and bidirectional streaming all work over plugin FFI.
*   **Per-Service Interfaces:** Only implement the service you need — no stubs for other services.
*   **Error Propagation:** Errors are returned to the host with full error messages.
*   **Version Independence:** Host and Plugin can be compiled with different Go versions.
*   **Dynamic Loading:** Load plugins at runtime via `dlopen` (CGO).

#### 1. Define Protocol (`service.proto`)
Same as standard gRPC.

#### 2. Generate Plugin Code (Server Side)
Use the `mode=plugin_server` option to generate per-service interfaces and C-exports.

```bash
protoc -Iapi \
    --go_out=./pkg/api --go_opt=paths=source_relative \
    --go-grpc_out=./pkg/api --go-grpc_opt=paths=source_relative \
    --plugin=protoc-gen-synurang-ffi=bin/protoc-gen-synurang-ffi \
    --synurang-ffi_out=./pkg/api \
    --synurang-ffi_opt=paths=source_relative,mode=plugin_server,services=MyService \
    service.proto
```

This generates:
*   `MyServicePlugin` interface — only methods for this service
*   `RegisterMyServicePlugin(s MyServicePlugin)` — per-service registration
*   `Synurang_Invoke_MyService` — C-exported function with error handling

#### 3. Implement Plugin (`plugin/main.go`)
Implement only the interface for your service — no stubs needed!

```go
package main

import "C"
import pb "my-plugin/pkg/api"

// Only implement MyServicePlugin - clean interface!
type MyPlugin struct{}

func (s *MyPlugin) MyMethod(ctx context.Context, req *pb.Request) (*pb.Response, error) {
    return &pb.Response{Message: "Hello from plugin!"}, nil
}

func init() {
    // Per-service registration
    pb.RegisterMyServicePlugin(&MyPlugin{})
}

func main() {} // Required for -buildmode=c-shared
```

Compile as shared library:
```bash
go build -buildmode=c-shared -o plugin.so ./plugin/main.go
```

#### 4. Load from Host

**Option A: gRPC ClientConnInterface (Recommended)**

Use `synurang.NewPluginClientConn` for drop-in gRPC client compatibility. This is the recommended approach—same client code works across FFI, TCP, and Plugin transports:

```go
import "github.com/ivere27/synurang/pkg/synurang"

// Load the plugin
plugin, err := synurang.LoadPlugin("./plugin.so")
if err != nil {
    log.Fatal(err)
}
defer plugin.Close()

// Create gRPC ClientConnInterface - drop-in replacement!
conn := synurang.NewPluginClientConn(plugin, "MyService")

// Use standard gRPC client - same code as network gRPC
client := pb.NewMyServiceClient(conn)
resp, err := client.MyMethod(ctx, &pb.Request{Name: "test"})

// Streaming works too!
stream, _ := client.ServerStream(ctx, &pb.Request{})
for {
    msg, err := stream.Recv()
    if err == io.EOF { break }
    fmt.Println(msg)
}
```

**Option B: Raw Invoke (Low-Level)**

For direct control, use `plugin.Invoke` with manual protobuf marshaling:

```go
// Prepare request
req := &pb.MyRequest{Name: "test"}
reqBytes, _ := proto.Marshal(req)

// Call the plugin - errors are automatically parsed
respBytes, err := plugin.Invoke("MyService", "/pkg.MyService/MyMethod", reqBytes)
if err != nil {
    log.Fatal(err)
}

// Unmarshal response
resp := &pb.MyResponse{}
proto.Unmarshal(respBytes, resp)
```

**Under the hood:** The plugin returns `[status:1byte][payload...]` where status=0 is success and status=1 is error. Both `PluginClientConn` and `Invoke` handle this automatically.

#### 5. Optional: Generate Plugin Client (Host Side)
Use `mode=plugin_client` to generate typed clients for the host:

```bash
protoc -Iapi \
    --synurang-ffi_out=./pkg/client \
    --synurang-ffi_opt=mode=plugin_client,services=MyService \
    service.proto
```

This generates `MyServicePluginClient` with typed methods:

```go
// With purego (pure Go, no CGO)
lib, _ := purego.Dlopen("./plugin.so", purego.RTLD_LAZY)
var invoke func(*byte, *byte, int32, *int32) *byte
var free func(*byte)
purego.RegisterLibFunc(&invoke, lib, "Synurang_Invoke_MyService")
purego.RegisterLibFunc(&free, lib, "Synurang_Free")

client := pb.NewMyServicePluginClient(invoke, free)
resp, err := client.MyMethod(ctx, &pb.Request{})
```

---

## 💡 Common Use Cases

### 1. High-Performance Data Processing
Offload heavy computational tasks like image processing, cryptography, or complex data analysis to Go. Go's efficient memory model and goroutines provide superior performance compared to Dart isolates for raw compute.

### 2. Embedded Database Management
Run a robust database engine (like SQLite, DuckDB, or specialized Go-based DBs) entirely within the Go runtime. Your Flutter UI can query data via strictly typed gRPC methods, while Go handles the complex persistence logic, migrations, and concurrency.

### 3. System-Level Integration
Use Go's `cgo` capabilities to interface with legacy C/C++ libraries or OS-specific APIs that might be cumbersome to access directly from Dart. Wrap these interactions in a clean gRPC API for your Flutter frontend.

### 4. Embeddable Libraries
Build libraries that work both as standalone gRPC servers or embedded directly via `FfiClientConn`. See [Go-to-Go FFI](#-go-to-go-ffi-embedded) for details and code examples.

### 5. In-Process Microservices (Proprietary Plugins)
Ship closed-source gRPC services as shared libraries for open-source host applications. See [In-Process Microservice](#-in-process-microservice-shared-library-plugin) for implementation details and code examples.

---

## 🚀 Key Features

*   **⚡ Direct Memory Access**: Request payloads use zero-copy via `unsafe.Slice`; responses are copied once via C malloc. See [Memory Model](#-memory-model).
*   **📡 Full gRPC Support**: Supports Unary, Server Streaming, Client Streaming, and Bidirectional Streaming RPCs.
*   **🔄 Bidirectional Communication**:
    *   **Flutter -> Go**: Standard client calls.
    *   **Go -> Flutter**: Dart acts as a **gRPC Server** via reverse-FFI callbacks, allowing Go to push updates or request UI state.
*   **🔌 Drop-in Replacement**: `FfiClientChannel` (Dart) is a drop-in replacement for standard gRPC `ClientChannel`—use the same generated client code with FFI transport.
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

**Synurang is a bridge library.** You do not run it directly; instead, you integrate it into your own Go and Flutter project.

### Prerequisites

*   **Go** (1.22+)
*   **Flutter** (3.19+)
*   **Protobuf Compiler (`protoc`)**
    *   Linux: `sudo apt install protobuf-compiler`
    *   Mac: `brew install protobuf`
*   **Protoc Plugins:**
    ```bash
    # Go plugins
    go install google.golang.org/protobuf/cmd/protoc-gen-go@latest
    go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@latest
    
    # Synurang plugin (for FFI bindings)
    go install github.com/ivere27/synurang/cmd/protoc-gen-synurang-ffi@latest

    # Dart plugin
    dart pub global activate protoc_plugin

    # Add Go bin to PATH (if not already added)
    export PATH=$PATH:$(go env GOPATH)/bin
    ```

### Step 1: Project Setup

Add `synurang` to your `pubspec.yaml`:

```yaml
dependencies:
  synurang: ^0.1.6
```

Add `synurang` to your Go module:

```bash
go get github.com/ivere27/synurang
```

### Step 2: Define Protocol

Create a `.proto` file (e.g., `api/service.proto`) to define your API.

```protobuf
syntax = "proto3";
package api;

service Greeter {
  rpc SayHello (HelloRequest) returns (HelloReply) {}
}

message HelloRequest {
  string name = 1;
}

message HelloReply {
  string message = 1;
}
```

### Step 3: Generate Code

Generate the Go and Dart code, including the special FFI bindings.

**Tip:** If you haven't installed the `protoc-gen-synurang-ffi` plugin yet, you can build it from source if you have the repository checked out:
```bash
make build_plugin
```
Or ensure it is in your PATH.

```bash
# Create output directories
mkdir -p pkg/api lib/src/generated

# 1. Generate Go gRPC code
protoc -Iapi --go_out=./pkg/api --go_opt=paths=source_relative \
    --go-grpc_out=./pkg/api --go-grpc_opt=paths=source_relative \
    service.proto

# 2. Generate Dart gRPC code
protoc -Iapi --dart_out=grpc:lib/src/generated service.proto

# 3. Generate Synurang FFI Glue Code (Go)
protoc -Iapi --plugin=protoc-gen-synurang-ffi=$(which protoc-gen-synurang-ffi) \
    --synurang-ffi_out=./pkg/api --synurang-ffi_opt=lang=go \
    service.proto

# 4. Generate Synurang FFI Glue Code (Dart)
protoc -Iapi --plugin=protoc-gen-synurang-ffi=$(which protoc-gen-synurang-ffi) \
    --synurang-ffi_out=./lib/src/generated \
    --synurang-ffi_opt=lang=dart,dart_package=my_app \
    service.proto
```

> [!NOTE]
> **Package Imports:** The `dart_package` option is recommended. It ensures generated files use `package:my_app/...` imports instead of relative paths (e.g., `../`). If omitted, relative imports are used by default.

> [!NOTE]
> **Well-Known Types:** The `protoc-gen-synurang-ffi` plugin automatically maps `google/protobuf/*` imports to `package:protobuf/well_known_types/*`. This avoids duplicating well-known types locally and ensures compatibility with the `protobuf` package. If you use other libraries that generate their own `google/protobuf/*.pb.dart` files, you may encounter type conflicts.

### Step 4: Implement Go Service

Implement the server interface in Go.

```go
// pkg/service/greeter.go
package service

import (
    "context"
    "fmt"
    pb "my-app/pkg/api"
)

type GreeterServer struct {
    pb.UnimplementedGreeterServer
}

func (s *GreeterServer) SayHello(ctx context.Context, req *pb.HelloRequest) (*pb.HelloReply, error) {
    return &pb.HelloReply{Message: fmt.Sprintf("Hello, %s!", req.Name)}, nil
}
```

### Step 5: Create Go Entry Point

Create a `main.go` file (e.g., `cmd/server/main.go`). This is the **most critical step**, as it defines the shared library entry point.

**You must import `github.com/ivere27/synurang/src` to export the necessary C symbols.**

```go
package main

import (
	"C" // Required for CGO
	"context"
	
	"github.com/ivere27/synurang/pkg/service"
	// IMPORT THIS TO EXPORT FFI SYMBOLS
	_ "github.com/ivere27/synurang/src" 
	
	pb "my-app/pkg/api"
	myservice "my-app/pkg/service"
	"google.golang.org/grpc"
)

// Init is called by Synurang when the library is loaded
func init() {
	service.RegisterGrpcServer(func(s *grpc.Server) {
		pb.RegisterGreeterServer(s, &myservice.GreeterServer{})
	})
}

func main() {
    // Empty main is required for buildmode=c-shared
}
```

### Step 6: Build Shared Library

Compile your Go code into a C-shared library.

**Project Structure:**
```
my-app/
├── cmd/server/main.go    # Entry point (Step 5)
├── pkg/
│   ├── api/              # Generated proto + FFI bindings
│   └── service/          # Your service implementations
└── api/service.proto     # Protocol definitions
```

**Build Command:**
```bash
CGO_ENABLED=1 go build -trimpath -ldflags "-s -w" \
    -buildmode=c-shared -o libmyapp.so cmd/server/main.go
```

**Flags:**
| Flag | Description |
|------|-------------|
| `CGO_ENABLED=1` | Required for C shared library |
| `-trimpath` | Remove file paths from binary |
| `-ldflags "-s -w"` | Strip debug info (smaller binary) |
| `-buildmode=c-shared` | Output as shared library |

**Cross-Platform:**
See the `synurang` makefile for Android NDK, macOS, and Windows build examples.

### Step 7: Flutter Integration

1.  **Place the Library:**
    *   **Linux:** Place `libmyapp.so` in a location accessible to the runner (or use `LD_LIBRARY_PATH` during dev).
    *   **Android:** Place `.so` files in `android/app/src/main/jniLibs/<arch>/`.

2.  **Initialize & Call:**

```dart
import 'package:synurang/synurang.dart';
import 'src/generated/service_ffi.pb.dart'; // Generated FFI client
import 'src/generated/service.pb.dart';     // Generated messages

void main() async {
  // 1. Load your shared library
  configureSynurang(libraryName: 'myapp', libraryPath: './libmyapp.so');
  
  // 2. Start the embedded server
  await startGrpcServerAsync();

  // 3. Make a call!
  final response = await GreeterFfi.SayHello(HelloRequest(name: "World"));
  print(response.message); // "Hello, World!"
}
```

---

## 🛠 Development Workflow

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

### Go API (`package:synurang/pkg/synurang`)

#### FFI Client Connection (for Embeddable Libraries)

Zero-copy Go-to-Go communication for building libraries that work both as standalone gRPC servers or embedded directly. Supports all RPC patterns.

*   **`NewFfiClientConn(invoker Invoker)`**: Creates an FFI client connection. Implements `grpc.ClientConnInterface`.
*   **`Invoker`**: Interface for dispatching RPC calls (implemented by generated `ffiInvoker`).

```go
// Embedded mode - same process, zero-copy, no network
server := &myservice.GreeterServer{}
conn := api.NewFfiClientConn(server)
client := pb.NewMyServiceClient(conn)

// Same client API works for both embedded and remote
resp, err := client.SayHello(ctx, &pb.HelloRequest{Name: "World"})

// Streaming also works
stream, err := client.StreamMessages(ctx)
stream.Send(&pb.Message{Text: "hello"})
reply, err := stream.Recv()
```

#### Plugin Loader (for Loading Shared Library Plugins)

Load and call plugin shared libraries with automatic error handling. Supports full gRPC semantics including streaming.

*   **`LoadPlugin(path string) (*Plugin, error)`**: Loads a plugin from a `.so`/`.dylib`/`.dll` file.
*   **`NewPluginClientConn(plugin *Plugin, serviceName string) *PluginClientConn`**: Creates a `grpc.ClientConnInterface` for using standard gRPC clients with plugin transport. **Recommended approach.**
*   **`(*Plugin) Invoke(serviceName, method string, data []byte) ([]byte, error)`**: Low-level method call. Handles status byte parsing and error propagation.
*   **`(*Plugin) OpenStream(serviceName, method string) (*PluginStream, error)`**: Opens a streaming RPC to the plugin.
*   **`(*Plugin) Close() error`**: Unloads the plugin.

```go
// Load plugin
plugin, err := synurang.LoadPlugin("./myplugin.so")
if err != nil {
    log.Fatal(err)
}
defer plugin.Close()

// Option 1: gRPC ClientConnInterface (Recommended)
conn := synurang.NewPluginClientConn(plugin, "MyService")
client := pb.NewMyServiceClient(conn)

// Unary call
resp, err := client.MyMethod(ctx, &pb.Request{})

// Server streaming
stream, _ := client.ServerStream(ctx, &pb.Request{})
for {
    msg, err := stream.Recv()
    if err == io.EOF { break }
    // process msg
}

// Option 2: Raw invoke (low-level)
respBytes, err := plugin.Invoke("MyService", "/pkg.MyService/Method", reqBytes)
if err != nil {
    if pluginErr, ok := err.(*synurang.PluginError); ok {
        fmt.Println("Plugin error:", pluginErr.Message)
    }
}
```

## 📂 Directory Structure

```
synurang/
├── api/core.proto           # Core Protocol definitions
├── cmd/
│   ├── server/main.go       # Go main with FFI exports
│   └── protoc-gen-synurang-ffi/  # Code generator plugin
├── example/                 # Example Flutter Application
│   ├── api/example.proto    # Example service definitions
│   ├── cmd/                  # Go CLI tools
│   ├── lib/main.dart        # Flutter Example App
│   └── test/                # Integration tests
├── pkg/
│   ├── api/                 # Generated Go proto + FFI bindings
│   ├── synurang/            # Runtime library
│   │   ├── synurang.go      # FfiClientConn, Invoker interfaces
│   │   ├── plugin.go        # Plugin loader (LoadPlugin, dlopen/dlsym)
│   │   └── plugin_conn.go   # PluginClientConn (grpc.ClientConnInterface)
│   └── service/             # Go service implementations
│       ├── cache.go         # SQLite cache service
│       ├── server.go        # gRPC server setup
│       └── stream_handler.go # FFI stream protocol
├── src/                     # Shared libraries (.so/.dylib output)
├── lib/
│   ├── synurang.dart        # Main Dart entry point (includes FfiClientChannel)
│   └── src/generated/       # Generated Dart proto
├── test/                    # Test suites
│   ├── go_ffi/              # Go-to-Go FFI tests
│   ├── plugin/              # Plugin FFI tests (shared library loading)
│   │   ├── api/             # Generated plugin API
│   │   ├── impl/            # Plugin implementation (builds to .so)
│   │   └── host/            # Host application that loads plugin
│   ├── cpp_ffi/             # C++ FFI tests (experimental)
│   └── rust_ffi/            # Rust FFI tests (experimental)
├── makefile
└── pubspec.yaml
```

---

## ⚖️ License

MIT License. See [LICENSE](LICENSE) for details.
