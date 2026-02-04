# Synurang

> gRPC over FFI and IPC

FFI and IPC transport for gRPC. Implements `grpc.ClientConnInterface` — same client code works over FFI, IPC, or network.

```go
// Network gRPC (the usual way)
conn, _ := grpc.Dial("localhost:50051")

// Synurang FFI - source (compiled-in backend)
conn := synurang.NewFfiClientConn(server)

// Synurang FFI - plugin (loaded at runtime)
plugin := synurang.LoadPlugin("./plugin.so")
conn := synurang.NewPluginClientConn(plugin, "MyService")

// Synurang IPC (child process)
conn, _ := synurang.StartProcess(ctx, exec.Command("./child"))

// Same client code works for all!
client := pb.NewGreeterClient(conn)
resp, _ := client.SayHello(ctx, &pb.HelloRequest{Name: "World"})
```

## Use Cases

- **Flutter + Go apps**: Compile Go as a shared library, call via FFI. No separate server process.
- **In-process microservices**: Ship proprietary gRPC services as `.so` binaries. No network, no source exposure.
- **Sidecar processes**: Spawn isolated child processes with different privileges or crash isolation.
- **Polyglot backends**: Parent in any language (Go/Dart/C++/Rust) spawns child in any language.
- **Debugging**: Enable TCP/UDS alongside FFI/IPC. Use grpcurl or Postman while app runs.

## Quick start

```bash
# Install the code generator
go install github.com/ivere27/synurang/cmd/protoc-gen-synurang-ffi@latest

# Generate FFI bindings from your .proto
protoc --synurang-ffi_out=. --synurang-ffi_opt=lang=go service.proto
```

