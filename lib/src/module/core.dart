import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

final class Method {
  final String path;
  final bool requestStream;
  final bool responseStream;
  const Method(this.path,
      {this.requestStream = false, this.responseStream = false});
}

final class RpcError implements Exception {
  final int code;
  final String message;
  final Uint8List details;
  RpcError(this.code, this.message, [Uint8List? details])
      : details = details ?? Uint8List(0);
  @override
  String toString() => 'RpcError($code): $message';
}

/// Request input has closed; response bytes and terminal status remain readable.
final class RequestClosedError implements Exception {
  @override
  String toString() => 'RPC request side is closed';
}

/// Cooperative cancellation, including cancellation before a call is opened.
final class CancellationToken {
  final _listeners = <void Function()>[];
  final _completion = Completer<void>();
  bool get isCancelled => _completion.isCompleted;
  Future<void> get cancelled => _completion.future;
  void cancel() {
    if (isCancelled) return;
    _completion.complete();
    for (final callback in List.of(_listeners)) {
      callback();
    }
    _listeners.clear();
  }

  void addListener(void Function() callback) {
    if (isCancelled) {
      callback();
    } else {
      _listeners.add(callback);
    }
  }

  void removeListener(void Function() callback) => _listeners.remove(callback);
}

final class CallOptions {
  final Duration? timeout;
  final CancellationToken? cancellation;
  const CallOptions({this.timeout, this.cancellation});

  void validate() {
    if (timeout != null && timeout!.isNegative) {
      throw ArgumentError.value(timeout, 'timeout', 'Must not be negative');
    }
    if (cancellation?.isCancelled ?? false) throw rpcStatus(1);
  }
}

abstract interface class ByteCall {
  Future<void> send(Uint8List bytes);
  Future<void> halfClose();
  Future<Uint8List?> recv();
  void cancel([int code = 1]);
  Future<void> close();
}

abstract interface class Transport {
  Future<ByteCall> open(Method method,
      {CallOptions options = const CallOptions()});
}

abstract interface class ModuleHost implements Transport {
  Future<void> close();
}

/// Low-level entries are synchronous and never wait for provider work. Each
/// instance belongs to one Dart isolate; every operation stays serialized there.
abstract interface class ModuleInstance {
  /// Install an instance notification sink before opening calls. The sink only
  /// schedules a later turn; foreign callbacks must never re-enter the ABI.
  void setWakeup(void Function() wakeup);
  int open(Method method, Duration? timeout);
  int send(int call, Uint8List bytes);
  int halfClose(int call);
  ReadResult receive(int call);
  void cancel(int call, int code);
  void release(int call);
  void poll(int budget);
  bool get hasWork;

  /// Zero releases the instance; three means producer cleanup is pending.
  int destroy();
}

final class ReadResult {
  final int kind;
  final int code;
  final Uint8List? data;
  const ReadResult(this.kind, {this.code = 0, this.data});
}

RpcError rpcStatus(int code, [Uint8List? details]) {
  var message = switch (code) {
    1 => 'Call cancelled',
    4 => 'Deadline exceeded',
    _ => 'RPC failed ($code)',
  };
  // core.v1.Error message is field 2. Preserve the entire original protobuf.
  if (details != null) {
    try {
      var position = 0;
      int varint() {
        var value = 0;
        for (var shift = 0; shift < 63; shift += 7) {
          final byte = details[position++];
          value |= (byte & 127) << shift;
          if (byte < 128) return value;
        }
        throw const FormatException('Malformed varint');
      }

      while (position < details.length) {
        final tag = varint();
        switch (tag & 7) {
          case 0:
            varint();
          case 1:
            position += 8;
          case 2:
            final size = varint();
            if (size < 0 || size > details.length - position) {
              throw const FormatException('Invalid length');
            }
            if (tag == 18) {
              message = utf8.decode(details.sublist(position, position + size));
            }
            position += size;
          case 5:
            position += 4;
          default:
            throw const FormatException('Unknown wire type');
        }
      }
    } on Object {
      // Malformed details must not replace the authoritative terminal status.
    }
  }
  return RpcError(code, message, details);
}

