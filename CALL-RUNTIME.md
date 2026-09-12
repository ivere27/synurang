# Native and WebAssembly call modules

Use `mode=module` for a service implementation and `mode=client` for a typed
client. Both sides exchange protobuf bytes through one asynchronous call
contract. All four RPC forms use `open / send / half_close / receive / cancel /
release`; unary has one request and one response. Methods are identified by
full paths such as `/example.v1.Greeter/SayHello`.

## The ABI does not prescribe a backend runtime

| Provider | Execution | Native library | WASM build |
|---|---|---|---|
| C / C++ | Synurang C callbacks and bounded queues; manual polling or native workers | `.so`, `.dll`, `.dylib`, `.a` | Clang/LLVM wasm32; manual polling |
| Rust | Rust `Future` / `Waker`, bounded queues | `cdylib` or `staticlib` | `wasm32-unknown-unknown` |
| Go | Go goroutines, channels, contexts | `c-shared` or `c-archive` | `GOOS=js GOARCH=wasm` and matching `wasm_exec.js` |
| Dart | Dart `Future` / `Stream` in an in-process transport | Dart service registration | JS/WasmGC transport exported to JavaScript |

**Go → Go.so, Flutter → Go.so, and Flutter → Rust.so do not run the C backend
runtime.** A C-compatible function table describes the boundary; it does not
make the implementation a C service. `src/module_host.c` is an optional dynamic
loader and function forwarder. It does not link `src/c_runtime.c`.

`poll` also has different jobs: C dispatches ready callbacks, Rust polls ready
futures, and Go only collects completed call state while goroutines do the work.
Each backend supplies its own timers, I/O and asynchronous event sources. Rust
futures can await Synurang streams directly; other asynchronous libraries need
their own reactor/executor integration. No provider should block inside an ABI
entry or a C callback/Rust future poll. Long CPU work must yield or run in a
worker when the embedding needs a responsive main thread.

## Generator capabilities

| Language | `mode=module` | `mode=client` / consumer |
|---|---|---|
| C | Typed callbacks and dependency-free protobuf codecs | Raw `module_host.h` ABI |
| C++ | C callback contract, usable from C++ | `module_host.hpp`: RAII, future, blocking and poll APIs |
| Rust | Typed asynchronous service traits using `synurang-call` | `synurang-host` module feature, Tokio async host |
| Go | Typed service interface and registration using `pkg/module` | `pkg/call`; standard generated gRPC clients through `pkg/callgrpc` |
| TypeScript | — | Promise, AsyncIterable, interactive duplex; browser/Node |
| Dart / Flutter | In-process service registration emitted with client mode | Future, Stream, interactive duplex; native/web |
| Java / Kotlin | — | Java protobuf types, CompletableFuture, optional gRPC channel |
| C# | — | Task, IAsyncEnumerable, optional gRPC CallInvoker |
| Python | — | Sync and asyncio clients, dependency-free message codecs |
| Swift | — | async functions, AsyncSequence, dependency-free message codecs |

Java/Kotlin, C#, Python and Swift module hosts are native consumers. This does
not claim those runtimes can export a C/WASM provider. Adding another provider
language means implementing the call ABI and mapping its scheduler and memory
ownership, not running it through the C callback runtime.

`target=native` or `target=wasm` optionally validates the selected role. The
module contract stays the same for both builds. Unsupported language/mode/target
combinations fail generation. In particular, managed native clients are not
silently presented as browser WASM clients.

```sh
cargo install --locked --path cmd/protoc-gen-synurang-ffi
protoc --synurang-ffi_out=lang=c,mode=module:generated service.proto
protoc --synurang-ffi_out=lang=rust,mode=module:generated service.proto
protoc --go_out=paths=source_relative:generated \
  --synurang-ffi_out=lang=go,mode=module:generated service.proto
protoc --synurang-ffi_out=lang=typescript,mode=client:generated service.proto
```

C/C++ module mode emits `_lite.h/.c` and `_ffi.h/.c`. Rust uses prost message
types; import the schema's prost types before including the generated service
file. Go uses standard Go protobuf messages. Java, C# and Dart likewise use
their normal protobuf generator. Python, Swift and TypeScript client generation
includes their lite codecs.

