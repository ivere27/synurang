import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'core.dart';

final class _Options extends Struct {
  @UintPtr()
  external int structSize;
  @Int32()
  external int executionMode;
  @UintPtr()
  external int workers;
  @UintPtr()
  external int inboundCapacity;
  @UintPtr()
  external int outboundCapacity;
  external Pointer<Void> wakeup;
  external Pointer<Void> wakeupData;
}

final class _CallOptions extends Struct {
  @Uint32()
  external int structSize;
  @Uint32()
  external int requestStream;
  @Uint32()
  external int responseStream;
  @Uint32()
  external int reserved;
  @Uint64()
  external int timeoutMs;
}

final class _ReadResult extends Struct {
  @Uint32()
  external int kind;
  @Int32()
  external int code;
  external Pointer<Uint8> data;
  @Uint32()
  external int size;
}

/// Load a dynamic module through the portable Synurang loader shim. Build the
/// shim with CMake's synurang_module_host target and bundle it with the app.
/// The host belongs to its creating isolate. Native provider work can execute
/// asynchronously; foreign entry calls and bounded polling never wait for it.
final class NativeModuleHost extends CallHost {
  NativeModuleHost._(super.instance);

  factory NativeModuleHost.load(String modulePath,
      {String? shimPath,
      String symbol = 'Synurang_GetApi',
      int capacity = 16}) {
    final bindings = _Bindings(_library(shimPath));
    return NativeModuleHost._(
        _NativeInstance.load(bindings, modulePath, symbol, capacity));
  }

  /// A native executable/addon can supply its statically linked API table.
  /// The caller keeps the module containing [api] loaded until close completes.
  factory NativeModuleHost.linked(Pointer<Void> api,
      {String? shimPath, int capacity = 16}) {
    final bindings = _Bindings(_library(shimPath));
    return NativeModuleHost._(_NativeInstance.linked(bindings, api, capacity));
  }

  static DynamicLibrary _library(String? path) {
    if (path == '') return DynamicLibrary.process();
    return DynamicLibrary.open(path ??
        (Platform.isWindows
            ? 'synurang_module_host.dll'
            : Platform.isMacOS || Platform.isIOS
                ? 'libsynurang_module_host.dylib'
                : 'libsynurang_module_host.so'));
  }
}

final class _Bindings {
  final DynamicLibrary library;
  _Bindings(this.library);
  late final load = library.lookupFunction<
      Pointer<Void> Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<_Options>),
      Pointer<Void> Function(Pointer<Utf8>, Pointer<Utf8>,
          Pointer<_Options>)>('synurang_host_load');
  late final linked = library.lookupFunction<
      Pointer<Void> Function(Pointer<Void>, Pointer<_Options>),
      Pointer<Void> Function(
          Pointer<Void>, Pointer<_Options>)>('synurang_host_linked');
  late final error = library.lookupFunction<Pointer<Utf8> Function(),
      Pointer<Utf8> Function()>('synurang_host_error');
  late final open = library.lookupFunction<
      Uint64 Function(Pointer<Void>, Pointer<Utf8>, Pointer<_CallOptions>),
      int Function(Pointer<Void>, Pointer<Utf8>,
          Pointer<_CallOptions>)>('synurang_host_open');
  late final send = library.lookupFunction<
      Int32 Function(Pointer<Void>, Uint64, Pointer<Uint8>, Uint32),
      int Function(
          Pointer<Void>, int, Pointer<Uint8>, int)>('synurang_host_send');
  late final halfClose = library.lookupFunction<
      Int32 Function(Pointer<Void>, Uint64),
      int Function(Pointer<Void>, int)>('synurang_host_half_close');
  late final receive = library.lookupFunction<
      Int32 Function(Pointer<Void>, Uint64, Pointer<_ReadResult>),
      int Function(
          Pointer<Void>, int, Pointer<_ReadResult>)>('synurang_host_receive');
  late final cancel = library.lookupFunction<
      Int32 Function(Pointer<Void>, Uint64, Int32),
      int Function(Pointer<Void>, int, int)>('synurang_host_cancel');
  late final release = library.lookupFunction<
      Void Function(Pointer<Void>, Uint64),
      void Function(Pointer<Void>, int)>('synurang_host_release');
  late final free = library.lookupFunction<
      Void Function(Pointer<Void>, Pointer<Void>),
      void Function(Pointer<Void>, Pointer<Void>)>('synurang_host_free');
  late final poll = library.lookupFunction<
      Uint32 Function(Pointer<Void>, Uint32),
      int Function(Pointer<Void>, int)>('synurang_host_poll');
  late final hasWork = library.lookupFunction<Int32 Function(Pointer<Void>),
      int Function(Pointer<Void>)>('synurang_host_has_work');
  late final destroy = library.lookupFunction<Int32 Function(Pointer<Void>),
      int Function(Pointer<Void>)>('synurang_host_destroy');
}