/// One event-driven executor per instance, with bounded work on each turn.
class CallHost implements ModuleHost {
  final ModuleInstance _instance;
  final _calls = <_LocalCall>{};
  Completer<void> _turn = Completer<void>();
  bool _scheduled = false;
  RpcError? _failure;
  Future<void>? _closing;
  bool _closed = false;
  CallHost(this._instance) {
    _instance.setWakeup(_wake);
  }

  @override
  Future<ByteCall> open(Method method,
      {CallOptions options = const CallOptions()}) async {
    if (_closing != null || _closed) throw RpcError(14, 'Host is closed');
    if (_failure != null) throw _failure!;
    options.validate();
    final handle = _instance.open(method, options.timeout);
    if (handle == 0) throw RpcError(13, 'Module rejected call creation');
    final call = _LocalCall(this, handle, options);
    _calls.add(call);
    _wake();
    return call;
  }

  void _wake() {
    if (_closed || _scheduled || (_failure != null && _closing == null)) return;
    _scheduled = true;
    Timer.run(() {
      _scheduled = false;
      if (_closed) return;
      final waiting = _turn;
      _turn = Completer<void>();
      try {
        _instance.poll(64);
        if (_instance.hasWork) _wake();
      } catch (error) {
        _failure ??= error is RpcError ? error : RpcError(13, '$error');
        for (final call in _calls) {
          if (!call._ended && !call._released) call._error ??= _failure;
          call._detach();
        }
      }
      waiting.complete();
    });
  }

  Future<void> _nextTurn() {
    if (_failure != null && _closing == null) return Future.error(_failure!);
    if (_instance.hasWork) _wake();
    return _turn.future;
  }

  @override
  Future<void> close() => _closing ??= Future<void>(() async {
        for (final call in List.of(_calls)) {
          await call.close();
        }
        while (true) {
          final status = _instance.destroy();
          if (status == 0) {
            _closed = true;
            _turn.complete();
            return;
          }
          if (status != 3) {
            throw RpcError(13, 'Module teardown failed ($status)');
          }
          await _nextTurn();
        }
      });
}

final class _LocalCall implements ByteCall {
  final CallHost host;
  final int handle;
  final CallOptions options;
  Future<void> _sendTail = Future.value();
  Timer? _timer;
  bool _released = false, _ended = false, _reading = false;
  RpcError? _error;
  Uint8List? _pending;
  _LocalCall(this.host, this.handle, this.options) {
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
  void _check() {
    if (_error != null) throw _error!;
    if (_released) throw rpcStatus(1);
    if (_ended) throw RequestClosedError();
  }

  Object _writeError() {
    // Inspect at most one read result and retain its bytes for recv(). Never
    // drain a producer to discover whether its request side has closed.
    if (_pending == null && !_ended && _error == null) {
      final result = host._instance.receive(handle);
      if (result.kind == 1) _pending = result.data;
      if (result.kind == 2) {
        _ended = true;
        _detach();
        if (result.code != 0) _error = rpcStatus(result.code, result.data);
      }
    }
    return _error ?? RequestClosedError();
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
      while (true) {
        _check();
        final status = host._instance.send(handle, owned);
        if (status == 0) return;
        if (status != -4) throw _writeError();
        await host._nextTurn();
      }
    });
  }

  @override
  Future<void> halfClose() => _enqueue(() async {
        _check();
        final status = host._instance.halfClose(handle);
        if (status != 0) throw _writeError();
      });

  @override
  Future<Uint8List?> recv() async {
    if (_reading) throw StateError('Only one receive may be pending per call');
    _reading = true;
    try {
      while (true) {
        if (_error != null) throw _error!;
        if (_ended) return null;
        _check();
        if (_pending != null) {
          final bytes = _pending;
          _pending = null;
          return bytes;
        }
        final result = host._instance.receive(handle);
        if (result.kind == 1) return result.data!;
        if (result.kind == 2) {
          _ended = true;
          _detach();
          if (result.code != 0) {
            _error = rpcStatus(result.code, result.data);
            throw _error!;
          }
          return null;
        }
        await host._nextTurn();
      }
    } finally {
      _reading = false;
    }
  }

  @override
  void cancel([int code = 1]) {
    if (_released || _ended || _error != null) return;
    host._instance.cancel(handle, code);
    _error = rpcStatus(code);
    _detach();
    host._wake();
  }

  void _detach() {
    _timer?.cancel();
    options.cancellation?.removeListener(_abort);
  }

  @override
  Future<void> close() async {
    if (_released) return;
    if (!_ended) cancel();
    _released = true;
    _detach();
    host._instance.release(handle);
    host._calls.remove(this);
    host._wake();
  }
}

