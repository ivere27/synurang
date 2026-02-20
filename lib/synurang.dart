// synurang - Minimal Flutter FFI + gRPC bridge for bidirectional Go/Dart communication
//
// =============================================================================
// THREADING MODEL
// =============================================================================
//
// All FFI calls are performed on a helper isolate to avoid blocking the main
// UI thread. The exception is stream callbacks from Go, which are dispatched
// to the main isolate via NativeCallable.listener (this is unavoidable since
// callbacks must run on the isolate that registered them).
//
// Memory Management:
// - All data from Go is allocated with C.CBytes (C malloc)
// - Dart uses NativeFinalizer to free this memory when the Uint8List is GC'd
// - This provides zero-copy semantics for large data transfers
//
// Threading:
// - Unary RPCs:     Helper isolate (via _CoreIsolateManager)
// - Stream init:    Helper isolate (via _CoreIsolateManager)
// - Stream data:    Main isolate (via NativeCallable.listener callback)
// - Cache ops:      Helper isolate (via _CoreIsolateManager)
//
// =============================================================================
// STREAM CHUNK ORDERING (IMPORTANT)
// =============================================================================
//
// Chunk order is PRESERVED within a single stream session because:
// 1. Each stream gets a unique session ID with its own Go channel
// 2. Chunks are sent sequentially via `await for` within a stream
// 3. Go's buffered channel (DataChan) maintains FIFO order
//
// CRITICAL: Do NOT share a stream session across multiple isolates.
// Each stream session must be owned by exactly ONE isolate. If multiple
// isolates send chunks to the same stream ID, ordering is NOT guaranteed.
//
// Safe:   Isolate A -> Stream 1, Isolate B -> Stream 2 (separate sessions)
// UNSAFE: Isolate A -> Stream 1, Isolate B -> Stream 1 (shared session)
//
// =============================================================================
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:developer' as developer;

import 'package:ffi/ffi.dart';
import 'package:grpc/grpc.dart';
import 'package:protobuf/protobuf.dart' show GeneratedMessage;
import 'package:protobuf/well_known_types/google/protobuf/any.pb.dart' as pb_any;
import 'package:synurang/src/generated/core.pb.dart' as pb;
import 'synurang_bindings_generated.dart';

// Re-export generated proto files
export 'src/generated/core.pb.dart' hide PingResponse;
export 'src/generated/core.pbgrpc.dart';
export 'src/generated/core_ffi.pb.dart';
export 'src/generated/cache.pb.dart';
export 'src/generated/cache.pbgrpc.dart';
export 'src/generated/cache_ffi.pb.dart';

// Re-export well-known types
export 'package:protobuf/well_known_types/google/protobuf/any.pb.dart';
export 'package:protobuf/well_known_types/google/protobuf/empty.pb.dart';
export 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart';
export 'package:protobuf/well_known_types/google/protobuf/duration.pb.dart';
export 'package:protobuf/well_known_types/google/protobuf/struct.pb.dart';
export 'package:protobuf/well_known_types/google/protobuf/wrappers.pb.dart';

// =============================================================================
// Plugin ABI Native Function Types
// =============================================================================

typedef _PluginInvokeNative = Pointer<Char> Function(
    Pointer<Char> method, Pointer<Char> data, Int32 dataLen,
    Pointer<Int32> respLen);
typedef _PluginInvokeDart = Pointer<Char> Function(
    Pointer<Char> method, Pointer<Char> data, int dataLen,
    Pointer<Int32> respLen);

typedef _PluginFreeNative = Void Function(Pointer<Void> ptr);
typedef _PluginFreeDart = void Function(Pointer<Void> ptr);

typedef _PluginStreamOpenNative = Uint64 Function(Pointer<Char> method);
typedef _PluginStreamOpenDart = int Function(Pointer<Char> method);

typedef _PluginStreamSendNative = Int32 Function(
    Uint64 handle, Pointer<Char> data, Int32 dataLen);
typedef _PluginStreamSendDart = int Function(
    int handle, Pointer<Char> data, int dataLen);

typedef _PluginStreamRecvNative = Pointer<Char> Function(
    Uint64 handle, Pointer<Int32> respLen, Pointer<Int32> status);
typedef _PluginStreamRecvDart = Pointer<Char> Function(
    int handle, Pointer<Int32> respLen, Pointer<Int32> status);

typedef _PluginStreamCloseSendNative = Void Function(Uint64 handle);
typedef _PluginStreamCloseSendDart = void Function(int handle);

typedef _PluginStreamCloseNative = Void Function(Uint64 handle);
typedef _PluginStreamCloseDart = void Function(int handle);

// =============================================================================
// Plugin Registry (Multi-Plugin Support)
// =============================================================================

bool _usePluginMode = false;

class _PluginRegistration {
  final String libraryPath;
  final List<String> serviceNames;
  const _PluginRegistration(this.libraryPath, this.serviceNames);
}

final List<_PluginRegistration> _pluginRegistrations = [];

/// Main-isolate plugin entry (holds finalizer + quick stream functions)
class _MainPluginEntry {
  final DynamicLibrary library;
  final NativeFinalizer finalizer;
  final _PluginFreeDart freeFunc;
  final Map<String, _PluginInvokeDart> _invokers = {};
  _PluginStreamSendDart? _streamSend;
  _PluginStreamCloseSendDart? _streamCloseSend;
  _PluginStreamCloseDart? _streamClose;
  bool _streamFuncsLoaded = false;

  _MainPluginEntry(this.library, this.freeFunc, this.finalizer);

  _PluginInvokeDart getInvoker(String serviceName) {
    return _invokers.putIfAbsent(serviceName, () {
      return library.lookupFunction<_PluginInvokeNative, _PluginInvokeDart>(
          'Synurang_Invoke_$serviceName');
    });
  }

  void ensureStreamFuncs() {
    if (_streamFuncsLoaded) return;
    _streamSend = library
        .lookupFunction<_PluginStreamSendNative, _PluginStreamSendDart>(
            'Synurang_Stream_Send');
    _streamCloseSend = library.lookupFunction<_PluginStreamCloseSendNative,
        _PluginStreamCloseSendDart>('Synurang_Stream_CloseSend');
    _streamClose = library
        .lookupFunction<_PluginStreamCloseNative, _PluginStreamCloseDart>(
            'Synurang_Stream_Close');
    _streamFuncsLoaded = true;
  }
}

final List<_MainPluginEntry> _mainPlugins = [];
final Map<String, int> _serviceToPluginIndex = {};

/// Worker-local plugin entry
class _WorkerPluginEntry {
  final DynamicLibrary library;
  final _PluginFreeDart freeFunc;
  _PluginStreamRecvDart? streamRecv;
  _PluginStreamSendDart? streamSend;
  _PluginStreamCloseSendDart? streamCloseSend;
  _PluginStreamCloseDart? streamClose;
  bool _streamFuncsLoaded = false;

  _WorkerPluginEntry(this.library, this.freeFunc);

  void ensureStreamFuncs() {
    if (_streamFuncsLoaded) return;
    streamSend = library
        .lookupFunction<_PluginStreamSendNative, _PluginStreamSendDart>(
            'Synurang_Stream_Send');
    streamRecv = library
        .lookupFunction<_PluginStreamRecvNative, _PluginStreamRecvDart>(
            'Synurang_Stream_Recv');
    streamCloseSend = library.lookupFunction<_PluginStreamCloseSendNative,
        _PluginStreamCloseSendDart>('Synurang_Stream_CloseSend');
    streamClose = library
        .lookupFunction<_PluginStreamCloseNative, _PluginStreamCloseDart>(
            'Synurang_Stream_Close');
    _streamFuncsLoaded = true;
  }
}

class _WorkerServiceEntry {
  final _WorkerPluginEntry plugin;
  final int pluginIndex;
  final _PluginInvokeDart invoke;
  final String serviceName;
  _PluginStreamOpenDart? _streamOpen;

  _WorkerServiceEntry(
      this.plugin, this.pluginIndex, this.invoke, this.serviceName);

  _PluginStreamOpenDart getStreamOpen() {
    _streamOpen ??= plugin.library
        .lookupFunction<_PluginStreamOpenNative, _PluginStreamOpenDart>(
            'Synurang_Stream_${serviceName}_Open');
    return _streamOpen!;
  }
}

final List<_WorkerPluginEntry> _workerPlugins = [];
final Map<String, _WorkerServiceEntry> _workerServices = {};

// Plugin stream state (main isolate only)
final Map<int, _PluginStreamState> _pluginActiveStreams = {};
int _nextDartStreamId = 1;

class _PluginStreamState {
  final StreamController<Uint8List> controller;
  final int pluginIndex;
  int handle = 0;
  _PluginStreamState(this.controller, this.pluginIndex);
}

String _extractServiceName(String method) {
  // "/pkg.Service/Method" → "Service"
  final fullService = method.substring(1, method.lastIndexOf('/'));
  return fullService.substring(fullService.lastIndexOf('.') + 1);
}

// =============================================================================
// FfiError - Structured error with gRPC status code
// =============================================================================

/// Exception thrown when FFI call fails. Includes gRPC status code.
class FfiError implements Exception {
  final String message;
  final int grpcCode;

  const FfiError(this.message, this.grpcCode);

  @override
  String toString() => 'FfiError($grpcCode): $message';
}

// =============================================================================
// FFI Request/Response Types (Internal)
// =============================================================================

class _StartRequest {
  final int id;
  final String storagePath;
  final String cachePath;
  final String engineSocketPath;
  final String engineTcpPort;
  final String viewSocketPath;
  final String viewTcpPort;
  final String token;
  final bool enableCache;
  final int streamTimeout;

  const _StartRequest(
      this.id,
      this.storagePath,
      this.cachePath,
      this.engineSocketPath,
      this.engineTcpPort,
      this.viewSocketPath,
      this.viewTcpPort,
      this.token,
      this.enableCache,
      this.streamTimeout);
}

