# Low-Level FFI API

This document covers using Synurang plugins through the low-level FFI/plugin boundary with raw protobuf bytes instead of generated gRPC stubs and channels. In FFI mode, the goal is minimal dependency: protobuf (or protobuf-lite) plus the host loader/stream API for your language.

The FFI wire format itself is protobuf-only. Some language packages still bundle gRPC/process helpers in the same artifact today, but the FFI call path shown here does not require gRPC APIs.

## When to use this

- Smaller binary size (no gRPC runtime)
- Fewer dependencies
- Embedded or constrained environments
- Full control over serialization

## Two approaches

| Approach | What you get | Marshalling |
|----------|-------------|-------------|
| **Codegen** (`protoc-gen-synurang-ffi`) | Typed client classes with methods matching your `.proto` | Automatic |
| **Manual** (raw bytes) | Direct `invoke()` / `openStream()` calls on the plugin host | You call `proto.Marshal` / `parseFrom` yourself |

Both skip generated gRPC stubs and channels in the actual call path. The codegen approach is recommended unless you need custom serialization or want to avoid the codegen step.

The canonical `protoc-gen-synurang-ffi` executable is implemented in Rust.
The `lang` option selects its output language; for example, `lang=go` still
generates Go bindings and does not select a Go implementation of the generator.

---

## Go

### Dependencies

```
# Required
google.golang.org/protobuf   # proto.Marshal / proto.Unmarshal

# Optional compatibility only
# google.golang.org/grpc     # low-level host calls do not need it
```

### With codegen

Generate:

```sh
protoc --synurang-ffi_out=. --synurang-ffi_opt=lang=go your_service.proto
```

This produces a `*PluginClient` per service with typed methods:

```go
import "github.com/ebitengine/purego"

lib, _ := purego.Dlopen("./libmyplugin.so", purego.RTLD_LAZY)

var invoke func(*byte, *byte, int32, *int32) *byte
var free   func(*byte)
purego.RegisterLibFunc(&invoke, lib, "Synurang_Invoke_Greeter")
purego.RegisterLibFunc(&free, lib, "Synurang_Free")

client := NewGreeterPluginClient(invoke, free)

// Unary - fully typed, marshalling handled internally
resp, err := client.SayHello(ctx, &pb.HelloRequest{Name: "World"})
fmt.Println(resp.Message)
```

> **Note:** The generated Go plugin client currently supports unary RPCs only. For streaming, use the manual approach below with the `synurang` host package.

### Manual (raw bytes)

Load a plugin and call methods directly using the `synurang` host package:

```go
import "github.com/ivere27/synurang/pkg/synurang"

plugin, err := synurang.LoadPlugin("./libmyplugin.so")
if err != nil {
    log.Fatal(err)
}
defer plugin.Close()
```

#### Unary

```go
reqBytes, _ := proto.Marshal(&pb.HelloRequest{Name: "World"})
respBytes, err := plugin.Invoke("Greeter", "/mypackage.Greeter/SayHello", reqBytes)
if err != nil {
    log.Fatal(err) // includes FfiError for application errors
}
resp := &pb.HelloReply{}
proto.Unmarshal(respBytes, resp)
```

#### Server streaming

```go
stream, err := plugin.OpenStream("Greeter", "/mypackage.Greeter/ListItems")
if err != nil {
    log.Fatal(err)
}
defer stream.Close()

// Send the request
reqBytes, _ := proto.Marshal(&pb.ListRequest{})
stream.Send(reqBytes)
stream.CloseSend()

// Receive responses
for {
    data, err := stream.Recv()
    if err == io.EOF {
        break
    }
    if err != nil {
        log.Fatal(err)
    }
    item := &pb.Item{}
    proto.Unmarshal(data, item)
    fmt.Println(item)
}
```

#### Client streaming

```go
stream, err := plugin.OpenStream("Greeter", "/mypackage.Greeter/Upload")
if err != nil {
    log.Fatal(err)
}
defer stream.Close()

// Send multiple requests
for _, chunk := range chunks {
    data, _ := proto.Marshal(chunk)
    stream.Send(data)
}
stream.CloseSend()

// Receive single response
respBytes, err := stream.Recv()
if err != nil {
    log.Fatal(err)
}
resp := &pb.UploadResponse{}
proto.Unmarshal(respBytes, resp)
```

#### Bidirectional streaming

```go
stream, err := plugin.OpenStream("Greeter", "/mypackage.Greeter/Chat")
if err != nil {
    log.Fatal(err)
}
defer stream.Close()

// Send in a goroutine
go func() {
    for _, msg := range messages {
        data, _ := proto.Marshal(msg)
        stream.Send(data)
    }
    stream.CloseSend()
}()

// Receive concurrently
for {
    data, err := stream.Recv()
    if err == io.EOF {
        break
    }
    if err != nil {
        log.Fatal(err)
    }
    reply := &pb.ChatMessage{}
    proto.Unmarshal(data, reply)
    fmt.Println(reply)
}
```

---

## Dart

### Dependencies

```yaml
dependencies:
  synurang: ...          # FFI host library; current package also bundles grpc-based process/stub helpers
  protobuf: ...          # writeToBuffer / fromBuffer
```

Your FFI/plugin code only needs protobuf bytes. You do not need to use grpc APIs in the call path shown below.

