# Rust native module consumer

Enable the standalone module host without gRPC dependencies:

```toml
synurang-host = { path = "../synurang/crates/synurang-host", default-features = false, features = ["module"] }
```

The default features also expose the independent existing `PluginHost` and
process/gRPC APIs. `ModuleHost` loads only the new `Synurang_GetApi` function
table and does not depend on the C runtime or its loader shim. It can consume
modules implemented in C, C++, Rust, Go, or another implementation of that ABI.

```rust,no_run
use synurang_host::{ModuleHost, ModuleOptions, ModuleCallOptions};

# async fn example() -> synurang_host::RpcResult<()> {
let host = ModuleHost::load("./service.so", ModuleOptions::default())?;
let options = ModuleCallOptions {
    timeout: Some(std::time::Duration::from_secs(2)),
    ..Default::default()
};
let response = host.unary("/example.Service/Unary", &[/* protobuf bytes */], options).await?;

let call = host.bidi("/example.Service/Bidi", Default::default()).await?;
call.send(&[]).await?; // Empty protobuf messages are valid.
let response = call.recv().await?; // Available before half_close.
call.half_close().await?;
while let Some(response) = call.recv().await? {
    // Decode response bytes with the application's protobuf codec.
}
call.close().await;
host.close().await?;
# Ok(())
# }
```

Create hosts inside an active Tokio runtime. Each instance belongs to one actor
with a bounded command queue. Foreign entries run sequentially and never wait
for producer completion. Polling is bounded to 64 callbacks per turn and yields
through Tokio timers. Calls can be cloned; send and half-close operations are
ordered, and one receive can run concurrently with sends. More than one pending
receive returns status 9 instead of racing the consumer queue.

The API supports all four cardinalities:

- `unary(path, bytes, options)` returns one response after checking terminal status.
- `server_stream(path, bytes, options)` returns a `ModuleCall`; its `responses()`
  method exposes a Rust stream of response bytes and terminal errors.
- `client_stream(path, stream_of_bytes, options)` sends and receives concurrently,
  including early server rejection of a request stream.
- `bidi(path, options)` returns a call with independent async send and receive.

`open(ModuleMethod, options)` exposes the raw common call contract. All method
identifiers are full `/package.Service/Method` paths. Use `CancellationToken`,
`ModuleCall.cancel()`, or a timeout to end pending work. `RpcError` retains the
status, message, and original serialized `core.v1.Error` details. A successful
unary payload followed by a failure still returns the failure.

A rejected write checks at most one foreign read and preserves any message for
the receiver. Unknown methods retain status 12. When only input is closed,
`RpcError::is_request_closed()` identifies that condition; responses and their
terminal status remain readable. `client_stream` accepts an early successful
response even when the request source still has messages or remains pending.

Cancelling an `open()` future releases a handle that the actor already created.
Cancelling a `recv()` future before it accepts a delivered message preserves
that message for the next receive. Dropping the last call clone schedules its
release. `ModuleCall.close()` schedules release for all its clones;
`ModuleHost.close()` waits until every retained producer is gone and the module
reports successful destruction. Concurrent host close calls share one result.

The loaded library remains alive until `destroy` returns zero. If the Tokio
runtime stops first, a cleanup thread retains the library and continues polling
and destruction. Explicit async close is the deterministic way to finish work.
For a `.a` linked into the executable, use unsafe
`ModuleHost::from_static_api(pointer, options)`. Its API table and code must
remain available for the process lifetime, including deferred cleanup.

Validation:

```sh
cargo test --manifest-path crates/synurang-host/Cargo.toml
cargo test --manifest-path crates/synurang-host/Cargo.toml --no-default-features --features module
SYNURANG_STATIC_MODULE_DIR=/tmp/synurang-call-full \
  cargo run --manifest-path test/call/rust_host/Cargo.toml -- /tmp/synurang-call-full
```

The last command consumes the fixtures from `test/test_call_runtime.sh` and
executes C/C++/Rust/Go shared modules plus a C archive linked into the Rust test
executable. The lifecycle test covers bounded queues, concurrent send/receive,
cancelled operation futures, deferred destruction, buffer ownership, and Tokio
shutdown during active foreign work.