See [Installation & Quick Start](#-installation--quick-start) for the full setup.

---

## How It Works

Synurang implements `grpc.ClientConnInterface`. The gRPC client works unchanged whether messages go over TCP or FFI.

```
┌─────────────────┐                      ┌─────────────────┐
│  Your Client    │                      │  Your Server    │
│                 │                      │                 │
│  gRPC Client    │ ──── Synurang ────►  │  gRPC Server    │
│  (unchanged)    │      (FFI)           │  (unchanged)    │
└─────────────────┘                      └─────────────────┘
```

All four gRPC patterns work: unary, server streaming, client streaming, and bidirectional streaming.

### Transports

| Transport | Description | Use Case |
|-----------|-------------|----------|
| **FFI (source)** | Compile Go into app | Embedded backend |
| **FFI (plugin)** | Load `.so` at runtime | Proprietary / in-process microservices |
| **Process Mode** | Parent-Child IPC | Sidecar processes, isolation, privileges |
| **TCP/UDS** | Standard network gRPC | Debugging, distributed |

FFI and TCP/UDS run simultaneously on the same server.

---

## Language Support

### Plugin Mode (FFI)

Host loads plugin as `.so`/`.dll` via `dlopen`/`LoadLibrary`.

| Host (Parent) | Plugin | Unix | Windows | Status |
|---------------|--------|------|---------|--------|
| Go | Go/C++/Rust | ✓ | Experimental | Stable |
| Dart/Flutter | Go | ✓ | Experimental | Stable |
| C++ | Go/C++/Rust | ✓ | Experimental | Experimental |
| Rust | Go/C++/Rust | ✓ | Experimental | Experimental |

### Process Mode (IPC)

Parent spawns child process with gRPC over IPC.

| Host (Parent) | Child | Unix | Windows | Status |
|---------------|-------|------|---------|--------|
| Go | Go/C++/Rust | socketpair | named pipes | Stable |
| Dart | Go/C++/Rust | TCP loopback | TCP loopback | Stable |
| C++ | Go/C++/Rust | socketpair | TCP loopback | Experimental |
| Rust | Go/C++/Rust | socketpair | named pipes | Experimental |

> **Note:** Dart uses TCP loopback on all platforms ([dart-lang/sdk#46196](https://github.com/dart-lang/sdk/issues/46196)). C++ uses TCP loopback on Windows only ([grpc/grpc#13447](https://github.com/grpc/grpc/issues/13447)). For TCP loopback, child must print `SYNURANG_PORT:<port>` to stdout.

---

## Simultaneous Transports

FFI and TCP/UDS can run at the same time on the same server.

```go
cfg := &service.Config{
    EngineTcpPort:    "50051",               // TCP
    EngineSocketPath: "/tmp/synurang.sock",  // UDS
    // FFI always available
}
```

App uses FFI for performance. Debug via TCP with grpcurl, Postman, or IDE — no restart required.

---

## Flutter + Go Architecture

Flutter handles UI, Go handles logic. Bidirectional communication supported.

```
┌──────────────────────┐          ┌──────────────────────┐
│  Flutter (UI/View)   │          │    Go (Logic/Data)   │
│                      │          │                      │
│  Widget Tree         │          │  Business Logic      │
│       │              │          │       │              │
│  Dart gRPC Client    │──FFI────►│  gRPC Server         │
│  Dart gRPC Server    │◄──FFI────│  gRPC Client         │  (optional)
└──────────────────────┘          └──────────────────────┘
```

- **Dart → Go**: Requests, queries, commands
- **Go → Dart** (optional): Push updates, UI state requests via reverse-FFI callbacks

Benefits:
- **Desktop-first development**: Develop on desktop, deploy to mobile unchanged
- **API-first design**: `.proto` defines the contract between frontend and backend

---

## Plugin System (In-Process Microservices)

Ship proprietary gRPC services as compiled `.so`/`.dll` binaries. Host loads at runtime via `dlopen`. Standard gRPC interface, no network overhead, no source exposure.

```
┌─────────────────────────────────────────┐
│ Host Process                            │
│                                         │
│  ┌──────────┐      ┌──────────────────┐ │
│  │ Host App │ ◄──► │ Plugin (.so)     │ │
│  │          │ gRPC │ [proprietary]    │ │
│  └──────────┘      └──────────────────┘ │
└─────────────────────────────────────────┘
```

**Plugin side:**

```go
package main

import "C"
import pb "my-plugin/pkg/api"

type MyPlugin struct{}

func (s *MyPlugin) DoSomething(ctx context.Context, req *pb.Request) (*pb.Response, error) {
    return &pb.Response{Result: "done"}, nil
}

func init() {
    pb.RegisterMyServicePlugin(&MyPlugin{})
}

func main() {}
```

Build:
```bash
CGO_ENABLED=1 go build -buildmode=c-shared -o plugin.so ./plugin/
```

**Host side:**

```go
plugin, _ := synurang.LoadPlugin("./plugin.so")
defer plugin.Close()

conn := synurang.NewPluginClientConn(plugin, "MyService")
client := pb.NewMyServiceClient(conn)
resp, _ := client.DoSomething(ctx, req)
```

All RPC types supported including streaming.

---

## Process Mode (Parent-Child IPC)

Run gRPC services in a separate child process with a secure, private IPC channel.

> **Note**: Parent process is always the gRPC **client**, child process is the gRPC **server**. The child can be written in any language (Go, C++, Rust, etc.).

- **Unix/Linux/macOS**: Uses `socketpair` (Go/C++/Rust) or TCP loopback (Dart).
- **Windows**: Uses Named Pipes (Go/Rust) or TCP loopback (C++/Dart). See [Process Mode table](#process-mode-ipc).

**Parent Process (Go):**

```go
cmd := exec.Command("./child-process")
conn, err := synurang.StartProcess(ctx, cmd)
if err != nil {
    log.Fatal(err)
}
defer conn.Close()

client := pb.NewMyServiceClient(conn)
resp, _ := client.DoSomething(ctx, req)
```

### Child Process Examples

Parent can be Go, Dart, C++, or Rust. Child can be **any language** that supports gRPC.

**Go Child:**

```go
ln, err := synurang.NewIPCListener()
if err != nil {
    log.Fatal(err)
}

s := grpc.NewServer()
pb.RegisterMyServiceServer(s, &server{})
s.Serve(ln)
```

**C++ Child (Unix - socketpair):**

```cpp
#include <grpcpp/grpcpp.h>
#include <grpcpp/server_posix.h>
#include <cstdlib>

int main() {
    int fd = std::stoi(std::getenv("SYNURANG_IPC"));

    grpc::ServerBuilder builder;
    builder.RegisterService(&service);
    auto server = builder.BuildAndStart();

    // Add the already-connected socketpair fd to the server
    grpc::AddInsecureChannelFromFd(server.get(), fd);

    server->Wait();
}
```

**C++ Child (Windows - TCP loopback):**

```cpp
#include <grpcpp/grpcpp.h>
#include <iostream>

int main() {
    grpc::ServerBuilder builder;
    int selected_port = 0;
    builder.AddListeningPort("127.0.0.1:0",
                             grpc::InsecureServerCredentials(),
                             &selected_port);
    builder.RegisterService(&service);
    auto server = builder.BuildAndStart();

    // Report port to parent (required for Windows)
    std::cout << "SYNURANG_PORT:" << selected_port << std::endl;

    server->Wait();
}
```

**Rust Child (tonic - Unix socketpair):**

```rust
use std::os::unix::io::FromRawFd;
use tonic::transport::Server;
use tokio::net::UnixStream;

#[tokio::main]
async fn main() {
    let fd: i32 = std::env::var("SYNURANG_IPC").unwrap().parse().unwrap();

    // socketpair gives us an already-connected stream, not a listener
    let std_stream = unsafe { std::os::unix::net::UnixStream::from_raw_fd(fd) };
    std_stream.set_nonblocking(true).unwrap();
    let stream = UnixStream::from_std(std_stream).unwrap();

    Server::builder()
        .add_service(MyServiceServer::new(MyService::default()))
        .serve_with_incoming(futures::stream::once(async { Ok::<_, std::io::Error>(stream) }))
        .await
        .unwrap();
}
```

### Benefits

- `StartProcess` returns a standard `*grpc.ClientConn`
- `NewIPCListener` returns a standard `net.Listener`
- Child process language is transparent to parent
- No network configuration required

---

## Memory Model

| Direction | Zero-copy | Mechanism |
|-----------|-----------|-----------|
| Request (Dart → Go) | Yes | `unsafe.Slice` |
| Response (Go → Dart) | Yes | `C.malloc` + `FreeFfiData` |
| Streaming | Configurable | Safe (1 copy) or zero-copy |

C++ and Rust backends: zero-copy in both directions.

---

## 📦 Installation & Quick Start

### Prerequisites

- **Go** 1.22+
- **Flutter** 3.19+ (if using Flutter)
- **protoc** (protobuf compiler)

```bash
# Install protoc plugins
go install google.golang.org/protobuf/cmd/protoc-gen-go@latest
go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@latest
go install github.com/ivere27/synurang/cmd/protoc-gen-synurang-ffi@latest

# For Dart
dart pub global activate protoc_plugin

# For C++ (Process Mode)
sudo apt-get install protobuf-compiler-grpc
```

### Step 1: Define API

```protobuf
// api/service.proto
syntax = "proto3";
package api;

service Greeter {
  rpc SayHello (HelloRequest) returns (HelloReply) {}
}

message HelloRequest { string name = 1; }
message HelloReply { string message = 1; }
```

### Step 2: Generate Code

```bash
# Go gRPC
protoc -Iapi --go_out=./pkg/api --go_opt=paths=source_relative \
    --go-grpc_out=./pkg/api --go-grpc_opt=paths=source_relative \
    service.proto

# Dart gRPC
protoc -Iapi --dart_out=grpc:lib/src/generated service.proto

# Synurang FFI bindings
protoc -Iapi --synurang-ffi_out=./pkg/api --synurang-ffi_opt=lang=go service.proto
protoc -Iapi --synurang-ffi_out=./lib/src/generated --synurang-ffi_opt=lang=dart service.proto
```

### Step 3: Implement Server

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

### Step 4: FFI Entry Point

```go
// cmd/server/main.go
package main

import "C"
import (
    "github.com/ivere27/synurang/pkg/service"
    _ "github.com/ivere27/synurang/src"  // Exports FFI symbols

    pb "my-app/pkg/api"
    myservice "my-app/pkg/service"
    "google.golang.org/grpc"
)

func init() {
    service.RegisterGrpcServer(func(s *grpc.Server) {
        pb.RegisterGreeterServer(s, &myservice.GreeterServer{})
    })
}

func main() {}
```

### Step 5: Build Shared Library

```bash
CGO_ENABLED=1 go build -buildmode=c-shared -o libmyapp.so cmd/server/main.go
```

### Step 6: Call from Dart

```dart
import 'package:synurang/synurang.dart';
import 'src/generated/service_ffi.pb.dart';
import 'src/generated/service.pb.dart';

void main() async {
  configureSynurang(libraryPath: './libmyapp.so');
  await startGrpcServerAsync();

  final response = await GreeterFfi.SayHello(HelloRequest(name: "World"));
  print(response.message);  // "Hello, World!"
}
```

---

## Testing Transports

```bash
# FFI
dart run example/console_main.dart

# TCP
dart run example/console_main.dart --mode=tcp --port=18000

# UDS
dart run example/console_main.dart --mode=uds --socket=/tmp/synurang.sock

# grpcurl
grpcurl -plaintext localhost:18000 api.Greeter/SayHello
```

---

## Features

- Full gRPC semantics: Unary, Server/Client/Bidi Streaming
- Drop-in replacement: Implements `grpc.ClientConnInterface`
- Zero-copy memory via `unsafe.Slice`
- Code generation: `protoc-gen-synurang-ffi`
- Thread-safe: Isolates and goroutines managed automatically
- Platforms: Android, iOS, macOS, Windows, Linux

---

## Experimental

**C++**: `--synurang-ffi_opt=lang=cpp`. Full support including all streaming types.

**Rust**: `--synurang-ffi_opt=lang=rust`. Full support including all streaming types.

---

## API Reference

### Dart

```dart
// Start/stop the embedded server
await startGrpcServerAsync();
await stopGrpcServerAsync();

// Cache API (Go-managed SQLite)
await cacheGetRaw(store, key);
await cachePutRaw(store, key, data, ttl);
```

### Go

```go
// FFI client connection (for embeddable libraries)
conn := api.NewFfiClientConn(server)
client := pb.NewMyServiceClient(conn)

// Plugin loader
plugin, _ := synurang.LoadPlugin("./plugin.so")
conn := synurang.NewPluginClientConn(plugin, "MyService")
```

---

## Project Structure

```
synurang/
├── cmd/
│   ├── server/main.go                # FFI entry point example
│   └── protoc-gen-synurang-ffi/      # Code generator
├── pkg/
│   ├── synurang/                     # Runtime library
│   │   ├── synurang.go               # FfiClientConn
│   │   ├── plugin.go                 # Plugin loader
│   │   └── plugin_conn.go            # PluginClientConn
│   └── service/                      # Server implementation
├── lib/                              # Dart package
│   ├── synurang.dart                 # Main entry point
│   └── src/generated/                # Generated proto
├── example/                          # Working examples
│   ├── go/                           # Go examples
│   │   ├── service/                  # Shared service logic
│   │   ├── process/                  # Process mode entry
│   │   └── plugin/                   # Plugin mode entry
│   ├── cpp/                          # C++ examples
│   │   ├── service/                  # Shared service logic
│   │   ├── process/                  # Process mode entry
│   │   └── plugin/                   # Plugin mode entry
│   └── rust/                         # Rust examples
│       ├── service/                  # Shared service logic
│       ├── process/                  # Process mode entry
│       └── plugin/                   # Plugin mode entry
└── test/                             # Test suites
```

---

## Related

Engine for **Synura**, a content viewer app.

- [Play Store](https://play.google.com/store/apps/details?id=io.tempage.synura)
- [Documentation](https://github.com/tempage/synura)

## License

MIT