### With codegen

Generate:

```sh
protoc --synurang-ffi_out=. --synurang-ffi_opt=lang=dart your_service.proto
```

This produces a `*Ffi` class per service with static methods for all 4 RPC types:

```dart
// Unary
final resp = await GreeterFfi.sayHello(HelloRequest(name: 'World'));
print(resp.message);

// Server streaming
final stream = GreeterFfi.listItems(ListRequest());
await for (final item in stream) {
  print(item);
}

// Client streaming
final resp = await GreeterFfi.upload(
  Stream.fromIterable(chunks.map((c) => UploadChunk(data: c))),
);

// Bidi streaming
final replies = GreeterFfi.chat(
  Stream.fromIterable(messages.map((m) => ChatMessage(text: m))),
);
await for (final reply in replies) {
  print(reply);
}
```

### Manual (raw bytes)

The `synurang` Dart package exposes top-level functions. No plugin loading step is needed -- the native library is loaded automatically via `DynamicLibrary.open`.

#### Unary

```dart
import 'package:synurang/synurang.dart' as synurang;

final reqBytes = HelloRequest(name: 'World').writeToBuffer();
final respBytes = await synurang.invokeBackendAsync(
    '/mypackage.Greeter/SayHello', reqBytes);
final resp = HelloReply.fromBuffer(respBytes);
```

#### Server streaming

```dart
final reqBytes = ListRequest().writeToBuffer();
final stream = synurang.invokeBackendServerStream(
    '/mypackage.Greeter/ListItems', reqBytes);

await for (final data in stream) {
  final item = Item.fromBuffer(data);
  print(item);
}
```

#### Client streaming

```dart
final dataStream = Stream.fromIterable(
  chunks.map((c) => UploadChunk(data: c).writeToBuffer()),
);
final respBytes = await synurang.invokeBackendClientStream(
    '/mypackage.Greeter/Upload', dataStream);
final resp = UploadResponse.fromBuffer(respBytes);
```

#### Bidirectional streaming

```dart
final inputStream = Stream.fromIterable(
  messages.map((m) => ChatMessage(text: m).writeToBuffer()),
);
final outputStream = synurang.invokeBackendBidiStream(
    '/mypackage.Greeter/Chat', inputStream);

await for (final data in outputStream) {
  final reply = ChatMessage.fromBuffer(data);
  print(reply);
}
```

---

## C++

### Dependencies

```
# Required
protobuf             # SerializeToString / ParseFromString

# NOT required
grpc++               # only needed for the gRPC-stub path
```

### With codegen

Generate:

```sh
protoc --synurang-ffi_out=. --synurang-ffi_opt=lang=cpp your_service.proto
```

This produces an `FfiServer` interface (for implementing plugins) and a `*FfiClient` class (for calling them). The generated client works with the `PluginHost` from `<synurang/plugin_host.hpp>`:

```cpp
#include <synurang/plugin_host.hpp>
#include "your_service_ffi.h"

auto plugin = synurang::PluginHost::load("./libmyplugin.so");

// The generated FfiClient wraps invoke calls with typed marshal/unmarshal
mypackage::GreeterFfiClient client(&plugin);

mypackage::HelloRequest req;
req.set_name("World");

mypackage::HelloReply resp;
if (client.SayHello(req, &resp)) {
    std::cout << resp.message() << std::endl;
}
```

### Manual (raw bytes)

```cpp
#include <synurang/plugin_host.hpp>

auto plugin = synurang::PluginHost::load("./libmyplugin.so");
// plugin.close() is called automatically by the destructor
```

#### Unary

```cpp
mypackage::HelloRequest req;
req.set_name("World");

std::string data;
req.SerializeToString(&data);
std::vector<uint8_t> req_bytes(data.begin(), data.end());

auto resp_bytes = plugin.invoke("Greeter", "/mypackage.Greeter/SayHello", req_bytes);

mypackage::HelloReply resp;
resp.ParseFromArray(resp_bytes.data(), resp_bytes.size());
std::cout << resp.message() << std::endl;
```

#### Server streaming

```cpp
auto stream = plugin.open_stream("Greeter", "/mypackage.Greeter/ListItems");

// Send request
mypackage::ListRequest req;
std::string data;
req.SerializeToString(&data);
stream->send(std::vector<uint8_t>(data.begin(), data.end()));
stream->close_send();

// Receive responses
bool eof = false;
while (!eof) {
    auto resp_bytes = stream->recv(eof);
    if (!eof) {
        mypackage::Item item;
        item.ParseFromArray(resp_bytes.data(), resp_bytes.size());
        std::cout << item.name() << std::endl;
    }
}
stream->close();
```

#### Client streaming

```cpp
auto stream = plugin.open_stream("Greeter", "/mypackage.Greeter/Upload");

// Send multiple requests
for (const auto& chunk : chunks) {
    std::string data;
    chunk.SerializeToString(&data);
    stream->send(std::vector<uint8_t>(data.begin(), data.end()));
}
stream->close_send();

// Receive single response
bool eof = false;
auto resp_bytes = stream->recv(eof);
mypackage::UploadResponse resp;
resp.ParseFromArray(resp_bytes.data(), resp_bytes.size());
stream->close();
```

#### Bidirectional streaming

