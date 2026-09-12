# Synurang for Java and Kotlin

The Java 8+ core exposes native module calls as `CompletableFuture` operations.
The same API supports C, C++, Rust, and Go modules and all four RPC shapes.
Kotlin can await these futures through its coroutine integration; the core has
no gRPC or coroutine dependency.

Build the JNI library from the repository:

```sh
cmake -S java/core/src/main/c -B build/java-jni
cmake --build build/java-jni
```

Run with `-Dsynurang.library.path=/absolute/path/to/libsynurang_jni.so`, or
package the library in the existing platform-specific JAR resource location.
JNI compiles the portable module loader and uses each provider's function
table. It does not impose the C service executor on Rust or Go providers.

Generate typed clients alongside standard Java protobuf messages:

```sh
protoc -I. --java_out=generated \
  --synurang-ffi_out=lang=java,mode=client:generated service.proto
```

The generated `<Service>Client` honors the proto's Java package, outer class,
and multiple-files options. Unary methods return typed futures. Streaming
methods return `TypedModuleCall<Request, Response>`:

```java
try (ModuleHost host = ModuleHost.load("./libgreeter.so")) {
    GreeterClient client = new GreeterClient(host);
    HelloReply reply = client.SayHello(request, Duration.ofSeconds(2)).join();
    try (TypedModuleCall<HelloRequest, HelloReply> call = client.Chat()) {
        call.send(request).join();
        HelloReply first = call.receive().join();
        call.halfClose().join();
        while (call.receive().join() != null) {
            // Consume remaining responses.
        }
    }
}
```

Async code composes or awaits the futures instead of calling `join`. Generated
future mapping propagates cancellation to the RPC. Client-streaming calls use
`send`, `halfClose`, then `result`; `result` waits for successful terminal status.
Empty byte arrays are valid messages, while `receive` returning null indicates
successful EOF. Errors preserve the RPC status, application code, and original
`core.v1.Error` payload in `FfiError`.

One scheduler serializes nonblocking JNI calls for an instance and polls a
bounded amount of provider work. Application continuations run on the common
pool or the executor passed to `ModuleHost.load(path, symbol, executor)`.
Await sends to respect backpressure: at most 16 sends and one receive can be
pending per call. The native output queue remains bounded when consumers pause.
Deadlines use monotonic time and cancellation is cooperative with the provider.

A provider may finish client streaming before accepting all requests. A rejected
`send` then fails with `RequestClosedException`; stop sending and continue with
`receive` or `result` to obtain the preserved response and terminal status.
Receiving can run concurrently with sending. The gRPC adapter handles this as
request-side EOF without closing the response side.

`closeAsync` cancels active calls and completes after provider cleanup. Blocking
`close` is a convenience for try-with-resources. Keep each host alive until its
calls finish, and close streams when leaving iteration early. Each loaded host
owns an independent instance. The loader requires the module ABI and does not
fall back to older per-service symbols.

The optional gRPC package supplies a regular `io.grpc.Channel`:

```java
Channel channel = new ModuleChannel(host);
GreeterGrpc.GreeterFutureStub stub = GreeterGrpc.newFutureStub(channel);
```

`SynurangChannel.create(host)` also accepts `ModuleHost`. All four method shapes,
response demand, deadlines, cancellation, and RPC status mapping are supported.
Structured error bytes are available in the `synurang-error-bin` trailer.
Metadata and call credentials are rejected explicitly because the module ABI
does not transport them. Network connection and TLS behavior belong to network
channels.

The native test launcher compiles JNI, generated clients, and gRPC adapters,
then exercises them against each supplied module:

```sh
bash test/call/test_java.sh /tmp/call-tests /path/to/c_module.so /path/to/rust_module.so
```