class _StopRequest {
  final int id;
  const _StopRequest(this.id);
}

class _Response {
  final int id;
  final int result;
  const _Response(this.id, this.result);
}

class _InvokeBackendRequest {
  final int id;
  final String method;
  final Uint8List data;
  const _InvokeBackendRequest(this.id, this.method, this.data);
}

class _InvokeBackendWithMetaRequest {
  final int id;
  final String method;
  final Uint8List data;
  final Uint8List? metadata; // key=value\n encoded
  const _InvokeBackendWithMetaRequest(
      this.id, this.method, this.data, this.metadata);
}

class _InvokeBackendResponse {
  final int id;
  final int address;
  final int len;
  const _InvokeBackendResponse(this.id, this.address, this.len);
}

class _ErrorResponse {
  final int id;
  final Object error;
  const _ErrorResponse(this.id, this.error);
}

// Cache Requests
class _CacheGetRequest {
  final int id;
  final String storeName;
  final String key;
  const _CacheGetRequest(this.id, this.storeName, this.key);
}

class _CacheGetResponse {
  final int id;
  final int address;
  final int len;
  const _CacheGetResponse(this.id, this.address, this.len);
}

class _CachePutRequest {
  final int id;
  final String storeName;
  final String key;
  final Uint8List data;
  final int ttlSeconds;
  const _CachePutRequest(
      this.id, this.storeName, this.key, this.data, this.ttlSeconds);
}

class _CachePutPtrRequest {
  final int id;
  final String storeName;
  final String key;
  final int dataAddress;
  final int dataLen;
  final int ttlSeconds;
  const _CachePutPtrRequest(this.id, this.storeName, this.key, this.dataAddress,
      this.dataLen, this.ttlSeconds);
}

class _CacheContainsRequest {
  final int id;
  final String storeName;
  final String key;
  const _CacheContainsRequest(this.id, this.storeName, this.key);
}

class _CacheDeleteRequest {
  final int id;
  final String storeName;
  final String key;
  const _CacheDeleteRequest(this.id, this.storeName, this.key);
}

class _CacheResponse {
  final int id;
  final int result;
  const _CacheResponse(this.id, this.result);
}

// Stream Requests (for isolate-based stream initiation)
class _ServerStreamRequest {
  final int id;
  final String method;
  final Uint8List data;
  const _ServerStreamRequest(this.id, this.method, this.data);
}

class _ClientStreamRequest {
  final int id;
  final String method;
  const _ClientStreamRequest(this.id, this.method);
}

class _BidiStreamRequest {
  final int id;
  final String method;
  const _BidiStreamRequest(this.id, this.method);
}

class _StreamIdResponse {
  final int id;
  final int streamId;
  const _StreamIdResponse(this.id, this.streamId);
}

// Plugin invoke response (carries pluginIndex for per-plugin finalizer)
class _PluginInvokeResponse {
  final int id;
  final int address;
  final int len;
  final int pluginIndex;
  const _PluginInvokeResponse(this.id, this.address, this.len, this.pluginIndex);
}

// Plugin stream requests
class _PluginServerStreamRequest {
  final int id;
  final int dartStreamId;
  final String method;
  final Uint8List data;
  const _PluginServerStreamRequest(
      this.id, this.dartStreamId, this.method, this.data);
}

class _PluginClientStreamRequest {
  final int id;
  final int dartStreamId;
  final String method;
  const _PluginClientStreamRequest(this.id, this.dartStreamId, this.method);
}

class _PluginBidiStreamRequest {
  final int id;
  final int dartStreamId;
  final String method;
  const _PluginBidiStreamRequest(this.id, this.dartStreamId, this.method);
}

// Worker → Main stream messages
class _PluginStreamData {
  final int dartStreamId;
  final int address;
  final int len;
  final int pluginIndex;
  const _PluginStreamData(
      this.dartStreamId, this.address, this.len, this.pluginIndex);
}

class _PluginStreamEnd {
  final int dartStreamId;
  const _PluginStreamEnd(this.dartStreamId);
}

class _PluginStreamError {
  final int dartStreamId;
  final Object error;
  const _PluginStreamError(this.dartStreamId, this.error);
}

// =============================================================================
// Public API
// =============================================================================

/// OPTIMIZATION: Pre-warm the helper isolate early during app startup.
void prewarmIsolate() {
  // ignore: discarded_futures
  _CoreIsolateManager.instance.ensureInitialized();
}

/// Ensure the native library is loaded and return its resolved path.
/// This should be called on the main isolate before spawning workers.
String ensureLibraryLoaded() {
  _ffi; // Trigger library loading
  return getResolvedLibraryPath()!;
}

/// Reset library state for app restart scenarios.
void resetCoreState() {
  _CoreIsolateManager.instance.reset();
}

/// Register a plugin .so for the given service names.
///
/// Each service name maps to per-service C ABI symbols:
///   `Synurang_Invoke_<ServiceName>` and `Synurang_Stream_<ServiceName>_Open`
/// Plus shared symbols: `Synurang_Free`, `Synurang_Stream_Send/Recv/CloseSend/Close`.
///
/// Call this before any FFI calls. Multiple plugins can be registered.
void registerPlugin(String libraryPath, List<String> serviceNames) {
  _usePluginMode = true;
  final reg = _PluginRegistration(libraryPath, serviceNames);
  _pluginRegistrations.add(reg);

  // Load on main isolate for finalizer + quick stream functions
  final lib = DynamicLibrary.open(libraryPath);
  final freePtr =
      lib.lookup<NativeFunction<_PluginFreeNative>>('Synurang_Free');
  final freeFunc = freePtr.asFunction<_PluginFreeDart>();
  final finalizer = NativeFinalizer(freePtr);

  final pluginIndex = _mainPlugins.length;
  _mainPlugins.add(_MainPluginEntry(lib, freeFunc, finalizer));

  for (final svc in serviceNames) {
    _serviceToPluginIndex[svc] = pluginIndex;
  }

  // Reset isolate pool so workers pick up new plugins
  _CoreIsolateManager.instance.reset();
}

/// Start the Go gRPC server
///
/// All parameters are optional with sensible defaults:
/// - [storagePath]: Path for persistent storage (default: empty)
/// - [cachePath]: Path for cache database (default: empty, cache disabled)
/// - [engineSocketPath]: Unix domain socket path for gRPC (default: empty)
/// - [engineTcpPort]: TCP port for gRPC server (default: empty)
/// - [viewSocketPath]: Unix domain socket for view service (default: empty)
/// - [viewTcpPort]: TCP port for view service (default: empty)
/// - [token]: Authentication token (default: empty)
Future<int> startGrpcServerAsync({
  String storagePath = '',
  String cachePath = '',
  String engineSocketPath = '',
  String engineTcpPort = '',
  String viewSocketPath = '',
  String viewTcpPort = '',
  String token = '',
  bool enableCache = false,
  int streamTimeout = 0,
}) async {
  return _CoreIsolateManager.instance.sendRequest<int>((id) => _StartRequest(
      id,
      storagePath,
      cachePath,
      engineSocketPath,
      engineTcpPort,
      viewSocketPath,
      viewTcpPort,
      token,
      enableCache,
      streamTimeout));
}

/// Stop the Go gRPC server
Future<int> stopGrpcServerAsync() async {
  return _CoreIsolateManager.instance
      .sendRequest<int>((id) => _StopRequest(id));
}

/// Invoke a backend method via FFI.
///
/// Routes through plugin registry in plugin mode, or Go backend in Go mode.
/// Optional parameters (zero-overhead when not used, Go mode only):
/// - [metadata]: Request metadata (e.g., auth tokens)
/// - [timeout]: Per-call timeout (deadline enforcement in Go)
Future<Uint8List> invokeBackendAsync(
  String method,
  Uint8List data, {
  Map<String, String>? metadata,
  Duration? timeout,
}) async {
  // Plugin mode: always uses _InvokeBackendRequest (worker handles dispatch)
  if (_usePluginMode || (metadata == null && timeout == null)) {
    return _CoreIsolateManager.instance.sendRequest<Uint8List>(
        (id) => _InvokeBackendRequest(id, method, data));
  }

  // Go mode with metadata/timeout
  final metaBuffer = StringBuffer();
  if (timeout != null) {
    metaBuffer.write('__timeout_ms=${timeout.inMilliseconds}\n');
  }
  if (metadata != null) {
    for (final entry in metadata.entries) {
      metaBuffer.write('${entry.key}=${entry.value}\n');
    }
  }
  final metaBytes = Uint8List.fromList(utf8.encode(metaBuffer.toString()));

  return _CoreIsolateManager.instance.sendRequest<Uint8List>(
      (id) => _InvokeBackendWithMetaRequest(id, method, data, metaBytes));
}

// =============================================================================
// FFI Streaming APIs
// =============================================================================

/// Stream message types (must match Go constants)
class _StreamMsgType {
  // ignore: unused_field
  static const int start = 0x01;
  static const int data = 0x02;
  static const int end = 0x03;
  static const int error = 0x04;
  static const int trailer = 0x05;
  // ignore: unused_field
  static const int header = 0x06;
}

/// Active stream controllers for receiving data from Go
final Map<int, StreamController<Uint8List>> _activeStreams = {};

/// Active stream trailers (populated when StreamMsgTrailer received)
final Map<int, Map<String, String>> _activeStreamTrailers = {};

/// Result of a server streaming FFI call, providing access to stream and trailers.
class FFIServerStreamResult {
  final Stream<Uint8List> stream;
  int _streamId;
  final Completer<Map<String, String>> _trailersCompleter = Completer();

  FFIServerStreamResult._(this.stream, this._streamId);

  /// Returns trailers after stream closes. Empty map if no trailers.
  Future<Map<String, String>> get trailers => _trailersCompleter.future;