```cpp
auto stream = plugin.open_stream("Greeter", "/mypackage.Greeter/Chat");

// In practice, send and recv on separate threads:

// Send thread
std::thread sender([&stream, &messages]() {
    for (const auto& msg : messages) {
        std::string data;
        msg.SerializeToString(&data);
        stream->send(std::vector<uint8_t>(data.begin(), data.end()));
    }
    stream->close_send();
});

// Recv on current thread
bool eof = false;
while (!eof) {
    auto resp_bytes = stream->recv(eof);
    if (!eof) {
        mypackage::ChatMessage reply;
        reply.ParseFromArray(resp_bytes.data(), resp_bytes.size());
        std::cout << reply.text() << std::endl;
    }
}

sender.join();
stream->close();
```

---

## Rust

### Dependencies

```toml
[dependencies]
synurang-host = { ... }   # PluginHost, PluginStream
prost = "0.12"            # encode_to_vec / decode
```

The low-level `PluginHost` / `PluginStream` / `FfiError` path is protobuf-only. The current crate also bundles tonic-based process helpers in the same artifact.

### With codegen

Generate:

```sh
protoc --synurang-ffi_out=. --synurang-ffi_opt=lang=rust your_service.proto
```

This produces an `FfiServer` trait (for implementing plugins) and a `*FfiClient` struct (for calling them):

```rust
use std::sync::Arc;

let server: Arc<dyn FfiServer> = /* your implementation */;
let client = GreeterFfiClient::new(server);

let req = HelloRequest { name: "World".into() };
let resp = client.say_hello(&req)?;
println!("{}", resp.message);
```

### Manual (raw bytes)

```rust
use synurang_host::PluginHost;
use prost::Message;

let plugin = PluginHost::load("./libmyplugin.so")?;
// plugin is closed on Drop
```

#### Unary

```rust
let req = HelloRequest { name: "World".into() };
let req_bytes = req.encode_to_vec();

let resp_bytes = plugin.invoke("Greeter", "/mypackage.Greeter/SayHello", &req_bytes)?;

let resp = HelloReply::decode(resp_bytes.as_slice())?;
println!("{}", resp.message);
```

#### Server streaming

```rust
let mut stream = plugin.open_stream("Greeter", "/mypackage.Greeter/ListItems")?;

// Send request
let req = ListRequest {};
stream.send(&req.encode_to_vec())?;
stream.close_send();

// Receive responses
loop {
    match stream.recv() {
        Ok(data) => {
            let item = Item::decode(data.as_slice())?;
            println!("{}", item.name);
        }
        Err(synurang_host::Error::Eof) => break,
        Err(e) => return Err(e.into()),
    }
}
stream.close();
```

#### Client streaming

```rust
let mut stream = plugin.open_stream("Greeter", "/mypackage.Greeter/Upload")?;

// Send multiple requests
for chunk in &chunks {
    stream.send(&chunk.encode_to_vec())?;
}
stream.close_send();

// Receive single response
let resp_bytes = stream.recv()?;
let resp = UploadResponse::decode(resp_bytes.as_slice())?;
stream.close();
```

#### Bidirectional streaming

> **Note:** `PluginStream` uses a single mutex for both `send()` and `recv()`, so concurrent send+recv from different threads will deadlock. Use a sequential send-then-recv pattern instead:

```rust
let stream = plugin.open_stream("Greeter", "/mypackage.Greeter/Chat")?;

// Send all messages first
for msg in &messages {
    stream.send(&msg.encode_to_vec())?;
}
stream.close_send();

// Then receive all responses
loop {
    match stream.recv() {
        Ok(data) => {
            let reply = ChatMessage::decode(data.as_slice())?;
            println!("{}", reply.text);
        }
        Err(synurang_host::Error::Eof) => break,
        Err(e) => return Err(e.into()),
    }
}
```

---

## Java

### Dependencies

```groovy
dependencies {
    implementation 'io.github.ivere27:synurang:...'   // PluginHost, PluginStream
    implementation 'com.google.protobuf:protobuf-java:3.25+'  // toByteArray / parseFrom

    // NOT required:
    // implementation 'io.grpc:grpc-stub:...'   // only needed for the gRPC-stub path
}
```

The `synurang` Java library declares `grpc-api` as `compileOnly` -- it is not pulled in at runtime unless you use the gRPC path.

### With codegen

Generate:

```sh
protoc --synurang-ffi_out=. --synurang-ffi_opt=lang=java \
       --synurang-ffi_opt=java_package=com.example your_service.proto
```

This produces a `*Ffi` class per service with typed methods for all 4 RPC types:

```java
try (PluginHost plugin = PluginHost.load("./libmyplugin.so")) {
    GreeterFfi greeter = new GreeterFfi(plugin);

    // Unary
    HelloReply resp = greeter.sayHello(HelloRequest.newBuilder()
            .setName("World").build());
    System.out.println(resp.getMessage());

    // Server streaming - returns Iterator
    Iterator<Item> items = greeter.listItems(ListRequest.getDefaultInstance());
    while (items.hasNext()) {
        System.out.println(items.next());
    }

    // Client streaming - takes Iterator
    List<UploadChunk> chunks = ...;
    UploadResponse uploadResp = greeter.upload(chunks.iterator());

    // Bidi streaming - returns BidiStream
    BidiStream<ChatMessage, ChatMessage> chat = greeter.chat();
    chat.send(ChatMessage.newBuilder().setText("Hello").build());
    chat.closeSend();
    Iterator<ChatMessage> replies = chat.responses();
    while (replies.hasNext()) {
        System.out.println(replies.next().getText());
    }
    chat.close();
}
```

