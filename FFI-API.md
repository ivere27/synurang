# Low-Level FFI API

This document covers using Synurang plugins **without** a gRPC library dependency. Instead of routing calls through generated gRPC stubs and a `ClientConn`/`ClientChannel`, you call the plugin's C ABI functions directly with raw protobuf bytes.

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

Both skip the gRPC library entirely. The codegen approach is recommended unless you need custom serialization or want to avoid the codegen step.

---

## Go

### Dependencies

```
# Required
google.golang.org/protobuf   # proto.Marshal / proto.Unmarshal

# NOT required
google.golang.org/grpc       # only needed for the gRPC-stub path
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
    log.Fatal(err) // includes PluginError for application errors
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
  synurang: ...          # FFI host library
  protobuf: ...          # writeToBuffer / fromBuffer

# NOT required:
#   grpc: ...            # only needed for the gRPC-stub path
```

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
prost = "0.12"             # encode_to_vec / decode

# NOT required:
# tonic = ...              # only needed for the gRPC-stub path
```

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
    } catch (PluginError e) {
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

## Comparison

| | gRPC stubs | FFI codegen | FFI manual |
|---|---|---|---|
| **Dependencies** | protobuf + grpc | protobuf only | protobuf only |
| **Marshalling** | Automatic | Automatic | Manual |
| **Streaming** | All 4 types | All 4 types (varies by lang) | All 4 types |
| **Type safety** | Full | Full | Bytes in / bytes out |
| **Setup** | `protoc --grpc_out` + `protoc --synurang-ffi_out` | `protoc --synurang-ffi_out` | None |
| **Binary size** | Larger (gRPC runtime) | Smaller | Smallest |

## C ABI reference

Every Synurang plugin exports these symbols:

```c
// Unary RPC
char* Synurang_Invoke_<Service>(char* method, char* data, int data_len, int* resp_len);
void  Synurang_Free(char* ptr);

// Streaming RPC
uint64_t Synurang_Stream_<Service>_Open(char* method);
int      Synurang_Stream_Send(uint64_t handle, char* data, int data_len);
char*    Synurang_Stream_Recv(uint64_t handle, int* resp_len, int* status);
void     Synurang_Stream_CloseSend(uint64_t handle);
void     Synurang_Stream_Close(uint64_t handle);
```

**Response format:** `[status:1byte][payload...]`

- Invoke: status `0` = success (payload is protobuf), status `1` = error (payload is message string)
- Stream Recv status out-param: `0` = data, `1` = EOF, `2+` = error
