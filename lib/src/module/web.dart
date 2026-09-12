import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'core.dart';

extension type _Transport(JSObject _) implements JSObject {
  external JSPromise<_Call> open(_Method method, _Options options);
  external JSPromise<JSAny?> close();
}

extension type _Method._(JSObject _) implements JSObject {
  external factory _Method(
      {JSString path, JSBoolean requestStream, JSBoolean responseStream});
}

extension type _Options._(JSObject _) implements JSObject {
  external factory _Options({JSNumber timeoutMs});
}

extension type _Call(JSObject _) implements JSObject {
  external JSPromise<JSAny?> send(JSUint8Array data);
  external JSPromise<JSAny?> halfClose();
  external JSPromise<JSUint8Array?> recv();
  external void cancel(JSNumber code);
  external JSPromise<JSAny?> close();
}

Object _rpcError(Object error) {
  if (error is RpcError) return error;
  // A rejected JS Promise is delivered as its original JS error object.
  try {
    final object = error as JSObject;
    final name = object.getProperty<JSString?>('name'.toJS);
    if (name?.toDart == 'RequestClosedError') return RequestClosedError();
    final code = object.getProperty<JSNumber?>('code'.toJS);
    if (code != null) {
      final message = object.getProperty<JSString?>('message'.toJS);
      final details = object.getProperty<JSUint8Array?>('details'.toJS);
      return RpcError(code.toDartInt, message?.toDart ?? 'RPC failed',
          details == null ? null : Uint8List.fromList(details.toDart));
    }
  } on Object {
    // Non-RPC JavaScript failures keep their original diagnostic.
  }
  return error;
}

Future<T> _await<T>(Future<T> future) async {
  try {
    return await future;
  } catch (error) {
    throw _rpcError(error);
  }
}

/// Wrap the common JavaScript Transport returned by createWasmHost, WorkerHost,
/// or another language's loader. No native pointer ABI is assumed here. The JS
/// transport owns its WASM instance/worker and is closed with this host.
final class JsModuleHost implements ModuleHost {
  final _Transport _transport;
  final _calls = <_JsCall>{};
  Future<void>? _closing;
  JsModuleHost.fromTransport(JSObject transport)
      : _transport = _Transport(transport);

  @override
  Future<ByteCall> open(Method method,
      {CallOptions options = const CallOptions()}) async {
    if (_closing != null) throw RpcError(14, 'Host is closed');
    options.validate();
    final micros = options.timeout?.inMicroseconds;
    final jsOptions = micros == null
        ? _Options()
        : _Options(
            timeoutMs: (micros ~/ 1000 + (micros % 1000 == 0 ? 0 : 1)).toJS);
    final foreign = await _await(_transport
        .open(
            _Method(
                path: method.path.toJS,
                requestStream: method.requestStream.toJS,
                responseStream: method.responseStream.toJS),
            jsOptions)
        .toDart);
    if (_closing != null) {
      foreign.cancel(1.toJS);
      await _await(foreign.close().toDart);
      throw RpcError(14, 'Host is closed');
    }
    final call = _JsCall(this, foreign, options.cancellation);
    _calls.add(call);
    return call;
  }

  @override
  Future<void> close() => _closing ??= Future<void>(() async {
        for (final call in List.of(_calls)) {
          await call.close();
        }
        await _await(_transport.close().toDart);
      });
}

final class _JsCall implements ByteCall {
  final JsModuleHost host;
  final _Call _call;
  final CancellationToken? token;
  bool _closed = false;
  RpcError? _cancelled;
  _JsCall(this.host, this._call, this.token) {
    token?.addListener(_abort);
  }

  void _abort() => cancel();
  void _check() {
    if (_cancelled != null) throw _cancelled!;
    if (_closed) throw rpcStatus(1);
  }

  @override
  Future<void> send(Uint8List bytes) async {
    _check();
    await _await(_call.send(Uint8List.fromList(bytes).toJS).toDart);
  }

  @override
  Future<void> halfClose() async {
    _check();
    await _await(_call.halfClose().toDart);
  }

  @override
  Future<Uint8List?> recv() async {
    _check();
    final data = await _await(_call.recv().toDart);
    return data == null ? null : Uint8List.fromList(data.toDart);
  }