final class Codec<T> {
  final Uint8List Function(T message) encode;
  final T Function(Uint8List bytes) decode;
  const Codec({required this.encode, required this.decode});
}

final class Duplex<I, O> {
  final ByteCall _call;
  final Codec<I> _input;
  final Codec<O> _output;
  Duplex._(this._call, this._input, this._output);
  Future<void> send(I message) => _call.send(_input.encode(message));
  Future<void> halfClose() => _call.halfClose();
  Future<O?> recv() async {
    final bytes = await _call.recv();
    return bytes == null ? null : _output.decode(bytes);
  }

  Stream<O> get responses async* {
    try {
      while (true) {
        final bytes = await _call.recv();
        if (bytes == null) return;
        yield _output.decode(bytes);
      }
    } finally {
      await _call.close();
    }
  }

  void cancel() => _call.cancel();
  Future<void> close() => _call.close();
}

Future<Duplex<I, O>> duplex<I, O>(
    Transport transport, Method method, Codec<I> input, Codec<O> output,
    {CallOptions options = const CallOptions()}) async {
  return Duplex._(
      await transport.open(method, options: options), input, output);
}

Future<O> _single<O>(ByteCall call, Codec<O> output) async {
  final bytes = await call.recv();
  if (bytes == null) throw RpcError(13, 'RPC completed without a response');
  if (await call.recv() != null) {
    throw RpcError(13, 'RPC produced multiple responses');
  }
  return output.decode(bytes);
}

Future<O> unary<I, O>(Transport transport, Method method, I request,
    Codec<I> input, Codec<O> output,
    {CallOptions options = const CallOptions()}) async {
  final call = await transport.open(method, options: options);
  try {
    await call.send(input.encode(request));
    await call.halfClose();
    return await _single(call, output);
  } finally {
    await call.close();
  }
}

Stream<O> serverStream<I, O>(Transport transport, Method method, I request,
    Codec<I> input, Codec<O> output,
    {CallOptions options = const CallOptions()}) async* {
  final call = await transport.open(method, options: options);
  try {
    await call.send(input.encode(request));
    await call.halfClose();
    while (true) {
      final bytes = await call.recv();
      if (bytes == null) return;
      yield output.decode(bytes);
    }
  } finally {
    await call.close();
  }
}

Future<O> clientStream<I, O>(Transport transport, Method method,
    Stream<I> requests, Codec<I> input, Codec<O> output,
    {CallOptions options = const CallOptions()}) async {
  final call = await transport.open(method, options: options);
  final iterator = StreamIterator(requests);
  final failure = Completer<O>();
  var stopped = false;
  // Observe send failures and terminal status concurrently, including servers
  // which reject a stream before all requests have been consumed.
  final sending = () async {
    while (!stopped && await iterator.moveNext()) {
      if (!stopped) await call.send(input.encode(iterator.current));
    }
    if (!stopped) await call.halfClose();
  }();
  unawaited(sending.then((_) {}, onError: (Object error, StackTrace stack) {
    if (error is RequestClosedError) return;
    if (!failure.isCompleted) failure.completeError(error, stack);
  }));
  try {
    return await Future.any([_single(call, output), failure.future]);
  } finally {
    stopped = true;
    await call.close();
    // User streams may delay their cancellation callback indefinitely. Request
    // cleanup without holding the completed RPC open on application work.
    unawaited(iterator.cancel().catchError((Object _) {}));
  }
}
