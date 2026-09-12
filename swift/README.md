The `SynurangLite` package provides protobuf codecs and the new `ModuleHost`
actor. Module clients use Swift `async` calls and demand-driven `AsyncSequence`
responses. The runtime has no external Swift package dependencies.

Build and install the native `synurang_module_host` loader shim alongside the
application, then generate lite messages and typed clients:

```sh
protoc -I proto \
  --synurang-ffi_out=lang=swift,mode=client:generated proto/service.proto
```

```swift
let host = try ModuleHost.load(path: "./module.so")
let client = CallsClient(transport: host)
do {
    let response = try await client.unary(request,
        options: .init(timeoutMilliseconds: 2_000))
    for try await item in client.server(request) { consume(item) }
    let summary = try await client.client(requests) // AsyncSequence<Value>

    let bidi = try await client.bidi()
    try await bidi.send(request)
    let immediate = try await bidi.receive() // Works before halfClose.
    try await bidi.halfClose()
    for try await item in bidi.responses { consume(item) }
    await bidi.close()
    try await host.close()
} catch {
    try? await host.close()
    throw error
}
```

The actor serializes native operations. Pending reads and sends suspend their
task while a bounded poll advances producer work. Send and receive may run
concurrently; multiple simultaneous operations in the same direction are rejected.
The response iterator pulls a single message for each `next()` and cancels its
call on an early loop exit. It does not accumulate an unbounded stream buffer.

Swift task cancellation cancels the underlying call. Timeouts use a monotonic
sleep and report RPC status 4. `ModuleRpcError.code` preserves final RPC status;
`details` contains the module's serialized `core.v1.Error`. Unary waits for the
terminal status as well as the response message.

Client-streaming accepts a `Sendable` input sequence and reads the response
concurrently. Early server completion cancels the input task and releases the
foreign call without waiting for application input to resume. Input sequences
should cooperate with Swift task cancellation for their own cleanup.
`ModuleRequestClosedError` means the response side remains readable after the
service stops accepting requests.

Call `try await host.close()` to cancel active calls and wait for retained native
work before unloading. Dropped hosts also schedule eventual cleanup. The native
loader requires `Synurang_GetApi` and has no old ABI fallback. Existing `lite`
generation outputs and their `PluginHost` remain separate APIs.

For a static `.a` provider, link its code and the native loader shim into the
application, expose the named C API accessor through a bridging header, and use
`ModuleHost.linked(api:)`. It resolves the shim's functions from the process.
Pass `loaderPath:` explicitly when the shim is a separate dynamic library.
The accessor table and provider code must outlive the host. On Linux, executable
symbols resolved with `dlsym` must be exported with `-Wl,--export-dynamic`.

The new native host and generated clients are tested on Linux with Swift 6.1.2.
The source package uses Swift tools version 5.9. Apple and Windows native targets
share the loader abstraction, but require their own platform builds and tests.