### Manual (raw bytes)

```java
import io.github.ivere27.synurang.PluginHost;
import io.github.ivere27.synurang.PluginStream;

try (PluginHost plugin = PluginHost.load("./libmyplugin.so")) {
    // ...
}
```

#### Unary

```java
byte[] reqBytes = HelloRequest.newBuilder()
        .setName("World")
        .build()
        .toByteArray();

byte[] respBytes = plugin.invoke("Greeter", "/mypackage.Greeter/SayHello", reqBytes);

HelloReply resp = HelloReply.parseFrom(respBytes);
System.out.println(resp.getMessage());
```

#### Server streaming

```java
PluginStream stream = plugin.openStream("Greeter", "/mypackage.Greeter/ListItems");

// Send request
stream.send(ListRequest.getDefaultInstance().toByteArray());
stream.closeSend();

// Receive responses
byte[] data;
while ((data = stream.recv()) != null) {
    Item item = Item.parseFrom(data);
    System.out.println(item.getName());
}
stream.close();
```

#### Client streaming

```java
PluginStream stream = plugin.openStream("Greeter", "/mypackage.Greeter/Upload");

// Send multiple requests
for (UploadChunk chunk : chunks) {
    stream.send(chunk.toByteArray());
}
stream.closeSend();

// Receive single response
byte[] respBytes = stream.recv();
UploadResponse resp = UploadResponse.parseFrom(respBytes);
stream.close();
```

#### Bidirectional streaming

```java
PluginStream stream = plugin.openStream("Greeter", "/mypackage.Greeter/Chat");

// Send in a separate thread
Thread sender = new Thread(() -> {
    try {
        for (ChatMessage msg : messages) {
            stream.send(msg.toByteArray());
        }
        stream.closeSend();
    } catch (FfiError e) {
        e.printStackTrace();
    }
});
sender.start();

// Receive on current thread
byte[] data;
while ((data = stream.recv()) != null) {
    ChatMessage reply = ChatMessage.parseFrom(data);
    System.out.println(reply.getText());
}

sender.join();
stream.close();
```

---

## Python (3.10+)

Python 2 is not supported. The Python package provides transport-neutral
clients, an in-process plugin/FFI host, and an optional remote gRPC transport;
it does not currently provide a Python plugin server or process host. Its core
`ctypes` runtime and generated protobuf-lite messages use only the Python
standard library. Python message generation currently targets proto3 schemas.

### Dependencies

From a Synurang checkout:

```sh
python3 -m pip install ./python
```

### With codegen

Generate both dependency-free protobuf-lite messages and the Synurang client:

```sh
protoc --synurang-ffi_out=. --synurang-ffi_opt=lang=python \
       your_service.proto
```

This emits `your_service_lite.py` and `your_service_ffi.py`; neither
`protoc --python_out` nor `google.protobuf` is required. The generated
`*Client` class exposes typed, snake-case methods for all four RPC styles over
any `RpcTransport`. `*Ffi` remains as a compatibility wrapper:

```python
import your_service_lite as pb
from synurang import FfiTransport, PluginHost
from your_service_ffi import GreeterClient, GreeterFfi

with PluginHost.load("./libmyplugin.so") as plugin:
    # Existing API
    greeter = GreeterFfi(plugin)

    # Equivalent neutral-transport API
    greeter = GreeterClient(FfiTransport(plugin))

    # Unary
    reply = greeter.say_hello(pb.HelloRequest(name="World"))

    # Server streaming: request -> Iterator[response]
    for item in greeter.list_items(pb.ListRequest()):
        print(item)

    # Client streaming: Iterable[request] -> response
    upload_reply = greeter.upload(iter(chunks))

    # Bidirectional streaming: explicit typed send/receive stream
    with greeter.chat() as chat:
        for message in messages:
            chat.send(message)
        chat.close_send()
        for reply in chat.responses():
            print(reply)
```

`lang=py` is an alias for `lang=python`. Add `mode=lite` to emit only the
message module.

### Remote gRPC with the same client

Remote transport is an optional dependency; generated messages remain
dependency-free and do not use `google.protobuf` or `grpcio-tools`:

```sh
python3 -m pip install './python[grpc]'
```

```python
import your_service_lite as pb
from synurang import GrpcTransport
from your_service_ffi import GreeterClient

with GrpcTransport.insecure_channel("127.0.0.1:50051") as transport:
    greeter = GreeterClient(transport)
    reply = greeter.say_hello(
        pb.HelloRequest(name="World"),
        timeout=5.0,
        metadata=(("x-request-id", "example"),),
    )
```

`GrpcTransport` uses synchronous `grpcio` and supports unary, server-streaming,
client-streaming, and bidirectional-streaming methods. Remote failures remain
native `grpc.RpcError` values; plugin failures remain `FfiError` values. The
generated keyword-only `timeout` and `metadata` arguments are forwarded to the
transport; the current native plugin ABI carries neither, so `FfiTransport`
rejects non-default values instead of silently ignoring them.