final class _Notification {
  void Function()? wakeup;
  late final native =
      NativeCallable<Void Function(Pointer<Void>)>.listener((Pointer<Void> _) {
    wakeup?.call();
  });
  void close() {
    wakeup = null;
    native.close();
  }
}

final class _NativeInstance implements ModuleInstance {
  final _Bindings bindings;
  final Pointer<Void> instance;
  final Pointer<_ReadResult> result = calloc<_ReadResult>();
  final _Notification notification;
  _NativeInstance._(this.bindings, this.instance, this.notification);

  @override
  void setWakeup(void Function() wakeup) => notification.wakeup = wakeup;

  static Pointer<_Options> _options(int capacity) {
    if (capacity < 1 || capacity > 65536) {
      throw RangeError.range(capacity, 1, 65536, 'capacity');
    }
    final options = calloc<_Options>();
    options.ref
      ..structSize = sizeOf<_Options>()
      ..executionMode = 1
      ..workers = 1
      ..inboundCapacity = capacity
      ..outboundCapacity = capacity;
    return options;
  }

  factory _NativeInstance.load(
      _Bindings bindings, String path, String symbol, int capacity) {
    if (path.contains('\x00') || symbol.contains('\x00')) {
      throw ArgumentError('NUL in module path or symbol');
    }
    final options = _options(capacity);
    final notification = _Notification();
    options.ref.wakeup = notification.native.nativeFunction.cast();
    final nativePath = path.toNativeUtf8();
    final nativeSymbol = symbol.toNativeUtf8();
    try {
      return _NativeInstance._checked(bindings,
          bindings.load(nativePath, nativeSymbol, options), notification);
    } finally {
      calloc.free(options);
      malloc.free(nativePath);
      malloc.free(nativeSymbol);
    }
  }

  factory _NativeInstance.linked(
      _Bindings bindings, Pointer<Void> api, int capacity) {
    final options = _options(capacity);
    final notification = _Notification();
    options.ref.wakeup = notification.native.nativeFunction.cast();
    try {
      return _NativeInstance._checked(
          bindings, bindings.linked(api, options), notification);
    } finally {
      calloc.free(options);
    }
  }

  factory _NativeInstance._checked(
      _Bindings bindings, Pointer<Void> instance, _Notification notification) {
    if (instance == nullptr) {
      notification.close();
      throw RpcError(13, bindings.error().toDartString());
    }
    return _NativeInstance._(bindings, instance, notification);
  }

  @override
  int open(Method method, Duration? timeout) {
    if (method.path.contains('\x00')) throw ArgumentError('NUL in method path');
    final path = method.path.toNativeUtf8();
    final options = calloc<_CallOptions>();
    final micros = timeout?.inMicroseconds;
    options.ref
      ..structSize = sizeOf<_CallOptions>()
      ..requestStream = method.requestStream ? 1 : 0
      ..responseStream = method.responseStream ? 1 : 0
      ..timeoutMs =
          micros == null ? -1 : micros ~/ 1000 + (micros % 1000 == 0 ? 0 : 1);
    try {
      return bindings.open(instance, path, options);
    } finally {
      malloc.free(path);
      calloc.free(options);
    }
  }

  @override
  int send(int call, Uint8List bytes) {
    final data = calloc<Uint8>(bytes.isEmpty ? 1 : bytes.length);
    try {
      data.asTypedList(bytes.length).setAll(0, bytes);
      return bindings.send(instance, call, data, bytes.length);
    } finally {
      calloc.free(data);
    }
  }

  @override
  int halfClose(int call) => bindings.halfClose(instance, call);
  @override
  ReadResult receive(int call) {
    final status = bindings.receive(instance, call, result);
    try {
      if (status != 0) throw RpcError(13, 'Native receive failed ($status)');
      final kind = result.ref.kind;
      if (kind == 0) return const ReadResult(0);
      if (kind != 1 && kind != 2) {
        throw RpcError(13, 'Invalid native read kind $kind');
      }
      return ReadResult(kind,
          code: result.ref.code,
          data: result.ref.size == 0
              ? Uint8List(0)
              : Uint8List.fromList(
                  result.ref.data.asTypedList(result.ref.size)));
    } finally {
      if (result.ref.data != nullptr) {
        bindings.free(instance, result.ref.data.cast());
        result.ref.data = nullptr;
      }
    }
  }

  @override
  void cancel(int call, int code) => bindings.cancel(instance, call, code);
  @override
  void release(int call) => bindings.release(instance, call);
  @override
  void poll(int budget) => bindings.poll(instance, budget);
  @override
  bool get hasWork => bindings.hasWork(instance) != 0;
  @override
  int destroy() {
    final status = bindings.destroy(instance);
    if (status == 0) {
      notification.close();
      calloc.free(result);
    }
    return status;
  }
}