  void _setStreamId(int streamId) {
    _streamId = streamId;
  }

  void _complete() {
    if (!_trailersCompleter.isCompleted) {
      _trailersCompleter
          .complete(_activeStreamTrailers.remove(_streamId) ?? {});
    }
  }
}

/// Pending FFI stream results waiting for trailers
final Map<int, FFIServerStreamResult> _pendingStreamResults = {};

/// Server streaming: Go sends multiple responses.
/// Returns [FFIServerStreamResult] with stream and trailers access.
FFIServerStreamResult invokeBackendServerStreamWithTrailers(
    String method, Uint8List data) {
  _ensureStreamCallbackRegistered();
  final controller = StreamController<Uint8List>();
  late FFIServerStreamResult result;

  result = FFIServerStreamResult._(
    controller.stream.transform(StreamTransformer.fromHandlers(
      handleDone: (sink) {
        result._complete();
        sink.close();
      },
    )),
    -1, // Will be set when stream starts
  );

  _CoreIsolateManager.instance
      .sendRequest<int>((id) => _ServerStreamRequest(id, method, data))
      .then((int streamId) {
    if (streamId < 0) {
      controller.addError(Exception('Failed to start server stream'));
      controller.close();
      return;
    }

    // Update the stream ID so trailers can be retrieved correctly
    result._setStreamId(streamId);

    _activeStreams[streamId] = controller;
    _pendingStreamResults[streamId] = result;

    controller.onCancel = () {
      _activeStreams.remove(streamId);
      _pendingStreamResults.remove(streamId);
      _activeStreamTrailers.remove(streamId);
      _ffi.CloseStream(streamId);
    };

    controller.onListen = () {
      _ffi.StreamReady(streamId);
    };
  }).catchError((Object error) {
    controller.addError(error);
    controller.close();
  });

  return result;
}

/// Server streaming: backend sends multiple responses (simple API without trailers).
Stream<Uint8List> invokeBackendServerStream(String method, Uint8List data) {
  if (_usePluginMode) {
    return _pluginServerStream(method, data);
  }

  // Go mode
  _ensureStreamCallbackRegistered();
  final controller = StreamController<Uint8List>();

  _CoreIsolateManager.instance
      .sendRequest<int>((id) => _ServerStreamRequest(id, method, data))
      .then((int streamId) {
    if (streamId < 0) {
      controller.addError(Exception('Failed to start server stream'));
      controller.close();
      return;
    }

    _activeStreams[streamId] = controller;

    controller.onCancel = () {
      _activeStreams.remove(streamId);
      _activeStreamTrailers.remove(streamId);
      _ffi.CloseStream(streamId);
    };

    _ffi.StreamReady(streamId);
  }).catchError((Object error) {
    controller.addError(error);
    controller.close();
  });

  return controller.stream;
}

/// Plugin-mode server streaming (pull-based recv loop on worker isolate).
Stream<Uint8List> _pluginServerStream(String method, Uint8List data) {
  final dartStreamId = _nextDartStreamId++;
  final svcName = _extractServiceName(method);
  final pluginIndex = _serviceToPluginIndex[svcName]!;
  final controller = StreamController<Uint8List>();

  _pluginActiveStreams[dartStreamId] =
      _PluginStreamState(controller, pluginIndex);

  _CoreIsolateManager.instance
      .sendRequest<int>((id) =>
          _PluginServerStreamRequest(id, dartStreamId, method, data))
      .then((int handle) {
    if (handle == 0) {
      controller.addError(Exception('Failed to start server stream'));
      controller.close();
      _pluginActiveStreams.remove(dartStreamId);
      return;
    }

    _pluginActiveStreams[dartStreamId]!.handle = handle;

    controller.onCancel = () {
      _pluginActiveStreams.remove(dartStreamId);
      final plugin = _mainPlugins[pluginIndex];
      plugin.ensureStreamFuncs();
      plugin._streamClose!(handle);
    };
  }).catchError((Object error) {
    controller.addError(error);
    controller.close();
    _pluginActiveStreams.remove(dartStreamId);
  });

  return controller.stream;
}

/// Client streaming: Dart sends multiple requests, backend returns single response
Future<Uint8List> invokeBackendClientStream(
    String method, Stream<Uint8List> dataStream) async {
  if (_usePluginMode) {
    return _pluginClientStream(method, dataStream);
  }

  // Go mode
  _ensureStreamCallbackRegistered();
  final completer = Completer<Uint8List>();

  final int streamId = await _CoreIsolateManager.instance
      .sendRequest<int>((id) => _ClientStreamRequest(id, method));

  if (streamId < 0) {
    throw Exception('Failed to start client stream');
  }

  final controller = StreamController<Uint8List>();
  _activeStreams[streamId] = controller;

  controller.stream.listen(
    (data) {
      if (!completer.isCompleted) completer.complete(data);
    },
    onError: (e) {
      if (!completer.isCompleted) completer.completeError(e);
    },
    onDone: () {
      _activeStreams.remove(streamId);
    },
  );

  await for (final data in dataStream) {
    final dataPtr = calloc<Uint8>(data.length);
    dataPtr.asTypedList(data.length).setAll(0, data);
    _ffi.SendStreamData(streamId, dataPtr.cast(), data.length);
    calloc.free(dataPtr);
  }

  _ffi.CloseStreamInput(streamId);
  return completer.future;
}

/// Plugin-mode client streaming.
/// Worker runs recv loop; main sends data via quick FFI calls.
Future<Uint8List> _pluginClientStream(
    String method, Stream<Uint8List> dataStream) async {
  final dartStreamId = _nextDartStreamId++;
  final svcName = _extractServiceName(method);
  final pluginIndex = _serviceToPluginIndex[svcName]!;

  final completer = Completer<Uint8List>();
  final controller = StreamController<Uint8List>();
  _pluginActiveStreams[dartStreamId] =
      _PluginStreamState(controller, pluginIndex);

  controller.stream.listen(
    (data) {
      if (!completer.isCompleted) completer.complete(data);
    },
    onError: (e) {
      if (!completer.isCompleted) completer.completeError(e);
    },
    onDone: () {
      _pluginActiveStreams.remove(dartStreamId);
      if (!completer.isCompleted) {
        completer.completeError(Exception('stream ended without response'));
      }
    },
  );

  // Open stream on worker (worker enters recv loop)
  final int handle = await _CoreIsolateManager.instance
      .sendRequest<int>(
          (id) => _PluginClientStreamRequest(id, dartStreamId, method));

  if (handle == 0) {
    _pluginActiveStreams.remove(dartStreamId);
    throw Exception('Failed to start client stream');
  }
  _pluginActiveStreams[dartStreamId]!.handle = handle;

  // Send data from main isolate (quick non-blocking FFI calls)
  final plugin = _mainPlugins[pluginIndex];
  plugin.ensureStreamFuncs();

  await for (final data in dataStream) {
    final dataPtr = calloc<Uint8>(data.length);
    dataPtr.asTypedList(data.length).setAll(0, data);
    plugin._streamSend!(handle, dataPtr.cast(), data.length);
    calloc.free(dataPtr);
  }

  plugin._streamCloseSend!(handle);
  return completer.future;
}

/// Bidirectional streaming: Both sides stream
Stream<Uint8List> invokeBackendBidiStream(
    String method, Stream<Uint8List> dataStream) {
  if (_usePluginMode) {
    return _pluginBidiStream(method, dataStream);
  }

  // Go mode
  _ensureStreamCallbackRegistered();
  final controller = StreamController<Uint8List>();

  _CoreIsolateManager.instance
      .sendRequest<int>((id) => _BidiStreamRequest(id, method))
      .then((int streamId) {
    if (streamId < 0) {
      controller.addError(Exception('Failed to start bidi stream'));
      controller.close();
      return;
    }

    _activeStreams[streamId] = controller;

    controller.onCancel = () {
      _activeStreams.remove(streamId);
      _ffi.CloseStream(streamId);
    };

    _ffi.StreamReady(streamId);
    _sendBidiStreamData(streamId, dataStream, controller);
  }).catchError((Object error) {
    controller.addError(error);
    controller.close();
  });

  return controller.stream;
}

Future<void> _sendBidiStreamData(int streamId, Stream<Uint8List> dataStream,
    StreamController controller) async {
  try {
    await for (final data in dataStream) {
      if (controller.isClosed) break;
      final dataPtr = calloc<Uint8>(data.length);
      dataPtr.asTypedList(data.length).setAll(0, data);
      _ffi.SendStreamData(streamId, dataPtr.cast(), data.length);
      calloc.free(dataPtr);
    }
    _ffi.CloseStreamInput(streamId);
  } catch (e) {
    if (!controller.isClosed) {
      controller.addError(e);
    }
  }
}

/// Plugin-mode bidi streaming.
/// Worker runs recv loop; main sends data via quick FFI calls.
Stream<Uint8List> _pluginBidiStream(
    String method, Stream<Uint8List> dataStream) {
  final dartStreamId = _nextDartStreamId++;
  final svcName = _extractServiceName(method);
  final pluginIndex = _serviceToPluginIndex[svcName]!;
  final controller = StreamController<Uint8List>();

  _pluginActiveStreams[dartStreamId] =
      _PluginStreamState(controller, pluginIndex);

  _CoreIsolateManager.instance
      .sendRequest<int>(
          (id) => _PluginBidiStreamRequest(id, dartStreamId, method))
      .then((int handle) {
    if (handle == 0) {
      controller.addError(Exception('Failed to start bidi stream'));
      controller.close();
      _pluginActiveStreams.remove(dartStreamId);
      return;
    }
    _pluginActiveStreams[dartStreamId]!.handle = handle;

    controller.onCancel = () {
      _pluginActiveStreams.remove(dartStreamId);
      final plugin = _mainPlugins[pluginIndex];
      plugin.ensureStreamFuncs();
      plugin._streamClose!(handle);
    };

    // Send data in the background
    _sendPluginBidiData(handle, pluginIndex, dataStream, controller);
  }).catchError((Object error) {
    controller.addError(error);
    controller.close();
    _pluginActiveStreams.remove(dartStreamId);
  });

  return controller.stream;
}