### Manual (raw bytes)

`PluginHost.invoke()` and `PluginHost.open_stream()` accept the service's short
name, the full protobuf method path, and serialized message bytes. A stream's
`recv()` returns `None` at EOF.

```python
import your_service_lite as pb
from synurang import PluginHost

with PluginHost.load("./libmyplugin.so") as plugin:
    # Unary
    data = plugin.invoke(
        "Greeter",
        "/mypackage.Greeter/SayHello",
        pb.HelloRequest(name="World").SerializeToString(),
    )
    reply = pb.HelloReply.FromString(data)

    # Server streaming
    with plugin.open_stream(
        "Greeter", "/mypackage.Greeter/ListItems"
    ) as stream:
        stream.send(pb.ListRequest().SerializeToString())
        stream.close_send()
        while (data := stream.recv()) is not None:
            print(pb.Item.FromString(data))

    # Client streaming
    with plugin.open_stream(
        "Greeter", "/mypackage.Greeter/Upload"
    ) as stream:
        for chunk in chunks:
            stream.send(chunk.SerializeToString())
        stream.close_send()
        data = stream.recv()
        if data is None:
            raise RuntimeError("upload returned no response")
        upload_reply = pb.UploadResponse.FromString(data)

    # Bidirectional streaming
    with plugin.open_stream(
        "Greeter", "/mypackage.Greeter/Chat"
    ) as stream:
        for message in messages:
            stream.send(message.SerializeToString())
        stream.close_send()
        while (data := stream.recv()) is not None:
            print(pb.ChatMessage.FromString(data))
```

---

## C

The C generator has two primary forms:

```sh
# Complete binding: messages plus service/plugin implementation
protoc --synurang-ffi_out=. --synurang-ffi_opt=lang=c \
       your_service.proto

# Messages and enums only
protoc --synurang-ffi_out=. --synurang-ffi_opt=lang=c,mode=lite \
       your_service.proto
```

For `api/your_service.proto`, the complete form emits source-relative files:

```text
api/your_service_lite.h
api/your_service_lite.c
api/your_service_ffi.h
api/your_service_ffi.c
```

A proto file without a selected service emits only its lite files. The
complete binding has one public include:

```c
#include "api/your_service_ffi.h"
```

That header includes the generated lite messages and
`<synurang/c_runtime.h>`. It declares the flattened unary call functions,
typed implementation handlers, typed streaming helpers, and the standard raw
plugin ABI. The generated `.c` file supplies the adapters. Link it with the
lite sources and `src/c_runtime.c`; no protobuf or gRPC C runtime is required.

`lang=c,mode=native` is accepted as a deprecated compatibility alias for the
complete form. It emits the same `_lite.*` and `_ffi.*` files; the old
`_ffi_native*` and separate server-header layout is not generated.

### Typed service implementation

For a `GreeterService` with unary `SayHello` and bidirectional `Chat` methods,
the generated contract follows this shape (exact message names come from the
proto package):

```c
static int say_hello(
    const ExampleHelloRequest* request,
    ExampleHelloReply* response,
    void* service_user_data) {
    /* request is borrowed; response is initialized and owned by the adapter. */
    return 0;
}

static void* chat_open(
    GreeterServiceChatStream stream,
    void* service_user_data) {
    /* Allocate or select state for this stream. This example borrows the
       shared service state; returning it does not transfer its ownership. */
    return service_user_data;
}

static void chat_message(
    GreeterServiceChatStream stream,
    const ExampleChatRequest* message,
    void* stream_user_data) {
    ExampleChatReply reply;
    example_chat_reply_init(&reply);
    /* Fill reply using its allocator. */
    if (greeter_chat_send(stream, &reply) == SYNURANG_WOULD_BLOCK) {
        /* Retain the logical reply and retry after on_writable. */
    }
    example_chat_reply_free(&reply);
}

static void chat_half_close(
    GreeterServiceChatStream stream,
    void* stream_user_data) {
    (void)stream_user_data;
    (void)greeter_chat_finish(stream);
}

static void chat_cancel(
    GreeterServiceChatStream stream,
    void* stream_user_data) {
    /* Ask outstanding async work to stop and release retained stream refs.
       Do not perform the final stream-state free here. */
    (void)stream;
    (void)stream_user_data;
}

static void chat_destroy(void* stream_user_data) {
    /* The sole final-free point for state owned by this stream. This example
       returned borrowed service state, so there is nothing to free here. */
    (void)stream_user_data;
}

GreeterServiceHandlers handlers = {0};
handlers.say_hello = say_hello;
handlers.chat.on_open = chat_open;
handlers.chat.on_message = chat_message;
handlers.chat.on_half_close = chat_half_close;
handlers.chat.on_cancel = chat_cancel;
handlers.chat.on_destroy = chat_destroy;

if (greeter_register(&handlers, app_state) != 0) {
    /* Already registered or invalid table. */
}
```

Each generated streaming method has `on_open`, `on_message`,
`on_half_close`, `on_writable`, `on_cancel`, and `on_destroy` slots.
When an `on_open` handler is present, its return value is passed to later
callbacks as that stream's state. If the stream is cancelled before `on_open`
runs, `on_open` is skipped and both `on_cancel` and `on_destroy` receive `NULL`:
no per-stream state was created. `on_cancel` is the cancellation notification;
use it to stop asynchronous work and arrange release of retained stream
references, but do not finally free owned stream state there. `on_destroy` is
called exactly once after all stream references are gone and is the one place
to perform that final free.

