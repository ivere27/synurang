# Synurang

> gRPC over FFI

FFI transport for gRPC. Implements `grpc.ClientConnInterface` — same client code works over FFI or network.

```go
// Network gRPC (the usual way)
conn, _ := grpc.Dial("localhost:50051")

// Synurang FFI (in-process, zero latency)
conn := synurang.NewFfiClientConn(server)

// Same client code works for both!
client := pb.NewGreeterClient(conn)
resp, _ := client.SayHello(ctx, &pb.HelloRequest{Name: "World"})
```

## Use Cases

- **Flutter + Go apps**: Compile Go as a shared library, call via FFI. No separate server process.
- **In-process microservices**: Ship proprietary gRPC services as `.so` binaries. No network, no source exposure.
- **Debugging**: Enable TCP/UDS alongside FFI. Use grpcurl or Postman while app runs via FFI.

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
| **TCP/UDS** | Standard network gRPC | Debugging, distributed |

All three run simultaneously on the same server.

---

## Language Support

| Client | Server | Status |
|--------|--------|--------|
| Go | Go | Stable |
| Dart/Flutter | Go | Stable |
| Go | Plugin (.so) | Stable |
| Dart | C++ | Experimental |
| Dart | Rust | Experimental |

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

**C++**: `--synurang-ffi_opt=lang=cpp`. Unary only, streaming not implemented.

**Rust**: `--synurang-ffi_opt=lang=rust`. Partial support.

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
└── test/                             # Test suites
```

---

## Related

Engine for **Synura**, a content viewer app.

- [Play Store](https://play.google.com/store/apps/details?id=io.tempage.synura)
- [Documentation](https://github.com/tempage/synura)

## License

MIT