Future<void> _sendPluginBidiData(int handle, int pluginIndex,
    Stream<Uint8List> dataStream, StreamController controller) async {
  final plugin = _mainPlugins[pluginIndex];
  plugin.ensureStreamFuncs();

  try {
    await for (final data in dataStream) {
      if (controller.isClosed) break;
      final dataPtr = calloc<Uint8>(data.length);
      dataPtr.asTypedList(data.length).setAll(0, data);
      plugin._streamSend!(handle, dataPtr.cast(), data.length);
      calloc.free(dataPtr);
    }
    plugin._streamCloseSend!(handle);
  } catch (e) {
    if (!controller.isClosed) {
      controller.addError(e);
    }
  }
}

/// Cache API - Get raw bytes
Future<Uint8List?> cacheGetRaw(String storeName, String key) async {
  return _CoreIsolateManager.instance
      .sendRequest<Uint8List?>((id) => _CacheGetRequest(id, storeName, key));
}

/// Cache API - Put raw bytes
Future<bool> cachePutRaw(
    String storeName, String key, Uint8List data, int ttlSeconds) async {
  final int result = await _CoreIsolateManager.instance.sendRequest<int>(
      (id) => _CachePutRequest(id, storeName, key, data, ttlSeconds));
  return result == 0;
}

/// Cache API - Put raw bytes using a pointer (Zero-Copy)
///
/// [dataPtr] must point to C-allocated memory (e.g. via calloc/malloc).
/// The caller retains ownership of the memory and is responsible for freeing it
/// after the Future completes.
Future<bool> cachePutPtr(String storeName, String key, Pointer<Uint8> dataPtr,
    int dataLen, int ttlSeconds) async {
  final int result = await _CoreIsolateManager.instance.sendRequest<int>((id) =>
      _CachePutPtrRequest(
          id, storeName, key, dataPtr.address, dataLen, ttlSeconds));
  return result == 0;
}

/// Cache API - Check if key exists
Future<bool> cacheContainsRaw(String storeName, String key) async {
  final int result = await _CoreIsolateManager.instance
      .sendRequest<int>((id) => _CacheContainsRequest(id, storeName, key));
  return result == 1;
}

/// Cache API - Delete key
Future<bool> cacheDeleteRaw(String storeName, String key) async {
  final int result = await _CoreIsolateManager.instance
      .sendRequest<int>((id) => _CacheDeleteRequest(id, storeName, key));
  return result == 0;
}

/// Exception thrown when a request is cancelled due to shutdown/reset.
class CoreShutdownException implements Exception {
  final String message;
  CoreShutdownException([this.message = 'Core reset during shutdown']);
  @override
  String toString() => 'CoreShutdownException: $message';
}

/// Exception thrown when a request times out.
/// This indicates a potential hang in the FFI call or worker isolate.
class CoreTimeoutException implements Exception {
  final String description;
  final Duration timeout;
  CoreTimeoutException(this.description, this.timeout);
  @override
  String toString() =>
      'CoreTimeoutException: "$description" timed out after ${timeout.inSeconds}s';
}

/// Represents a single worker in the isolate pool
class _PoolWorker {
  final Isolate isolate;
  final SendPort sendPort;
  final int index;
  int pendingRequests = 0;
  int completedRequests = 0;

  _PoolWorker(this.index, this.isolate, this.sendPort);
}

/// Statistics about the isolate pool for monitoring and debugging.
class PoolStats {
  /// Number of workers in the pool
  final int workerCount;

  /// Number of pending requests per worker
  final List<int> pendingPerWorker;

  /// Total completed requests per worker
  final List<int> completedPerWorker;

  /// Total pending requests across all workers
  int get totalPending => pendingPerWorker.fold(0, (a, b) => a + b);

  /// Total completed requests across all workers
  int get totalCompleted => completedPerWorker.fold(0, (a, b) => a + b);

  const PoolStats({
    required this.workerCount,
    required this.pendingPerWorker,
    required this.completedPerWorker,
  });

  @override
  String toString() =>
      'PoolStats(workers: $workerCount, pending: $totalPending, completed: $totalCompleted)';
}

/// Get current pool statistics for monitoring.
PoolStats getPoolStats() => _CoreIsolateManager.instance.getStats();

// =============================================================================
// Isolate Pool Implementation
// =============================================================================

/// Default pool size - dynamically calculated based on CPU cores
/// Uses half the available cores, clamped between 2 and 6
int _poolSize = (Platform.numberOfProcessors / 2).clamp(2, 6).toInt();

/// Configure the isolate pool size (call before first request)
void configurePoolSize(int size) {
  if (size < 1) throw ArgumentError('Pool size must be at least 1');
  _poolSize = size;
}

/// Get the current isolate pool size
int getPoolSize() => _poolSize;

class _CoreIsolateManager {
  static final _CoreIsolateManager instance = _CoreIsolateManager._internal();

  _CoreIsolateManager._internal();

  final Map<int, Completer<dynamic>> _requests = <int, Completer<dynamic>>{};
  final Map<int, int> _requestToWorker =
      <int, int>{}; // requestId -> workerIndex
  int _nextRequestId = 0;

  // Isolate pool instead of single isolate
  final List<_PoolWorker> _workers = [];
  ReceivePort? _mainReceivePort;
  bool _isReset = false;
  Future<void>? _initFuture;

  Future<void> ensureInitialized() async {
    await _ensurePoolReady();
  }

  Future<T> sendRequest<T>(Object Function(int id) requestBuilder,
      {Duration timeout = const Duration(seconds: 30),
      String debugLabel = 'request'}) async {
    await _ensurePoolReady();

    final int requestId = _nextRequestId++;
    final request = requestBuilder(requestId);
    final Completer<T> completer = Completer<T>();
    _requests[requestId] = completer;

    // Load-aware scheduling: pick worker with least pending requests
    _PoolWorker worker = _workers[0];
    for (final w in _workers) {
      if (w.pendingRequests < worker.pendingRequests) {
        worker = w;
      }
    }

    _requestToWorker[requestId] = worker.index;
    worker.pendingRequests++;
    worker.sendPort.send(request);

    // Timeout wrapper
    return completer.future.timeout(timeout, onTimeout: () {
      _requests.remove(requestId);
      final workerIdx = _requestToWorker.remove(requestId);
      if (workerIdx != null && workerIdx < _workers.length) {
        _workers[workerIdx].pendingRequests--;
      }
      throw CoreTimeoutException(debugLabel, timeout);
    });
  }

  void reset() {
    // Cancel pending requests
    for (final completer in _requests.values) {
      if (!completer.isCompleted) {
        completer.completeError(CoreShutdownException());
      }
    }
    _requests.clear();
    _requestToWorker.clear();

    // Cleanup workers
    for (final worker in _workers) {
      worker.isolate.kill(priority: Isolate.immediate);
    }
    _workers.clear();

    // Cleanup receive port
    _mainReceivePort?.close();
    _mainReceivePort = null;

    // Reset state
    _isReset = true;
    _nextRequestId = 0;
    _initFuture = null;
  }

  /// Get pool statistics for monitoring and debugging.
  PoolStats getStats() {
    if (_workers.isEmpty) {
      return const PoolStats(
        workerCount: 0,
        pendingPerWorker: [],
        completedPerWorker: [],
      );
    }
    return PoolStats(
      workerCount: _workers.length,
      pendingPerWorker: _workers.map((w) => w.pendingRequests).toList(),
      completedPerWorker: _workers.map((w) => w.completedRequests).toList(),
    );
  }

  Future<void> _ensurePoolReady() {
    if (_isReset || _initFuture == null) {
      _isReset = false;
      _initFuture = _createWorkerPool();
    }
    return _initFuture!;
  }

  Future<void> _createWorkerPool() async {
    String? resolvedPath;
    if (!_usePluginMode) {
      // Go mode: ensure library is loaded on main isolate first to resolve path
      resolvedPath = ensureLibraryLoaded();
    }

    _mainReceivePort = ReceivePort();
    final sendPortCompleter = <Completer<SendPort>>[];

    // Set up the main receive port to handle all responses
    _mainReceivePort!.listen((dynamic data) {
      if (data is (int, SendPort)) {
        // Worker initialization: (workerIndex, sendPort)
        sendPortCompleter[data.$1].complete(data.$2);
        return;
      }
      _handleResponse(data);
    });

    // Spawn all workers in parallel
    final futures = <Future<Isolate>>[];
    for (int i = 0; i < _poolSize; i++) {
      sendPortCompleter.add(Completer<SendPort>());
      futures.add(Isolate.spawn(
        _workerEntryPoint,
        _WorkerInitMessage(
          workerIndex: i,
          mainSendPort: _mainReceivePort!.sendPort,
          libraryName: _libraryName,
          libraryPath: resolvedPath,
          usePluginMode: _usePluginMode,
          pluginRegistrations:
              _usePluginMode ? _pluginRegistrations : const [],
        ),
      ));
    }

    // Wait for all isolates to spawn
    final isolates = await Future.wait(futures);

    // Wait for all workers to send their SendPorts
    final sendPorts = await Future.wait(sendPortCompleter.map((c) => c.future));

    // Build the worker pool
    for (int i = 0; i < _poolSize; i++) {
      _workers.add(_PoolWorker(i, isolates[i], sendPorts[i]));
    }
  }