If the `on_open` slot itself is omitted, later callbacks receive the registered
`service_user_data` as a convenience. That pointer remains shared, borrowed
service state; ownership is not transferred to each stream. Because
`on_destroy` runs once per stream, it must not free shared service state. Free
that state only after every stream has delivered `on_destroy` and the service
owner has completed the unregister/shutdown lifecycle.
Callbacks for one stream are serialized. Different streams may execute
concurrently in the threaded runtime.

Incoming typed messages and callback stream pointers are borrowed. Do not
retain a message pointer. If asynchronous work must use a stream after the
callback returns, call `synurang_stream_retain()` first and
`synurang_stream_release()` from the completion or cancellation path.
`on_destroy` runs exactly once after the handle and every retained stream
reference have been released.

Generated `*_send` helpers encode and copy the response before returning.
Queues are bounded (16 entries by default); `SYNURANG_WOULD_BLOCK` means the
response must be retried after `on_writable`. `*_finish` publishes EOF after
queued responses, while `*_fail` publishes a serialized `core.v1.Error` and a
negative stream status. Both operations terminate the whole RPC: later sends
return `SYNURANG_CLOSED`, queued input callbacks are discarded, and normal
completion does not call `on_cancel`. For a server-streaming method, the
generated adapter accepts exactly one request message and fails a second one.

### Threaded runtime (default)

`greeter_register(&handlers, app_state)` selects a lazily-created,
process-wide runtime. On native threaded builds it owns one worker by default;
the worker executes the same non-blocking dispatch core exposed by
`synurang_runtime_poll()`. This is the simple choice for an ordinary C shared
library and remains compatible with blocking plugin hosts using
`Synurang_Stream_Recv`.

The pointer returned by `synurang_runtime_default()` is borrowed. Do not cache
or use it concurrently with `synurang_runtime_shutdown_default()`; pass `NULL`
to `synurang_stream_open()` (as generated adapters do) so open and shutdown are
synchronized internally.

For custom worker and queue settings, create a threaded runtime explicitly and
pass it to the generated registration function:

```c
SynurangRuntimeOptions options = SYNURANG_RUNTIME_OPTIONS_INIT;
options.execution_mode = SYNURANG_EXECUTION_THREADED;
options.worker_count = 4;

SynurangRuntime* runtime = synurang_runtime_create(&options);
if (!runtime ||
    greeter_register_with_runtime(runtime, &handlers, app_state) != 0) {
    /* Handle initialization failure. */
}
```

### Manual polling for libuv and WebAssembly

Manual execution creates no runtime worker. `synurang_runtime_poll()` never
blocks; callbacks execute on the thread that calls it.

```c
static void schedule_poll(void* user_data) {
    AppLoop* app = (AppLoop*)user_data;
    /* libuv: uv_async_send(&app->stream_async);
       WebAssembly: ask JavaScript to queue a microtask. */
}

SynurangRuntimeOptions options = SYNURANG_RUNTIME_OPTIONS_INIT;
options.execution_mode = SYNURANG_EXECUTION_MANUAL;
options.wakeup = schedule_poll;
options.wakeup_user_data = app_loop;

SynurangRuntime* runtime = synurang_runtime_create(&options);
greeter_register_with_runtime(runtime, &handlers, app_state);
```

The scheduled event-loop callback drains a bounded amount of work and
reschedules itself when necessary:

```c
void service_poll_callback(AppLoop* app) {
    (void)synurang_runtime_poll(app->runtime, 64);
    if (synurang_runtime_has_pending(app->runtime)) {
        schedule_poll(app);
    }
}
```

In a libuv embedding, `schedule_poll` normally calls `uv_async_send`; in a
single-threaded WebAssembly embedding it normally schedules an exported poll
call with `queueMicrotask`. A build with `SYNURANG_RUNTIME_NO_THREADS` accepts
manual execution only, and its default runtime is also manual.

`wakeup` also runs when asynchronous work publishes the first readable
response, EOF, or error to a previously empty stream. Therefore the scheduled
loop task should both poll callbacks and retry `TryRecv` for handles it is
waiting on, draining each until it reaches `SYNURANG_PENDING`, EOF, or an
error. Wakeups are readiness hints and are not guaranteed one-for-one with
messages.

Event-loop integrations should use `Synurang_Stream_TrySend` and
`Synurang_Stream_TryRecv`. These functions do not directly pump the runtime,
but making work ready can invoke `wakeup`; if that hook synchronously calls
`synurang_runtime_poll()`, callbacks may re-enter before the `Try` call returns.
The usual libuv or microtask wakeup only schedules a later poll:

```c
char* data = Synurang_Stream_TryRecv(handle, &data_len, &status);
if (!data && status == SYNURANG_PENDING) {
    /* Poll and try again later. */
}
```

