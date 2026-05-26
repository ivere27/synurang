# Synurang

> gRPC over FFI and IPC

FFI and IPC transport for gRPC. Implements `grpc.ClientConnInterface` — same client code works over FFI, IPC, or network.

```go
// Network gRPC (the usual way)
conn, _ := grpc.Dial("localhost:50051")

// Synurang FFI - source (compiled-in backend)
conn := api.NewMyServiceFfiClientConn(server)

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
- **Android + native plugins**: Load Go/C++/Rust plugins via JNI. Write `.proto`, never touch JNI again.
- **In-process microservices**: Ship proprietary gRPC services as `.so` binaries. No network, no source exposure.
- **Sidecar processes**: Spawn isolated child processes with different privileges or crash isolation.
- **Polyglot backends**: Parent in any language (Go/Dart/C++/Rust/Java/C#) spawns child in any language.
- **Debugging**: Enable TCP/UDS alongside FFI/IPC. Use grpcurl or Postman while app runs.

## Quick start

```bash
# Install the code generator
go install github.com/ivere27/synurang/cmd/protoc-gen-synurang-ffi@latest

# Generate FFI bindings from your .proto
protoc --synurang-ffi_out=. --synurang-ffi_opt=lang=go service.proto

# Generate native C ABI (flattened parameters, no protobuf at call site)
protoc --synurang-ffi_out=. --synurang-ffi_opt=lang=rust,mode=native service.proto
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

### Code Generation Modes

The `mode` parameter controls what kind of code is generated.

| Language | Mode | Output | Description |
|----------|------|--------|-------------|
| go | *(default)* | `_ffi.pb.go` | gRPC FFI client/server bindings |
| dart | *(default)* | `_ffi.pb.dart` | Dart FFI client |
| cpp | *(default)* | `_ffi.h` | C++ FFI host header |
| rust | *(default)* | `_ffi.rs` | Rust FFI host bindings |
| rust | `native` | `_ffi_native.rs` | Flattened C ABI (per-method functions, no protobuf at call site) |
| rust | `wasm` | `_wasm.rs` | WASM exports via `#[wasm_bindgen]` |
| java | *(default)* | `_ffi.java` | Java FFI host bindings |
| csharp | *(default)* | `_ffi.cs` | C# FFI host bindings |
| typescript | *(default)* | `_ffi.ts` + `_lite.ts` | TypeScript FFI client wrapper plus companion protobuf-lite message module when services are generated |
| typescript | `lite` | `_lite.ts` | TypeScript protobuf-lite message classes with binary parse/serialize and JSON output |
| c | `native` | `_ffi_native.h` | C header with flattened per-method signatures |
| c | `activex` | `_activex.h` | COM/ActiveX dispatch header |

The default `plugin_server` mode exports the standard Synurang ABI (`Synurang_Invoke_<Service>(method, bytes, len, &out_len)`) — all data is serialized protobuf, and any Synurang host can load the plugin.

Native and WASM modes generate **per-method functions** with flattened parameters (e.g., `cache_put(store, store_len, key, key_len, value, value_len, ttl, cost)`). Callers pass scalars directly - no protobuf serialization at the call site. This is for direct FFI from C/C++/WASM without the Synurang host infrastructure. Native mode emits `_pb` fallbacks for methods with `repeated`, `oneof`, or `map` fields. WASM mode emits a `_pb` variant for every unary RPC and stream APIs for streaming RPCs (`*_stream_open`, `*_stream_send`, `*_stream_recv`, `*_stream_close_send`, `*_stream_close`).

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
| Java/Android | Go/C++/Rust | ✓ | ✓ | Experimental |
| C# (.NET) | Go/C++/Rust | ✓ | ✓ | Experimental |

### Process Mode (IPC)

Parent spawns child process with gRPC over IPC.

| Host (Parent) | Child | Unix | Windows | Status |
|---------------|-------|------|---------|--------|
| Go | Go/C++/Rust | socketpair | named pipes | Stable |
| Dart | Go/C++/Rust | TCP loopback | TCP loopback | Stable |
| C++ | Go/C++/Rust | socketpair | TCP loopback | Experimental |
| Rust | Go/C++/Rust | socketpair | named pipes | Experimental |
| Java/Android | Go/C++/Rust | socketpair | TCP loopback | Experimental |
| C# (.NET) | Go/C++/Rust | socketpair | named pipes | Experimental |

