/// Protobuf calls over native modules, JavaScript WASM/worker transports, and
/// Dart service implementations. This library has no gRPC dependency.
library;

export 'src/module/core.dart';
export 'src/module/in_process.dart';
export 'src/module/native_stub.dart'
    if (dart.library.ffi) 'src/module/native.dart';
export 'src/module/web_stub.dart'
    if (dart.library.js_interop) 'src/module/web.dart';