The blocking names `Synurang_Stream_Send` and `Synurang_Stream_Recv` also
return without blocking on a manual runtime, but they are not inert: the
calling thread becomes the executor and dispatches pending callbacks until the
operation can complete or a pass dispatches nothing. That is what lets a stock
blocking host — which knows only the plugin ABI and never calls
`synurang_runtime_poll()` — drive a manual or threadless plugin. `WOULD_BLOCK`
and `PENDING` are therefore reported only once no callback can make further
progress. Inside an event loop prefer the explicit `Try` names, which never run
the poll loop directly and keep backpressure handling on your own schedule;
the synchronous-`wakeup` re-entry caveat above still applies.

### Shutdown and shared-library unload

Generated `*_unregister()` removes the service's global handler table and
allows later registration. It does not cancel active streams. Do not race it
with unary calls or new stream opens; already-open streams keep their own
callback-table copy. Keep service and per-stream user data alive until the
runtime has delivered `on_destroy`. Use this order before unloading code that
owns handlers:

1. Stop accepting work and close/cancel every stream.
2. Release asynchronous retained stream references.
3. For an explicit runtime, call `synurang_runtime_destroy(runtime)` and then
   the generated `*_unregister()`.
4. For the process-wide default, unregister every service using it, then call
   `synurang_runtime_shutdown_default()` before `dlclose`.

The default shutdown call releases the current runtime; a later default
registration/open lazily creates a fresh one.
In a threadless build, final runtime storage is deferred until the last
retained stream is released if step 2 is violated; the runtime is still
logically destroyed and must not be used again.

---

## Structured FFI Errors

Synurang carries `core.v1.Error` over FFI/plugin boundaries. The canonical structured error is `FfiError`.

In FFI mode, think in terms of protobuf payloads, not gRPC packages. `core.v1.Error` is just a protobuf message, so host/plugin code can work with only protobuf or protobuf-lite support. `grpc_code` is just the integer field in that message.

Hosts should assert both the user message and the structured fields:

- `code`: app-specific error code
- `message`: human-readable error
- `grpc_code`: gRPC status code

Start with the existing codec/unit checks:

```bash
dart test test/ffi_error_test.dart
go test ./pkg/ffierror ./pkg/synurang
```

For end-to-end testing, add a deterministic trigger to one service implementation and return a structured protobuf-backed error. No `grpc/status` or `grpc/codes` import is required:

```go
import (
    "github.com/ivere27/synurang/pkg/ffierror"
)

func ffiTestError(code int32, message string) error {
    return ffierror.New(code, message, 10) // 10 = ABORTED
}
```

Use the same deterministic trigger input across all 4 RPC types:

- Unary: `if req.Name == "trigger_error" { return nil, ffiTestError(4101, "unary failed") }`
- Server stream: `if req.Name == "trigger_error" { return ffiTestError(4102, "server stream failed") }`
- Client stream: if any received item has `Name == "trigger_error"`, return `ffiTestError(4103, "client stream failed")`
- Bidi stream: if any received item has `Name == "trigger_error"`, return `ffiTestError(4104, "bidi failed")`

Then assert the decoded `FfiError` fields in each host:

- Dart: catch `FfiError` and check `e.code` / `e.grpcCode`
- Go: `var ffiErr *synurang.FfiError; errors.As(err, &ffiErr)`
- Java/C#: catch `FfiError` and inspect `getCode()` / `Code` and `getGrpcCode()` / `GrpcCode`
- C++: catch `synurang::FfiError` and inspect `code()` / `grpc_code()`
- Rust: match `Error::PluginError(err)` or `Error::StreamError(err)` and inspect the inner `FfiError`
- Python: catch `FfiError` and inspect `code`, `grpc_code`, `message`, and the original `payload`

Example host-side usage:

```dart
try {
  await synurang.invokeBackendAsync(method, requestBytes);
} on synurang.FfiError catch (e) {
  print('code=${e.code} grpc=${e.grpcCode} message=${e.message}');
}
```

```go
resp, err := plugin.Invoke("GoGreeterService", "/example.v1.GoGreeterService/Bar", reqBytes)
if err != nil {
    var ffiErr *synurang.FfiError
    if errors.As(err, &ffiErr) {
        fmt.Printf("code=%d grpc=%d message=%s\n", ffiErr.Code, ffiErr.GrpcCode, ffiErr.Message)
    }
    return err
}
_ = resp
```

```java
try {
    plugin.invoke("GoGreeterService", "/example.v1.GoGreeterService/Bar", reqBytes);
} catch (FfiError e) {
    System.out.println("code=" + e.getCode() + " grpc=" + e.getGrpcCode() + " message=" + e.getMessage());
}
```

```csharp
try
{
    plugin.Invoke("GoGreeterService", "/example.v1.GoGreeterService/Bar", reqBytes);
}
catch (FfiError e)
{
    Console.WriteLine($"code={e.Code} grpc={e.GrpcCode} message={e.Message}");
}
```

```cpp
try {
    plugin.invoke("GoGreeterService", "/example.v1.GoGreeterService/Bar", req_bytes);
} catch (const synurang::FfiError& e) {
    std::cout << "code=" << e.code() << " grpc=" << e.grpc_code()
              << " message=" << e.what() << std::endl;
}
```

```rust
match plugin.invoke("GoGreeterService", "/example.v1.GoGreeterService/Bar", &req_bytes) {
    Err(synurang_host::Error::PluginError(err))
    | Err(synurang_host::Error::StreamError(err)) => {
        println!(
            "code={} grpc={} message={}",
            err.code, err.grpc_code, err.message
        );
    }
    other => {
        let _ = other?;
    }
}
```

