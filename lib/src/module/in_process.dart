import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'core.dart';

final class CallContext {
  final CancellationToken cancellation;
  final Duration? timeout;
  CallContext._(this.cancellation, this.timeout);
  bool get isCancelled => cancellation.isCancelled;
  Future<void> get cancelled => cancellation.cancelled;
  void throwIfCancelled() {
    if (isCancelled) throw rpcStatus(1);
  }
}

/// The provider side of a call. Completion of the registered handler publishes
/// terminal success; throwing RpcError publishes that status and its details.
/// Await send for bounded output capacity and observe context cancellation in
/// external work. requests and recv are alternative ways to consume input.
abstract interface class ServiceCall {
  CallContext get context;
  Stream<Uint8List> get requests;
  Future<Uint8List?> recv();
  Future<void> send(Uint8List bytes);
}

typedef CallHandler = Future<void> Function(ServiceCall call);

final class _Registration {
  final Method method;
  final CallHandler handler;
  const _Registration(this.method, this.handler);
}

/// Dart services use the same protobuf transport as foreign modules. Register
/// reverse-call services here and supply the transport to the initiating peer's
/// dispatcher. This is an in-process transport, not an exported native ABI.
final class InProcessTransport implements ModuleHost {
  final int capacity;
  final _methods = <String, _Registration>{};
  final _calls = <_InProcessCall>{};
  bool _started = false, _closed = false;
  InProcessTransport({this.capacity = 16}) {
    if (capacity < 1 || capacity > 65536) {
      throw RangeError.range(capacity, 1, 65536, 'capacity');
    }
  }

  void register(Method method, CallHandler handler) {
    if (_closed || _started) {
      throw StateError('Register services before opening calls');
    }
    if (!method.path.startsWith('/') || method.path.contains('\x00')) {
      throw ArgumentError.value(method.path, 'method');
    }
    if (_methods.containsKey(method.path)) {
      throw StateError('Duplicate method ${method.path}');
    }
    _methods[method.path] = _Registration(method, handler);
  }

  @override
  Future<ByteCall> open(Method method,
      {CallOptions options = const CallOptions()}) async {
    if (_closed) throw RpcError(14, 'Host is closed');
    options.validate();
    _started = true;
    final registration = _methods[method.path];
    final call = _InProcessCall(this, method, options);
    _calls.add(call);
    if (registration == null) {
      call._finish(RpcError(12, 'Unknown method ${method.path}'));
    } else if (registration.method.requestStream != method.requestStream ||
        registration.method.responseStream != method.responseStream) {
      call._finish(RpcError(3, 'Method cardinality mismatch'));
    } else if (!call._finished) {
      unawaited(Future<void>(() async {
        try {
          await registration.handler(_ServiceCall(call));
          call._finish();
        } catch (error) {
          call._finish(error is RpcError
              ? error
              : RpcError(13, 'Service handler failed: $error'));
        }
      }));
    }
    return call;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final call in List.of(_calls)) {
      await call.close();
    }
  }
}

final class _Queue {
  final int capacity;
  final _values = Queue<Uint8List>();
  Completer<void>? _change;
  bool _ended = false;
  Object? _error;
  _Queue(this.capacity);
  Future<void> _changed() => (_change ??= Completer<void>()).future;
  void _notify() {
    _change?.complete();
    _change = null;
  }

  Future<void> put(Uint8List bytes) async {
    final owned = Uint8List.fromList(bytes);
    while (!_ended && _values.length >= capacity) {
      await _changed();
    }
    if (_ended) throw _error ?? rpcStatus(1);
    _values.add(owned);
    _notify();
  }

  Future<Uint8List?> take() async {
    while (_values.isEmpty && !_ended) {
      await _changed();
    }
    if (_values.isNotEmpty) {
      final result = _values.removeFirst();
      _notify();
      return result;
    }
    if (_error != null) throw _error!;
    return null;
  }

  void end([Object? error, bool discard = false]) {
    if (_ended && !discard) return;
    _ended = true;
    _error = error;
    if (discard) _values.clear();
    _notify();
  }
}