  void _handleResponse(dynamic data) {
    if (data is _Response) {
      _completeRequest<int>(data.id, data.result);
      return;
    }
    if (data is _InvokeBackendResponse) {
      _completeZeroCopy(data.id, data.address, data.len);
      return;
    }
    // Plugin invoke response (per-plugin finalizer)
    if (data is _PluginInvokeResponse) {
      _completePluginZeroCopy(
          data.id, data.address, data.len, data.pluginIndex);
      return;
    }
    // Plugin stream data (routed directly to StreamController)
    if (data is _PluginStreamData) {
      _handlePluginStreamDataMsg(data);
      return;
    }
    if (data is _PluginStreamEnd) {
      final info = _pluginActiveStreams.remove(data.dartStreamId);
      info?.controller.close();
      return;
    }
    if (data is _PluginStreamError) {
      final info = _pluginActiveStreams.remove(data.dartStreamId);
      if (info != null) {
        info.controller.addError(data.error is String
            ? FfiError(data.error as String, 0)
            : data.error);
        info.controller.close();
      }
      return;
    }
    // Cache Responses
    if (data is _CacheGetResponse) {
      _completeZeroCopy(data.id, data.address, data.len, allowNull: true);
      return;
    }
    if (data is _CacheResponse) {
      _completeRequest<int>(data.id, data.result);
      return;
    }
    // Stream Responses
    if (data is _StreamIdResponse) {
      _completeRequest<int>(data.id, data.streamId);
      return;
    }
    if (data is _ErrorResponse) {
      _updateWorkerStats(data.id);
      final completer = _requests.remove(data.id);
      completer?.completeError(data.error);
      return;
    }
    developer.log(
        'Synurang: unsupported response type: ${data.runtimeType}');
  }

  void _completeRequest<T>(int id, T result) {
    _updateWorkerStats(id);
    final completer = _requests.remove(id) as Completer<T>?;
    completer?.complete(result);
  }

  void _completeZeroCopy(int id, int address, int len,
      {bool allowNull = false}) {
    _updateWorkerStats(id);
    if (allowNull) {
      final completer = _requests.remove(id) as Completer<Uint8List?>?;
      if (address == 0 || len == 0) {
        completer?.complete(null);
        return;
      }
      completer?.complete(_decodeZeroCopyPointer(address, len));
    } else {
      final completer = _requests.remove(id) as Completer<Uint8List>?;
      if (address == 0) {
        completer?.complete(Uint8List(0));
        return;
      }
      completer?.complete(_decodeZeroCopyPointer(address, len));
    }
  }

  /// Update worker stats when a request completes.
  void _updateWorkerStats(int requestId) {
    final workerIdx = _requestToWorker.remove(requestId);
    if (workerIdx != null && workerIdx < _workers.length) {
      final worker = _workers[workerIdx];
      worker.pendingRequests--;
      worker.completedRequests++;
    }
  }

  Uint8List _decodeZeroCopyPointer(int address, int len) {
    final ptr = Pointer<Void>.fromAddress(address);
    final result = ptr.cast<Uint8>().asTypedList(len);
    final payload = _NativePayload();
    _finalizer.attach(payload, ptr.cast(), detach: payload, externalSize: len);
    _payloadExpando[result] = payload;
    return result;
  }

  /// Complete a plugin invoke response with per-plugin finalizer.
  /// Response format: [status:1byte][payload...] where status 0=success, 1=error.
  void _completePluginZeroCopy(
      int id, int address, int totalLen, int pluginIndex) {
    _updateWorkerStats(id);
    final completer = _requests.remove(id) as Completer<Uint8List>?;
    if (completer == null) return;

    if (address == 0 || totalLen <= 0) {
      completer.complete(Uint8List(0));
      return;
    }

    final ptr = Pointer<Void>.fromAddress(address);
    final allBytes = ptr.cast<Uint8>();
    final status = allBytes.value; // byte 0
    final plugin = _mainPlugins[pluginIndex];

    if (status == 1) {
      // Error
      final errorBytes = allBytes.elementAt(1).asTypedList(totalLen - 1);
      final errorMsg = utf8.decode(errorBytes);
      plugin.freeFunc(ptr);
      completer.completeError(FfiError(errorMsg, 0));
      return;
    }

    // Success: zero-copy payload (skip status byte)
    final payload = allBytes.elementAt(1).asTypedList(totalLen - 1);
    final nativePayload = _NativePayload();
    plugin.finalizer.attach(nativePayload, ptr.cast(),
        detach: nativePayload, externalSize: totalLen);
    _payloadExpando[payload] = nativePayload;
    completer.complete(payload);
  }

  /// Handle plugin stream data message (route to StreamController).
  void _handlePluginStreamDataMsg(_PluginStreamData data) {
    final info = _pluginActiveStreams[data.dartStreamId];
    if (info == null) {
      // Stream already cancelled — free the pointer
      if (data.address != 0) {
        _mainPlugins[data.pluginIndex]
            .freeFunc(Pointer<Void>.fromAddress(data.address));
      }
      return;
    }

    if (data.address == 0 || data.len <= 0) return;

    final ptr = Pointer<Void>.fromAddress(data.address);
    final allBytes = ptr.cast<Uint8>();
    final status = allBytes.value;
    final plugin = _mainPlugins[info.pluginIndex];

    if (status == 1) {
      // Error in stream data
      final errorBytes = allBytes.elementAt(1).asTypedList(data.len - 1);
      final errorMsg = utf8.decode(errorBytes);
      plugin.freeFunc(ptr);
      info.controller.addError(FfiError(errorMsg, 0));
      return;
    }

    // Success: zero-copy payload (skip status byte)
    final payload = allBytes.elementAt(1).asTypedList(data.len - 1);
    final nativePayload = _NativePayload();
    plugin.finalizer.attach(nativePayload, ptr.cast(),
        detach: nativePayload, externalSize: data.len);
    _payloadExpando[payload] = nativePayload;
    info.controller.add(payload);
  }
}

/// Worker init message including worker index and resolved library path
class _WorkerInitMessage {
  final int workerIndex;
  final SendPort mainSendPort;
  final String libraryName;
  final String? libraryPath;
  final bool usePluginMode;
  final List<_PluginRegistration> pluginRegistrations;

  _WorkerInitMessage({
    required this.workerIndex,
    required this.mainSendPort,
    required this.libraryName,
    this.libraryPath,
    this.usePluginMode = false,
    this.pluginRegistrations = const [],
  });
}

/// Worker isolate entry point
void _workerEntryPoint(_WorkerInitMessage msg) {
  if (msg.usePluginMode) {
    _initWorkerPlugins(msg.pluginRegistrations);
  } else {
    // Go mode: configure with the resolved library path from main isolate
    configureSynurang(
        libraryName: msg.libraryName, libraryPath: msg.libraryPath);
  }

  final receivePort = ReceivePort();
  receivePort.listen((dynamic data) {
    _handleIsolateMessage(data, msg.mainSendPort);
  });

  // Send back (workerIndex, sendPort) tuple
  msg.mainSendPort.send((msg.workerIndex, receivePort.sendPort));
}

/// Initialize worker-local plugin state from registrations.
void _initWorkerPlugins(List<_PluginRegistration> registrations) {
  _usePluginMode = true;
  for (int i = 0; i < registrations.length; i++) {
    final reg = registrations[i];
    final lib = DynamicLibrary.open(reg.libraryPath);
    final freeFunc =
        lib.lookupFunction<_PluginFreeNative, _PluginFreeDart>(
            'Synurang_Free');
    final workerPlugin = _WorkerPluginEntry(lib, freeFunc);
    _workerPlugins.add(workerPlugin);

    for (final svc in reg.serviceNames) {
      final invoke =
          lib.lookupFunction<_PluginInvokeNative, _PluginInvokeDart>(
              'Synurang_Invoke_$svc');
      _workerServices[svc] =
          _WorkerServiceEntry(workerPlugin, i, invoke, svc);
    }
  }
}

// =============================================================================
// Isolate Message Handler
// =============================================================================