```python
from synurang import FfiError

try:
    plugin.invoke(
        "GoGreeterService",
        "/example.v1.GoGreeterService/Bar",
        request_bytes,
    )
except FfiError as error:
    print(
        f"code={error.code} grpc={error.grpc_code} "
        f"message={error.message}"
    )
```

Unary plugin return path (`host -> unary call -> plugin`):

If the host calls `/example.v1.GoGreeterService/Bar`, the plugin method should return or throw `FfiError` like this.

```go
func (p *MyPlugin) Bar(ctx context.Context, req *examplepb.HelloRequest) (*examplepb.HelloResponse, error) {
    if req.Name == "trigger_error" {
        return nil, ffiTestError(4101, "go unary ffi error")
    }
    // ...
}
```

```cpp
HelloResponse Bar(const HelloRequest& request) override {
    if (request.name() == "trigger_error") {
        throw FfiError("cpp unary ffi error", 4201, 10);
    }
    // ...
}
```

```rust
fn bar(&self, request: HelloRequest) -> Result<HelloResponse, FfiError> {
    if request.name == "trigger_error" {
        return Err(FfiError::new("rust unary ffi error", 4301, 10));
    }
    // ...
}
```

For streaming plugin methods, use the same pattern in the plugin implementation:

- Go: `return ffiTestError(code, "...")`
- C++: `throw FfiError("...", code, 10)`
- Rust: `return Err(FfiError::new("...", code, 10))`

If you already use gRPC status values in Go, those still work for compatibility. But the FFI wire format itself is only `core.v1.Error`, so low-level FFI examples in this document avoid requiring any gRPC package.

The existing host runners are a good place to wire this in:

```bash
make test_host_csharp
make test_host_java
make test_host_rust
make test_host_python
make test_host_all
```

The example plugins in `example/go/plugin/main.go`, `example/cpp/plugin/main.cpp`, and `example/rust/plugin/src/lib.rs` already use this trigger value for `Bar`, `BarServerStream`, `BarClientStream`, and `BarBidiStream`.

---

## Comparison

| | gRPC stubs | FFI codegen | FFI manual |
|---|---|---|---|
| **Dependencies** | protobuf + grpc | protobuf API on the call path; package deps vary by lang | protobuf API on the call path; package deps vary by lang |
| **Marshalling** | Automatic | Automatic | Manual |
| **Streaming** | All 4 types | All 4 types (varies by lang) | All 4 types |
| **Type safety** | Full | Full | Bytes in / bytes out |
| **Setup** | `protoc --grpc_out` + `protoc --synurang-ffi_out` | `protoc --synurang-ffi_out` | None |
| **Binary size** | Larger (gRPC runtime) | Smaller | Smallest |

## C ABI reference

Every Synurang plugin exports these baseline symbols:

```c
// Unary RPC
char* Synurang_Invoke_<Service>(const char* method, const char* data, int data_len, int* resp_len);
void  Synurang_Free(char* ptr);

// Streaming RPC
uint64_t Synurang_Stream_<Service>_Open(const char* method);
int      Synurang_Stream_Send(uint64_t handle, char* data, int data_len);
char*    Synurang_Stream_Recv(uint64_t handle, int* resp_len, int* status);
void     Synurang_Stream_CloseSend(uint64_t handle);
void     Synurang_Stream_Close(uint64_t handle);
```

The shared C runtime additionally exports explicit non-blocking forms for
manual event loops:

```c
int   Synurang_Stream_TrySend(uint64_t handle, const char* data, int data_len);
char* Synurang_Stream_TryRecv(uint64_t handle, int* resp_len, int* status);
```

**Response format:**

- Invoke:
  - `resp_len >= 0`: success, payload is raw protobuf bytes
  - `resp_len < 0`: error, payload is serialized `core.v1.Error`
- Stream Recv:
  - `status == SYNURANG_OK` (`0`): success, payload is raw protobuf bytes
  - `status == SYNURANG_EOF` (`1`): EOF
  - `status == SYNURANG_PENDING` (`3`): C runtime extension, returned only by `TryRecv` or by `Recv` on a manual runtime that has no callback left to run. Hosts that predate this status treat it as an error, so a plugin meant for blocking hosts should keep the threaded default.
  - `status < 0`: error, payload is serialized `core.v1.Error`

Empty protobuf payloads are valid successes. That means `resp_len == 0` for unary or `status == 0` with `resp_len == 0` for streaming is not an error by itself.

`Send`/`Recv` may block only with a threaded runtime. On a manual runtime they
never block and instead dispatch pending callbacks on the calling thread until
the operation completes, so an ordinary blocking host keeps working against a
manual or threadless plugin. Event loops should prefer the explicit
`TrySend`/`TryRecv` forms. They do not directly pump callbacks, although a
configured `wakeup` hook can synchronously poll and re-enter them.
`SYNURANG_WOULD_BLOCK` (`-4`) means a bounded queue has no capacity yet.
Generated typed service handlers receive `on_writable` when response capacity
becomes available. See the [C runtime section](#manual-polling-for-libuv-and-webassembly)
for polling and lifecycle rules.
