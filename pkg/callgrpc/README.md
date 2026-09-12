# gRPC clients over native modules

`callgrpc.Conn` implements `grpc.ClientConnInterface` using the versioned native
module host. Standard generated gRPC clients can call C, C++, Rust, and Go
providers without a network connection or service-name argument:

```go
module, err := call.Load("./greeter.so", 16)
if err != nil {
    return err
}
defer module.Close()

client := pb.NewGreeterClient(callgrpc.New(module))
reply, err := client.SayHello(ctx, request)
```

All four RPC shapes use the same call lifecycle. Bidi streams exchange messages
before `CloseSend`. Context deadlines and cancellation reach the provider and
release the native call. Unary and client-streaming replies wait for successful
terminal status before returning. The host serializes native entry per instance;
Go callers can concurrently send and receive, and queues remain bounded.

Provider failures preserve their gRPC status and decode `core.v1.Error` into
standard gRPC status details. Trailers carry the original `synurang-error-bin`
payload and the encoded `grpc-status-details-bin` status. The adapter supports
header/trailer collection, `OnFinish`, and message-size limits. Request metadata,
credentials, compression, custom codecs, and network-specific options are
rejected explicitly when supplied. Closing the adapter's borrowed module is
the caller's responsibility.

Build native providers and run the actual Go host and generated gRPC client
conformance with the race detector:

```sh
bash test/call/test_go.sh /path/to/c_module.so /path/to/rust_module.so /path/to/go_module.so
```