void _handleIsolateMessage(dynamic data, SendPort sendPort) {
  // Plugin-mode handlers
  if (_usePluginMode) {
    _handlePluginIsolateMessage(data, sendPort);
    return;
  }

  // Go-mode handlers below
  if (data is _StartRequest) {
    final Pointer<CoreArgument> cArg = calloc<CoreArgument>();
    cArg.ref.storagePath = data.storagePath.toNativeUtf8().cast<Char>();
    cArg.ref.cachePath = data.cachePath.toNativeUtf8().cast<Char>();
    cArg.ref.engineSocketPath =
        data.engineSocketPath.toNativeUtf8().cast<Char>();
    cArg.ref.engineTcpPort = data.engineTcpPort.toNativeUtf8().cast<Char>();
    cArg.ref.viewSocketPath = data.viewSocketPath.toNativeUtf8().cast<Char>();
    cArg.ref.viewTcpPort = data.viewTcpPort.toNativeUtf8().cast<Char>();
    cArg.ref.token = data.token.toNativeUtf8().cast<Char>();
    cArg.ref.enableCache = data.enableCache ? 1 : 0;
    cArg.ref.streamTimeout = data.streamTimeout;

    final int result = _ffi.StartGrpcServer(cArg.ref);
    calloc.free(cArg.ref.storagePath);
    calloc.free(cArg.ref.cachePath);
    calloc.free(cArg.ref.engineSocketPath);
    calloc.free(cArg.ref.engineTcpPort);
    calloc.free(cArg.ref.viewSocketPath);
    calloc.free(cArg.ref.viewTcpPort);
    calloc.free(cArg.ref.token);
    calloc.free(cArg);

    sendPort.send(_Response(data.id, result));
    return;
  }
  if (data is _StopRequest) {
    final int result = _ffi.StopGrpcServer();
    sendPort.send(_Response(data.id, result));
    return;
  }
  if (data is _InvokeBackendRequest) {
    try {
      final ffiData = _invokeBackendRaw(data.method, data.data);

      if (ffiData.data == nullptr) {
        sendPort.send(_InvokeBackendResponse(data.id, 0, 0));
        return;
      }

      if (ffiData.len < 0) {
        final errorLen = -ffiData.len;
        final errorBytes = ffiData.data.cast<Uint8>().asTypedList(errorLen);

        Object errorToThrow;
        try {
          final pbErr = pb.Error.fromBuffer(errorBytes);
          errorToThrow = FfiError(pbErr.message, pbErr.grpcCode);
        } catch (e) {
          final errorMessage = String.fromCharCodes(errorBytes);
          errorToThrow = FfiError(errorMessage, 0);
        }
        _ffi.FreeFfiData(ffiData.data);
        sendPort.send(_ErrorResponse(data.id, errorToThrow));
      } else {
        sendPort.send(
            _InvokeBackendResponse(data.id, ffiData.data.address, ffiData.len));
      }
    } catch (e) {
      sendPort.send(_ErrorResponse(data.id, e));
    }
    return;
  }
  if (data is _InvokeBackendWithMetaRequest) {
    try {
      final ffiData =
          _invokeBackendWithMetaRaw(data.method, data.data, data.metadata);

      if (ffiData.data == nullptr) {
        sendPort.send(_InvokeBackendResponse(data.id, 0, 0));
        return;
      }

      if (ffiData.len < 0) {
        final errorLen = -ffiData.len;
        final errorBytes = ffiData.data.cast<Uint8>().asTypedList(errorLen);

        Object errorToThrow;
        try {
          final pbErr = pb.Error.fromBuffer(errorBytes);
          errorToThrow = FfiError(pbErr.message, pbErr.grpcCode);
        } catch (e) {
          final errorMessage = String.fromCharCodes(errorBytes);
          errorToThrow = FfiError(errorMessage, 0);
        }
        _ffi.FreeFfiData(ffiData.data);
        sendPort.send(_ErrorResponse(data.id, errorToThrow));
      } else {
        sendPort.send(
            _InvokeBackendResponse(data.id, ffiData.data.address, ffiData.len));
      }
    } catch (e) {
      sendPort.send(_ErrorResponse(data.id, e));
    }
    return;
  }

  // Cache Handlers
  if (data is _CacheGetRequest) {
    try {
      final storeNamePtr = data.storeName.toNativeUtf8().cast<Char>();
      final keyPtr = data.key.toNativeUtf8().cast<Char>();

      final ffiData = _ffi.CacheGet(storeNamePtr, keyPtr);

      calloc.free(storeNamePtr);
      calloc.free(keyPtr);

      if (ffiData.data == nullptr) {
        sendPort.send(_CacheGetResponse(data.id, 0, 0));
      } else {
        sendPort.send(
            _CacheGetResponse(data.id, ffiData.data.address, ffiData.len));
      }
    } catch (e) {
      sendPort.send(_ErrorResponse(data.id, e));
    }
    return;
  }
  if (data is _CachePutRequest) {
    try {
      final storeNamePtr = data.storeName.toNativeUtf8().cast<Char>();
      final keyPtr = data.key.toNativeUtf8().cast<Char>();
      final dataPtr = calloc<Uint8>(data.data.length);
      final dataList = dataPtr.asTypedList(data.data.length);
      dataList.setAll(0, data.data);

      final result = _ffi.CachePut(storeNamePtr, keyPtr, dataPtr.cast<Void>(),
          data.data.length, data.ttlSeconds);

      calloc.free(storeNamePtr);
      calloc.free(keyPtr);
      calloc.free(dataPtr);
      sendPort.send(_CacheResponse(data.id, result));
    } catch (e) {
      sendPort.send(_ErrorResponse(data.id, e));
    }
    return;
  }
  if (data is _CachePutPtrRequest) {
    try {
      final storeNamePtr = data.storeName.toNativeUtf8().cast<Char>();
      final keyPtr = data.key.toNativeUtf8().cast<Char>();

      // Zero-copy: Pass the address directly.
      // Caller owns the memory, so we do not free dataPtr here.
      final dataPtr = Pointer<Void>.fromAddress(data.dataAddress);

      final result = _ffi.CachePut(
          storeNamePtr, keyPtr, dataPtr, data.dataLen, data.ttlSeconds);

      calloc.free(storeNamePtr);
      calloc.free(keyPtr);
      sendPort.send(_CacheResponse(data.id, result));
    } catch (e) {
      sendPort.send(_ErrorResponse(data.id, e));
    }
    return;
  }
  if (data is _CacheContainsRequest) {
    try {
      final storeNamePtr = data.storeName.toNativeUtf8().cast<Char>();
      final keyPtr = data.key.toNativeUtf8().cast<Char>();

      final result = _ffi.CacheContains(storeNamePtr, keyPtr);
      calloc.free(storeNamePtr);
      calloc.free(keyPtr);
      sendPort.send(_CacheResponse(data.id, result));
    } catch (e) {
      sendPort.send(_ErrorResponse(data.id, e));
    }
    return;
  }
  if (data is _CacheDeleteRequest) {
    try {
      final storeNamePtr = data.storeName.toNativeUtf8().cast<Char>();
      final keyPtr = data.key.toNativeUtf8().cast<Char>();

      final result = _ffi.CacheDelete(storeNamePtr, keyPtr);
      calloc.free(storeNamePtr);
      calloc.free(keyPtr);
      sendPort.send(_CacheResponse(data.id, result));
    } catch (e) {
      sendPort.send(_ErrorResponse(data.id, e));
    }
    return;
  }

  // Stream Handlers - FFI calls on helper isolate to avoid blocking main thread
  if (data is _ServerStreamRequest) {
    try {
      final methodPtr = data.method.toNativeUtf8();
      final dataPtr = calloc<Uint8>(data.data.length);
      final dataList = dataPtr.asTypedList(data.data.length);
      dataList.setAll(0, data.data);

      final streamId = _ffi.InvokeBackendServerStream(
        methodPtr.cast(),
        dataPtr.cast(),
        data.data.length,
      );

      calloc.free(methodPtr);
      calloc.free(dataPtr);

      sendPort.send(_StreamIdResponse(data.id, streamId));
    } catch (e) {
      sendPort.send(_ErrorResponse(data.id, e));
    }
    return;
  }
  if (data is _ClientStreamRequest) {
    try {
      final methodPtr = data.method.toNativeUtf8();
      final streamId = _ffi.InvokeBackendClientStream(methodPtr.cast());
      calloc.free(methodPtr);

      sendPort.send(_StreamIdResponse(data.id, streamId));
    } catch (e) {
      sendPort.send(_ErrorResponse(data.id, e));
    }
    return;
  }
  if (data is _BidiStreamRequest) {
    try {
      final methodPtr = data.method.toNativeUtf8();
      final streamId = _ffi.InvokeBackendBidiStream(methodPtr.cast());
      calloc.free(methodPtr);

      sendPort.send(_StreamIdResponse(data.id, streamId));
    } catch (e) {
      sendPort.send(_ErrorResponse(data.id, e));
    }
    return;
  }

  developer.log('Synurang isolate: unsupported message type: ${data.runtimeType}');
}

// =============================================================================
// Plugin-Mode Isolate Message Handler
// =============================================================================

_WorkerServiceEntry? _resolveWorkerService(String method) {
  final svcName = _extractServiceName(method);
  return _workerServices[svcName];
}

void _handlePluginIsolateMessage(dynamic data, SendPort sendPort) {
  if (data is _InvokeBackendRequest) {
    try {
      final service = _resolveWorkerService(data.method);
      if (service == null) {
        sendPort.send(_ErrorResponse(
            data.id,
            FfiError(
                'service not found: ${_extractServiceName(data.method)}', 0)));
        return;
      }

      final methodPtr = data.method.toNativeUtf8().cast<Char>();
      final dataPtr = calloc<Uint8>(data.data.length);
      dataPtr.asTypedList(data.data.length).setAll(0, data.data);
      final respLenPtr = calloc<Int32>();

      final resultPtr = service.invoke(
          methodPtr, dataPtr.cast<Char>(), data.data.length, respLenPtr);
      final respLen = respLenPtr.value;

      calloc.free(methodPtr);
      calloc.free(dataPtr);
      calloc.free(respLenPtr);

      if (resultPtr == nullptr || respLen <= 0) {
        sendPort.send(
            _ErrorResponse(data.id, FfiError('null response from plugin', 0)));
        return;
      }

      // Check status byte on worker to handle errors without zero-copy
      final status = resultPtr.cast<Uint8>().value;
      if (status == 1) {
        final errorBytes =
            resultPtr.cast<Uint8>().elementAt(1).asTypedList(respLen - 1);
        final errorMsg = utf8.decode(errorBytes);
        service.plugin.freeFunc(resultPtr.cast<Void>());
        sendPort.send(_ErrorResponse(data.id, FfiError(errorMsg, 0)));
        return;
      }

      // Success: send pointer for zero-copy on main isolate
      sendPort.send(_PluginInvokeResponse(
          data.id, resultPtr.cast<Void>().address, respLen,
          service.pluginIndex));
    } catch (e) {
      sendPort.send(_ErrorResponse(data.id, e));
    }
    return;
  }

  if (data is _PluginServerStreamRequest) {
    try {
      final service = _resolveWorkerService(data.method);
      if (service == null) {
        sendPort.send(_StreamIdResponse(data.id, 0));
        return;
      }

      service.plugin.ensureStreamFuncs();
      final methodPtr = data.method.toNativeUtf8().cast<Char>();
      final handle = service.getStreamOpen()(methodPtr);
      calloc.free(methodPtr);

      if (handle == 0) {
        sendPort.send(_StreamIdResponse(data.id, 0));
        return;
      }

      // Send initial request data to the stream
      final dataPtr = calloc<Uint8>(data.data.length);
      dataPtr.asTypedList(data.data.length).setAll(0, data.data);
      service.plugin.streamSend!(handle, dataPtr.cast<Char>(), data.data.length);
      calloc.free(dataPtr);

      // Complete the sendRequest with the handle
      sendPort.send(_StreamIdResponse(data.id, handle));

      // Enter blocking recv loop (this blocks the worker for the stream duration)
      _pluginStreamRecvLoop(
          data.dartStreamId, handle, service, sendPort);
    } catch (e) {
      sendPort.send(_ErrorResponse(data.id, e));
    }
    return;
  }

  if (data is _PluginClientStreamRequest) {
    try {
      final service = _resolveWorkerService(data.method);
      if (service == null) {
        sendPort.send(_StreamIdResponse(data.id, 0));
        return;
      }

      service.plugin.ensureStreamFuncs();
      final methodPtr = data.method.toNativeUtf8().cast<Char>();
      final handle = service.getStreamOpen()(methodPtr);
      calloc.free(methodPtr);

      if (handle == 0) {
        sendPort.send(_StreamIdResponse(data.id, 0));
        return;
      }

      // Complete the sendRequest with the handle
      sendPort.send(_StreamIdResponse(data.id, handle));

      // Enter blocking recv loop
      _pluginStreamRecvLoop(
          data.dartStreamId, handle, service, sendPort);
    } catch (e) {
      sendPort.send(_ErrorResponse(data.id, e));
    }
    return;
  }

  if (data is _PluginBidiStreamRequest) {
    try {
      final service = _resolveWorkerService(data.method);
      if (service == null) {
        sendPort.send(_StreamIdResponse(data.id, 0));
        return;
      }

      service.plugin.ensureStreamFuncs();
      final methodPtr = data.method.toNativeUtf8().cast<Char>();
      final handle = service.getStreamOpen()(methodPtr);
      calloc.free(methodPtr);

      if (handle == 0) {
        sendPort.send(_StreamIdResponse(data.id, 0));
        return;
      }

      // Complete the sendRequest with the handle
      sendPort.send(_StreamIdResponse(data.id, handle));

      // Enter blocking recv loop
      _pluginStreamRecvLoop(
          data.dartStreamId, handle, service, sendPort);
    } catch (e) {
      sendPort.send(_ErrorResponse(data.id, e));
    }
    return;
  }

  developer.log(
      'Synurang plugin worker: unsupported message type: ${data.runtimeType}');
}

