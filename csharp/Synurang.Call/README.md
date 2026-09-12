`Synurang.Call` is the .NET 8 module client runtime. It has no gRPC or protobuf
dependency. `Synurang.Call.Grpc` is an optional adapter for standard gRPC clients.

Build the native loader shim (`synurang_module_host` CMake target) and install
`libsynurang_module_host.so`, `libsynurang_module_host.dylib`, or
`synurang_module_host.dll` in the application's native library search path.
Modules expose the new `Synurang_GetApi` table; there is no old ABI fallback.

Generate protobuf messages with protoc's C# generator, and typed module clients
with `protoc-gen-synurang-ffi`:

```sh
protoc -I proto --csharp_out=generated \
  --synurang-ffi_out=lang=csharp,mode=client:generated proto/service.proto
```

Reference `Synurang.Call.csproj` and `Google.Protobuf` from the application that
compiles those generated files. The generated clients accept `IModuleTransport`.

```csharp
await using var host = ModuleHost.Load("./module.so");
var client = new CallsClient(host);
var response = await client.UnaryAsync(request,
    new ModuleCallOptions(cancellationToken, TimeSpan.FromSeconds(2)));

await foreach (var item in client.Server(request).WithCancellation(cancellationToken))
    Consume(item);

var summary = await client.ClientAsync(requests); // IAsyncEnumerable<Value>
await using var bidi = client.Bidi();
await using var responses = bidi.ReadAllAsync().GetAsyncEnumerator(cancellationToken);
await bidi.SendAsync(request);
if (await responses.MoveNextAsync()) Consume(responses.Current);
await bidi.HalfCloseAsync();
```

Unary, server, client, and bidi streaming share the same nonblocking call ABI.
The runtime serializes native entry calls and yields its task when polling finds
no progress. Request and response directions can progress concurrently; receive
iteration reads on demand. A unary task waits for terminal RPC status even if a
response arrived earlier. `ModuleRpcException.Code` is the RPC status, and
`Details` preserves the serialized `core.v1.Error`.

Client-streaming reads the response while producing requests. If the service
finishes early, the result completes promptly and input enumeration is stopped.
An input iterator that ignores cancellation may finish its cleanup later.
`ModuleRequestClosedException` only closes the request side; buffered responses
and terminal status remain readable.

Dispose calls and hosts with `await using`. Breaking response iteration cancels
and releases that call. Disposing a host cancels pending calls and waits for
retained producer work before unloading the module. Explicit disposal is required;
the runtime does not rely on finalizers for foreign producer shutdown.

For a statically linked provider, pass its accessor's table pointer to
`ModuleHost.Linked(api)`. Keep the table and provider code alive through host
disposal. The loader shim can still be distributed as a small native library.

For standard gRPC generated clients, reference `Synurang.Call.Grpc` and construct
their client with `new ModuleCallInvoker(host)`. This adapter supports all four
method types, cancellation, deadlines, and final status. The local module ABI
does not carry gRPC headers or credentials. Error bytes use the binary trailer
`synurang-error-bin`; they are `core.v1.Error`, not a `google.rpc.Status` payload.