final class _InProcessCall implements ByteCall {
  final InProcessTransport host;
  final Method method;
  final CallOptions options;
  final _Queue input, output;
  final CancellationToken _cancellation = CancellationToken();
  late final CallContext context =
      CallContext._(_cancellation, options.timeout);
  Timer? _timer;
  Future<void> _sendTail = Future.value();
  bool _finished = false, _released = false, _halfClosed = false;
  bool _reading = false, _providerReading = false;
  int _sent = 0, _produced = 0;
  RpcError? _error;
  RpcError? _localCancellation;
  _InProcessCall(this.host, this.method, this.options)
      : input = _Queue(host.capacity),
        output = _Queue(host.capacity) {
    options.cancellation?.addListener(_abort);
    if (options.timeout != null) {
      if (options.timeout == Duration.zero) {
        cancel(4);
      } else {
        _timer = Timer(options.timeout!, () => cancel(4));
      }
    }
  }

  void _abort() => cancel();
  void _detach() {
    _timer?.cancel();
    options.cancellation?.removeListener(_abort);
  }

  void _checkSend() {
    if (_released) throw _error ?? rpcStatus(1);
    if (_error != null) throw _error!;
    if (_finished || _halfClosed) throw RequestClosedError();
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    final result = _sendTail.then((_) => operation());
    _sendTail = result.then((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  @override
  Future<void> send(Uint8List bytes) {
    final owned = Uint8List.fromList(bytes);
    return _enqueue(() async {
      _checkSend();
      if (!method.requestStream && _sent != 0) {
        final error = RpcError(3, 'RPC accepts one request');
        _finish(error);
        output.end(error, true);
        throw error;
      }
      await input.put(owned);
      ++_sent;
    });
  }

  @override
  Future<void> halfClose() => _enqueue(() async {
        if (_released) throw _error ?? rpcStatus(1);
        if (_localCancellation != null) throw _localCancellation!;
        // A published terminal status closes request input successfully. Its
        // response bytes and any terminal error must remain observable by recv.
        if (_finished) return;
        if (_halfClosed) return;
        _checkSend();
        if (!method.requestStream && _sent != 1) {
          final error = RpcError(3, 'RPC requires one request');
          _finish(error);
          output.end(error, true);
          throw error;
        }
        _halfClosed = true;
        input.end();
      });

  @override
  Future<Uint8List?> recv() async {
    if (_reading) throw StateError('Only one receive may be pending per call');
    if (_released) throw _error ?? rpcStatus(1);
    _reading = true;
    try {
      return await output.take();
    } finally {
      _reading = false;
    }
  }

  Future<Uint8List?> _providerRecv() async {
    if (_providerReading) throw StateError('Concurrent provider receive');
    _providerReading = true;
    try {
      return await input.take();
    } finally {
      _providerReading = false;
    }
  }

  Future<void> _providerSend(Uint8List bytes) async {
    if (_finished) throw _error ?? rpcStatus(1);
    if (!method.responseStream && _produced != 0) {
      final error = RpcError(13, 'RPC produced multiple responses');
      _finish(error);
      throw error;
    }
    ++_produced;
    await output.put(bytes);
  }

  void _finish([RpcError? error]) {
    if (_finished) return;
    if (error == null && !method.responseStream && _produced != 1) {
      error = RpcError(13, 'RPC completed without a response');
    }
    _finished = true;
    _error = error;
    _detach();
    output.end(error);
    input.end(error ?? RequestClosedError(), true);
    _cancellation.cancel();
  }

  @override
  void cancel([int code = 1]) {
    if (_released || _finished) return;
    final error = rpcStatus(code);
    _localCancellation = error;
    _finish(error);
    output.end(error, true);
  }

  @override
  Future<void> close() async {
    if (_released) return;
    if (!_finished) cancel();
    _released = true;
    _detach();
    input.end(_error ?? rpcStatus(1), true);
    output.end(_error ?? rpcStatus(1), true);
    host._calls.remove(this);
  }
}

final class _ServiceCall implements ServiceCall {
  final _InProcessCall call;
  _ServiceCall(this.call);
  @override
  CallContext get context => call.context;
  @override
  Future<Uint8List?> recv() => call._providerRecv();
  @override
  Future<void> send(Uint8List bytes) => call._providerSend(bytes);
  @override
  Stream<Uint8List> get requests async* {
    while (true) {
      final bytes = await recv();
      if (bytes == null) return;
      yield bytes;
    }
  }
}