> **Note:** Java/Android uses socketpair on Unix (requires grpc-okhttp on classpath), TCP loopback otherwise. C# uses socketpair on Unix (with TCP loopback fallback), named pipes on Windows (with TCP loopback fallback). Dart uses TCP loopback on all platforms ([dart-lang/sdk#46196](https://github.com/dart-lang/sdk/issues/46196)). C++ uses TCP loopback on Windows only ([grpc/grpc#13447](https://github.com/grpc/grpc/issues/13447)). For TCP loopback, child must print `SYNURANG_PORT:<port>` to stdout. For named pipes, child must print `SYNURANG_PIPE:<pipename>` to stdout.

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

- **Unix/Linux/macOS/Android**: Uses `socketpair` (Go/C++/Rust/Java) or TCP loopback (Dart).
- **Windows**: Uses Named Pipes (Go/Rust) or TCP loopback (C++/Dart/Java). See [Process Mode table](#process-mode-ipc).

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

Parent can be Go, Dart, C++, Rust, Java, or C#. Child can be **any language** that supports gRPC.

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
protoc -Iapi --synurang-ffi_out=./java/src --synurang-ffi_opt=lang=java,java_package=com.example.api service.proto
protoc -Iapi --synurang-ffi_out=./csharp/src --synurang-ffi_opt=lang=csharp,csharp_namespace=Example.Api service.proto
protoc -Iapi --synurang-ffi_out=./web/src/generated --synurang-ffi_opt=lang=typescript service.proto

# Rust native C ABI (flattened parameters, no protobuf at call site)
protoc -Iapi --synurang-ffi_out=./rust/src --synurang-ffi_opt=lang=rust,mode=native service.proto

# Rust WASM (wasm-bindgen exports)
protoc -Iapi --synurang-ffi_out=./wasm/src --synurang-ffi_opt=lang=rust,mode=wasm service.proto

# C native header (FFI contract for C/C++ plugins)
protoc -Iapi --synurang-ffi_out=./native --synurang-ffi_opt=lang=c,mode=native service.proto
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

### Testing Structured FFI Errors

Structured `FfiError(core.v1.Error)` usage, plugin-side return examples, and end-to-end testing are documented in [FFI-API.md](FFI-API.md).

---

## Features

- Full gRPC semantics: Unary, Server/Client/Bidi Streaming
- Drop-in replacement: Implements `grpc.ClientConnInterface`
- Zero-copy memory via `unsafe.Slice`
- Code generation: `protoc-gen-synurang-ffi`
- Thread-safe: Isolates and goroutines managed automatically
- Platforms: Android, iOS, macOS, Windows, Linux, WebAssembly
- Native C ABI: Per-method functions with flattened parameters (Rust/C, no protobuf at call site)

---

## Experimental

**C++**: `--synurang-ffi_opt=lang=cpp`. Full support including all streaming types.

**Rust**: `--synurang-ffi_opt=lang=rust`. Full support including all streaming types.

**Rust Native**: `--synurang-ffi_opt=lang=rust,mode=native`. Generates per-method C ABI functions with flattened parameters — each scalar field becomes a direct function argument instead of going through serialized protobuf bytes. Methods with `repeated`, `oneof`, or `map` fields get a `_pb` fallback that accepts raw protobuf bytes. Error handling via thread-local `last_error()` (dlerror-style). Unary only.

**Rust WASM**: `--synurang-ffi_opt=lang=rust,mode=wasm`. Generates `#[wasm_bindgen]` exports for browser/JS execution. Same flattened signature convention as native mode with idiomatic Rust types (`&str`, `&[u8]`), plus stream exports for streaming RPCs (`*_stream_open/send/recv/close_send/close`). `*_stream_recv` returns `[status, payload...]` where status is `0=data`, `1=eof`, `2=error`, `3=pending`.

**C Native**: `--synurang-ffi_opt=lang=c` or `--synurang-ffi_opt=lang=c,mode=native`. Generates a C header (`.h`) declaring per-method function signatures with flattened parameters. Companion to Rust native — implement in C/C++ and call directly without protobuf serialization.

**ActiveX**: `--synurang-ffi_opt=lang=c,mode=activex`. Generates a Windows COM/ActiveX dispatch header with DISPID constants, name lookup table, and re-includable dispatch macros. Driven by `(synurang.v1.activex_service)` service option in `.proto` files.

**Java/Android**: `--synurang-ffi_opt=lang=java`. Full support including all streaming types via JNI.

**C# (.NET Framework 4.0+ / .NET Core 3.1+)**: `--synurang-ffi_opt=lang=csharp`. Full support including all streaming types. Pure managed interop — no native bridge required.

**TypeScript**: `--synurang-ffi_opt=lang=typescript`. Generates lightweight TypeScript schema constants plus service FFI client wrappers backed by a `PluginHost` abstraction. For proto files with generated services, the same invocation also emits the companion `_lite.ts` module used for `fromBinary()`/`parseFrom()`, `toBinary()`/`toByteArray()`, and `toJson()` helpers. `--synurang-ffi_opt=lang=typescript,mode=lite` generates only the protobuf-lite message module.

#### C# .NET Version Compatibility

| Target | Plugin (FFI) | CallInvoker (gRPC) | Process (TCP) | Process (named pipe) | Process (socketpair) |
|--------|-------------|-------------------|---------------|---------------------|---------------------|
| .NET Framework 4.0+ | Full | — | — | — | — |
| .NET Core 3.1 | Full | Full | Full | — | — |
| .NET 5.0+ | Full | Full | Full | Full (Windows) | Full (Unix) |

- **.NET Framework 4.0** — Plugin/FFI mode only. Uses `kernel32!LoadLibrary/GetProcAddress` for native loading. Windows XP compatible.
- **.NET Core 3.1** — Full plugin + gRPC support. Uses `NativeLibrary` for native loading. TCP loopback on all platforms.
- **.NET 5.0+** — All features. Named pipes on Windows via `SocketsHttpHandler.ConnectCallback`. Socketpair on Unix.

---

## API Reference

### Dart

#### Lifecycle

```dart
// Start/stop the embedded native core
await startGrpcServerAsync(token: 'xxx', cachePath: '/path/to/cache');
await stopGrpcServerAsync();

// Reusable options object (recommended — also required for recoverCoreAsync)
final opts = StartGrpcServerOptions(
  token: 'xxx',
  cachePath: '/path/to/cache',
);
await startGrpcServerWithOptionsAsync(opts);
```

#### Per-call timeout

The default Dart-side wait for any FFI call is **30 seconds**. A timeout marks the
core unhealthy and cancels every other in-flight request. For calls that may
legitimately exceed 30s (heavy queries, batch ops, blob uploads), pass an
explicit `timeout:`. The backend enforces the deadline first; Dart waits
`timeout + 5s` grace so callers receive a clean `DEADLINE_EXCEEDED` rather than
a `CoreTimeoutException`.

```dart
await invokeBackendAsync(method, data, timeout: Duration(minutes: 5));

// gRPC clients flow through CallOptions.timeout automatically
final stub = MyServiceClient(channel,
    options: CallOptions(timeout: Duration(minutes: 5)));
```

#### Core state & recovery

If the native core hangs (e.g., a Rust deadlock holding a global lock),
`recoverCoreAsync` performs a Dart-side reset plus native `Stop`/`Start`
without reloading the shared library.

| `CoreState` | meaning | accepts RPCs? |
|---|---|---|
| `healthy` | normal operation | yes |
| `unhealthy` | a request timed out; recovery not yet attempted | no |
| `recovering` | recovery is in flight | no |
| `restartRequired` | recovery itself timed out — native lib likely deadlocked | never (sticky) |

```dart
try {
  await client.someRpc(...);
} on CoreTimeoutException {
  final result = await recoverCoreAsync(
    previousStartOptions: opts,
    stopTimeout: Duration(seconds: 2),
    startTimeout: Duration(seconds: 5),
  );

  if (result.recovered) {
    // Re-create gRPC channels / providers as needed
  } else if (result.restartRequired) {
    // Native lib is wedged — process restart is the only remedy
    showRestartRequiredUi();
  } else {
    // result.failed — surface error, retry later if appropriate
  }
}

// Inspect state directly
final state = getCoreState();
```

`recoverCoreAsync` is idempotent under concurrent callers: a second call while
one is in flight returns the same future. The caller owns
`previousStartOptions` — synurang does not cache them. There is **no** automatic
RPC retry: timed-out FFI calls may still complete later natively, and retrying
non-idempotent operations is the caller's choice.

`resetCoreState()` kills helper isolates and fails pending requests/streams but
does **not** unload or reload the shared library. Use it for app-restart-style
cleanup, not for recovery from a native hang.

#### Exceptions

| Exception | When | gRPC mapping |
|---|---|---|
| `CoreTimeoutException` | FFI request exceeded its timeout | `unavailable` |
| `CoreUnavailableException` | RPC issued while `unhealthy` / `recovering` | `unavailable` |
| `CoreRestartRequiredException` | core is in `restartRequired` (or recovery timed out) | `unavailable` |
| `CoreShutdownException` | core was reset under the caller | `unavailable` |

`FfiClientChannel` automatically maps the above to `GrpcError.unavailable`; any
other error → `internal`.

#### Cache API

```dart
await cacheGetRaw(store, key);
await cachePutRaw(store, key, data, ttl);
```

> **Note:** `recoverCoreAsync` only applies to the embedded core (the mode
> activated by `startGrpcServerAsync` — what the Transports table calls
> "FFI (source)"). In plugin mode (`registerPlugin`) there are no `Start`/`Stop`
> symbols to call, so recovery always returns `restartRequired` — a process
> restart is required for native-side hangs.

### Go

```go
// FFI client connection (for embeddable libraries)
conn := api.NewMyServiceFfiClientConn(server)
client := pb.NewMyServiceClient(conn)

// Plugin loader
plugin, _ := synurang.LoadPlugin("./plugin.so")
conn := synurang.NewPluginClientConn(plugin, "MyService")
```

### Java/Android

Four Maven packages — two for Android (AAR), two for desktop (JAR with embedded natives):

| Package | Platform | Contents |
|---------|----------|----------|
| `synurang-android` | Android | Core: PluginHost, ProcessHost, JNI bridge (AAR) |
| `synurang-android-grpc` | Android | SynurangChannel, SynurangClientCall (AAR) |
| `synurang-desktop` | Linux/macOS/Windows | Core + embedded JNI natives for 5 platforms (JAR) |
| `synurang-desktop-grpc` | Linux/macOS/Windows | SynurangChannel, SynurangClientCall (JAR) |

The desktop JAR auto-extracts the native library at runtime — no `-Djava.library.path` needed.

```groovy
// Android (build.gradle)
implementation 'io.github.ivere27:synurang-android:0.6.0'
implementation 'io.github.ivere27:synurang-android-grpc:0.6.0'  // optional, for gRPC channel
implementation 'io.grpc:grpc-api:1.60.0'                        // required if using -grpc

// Desktop (build.gradle)
implementation 'io.github.ivere27:synurang-desktop:0.6.0'
implementation 'io.github.ivere27:synurang-desktop-grpc:0.6.0'  // optional, for gRPC channel
implementation 'io.grpc:grpc-api:1.60.0'                        // required if using -grpc
```

```java
// Low-level API (core only, no gRPC dependency)
PluginHost plugin = PluginHost.load("./libplugin.so");
byte[] resp = plugin.invoke("MyService", "/pkg.MyService/Method", requestBytes);
PluginStream stream = plugin.openStream("MyService", "/pkg.MyService/StreamMethod");

// Process mode — socketpair IPC on Unix, TCP loopback fallback on Windows
ProcessHost proc = ProcessHost.start("./child-process");
ManagedChannel channel = (ManagedChannel) proc.channel();  // socketpair, no TCP

// Plugin mode — drop-in grpc-java Channel (requires synurang-android-grpc)
Channel channel = SynurangChannel.create(plugin, "MyService");
MyServiceGrpc.MyServiceBlockingStub stub = MyServiceGrpc.newBlockingStub(channel);
HelloReply reply = stub.sayHello(request);  // goes through FFI, not TCP

plugin.close();
```

### C# (.NET)

```csharp
// Plugin mode — drop-in gRPC CallInvoker (recommended)
using var plugin = PluginHost.Load("./libplugin.so");
var invoker = new SynurangCallInvoker(plugin, "MyService");

// Standard protoc-gen-grpc-csharp stubs — zero custom codegen
var client = new MyService.MyServiceClient(invoker);
var reply = client.SayHello(request);  // goes through FFI, not TCP

// Process mode — socketpair IPC on Unix, TCP loopback on Windows
using var proc = ProcessHost.Start("./child-process");
var channel = proc.Channel;  // GrpcChannel over socketpair

// Low-level API (when you don't want grpc-dotnet dependency)
byte[] resp = plugin.Invoke("MyService", "/pkg.MyService/Method", requestBytes);
using var stream = plugin.OpenStream("MyService", "/pkg.MyService/StreamMethod");
```

### Android Example
The Kotlin demo in `example/java/android/` showcases:
- **Go Backend**: Standard gRPC services running as a plugin or child process.
- **Rust Media Pipeline**: Zero-copy YUV frame processing via FFI.
- **Native IPC**: High-performance `socketpair` transport (no TCP overhead).

To run the demo:
```bash
make run_android_java
```

---

## Project Structure

```
synurang/
├── cmd/
│   ├── server/main.go                # FFI entry point example
│   └── protoc-gen-synurang-ffi/      # Code generator (go/dart/cpp/rust/java/csharp/typescript/c/wasm/activex)
├── pkg/
│   ├── synurang/                     # Runtime library
│   │   ├── synurang.go               # FfiClientConn
│   │   ├── plugin.go                 # Plugin loader
│   │   └── plugin_conn.go            # PluginClientConn
│   └── service/                      # Server implementation
├── lib/                              # Dart package
│   ├── synurang.dart                 # Main entry point
│   └── src/generated/                # Generated proto
├── java/                             # Java host library (multi-module Gradle)
│   ├── core/                         # Core module: PluginHost, ProcessHost, JNI bridge (zero dependencies)
│   │   ├── src/main/java/            # PluginHost, PluginStream, BidiStream, SynurangJni, etc.
│   │   └── src/main/c/               # JNI native layer
│   └── grpc/                         # gRPC module: SynurangChannel, SynurangClientCall (requires grpc-api)
├── csharp/                           # C# host library (pure managed)
│   └── Synurang/                     # PluginHost, SynurangCallInvoker, ProcessHost
├── example/                          # Working examples
│   ├── go/                           # Go examples
│   │   ├── service/                  # Shared service logic
│   │   ├── process/                  # Process mode entry
│   │   └── plugin/                   # Plugin mode entry
│   ├── cpp/                          # C++ examples
│   │   ├── service/                  # Shared service logic
│   │   ├── process/                  # Process mode entry
│   │   └── plugin/                   # Plugin mode entry
│   ├── rust/                         # Rust examples
│   │   ├── service/                  # Shared service logic
│   │   ├── process/                  # Process mode entry
│   │   └── plugin/                   # Plugin mode entry
│   └── java/                         # Java/Android examples
│       ├── android/                  # Kotlin Android app
│       └── rust-plugin/              # Rust media plugin
└── test/                             # Test suites
```

---

## Low-Level FFI API (No gRPC Dependency)

All 6 host languages can call plugins directly without any gRPC library — just raw protobuf bytes via `invoke()` / `openStream()`. See [`FFI-API.md`](FFI-API.md) for details.

```bash
make test_ffi   # Run all FFI API tests (Go, C++, Rust, Java, Dart, C#)
```

---

## Related

Engine for **Synura**, a content viewer app.

- [Play Store](https://play.google.com/store/apps/details?id=io.tempage.synura)
- [Documentation](https://github.com/tempage/synura)

## License

MIT
