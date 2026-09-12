import 'dart:async';
import 'dart:typed_data';

import 'package:synurang/module.dart';

import 'conformance.pb.dart';
import 'conformance_client.dart';

void equal(Object? actual, Object? expected) {
  if (actual != expected) throw StateError('Expected $expected, got $actual');
}

Future<RpcError> fails(Future<Object?> future, int code) async {
  try {
    await future;
  } on RpcError catch (error) {
    equal(error.code, code);
    return error;
  }
  throw StateError('Expected RPC status $code');
}

Value value(int number) => Value(value: number);

Future<void> conformance(FutureOr<ModuleHost> Function() create) async {
  final host = await create(), otherHost = await create();
  final client = CallsClient(host), other = CallsClient(otherHost);
  try {
    equal((await client.unary(value(0))).value, 0);
    equal((await client.unary(value(42))).value, 42);
    var count = 0;
    await for (final response in client.server(value(50))) {
      equal(response.value, count++);
    }
    equal(count, 50);
    final requests = Stream.fromIterable(List.generate(50, value));
    equal((await client.client(requests)).value, 1225);
    equal(
        (await client.client(Stream.fromIterable([
          value(-2),
          ...List.generate(100, value),
        ])))
            .value,
        42);
    final unfinished = StreamController<Value>();
    unfinished.add(value(-2));
    equal(
        (await client
                .client(unfinished.stream)
                .timeout(const Duration(seconds: 2)))
            .value,
        42);
    await unfinished.close();
    final bidi = await client.bidi();
    try {
      for (var n = 0; n < 30; ++n) {
        await bidi.send(value(n));
        equal((await bidi.recv())?.value, n);
      }
      await bidi.halfClose();
      equal(await bidi.recv(), null);
    } finally {
      await bidi.close();
    }
    final responses =
        await Future.wait(List.generate(25, (n) => client.unary(value(n))));
    for (var n = 0; n < responses.length; ++n) {
      equal(responses[n].value, n);
    }
    equal((await other.unary(value(123))).value, 123);
    await fails(client.fail(value(0)), 7);
    await fails(client.unary(value(-1)), 7);
    final unknown = await host.open(const Method('/unknown.Service/Method'));
    try {
      await fails(unknown.recv(), 12);
    } finally {
      await unknown.close();
    }
    final unknownWrite =
        await host.open(const Method('/unknown.Service/Method'));
    try {
      await fails(unknownWrite.send(Uint8List(0)), 12);
    } finally {
      await unknownWrite.close();
    }
    final preserving = await host.open(
        const Method('/synurang.test.Calls/Server', responseStream: true));
    try {
      await preserving.send(value(100).writeToBuffer());
      await preserving.halfClose();
      equal(Value.fromBuffer((await preserving.recv())!).value, 0);
      try {
        await preserving.send(value(1).writeToBuffer());
        throw StateError('Expected closed request side');
      } on RequestClosedError {/* Responses remain readable. */}
      for (var n = 1; n < 100; ++n) {
        equal(Value.fromBuffer((await preserving.recv())!).value, n);
      }
      equal(await preserving.recv(), null);
    } finally {
      await preserving.close();
    }
    final token = CancellationToken();
    final cancelled = fails(
        client.wait(value(0), options: CallOptions(cancellation: token)), 1);
    Timer(const Duration(milliseconds: 10), token.cancel);
    await cancelled;
    await fails(
        client.wait(value(0),
            options: const CallOptions(timeout: Duration(milliseconds: 20))),
        4);
    await fails(
        client.wait(value(0),
            options: const CallOptions(timeout: Duration.zero)),
        4);
    await fails(
        client.wait(value(0), options: CallOptions(cancellation: token)), 1);
    await for (final response in client.server(value(10000))) {
      equal(response.value, 0);
      break;
    }
    final pending = fails(client.wait(value(0)), 1);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await host.close();
    await pending;
    await fails(client.unary(value(0)), 14);
    equal((await other.unary(value(9))).value, 9);
  } finally {
    await host.close();
    await otherHost.close();
  }
}

/// The generated server contract exercises Dart's role as a reverse-call
/// provider without requiring native Dart callbacks or a gRPC server.
final class DartCalls implements CallsService {
  @override
  Future<Value> unary(Value request, CallContext context) async {
    await Future<void>.delayed(Duration.zero);
    if (request.value == -1) throw RpcError(7, 'Error after response');
    return request;
  }

  @override
  Stream<Value> server(Value request, CallContext context) async* {
    for (var n = 0; n < request.value; ++n) {
      context.throwIfCancelled();
      yield value(n);
    }
  }

  @override
  Future<Value> client(Stream<Value> request, CallContext context) async {
    var total = 0;
    await for (final item in request) {
      if (item.value == -2) return value(42);
      total += item.value;
    }
    return value(total);
  }

  @override
  Stream<Value> bidi(Stream<Value> request, CallContext context) => request;

  @override
  Future<Value> wait(Value request, CallContext context) async {
    await context.cancelled;
    context.throwIfCancelled();
    return request;
  }

  @override
  Future<Value> fail(Value request, CallContext context) async {
    throw RpcError(7, 'Permission denied by Dart provider');
  }
}

InProcessTransport dartProvider() {
  final transport = InProcessTransport(capacity: 2);
  registerCalls(transport, DartCalls());
  return transport;
}