/// Blocking recv loop for plugin streams. Runs on a worker isolate.
/// Sends _PluginStreamData/_PluginStreamEnd/_PluginStreamError to main.
void _pluginStreamRecvLoop(int dartStreamId, int handle,
    _WorkerServiceEntry service, SendPort sendPort) {
  final respLenPtr = calloc<Int32>();
  final statusPtr = calloc<Int32>();

  try {
    while (true) {
      final dataPtr =
          service.plugin.streamRecv!(handle, respLenPtr, statusPtr);
      final status = statusPtr.value;
      final respLen = respLenPtr.value;

      if (status == 1) {
        // EOF
        sendPort.send(_PluginStreamEnd(dartStreamId));
        break;
      }
      if (status >= 2) {
        // Error
        String errorMsg = 'stream error (status $status)';
        if (dataPtr != nullptr && respLen > 0) {
          errorMsg =
              dataPtr.cast<Utf8>().toDartString(length: respLen);
          service.plugin.freeFunc(dataPtr.cast<Void>());
        }
        sendPort.send(_PluginStreamError(dartStreamId, errorMsg));
        break;
      }

      // Data (status == 0)
      if (dataPtr == nullptr || respLen <= 0) continue;

      // Send pointer address + len to main for zero-copy
      sendPort.send(_PluginStreamData(dartStreamId,
          dataPtr.cast<Void>().address, respLen, service.pluginIndex));
    }
  } finally {
    calloc.free(respLenPtr);
    calloc.free(statusPtr);
  }
}

// =============================================================================
// Direct FFI Helpers (Go Mode)
// =============================================================================

String _libraryName = 'synurang';
String? _resolvedLibraryPath;

/// Configure the shared library name to load.
/// This must be called before using any other functionality of the library.
/// Defaults to 'synurang'.
///
/// If [libraryPath] is provided, it will be used directly as the library path.
/// This is useful for worker isolates that need the resolved path.
void configureSynurang({required String libraryName, String? libraryPath}) {
  _libraryName = libraryName;
  _resolvedLibraryPath = libraryPath;
  // Reset bindings so they're reloaded with the new library name
  _bindings = null;
  _dylib = null;
}

/// Get the resolved library path (only available after library is loaded)
String? getResolvedLibraryPath() => _resolvedLibraryPath;

DynamicLibrary? _dylib;
SynurangBindings? _bindings;

DynamicLibrary get _lib {
  if (_dylib != null) return _dylib!;

  String libPath;

  // If we have a resolved path (from main isolate or passed to worker), use it
  if (_resolvedLibraryPath != null) {
    libPath = _resolvedLibraryPath!;
  } else {
    // First load - construct the expected path
    if (Platform.isMacOS || Platform.isIOS) {
      libPath = '$_libraryName.framework/$_libraryName';
    } else if (Platform.isAndroid || Platform.isLinux) {
      libPath = 'lib$_libraryName.so';
    } else if (Platform.isWindows) {
      libPath = '$_libraryName.dll';
    } else {
      throw UnsupportedError('Unknown platform: ${Platform.operatingSystem}');
    }
  }

  try {
    _dylib = DynamicLibrary.open(libPath);
    // Store the resolved path for workers
    _resolvedLibraryPath = libPath;
  } catch (e) {
    throw UnsupportedError(
        'Failed to load shared library: $libPath. Error: $e');
  }
  return _dylib!;
}

SynurangBindings get _ffi {
  _bindings ??= SynurangBindings(_lib);
  return _bindings!;
}

FfiData _invokeBackendRaw(String method, Uint8List data) {
  final methodPtr = method.toNativeUtf8().cast<Char>();
  final dataPtr = calloc<Uint8>(data.length);
  final dataList = dataPtr.asTypedList(data.length);
  dataList.setAll(0, data);

  final ffiData =
      _ffi.InvokeBackend(methodPtr, dataPtr.cast<Void>(), data.length);

  calloc.free(methodPtr);
  calloc.free(dataPtr);
  return ffiData;
}

FfiData _invokeBackendWithMetaRaw(
    String method, Uint8List data, Uint8List? metadata) {
  final methodPtr = method.toNativeUtf8().cast<Char>();
  final dataPtr = calloc<Uint8>(data.length);
  final dataList = dataPtr.asTypedList(data.length);
  dataList.setAll(0, data);

  Pointer<Uint8> metaPtr = nullptr.cast();
  int metaLen = 0;
  if (metadata != null && metadata.isNotEmpty) {
    metaPtr = calloc<Uint8>(metadata.length);
    final metaList = metaPtr.asTypedList(metadata.length);
    metaList.setAll(0, metadata);
    metaLen = metadata.length;
  }

  final ffiData = _ffi.InvokeBackendWithMeta(methodPtr, dataPtr.cast<Void>(),
      data.length, metaPtr.cast<Void>(), metaLen);

  calloc.free(methodPtr);
  calloc.free(dataPtr);
  if (metaLen > 0) calloc.free(metaPtr);
  return ffiData;
}

/// Invoke backend synchronously (for main thread use)
Uint8List invokeBackend(String method, Uint8List data) {
  if (_usePluginMode) {
    return _invokePluginSync(method, data);
  }

  // Go mode
  final ffiData = _invokeBackendRaw(method, data);
  if (ffiData.data == nullptr) {
    return Uint8List(0);
  }
  if (ffiData.len < 0) {
    final errorLen = -ffiData.len;
    final errorBytes = ffiData.data.cast<Uint8>().asTypedList(errorLen);
    try {
      final pbErr = pb.Error.fromBuffer(errorBytes);
      final any = pb_any.Any.pack(pbErr);
      final error = GrpcError.custom(pbErr.grpcCode, pbErr.message, [any]);
      _ffi.FreeFfiData(ffiData.data);
      throw error;
    } catch (e) {
      _ffi.FreeFfiData(ffiData.data);
      if (e is GrpcError) rethrow;
      final errorMessage = String.fromCharCodes(errorBytes);
      throw Exception(errorMessage);
    }
  }
  final result = ffiData.data.cast<Uint8>().asTypedList(ffiData.len);
  final payload = _NativePayload();
  _finalizer.attach(payload, ffiData.data.cast(),
      detach: payload, externalSize: ffiData.len);
  _payloadExpando[result] = payload;
  return result;
}

/// Plugin-mode synchronous invoke on main isolate.
Uint8List _invokePluginSync(String method, Uint8List data) {
  final svcName = _extractServiceName(method);
  final pluginIndex = _serviceToPluginIndex[svcName]!;
  final plugin = _mainPlugins[pluginIndex];
  final invoker = plugin.getInvoker(svcName);

  final methodPtr = method.toNativeUtf8().cast<Char>();
  final dataPtr = calloc<Uint8>(data.length);
  dataPtr.asTypedList(data.length).setAll(0, data);
  final respLenPtr = calloc<Int32>();

  final resultPtr =
      invoker(methodPtr, dataPtr.cast<Char>(), data.length, respLenPtr);
  final respLen = respLenPtr.value;

  calloc.free(methodPtr);
  calloc.free(dataPtr);
  calloc.free(respLenPtr);

  if (resultPtr == nullptr || respLen <= 0) {
    return Uint8List(0);
  }

  final status = resultPtr.cast<Uint8>().value;

  if (status == 1) {
    final errorBytes =
        resultPtr.cast<Uint8>().elementAt(1).asTypedList(respLen - 1);
    final errorMsg = utf8.decode(errorBytes);
    plugin.freeFunc(resultPtr.cast<Void>());
    throw FfiError(errorMsg, 0);
  }

  // Zero-copy success response (skip status byte)
  final payload = resultPtr.cast<Uint8>().elementAt(1).asTypedList(respLen - 1);
  final nativePayload = _NativePayload();
  plugin.finalizer.attach(nativePayload, resultPtr.cast(),
      detach: nativePayload, externalSize: respLen);
  _payloadExpando[payload] = nativePayload;
  return payload;
}

