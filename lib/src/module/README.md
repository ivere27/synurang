# Dart module calls

Generate protobuf messages with `protoc-gen-dart`, then generate clients and Dart
service contracts with:

```sh
protoc --dart_out=lib/generated \
  --synurang-ffi_out=lang=dart,mode=client:lib/generated service.proto
```

The generated `ServiceClient` accepts `Transport` and does not import gRPC.
Unary and client streaming return `Future<Response>`, server streaming returns
`Stream<Response>`, and bidi returns `Future<Duplex<Request, Response>>`.
`Duplex.send` and `recv` work before `halfClose`.

```dart
import 'package:synurang/module.dart';
import 'generated/service_client.dart';

final host = NativeModuleHost.load('libservice.so',
    shimPath: 'libsynurang_module_host.so');
final client = ServiceClient(host);
try {
  final response = await client.unary(request,
      options: CallOptions(timeout: Duration(seconds: 2)));
  final call = await client.bidi();
  try {
    await call.send(request);
    final first = await call.recv();
    await call.halfClose();
    await for (final response in call.responses) {
      // Consume subsequent responses.
    }
  } finally {
    await call.close();
  }
} finally {
  await host.close();
}
```

Build the loader shim with CMake's `synurang_module_host` target. It loads the
new `Synurang_GetApi` ABI exclusively. A statically linked executable can pass
its module table to `NativeModuleHost.linked`; it must keep that code loaded
until the host finishes closing. Instances belong to one Dart isolate. If using
an isolate for native work, create its host there and exchange bytes through
ports. Foreign calls never wait; the host yields between bounded polls and
waits asynchronously for producer cleanup before unloading a module.

For Flutter Web/Dart Web, instantiate the shared JavaScript WASM loader or
`WorkerHost`, then pass its JS object to `JsModuleHost.fromTransport`. A loader
for another language, such as Go, can expose the same JavaScript `Transport`
without presenting C memory pointers to Dart. Both JavaScript and WasmGC Dart
compilation are covered by the browser tests.

```dart
import 'dart:js_interop';
import 'package:synurang/module.dart';

@JS('createServiceHost')
external JSPromise<JSObject> createServiceHost();

final host = JsModuleHost.fromTransport(await createServiceHost().toDart);
// Use the same generated ServiceClient(host).
```

To implement a service in Dart, implement the generated `ServiceService`
interface and call `registerService(InProcessTransport, implementation)`.
Handlers receive `CallContext`: observe `context.cancelled` or
`context.throwIfCancelled()` while doing external work. The transport applies
bounded input/output queues, cardinality checks, deadlines and terminal status.
This supports local Dart calls. On the web, `exportTransport(transport)` exposes
the same handlers to JavaScript clients or a worker dispatcher for reverse
calls. It preserves protobuf error details and supports JavaScript AbortSignal.
It does not export Dart handlers as native C function pointers.

Await sends to respect backpressure. Only one receive may be pending per call.
Cancel an RPC through `CancellationToken` or `Duplex.cancel`; always close the
duplex/host. Cancelling a generated response stream closes its underlying call.
A unary response becomes successful only after terminal status, so an error
sent after the response is retained.

`RequestClosedError` means the request side stopped accepting messages while
responses remain readable. Rejected writes inspect at most one foreign result
and preserve any message. Client streaming still accepts an early successful
response without waiting for an unfinished request source.

Run `bash test/test_dart_call_runtime.sh CALL_TEST_OUTPUT` after
`test/test_call_runtime.sh` has generated the native and WASM fixtures. The Dart
runner executes generated clients against native modules and real Chromium
WASM/worker hosts, JavaScript clients against exported Dart handlers, and
backpressure/cancellation/cardinality tests.