Existing default, `plugin_server`, `native` and `wasm` generator modes are
separate interfaces. New module hosts load `Synurang_GetApi`; there is no
fallback to `Synurang_Invoke_<Service>` or per-method flattened exports.

## C/C++ WASM without Emscripten

Use upstream Clang/LLVM and a wasm32 libc/sysroot. The reproducible build uses
[WASI SDK](https://github.com/WebAssembly/wasi-sdk), which supplies Clang, LLD and
wasi-libc. The SDK supplies build tools; a WASI execution environment is not
required by the Synurang fixture. Its linked WASM has **zero imports**.
Emscripten, generated JavaScript glue and pthread emulation are not used.

Supported WASM execution has two modes:

| Mode | Where C/Rust callbacks run | Memory ownership |
|---|---|---|
| Same-thread polling | The calling JS thread, between bounded polling turns | One non-shared WASM instance |
| Web Worker / Node Worker | Polling inside the worker | Each worker creates and owns its non-shared instance |

Neither mode requires `SharedArrayBuffer`, cross-origin isolation, or COOP/COEP
headers. Ports exchange copied protobuf messages. WASM threads, pthread pools,
and shared-memory instances are outside the supported scope and are rejected
by the WASM loader, including custom `createWasmHost` factories. This restriction
does not change native C/C++ runtime thread support.

Polling limits callbacks per turn; it cannot preempt a long-running callback.
Use a Worker to keep that work off the browser's main thread, and have callbacks
yield or finish promptly so their worker can process cancellation and other
calls. Cancellation remains cooperative in both modes.

```sh
# generated/ contains the C module and lite outputs; provider.c registers handlers.
"$WASI_SDK_PATH/bin/clang" -O2 -mexec-model=reactor \
  -DSYNURANG_RUNTIME_NO_THREADS -Iinclude -Igenerated \
  src/c_runtime.c src/call.c src/wasm.c \
  generated/service_lite.c generated/service_ffi.c provider.c \
  -Wl,--export-memory -o service.wasm
```

For C++, compile the provider with the SDK's `clang++`, then link its object
with the same runtime and generated C sources. If a provider uses C++ standard
library facilities, link with `clang++` and the required target libraries.
`src/wasm.c` exports ordinary WASM functions through Clang's `export_name`
attribute. The host uses exported `memory`, the module allocator/free pair and
64-bit call IDs represented as JavaScript `bigint`. The loader validates
`synurang_module_abi_version() == 1` and supplies the `synurang.wakeup(token)`
import. Tokens route notifications to the owning instance; the callback only
schedules later work. A custom reactor must use this same notification path
when external I/O or timers resume provider work.

A provider that uses filesystem, sockets or other OS APIs may introduce WASI or
custom imports. Supply those explicitly to `instantiateWasm(bytes, imports)`;
Synurang does not silently emulate an operating system. This loader accepts
non-shared core WASM modules, not WASI component-model binaries. C polling
dispatches ready service callbacks; it does not supply external I/O or timers.
Applications connect those event sources to the provider's completion callbacks.

## TypeScript: same client, different host

Build the local runtime package with `npm ci --prefix typescript` and
`npm run --prefix typescript build`, then install/link that local package in the
consumer project. Generated clients use a structural `Transport`, so they also
accept the package's hosts. Installation builds the native Node adapter with
node-gyp and needs a C compiler, Python and Node development headers. Bundle
`dist/synurang_module_host.node` with the Node loader; `addonPath` can override
its location. Browser hosts do not load that addon.

The TypeScript `Host` schedules bounded polling turns when an operation or
provider notification makes progress possible. It leaves
responses in the provider's bounded queue until the consumer reads them. After
the last call is released it drains ready callbacks, then stops scheduling;
`host.close()` additionally waits for outstanding producer cleanup before
destroying the instance. Polling faults are reported through the host's calls.

Ready work is scheduled with `MessageChannel` on the current event loop. When
no work is ready, the host waits for a notification or a call's one-shot deadline
timer. A quiet stream has no periodic polling timer. Environments without
`MessageChannel` use a zero-delay timer to schedule notified work. Native Node
uses `uv_async_send`, which posts to the event loop without blocking a producer
thread. WASM imports and Go's JS bridge feed the same scheduler.

```ts
import { createNativeHost } from '@synurang/runtime/node';
import { createWasmHost, instantiateWasm } from '@synurang/runtime/wasm';
import { WorkerHost } from '@synurang/runtime/worker';
import { GreeterClient } from './generated/service_ffi.js';

// Node native dynamic library, loaded by the bundled native adapter.
const native = await createNativeHost('./service.so');

// Browser or Node WASM: bytes come from fetch() or fs.readFile().
const wasm = await createWasmHost(() => instantiateWasm(bytes));
const client = new GreeterClient(wasm);
try {
  const reply = await client.sayHello(request, { timeoutMs: 2000 });
  const call = await client.chat();
  try {
    await call.send(request);
    const first = await call.recv(); // Works before halfClose.
    await call.halfClose();
    for await (const reply of call.responses) { /* ... */ }
  } finally { await call.close(); }
} finally { await wasm.close(); await native.close(); }
```

For a statically linked Node addon, compile `src/node.c` with the module's `.a`
and use `createLinkedHost(addon)`. For Go WASM, load the Go toolchain's matching
`wasm_exec.js`, then call `createGoWasmHost(bytes, globalThis.Go)`. Go uses its own
runtime imports and JS bridge; its calls still implement the same `Transport`.
The Go bridge batches open/send/half-close for the `unary` and `serverStream`
helpers. A unary response can carry its terminal status in the same owned byte
packet; the host still checks that status before reporting success. Streaming
responses are read one at a time to preserve queue bounds.

Workers use the same client. In a browser module worker:

```ts
// service-worker.ts
import { serveWorker } from '@synurang/runtime/worker';
import { createWasmHost, instantiateWasm } from '@synurang/runtime/wasm';
serveWorker(self, async () => {
  const bytes = await (await fetch('./service.wasm')).arrayBuffer();
  return createWasmHost(() => instantiateWasm(bytes));
});

// Main thread
import { WorkerHost } from '@synurang/runtime/worker';
const host = new WorkerHost(new Worker('./service-worker.js', { type: 'module' }));
const client = new GreeterClient(host);
```

Node uses `worker_threads.Worker` and `parentPort` with the same `WorkerHost` /
`serveWorker` functions. Each worker owns its module instance; ports exchange
copied protobuf bytes and protocol IDs, never native pointers. Closing a host
waits for module cleanup before closing its worker. These workers host separate
polling instances; they do not form a shared-memory WASM thread pool.

`grpc=js` additionally generates grpc-js clients and `PluginChannel`:

```ts
const client = new GreeterClient('synurang', grpc.credentials.createInsecure(), {
  channelOverride: new PluginChannel(host, GreeterService),
});
```

Here `'synurang'` is the address argument required by grpc-js. FFI dispatch comes
from `host` and the full method paths in `GreeterService`. A browser does not
need grpc-js: use the Promise/stream client directly. The adapter supports the
four RPC shapes, errors, cancellation and deadlines. Network transport features
such as TLS, name resolution, connection balancing and HTTP metadata are not
provided by this ABI.

## Lifetime, flow control and errors

Portable native hosts pass a non-null `SynurangRuntimeOptions` with its exact
`struct_size`, `MANUAL` execution and input/output capacities in `1..65536`.
`worker_count` is ignored in MANUAL mode. `wakeup` and `wakeup_user_data` identify
the host's notification sink. Provider-specific defaults for null options,
zero capacities, partial option structs and threaded execution are outside this
portable subset. Native ABI v1 loaders also require the exact `SynurangApi` size;
the size field does not promise prefix-compatible table extensions.

- Foreign operations return immediately with success, pending or would-block.
  Hosts yield between bounded polls and implement their language's await/blocking API.
  C, Rust and Go notify the instance when ready work, readable output/terminal,
  writable request capacity or completed producer cleanup can unblock a host.
  `has_work` describes work runnable now; Go can return false because goroutines
  run independently. A false result permits waiting for notification, not
  treating a pending operation as complete.
- Notifications may coalesce and arrive on any producer thread. A callback
  only records/posts a wakeup; it must not enter any ABI operation, including
  `has_work`. Hosts retain a pending notification or generation counter so a
  signal between checking state and beginning a wait cannot be lost. One
  executor serializes each instance and leaves response queues bounded.
  Keep the callback and its state alive through PENDING destruction. After
  destroy returns OK, no callback is running or can begin; discard queued host
  tasks without accessing the freed instance.
- Go coalesces host notifications per instance before entering cgo or JS; a
  poll acknowledges the outstanding notification. Internal Go waiters use a
  separate signal. Data/capacity callbacks run outside the call lock while a
  running or retained producer protects their lifetime; final retirement keeps
  its callback atomic with destruction. Released calls with no remaining
  producers are reclaimed without waiting for another poll.
- Releasing a call can enqueue producer cancellation/destruction callbacks.
  Schedule bounded polling turns in the background while `has_work` is true,
  even after releasing the last call. Call close returns without waiting for
  unrelated work to become idle. Instance close first cancels/releases all
  calls, then waits for producer retirement. Continuously ready CPU work still
  needs execution time; bounded turns let other calls and cancellation run.
- Input/output queues are bounded. Await sends. Read bidi output concurrently
  with sending input; waiting for half-close before reading can deadlock a
  bounded bidirectional protocol.
- Before terminal status is published, a second non-streaming request or
  half-close without its required request aborts the call with status 3 and
  discards queued responses. Already published terminal results take precedence.
- In C, retry a blocked response in `on_writable`. Pause input callbacks with
  `synurang_stream_pause_input` while saving that response, then resume them.
  Callback arguments are borrowed; copy data needed after a callback returns.
- Retain C streams before external async work and release on completion/cancel.
  Go handlers normally own their work until return; use `Call.Retain` or
  `Stream.Retain` for cleanup that outlives the handler. Rust tracks outstanding
  call context/sender/waker ownership during shutdown.
  Go services can register `Instance.OnClose` for final nonblocking resource
  release after all handlers and retained work stop.
- Cancellation is cooperative. Instance destruction returns PENDING while
  producer work remains. Hosts must keep the module loaded and poll/retry until
  destruction succeeds. A handler that ignores cancellation can delay close.
- Native Go modules pin their shared-library mapping for the process lifetime
  because Go runtime threads can outlive an individual instance. Closing still
  releases the instance and its calls; it does not unload the Go runtime.
- Empty protobuf messages are valid data, distinct from EOF. Terminal status is
  immutable once the provider publishes it, except that response-cardinality
  validation may reject an otherwise completed unary RPC with status 13.
  A unary result is successful only
  after its final status, so an error following a response remains an error.
  Errors retain the serialized `core.v1.Error` payload and RPC status code.
- Host deadline/abort policy may reject a call locally even if the provider
  has already finished. Cancellation cannot overwrite the provider's published
  terminal status at the raw ABI boundary.
  Python's native host exposes the provider's result after forwarding cancel or
  expiry; it does not impose a competing local terminal status. The ABI's cancel
  return value acknowledges the operation, not which outcome won the race.

See the runnable providers in [test/call](test/call), the
[Dart host](lib/src/module/README.md), [Java](java/README.md),
[C#](csharp/Synurang.Call/README.md), [Python](python/README.md),
[Swift](swift/README.md), and [Go gRPC adapter](pkg/callgrpc/README.md).

The [shared-memory example](example/shared_memory/README.md) uses Python and C++
callers with a C backend on Linux. Protobuf carries a POSIX buffer descriptor
and completion; the backend modifies the shared payload directly and unmaps it
before acknowledging completion. Run both callers with `make test_shared_memory`.
The [frame-queue extension](example/shared_memory/QUEUE.md) uses a bidi call and
a shared image pool for FIFO, Latest and Batch processing in C, with concurrent
Python/C++ producers and consumers. Run `make test_shared_memory_queue` for both
scenarios, a visual replay, and backpressure/cleanup checks.

## Verification

```sh
# Linux: native + static addons, Node/browser WASM, direct and workers.
WASI_SDK_PATH=/path/to/wasi-sdk make test_call_runtime

# Also execute every native language host and Dart JS/WasmGC browser client.
WASI_SDK_PATH=/path/to/wasi-sdk SWIFT=/path/to/swift make test_call_all
```

The full suite requires Clang/WASI SDK, the Rust wasm32-unknown-unknown target,
Go/protoc plugins, C/C++, Node/npm, Python, Java, .NET, Dart/Flutter and Swift.
Missing required tools fail the selected suite rather than counting as a pass.
Playwright installs Chromium for real browser execution. Tests exercise all RPC
shapes, interleaved and concurrent bidi, backpressure, errors, cancellation,
deadlines, independent instances, close during pending work, static linkage,
memory growth, independent polling progress, shared-memory rejection and
C/C++/Rust WASM notification imports. Browser polling and Worker tests run without
cross-origin isolation headers. Native conformance is run on Linux; this change
does not claim Windows, macOS or mobile execution coverage.

## Benchmark

Local measurements on 2026-09-12 compare **the existing FFI API before the call
runtime** with **the current notify-driven call runtime**. Both use a 2-byte
protobuf unary echo with one outstanding request. Hosts exchange pre-encoded
bytes; provider protobuf decoding and encoding are included. The current path
includes open, send, half-close, response and terminal receive, and release.

Ryzen 5 5600U/Linux x86-64; C/C++ `-O2`, Rust release, Go default optimizations.
Values are medians of three separate process runs, each with 300 ms warmup and
1 s measurement. Time per RPC is elapsed wall time divided by completed calls.
The call runtime uses queue capacity 16.

### Dart → native

Dart 3.9.2 AOT. The legacy plugin API is measured both synchronously through
`invokeBackend` and asynchronously through `invokeBackendAsync` on a helper
isolate. The current path uses `NativeModuleHost` and the async `unary` helper.
C++ uses a C++ handler with the generated C binding in both paths.

| Provider | Before: sync FFI (µs/RPC) | Before: async FFI (µs/RPC) | After: call runtime (µs/RPC) | After: RPC/s |
|---|---:|---:|---:|---:|
| C | 2.20 | 13.48 | 10.12 | 98,855 |
| C++ | 2.13 | 13.90 | 10.01 | 99,933 |
| Rust | 2.18 | 13.68 | 10.38 | 96,379 |
| Go | 2.90 | 15.76 | 33.22 | 30,105 |

Direct sync FFI has the lowest latency. Against the legacy async helper-isolate
path, C/C++/Rust take about **24–28% less time**, while Go takes **2.1× as long**
in this immediate-response workload. These are complete API costs, including
scheduling and buffer management.

### TypeScript → WASM

Node.js 24.19.0, TypeScript runtime compiled to ES2022, same-thread non-shared
WASM. The legacy Rust path uses the generated `calls_unary_pb` export through
wasm-bindgen 0.2.117; the current path uses the async `unary` helper. Both loops
yield every 64 operations. Measurements cover direct Node calls, excluding
browser and Worker message transport. The Go helper batches the initial request
operations and can receive the response and terminal in one bridge crossing;
the complete call lifecycle is still included.

| Provider | Before: sync WASM binding (µs/RPC) | After: call runtime (µs/RPC) | After: RPC/s |
|---|---:|---:|---:|
| C | — | 6.21 | 160,911 |
| C++ | — | 6.10 | 163,907 |
| Rust | 0.36 | 6.70 | 149,161 |
| Go | — | 112.11 | 8,920 |

The before/after WASM comparison covers Rust's existing generated binding.
No legacy WASM baseline was measured for C/C++/Go. Rust's full async call
lifecycle takes about **18.8×** the time of its direct sync binding in this tiny
echo workload; the current path completes about **149k RPC/s**.