// Marker class for keeping pointers alive
class _NativePayload implements Finalizable {}

final Expando<_NativePayload> _payloadExpando = Expando();

final _freeFfiDataPtr =
    _lib.lookup<NativeFunction<Void Function(Pointer<Void>)>>('FreeFfiData');
final _finalizer = NativeFinalizer(_freeFfiDataPtr);

// =============================================================================
// FFI Stream Helpers (Exposed for Dart Handlers)
// =============================================================================

/// Send data to a Go stream (for Dart -> Go streaming)
void sendStreamData(int streamId, Uint8List data) {
  final dataPtr = calloc<Uint8>(data.length);
  final dataList = dataPtr.asTypedList(data.length);
  dataList.setAll(0, data);
  _ffi.SendStreamData(streamId, dataPtr.cast(), data.length);
  calloc.free(dataPtr);
}

/// Close a stream (signal EOF to Go)
void closeStream(int streamId) {
  _ffi.CloseStream(streamId);
}

/// Register a stream controller for receiving data from Go
void registerStreamController(
    int streamId, StreamController<Uint8List> controller) {
  _activeStreams[streamId] = controller;
}

// =============================================================================
// Dart Handler Registration (Go -> Dart callbacks)
// =============================================================================

typedef InvokeDartCallbackNative = Void Function(
    Int64 requestId, Pointer<Utf8> method, Pointer<Void> data, Int64 len);

typedef DartHandler = Uint8List Function(String method, Uint8List data);
DartHandler? _dartHandler;
NativeCallable<InvokeDartCallbackNative>? _callback;

void registerDartHandler(DartHandler handler) {
  _dartHandler = handler;
  final register = _lib
      .lookup<
              NativeFunction<
                  Void Function(
                      Pointer<NativeFunction<InvokeDartCallbackNative>>)>>(
          'RegisterDartCallback')
      .asFunction<
          void Function(Pointer<NativeFunction<InvokeDartCallbackNative>>)>();
  _callback =
      NativeCallable<InvokeDartCallbackNative>.listener(_handleDartCallback);
  register(_callback!.nativeFunction);

  // Also register the stream callback
  _ensureStreamCallbackRegistered();
}

// =============================================================================
// Stream Callback Registration (Go -> Dart streaming data)
// =============================================================================

typedef StreamCallbackNative = Void Function(
    Int64 streamId, Int8 msgType, Pointer<Void> data, Int64 len);

NativeCallable<StreamCallbackNative>? _streamCallbackHandle;
Completer<void>? _streamCallbackCompleter;

/// Thread-safe stream callback registration using a Completer pattern.
/// This ensures only one registration occurs even when called concurrently
/// from multiple stream invocations.
void _ensureStreamCallbackRegistered() {
  // Fast path: already registered
  if (_streamCallbackHandle != null) return;

  // Synchronization: only one caller initializes
  Completer<void>? myCompleter;
  bool shouldInit = false;

  // Note: Dart is single-threaded for synchronous code, but this pattern
  // ensures correctness even with async gaps. Zone-local sync is enough here.
  if (_streamCallbackCompleter == null) {
    _streamCallbackCompleter = Completer<void>();
    myCompleter = _streamCallbackCompleter;
    shouldInit = true;
  }

  if (shouldInit) {
    try {
      final register = _lib
          .lookup<
                  NativeFunction<
                      Void Function(
                          Pointer<NativeFunction<StreamCallbackNative>>)>>(
              'RegisterStreamCallback')
          .asFunction<
              void Function(Pointer<NativeFunction<StreamCallbackNative>>)>();

      _streamCallbackHandle =
          NativeCallable<StreamCallbackNative>.listener(_handleStreamCallback);
      register(_streamCallbackHandle!.nativeFunction);
      myCompleter!.complete();
    } catch (e) {
      _streamCallbackCompleter = null; // Reset for retry
      myCompleter!.completeError(e);
      rethrow;
    }
  }
}

void _handleStreamCallback(
    int streamId, int msgType, Pointer<Void> data, int len) {
  final controller = _activeStreams[streamId];
  if (controller == null) {
    developer.log('Dart: WARNING - Controller not found for stream $streamId!');
    // Still need to free the data if Go allocated it
    if (data != nullptr && len > 0) {
      _ffi.FreeFfiData(data);
    }
    return;
  }

  switch (msgType) {
    case _StreamMsgType.data:
      if (len > 0) {
        final zeroCopyData = data.cast<Uint8>().asTypedList(len);
        final payload = _NativePayload();
        _finalizer.attach(payload, data.cast(),
            detach: payload, externalSize: len);
        _payloadExpando[zeroCopyData] = payload;
        controller.add(zeroCopyData);
      }
      break;
    case _StreamMsgType.trailer:
      if (len > 0) {
        final trailerStr = data.cast<Utf8>().toDartString(length: len);
        final trailers = <String, String>{};
        for (final line in trailerStr.split('\n')) {
          if (line.isEmpty) continue;
          final idx = line.indexOf('=');
          if (idx > 0) {
            trailers[line.substring(0, idx)] = line.substring(idx + 1);
          }
        }
        _activeStreamTrailers[streamId] = trailers;
        _ffi.FreeFfiData(data);
      }
      break;
    case _StreamMsgType.end:
      _activeStreams.remove(streamId);
      controller.close();
      break;
    case _StreamMsgType.error:
      final errorMsg =
          len > 0 ? data.cast<Utf8>().toDartString() : 'Unknown stream error';
      if (len > 0) {
        _ffi.FreeFfiData(data);
      }
      _activeStreams.remove(streamId);
      _activeStreamTrailers.remove(streamId);
      controller.addError(Exception(errorMsg));
      controller.close();
      break;
  }
}

void unregisterDartHandler() {
  _dartHandler = null;
  _callback?.close();
  _callback = null;
}

void _handleDartCallback(
    int requestId, Pointer<Utf8> method, Pointer<Void> data, int len) {
  if (_dartHandler == null) {
    _ffi.SendFfiResponse(requestId, nullptr, 0);
    return;
  }
  final methodName = method.toDartString();
  final dataBytes = data.cast<Uint8>().asTypedList(len);

  try {
    final responseBytes = _dartHandler!(methodName, dataBytes);
    final resultPtr = calloc<Uint8>(responseBytes.length);
    final resultList = resultPtr.asTypedList(responseBytes.length);
    resultList.setAll(0, responseBytes);

    _ffi.SendFfiResponse(
        requestId, resultPtr.cast<Void>(), responseBytes.length);
    calloc.free(resultPtr);
  } catch (e) {
    developer.log('Error in Dart callback: $e');
    _ffi.SendFfiResponse(requestId, nullptr, 0);
  }
}

// =============================================================================
// FfiClientChannel - gRPC ClientChannel implementation for FFI transport
// =============================================================================

/// A [ClientChannel] implementation that routes gRPC calls through FFI.
///
/// This allows using standard generated gRPC client stubs with the FFI backend:
/// ```dart
/// final channel = FfiClientChannel();
/// final client = GreeterClient(channel);
/// final response = await client.sayHello(HelloRequest(name: 'World'));
/// ```
///
/// Only unary RPCs are supported. Streaming calls will throw an error.
class FfiClientChannel implements ClientChannel {
  @override
  final ChannelOptions options;

  FfiClientChannel({this.options = const ChannelOptions()});

  @override
  Future<void> shutdown() async {}

  @override
  Future<void> terminate() async {}

  @override
  String get host => 'ffi';

  @override
  int get port => 0;

  @override
  Stream<ConnectionState> get onConnectionStateChanged =>
      Stream.value(ConnectionState.ready);

  @override
  ClientCall<Q, R> createCall<Q, R>(
      ClientMethod<Q, R> method, Stream<Q> requests, CallOptions options) {
    return _FfiClientCall<Q, R>(method, requests, options);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FfiClientCall<Q, R> extends ClientCall<Q, R> {
  final ClientMethod<Q, R> _method;
  final Stream<Q> _requests;
  final _headers = Completer<Map<String, String>>();
  final _trailers = Completer<Map<String, String>>();

  _FfiClientCall(this._method, this._requests, CallOptions options)
      : super(_method, _requests, options);

  @override
  Stream<R> get response async* {
    try {
      // Collect all requests from the stream
      final requests = await _requests.toList();

      if (requests.isEmpty) {
        throw const GrpcError.invalidArgument('No request provided');
      }

      // For FfiClientChannel, we use the unary path for all calls.
      // The Go side's generated *Internal methods flatten streaming to unary.
      // For client/bidi streaming with multiple requests, we send only the last request
      // (matching the behavior of the *Internal methods).
      final request = requests.last;
      if (request is! GeneratedMessage) {
        throw const GrpcError.internal('Request must be a GeneratedMessage');
      }

      final data = request.writeToBuffer();
      final responseBytes = await invokeBackendAsync(_method.path, data);
      final response = _method.responseDeserializer(responseBytes);

      _headers.complete({});
      _trailers.complete({});
      yield response;
    } catch (e) {
      if (!_headers.isCompleted) _headers.complete({});
      if (!_trailers.isCompleted) _trailers.complete({});
      if (e is GrpcError) {
        rethrow;
      }
      throw GrpcError.internal(e.toString());
    }
  }

  @override
  Future<void> cancel() async {}

  @override
  Future<Map<String, String>> get headers => _headers.future;

  @override
  Future<Map<String, String>> get trailers => _trailers.future;
}