  @override
  void cancel([int code = 1]) {
    if (_closed || _cancelled != null) return;
    _cancelled = rpcStatus(code);
    _call.cancel(code.toJS);
    token?.removeListener(_abort);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    cancel();
    _closed = true;
    token?.removeListener(_abort);
    try {
      await _await(_call.close().toDart);
    } finally {
      host._calls.remove(this);
    }
  }
}

JSPromise<T> _promise<T extends JSAny?>(Future<T> future) => JSPromise<T>(
      (JSFunction resolve, JSFunction reject) {
        unawaited(future.then((value) {
          resolve.callAsFunction(null, value);
        }, onError: (Object error, StackTrace stack) {
          final constructor =
              globalContext.getProperty<JSFunction>('Error'.toJS);
          final exception = constructor.callAsConstructor<JSObject>(
              (error is RpcError ? error.message : '$error').toJS);
          if (error is RequestClosedError) {
            exception.setProperty('name'.toJS, 'RequestClosedError'.toJS);
          }
          exception.setProperty('stack'.toJS, '$stack'.toJS);
          exception.setProperty(
              'code'.toJS, (error is RpcError ? error.code : 13).toJS);
          exception.setProperty('details'.toJS,
              (error is RpcError ? error.details : Uint8List(0)).toJS);
          reject.callAsFunction(null, exception);
        }));
      }.toJS,
    );

/// Export Dart handlers to JavaScript's common Transport contract. This enables
/// a JS client or worker dispatcher to initiate reverse calls into Dart using
/// the same Promise/byte API as a foreign module. The returned transport owns
/// [host], including its close operation.
JSObject exportTransport(ModuleHost host) {
  final result = JSObject();
  result.setProperty(
      'open'.toJS,
      ((JSObject method, [JSObject? options]) {
        return _promise(Future<JSObject>(() async {
          final timeout = options?.getProperty<JSNumber?>('timeoutMs'.toJS);
          final signal = options?.getProperty<JSObject?>('signal'.toJS);
          final cancellation = CancellationToken();
          final listener = (() => cancellation.cancel()).toJS;
          if (signal != null) {
            if (signal.getProperty<JSBoolean>('aborted'.toJS).toDart) {
              cancellation.cancel();
            } else {
              signal.callMethod<JSAny?>(
                  'addEventListener'.toJS, 'abort'.toJS, listener);
            }
          }
          void detach() {
            signal?.callMethod<JSAny?>(
                'removeEventListener'.toJS, 'abort'.toJS, listener);
          }

          try {
            final call = await host.open(
                Method(method.getProperty<JSString>('path'.toJS).toDart,
                    requestStream: method
                        .getProperty<JSBoolean>('requestStream'.toJS)
                        .toDart,
                    responseStream: method
                        .getProperty<JSBoolean>('responseStream'.toJS)
                        .toDart),
                options: CallOptions(
                    timeout: timeout == null
                        ? null
                        : Duration(milliseconds: timeout.toDartInt),
                    cancellation: cancellation));
            final output = JSObject();
            output.setProperty(
                'send'.toJS,
                ((JSUint8Array data) {
                  return _promise(call
                      .send(Uint8List.fromList(data.toDart))
                      .then<JSAny?>((_) => null));
                }).toJS);
            output.setProperty(
                'halfClose'.toJS,
                (() {
                  return _promise(call.halfClose().then<JSAny?>((_) => null));
                }).toJS);
            output.setProperty(
                'recv'.toJS,
                (() {
                  return _promise(call.recv().then<JSUint8Array?>((data) {
                    if (data == null) detach();
                    return data?.toJS;
                  }));
                }).toJS);
            output.setProperty(
                'cancel'.toJS,
                (([JSNumber? code]) {
                  call.cancel(code?.toDartInt ?? 1);
                  detach();
                }).toJS);
            output.setProperty(
                'close'.toJS,
                (() {
                  detach();
                  return _promise(call.close().then<JSAny?>((_) => null));
                }).toJS);
            return output;
          } catch (_) {
            detach();
            rethrow;
          }
        }));
      }).toJS);
  result.setProperty('close'.toJS,
      (() => _promise(host.close().then<JSAny?>((_) => null))).toJS);
  return result;
}
