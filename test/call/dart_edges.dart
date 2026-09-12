import 'dart:async';
import 'dart:typed_data';

import 'package:synurang/module.dart';

Future<void> expectCode(Future<Object?> future, int code) async {
  try {
    await future;
  } on RpcError catch (error) {
    if (error.code != code) rethrow;
    return;
  }
  throw StateError('Expected status $code');
}

void expect(bool condition, String message) {
  if (!condition) throw StateError(message);
}

final class SchedulerInstance implements ModuleInstance {
  void Function() wakeup = () {};
  final calls = <int, String>{};
  final output = <int, Uint8List>{};
  final finished = <int>{};
  int next = 0, polls = 0, cleanup = 0;
  bool busy = false, destroyed = false, failPoll = false;
  @override
  void setWakeup(void Function() callback) => wakeup = callback;
  @override
  int open(Method method, Duration? timeout) {
    calls[++next] = method.path;
    if (method.path == '/busy') busy = true;
    return next;
  }

  @override
  int send(int id, Uint8List bytes) {
    if (calls[id] == '/echo') {
      output[id] = bytes;
      finished.add(id);
      wakeup();
    }
    return 0;
  }

  @override
  int halfClose(int id) => 0;
  @override
  ReadResult receive(int id) {
    final bytes = output.remove(id);
    if (bytes != null) return ReadResult(1, data: bytes);
    return ReadResult(finished.contains(id) ? 2 : 0);
  }

  @override
  void cancel(int id, int code) {
    if (calls[id] == '/busy') busy = false;
    wakeup();
  }

  @override
  void release(int id) {
    calls.remove(id);
    cleanup += 129;
    wakeup();
  }

  @override
  bool get hasWork => busy || cleanup > 0;
  @override
  void poll(int budget) {
    expect(!destroyed, 'Poll after destroy');
    expect(budget <= 64, 'Unbounded poll');
    ++polls;
    if (failPoll) {
      failPoll = false;
      throw StateError('Injected poll failure');
    }
    cleanup = (cleanup - budget).clamp(0, 100000);
  }

  @override
  int destroy() {
    if (cleanup != 0 || calls.isNotEmpty) return 3;
    destroyed = true;
    return 0;
  }
}

Future<void> schedulerEdges() async {
  const limit = Duration(seconds: 1);
  final codec =
      Codec<Uint8List>(encode: (value) => value, decode: (value) => value);
  final instance = SchedulerInstance();
  final host = CallHost(instance);
  // Closing a completed unary must not wait for an unrelated yielding task.
  await host.open(const Method('/busy'));
  final response = await unary(
          host, const Method('/echo'), Uint8List.fromList([7]), codec, codec)
      .timeout(limit);
  expect(response.single == 7 && instance.busy,
      'Unrelated ready work delayed unary completion');
  await host.close().timeout(limit);

  final closing = CallHost(SchedulerInstance());
  await closing.open(const Method('/idle'));
  await closing.open(const Method('/busy'));
  await closing.close().timeout(limit);

  final quiet = SchedulerInstance();
  final idleHost = CallHost(quiet);
  final call = await idleHost.open(const Method('/idle'));
  await Future<void>.delayed(const Duration(milliseconds: 20));
  final idlePolls = quiet.polls;
  final receiving = call.recv();
  await Future<void>.delayed(const Duration(milliseconds: 20));
  expect(quiet.polls == idlePolls, 'Quiet call caused periodic polling');
  quiet.output[1] = Uint8List.fromList([9]);
  quiet.wakeup();
  expect((await receiving.timeout(limit))!.single == 9,
      'Notification did not wake receiver');
  await call.close().timeout(limit);
  await Future<void>.delayed(const Duration(milliseconds: 20));
  expect(quiet.cleanup == 0, 'Final release did not drain multiple batches');
  await idleHost.close().timeout(limit);
  final stopped = quiet.polls;
  quiet.wakeup();
  await Future<void>.delayed(const Duration(milliseconds: 10));
  expect(quiet.polls == stopped, 'Queued notification survived close');

  final failed = SchedulerInstance()..failPoll = true;
  final failedHost = CallHost(failed);
  final failedCall = await failedHost.open(const Method('/idle'));
  await Future<void>.delayed(const Duration(milliseconds: 10));
  await expectCode(failedCall.recv(), 13);
  await failedHost.close().timeout(limit);
}

Future<void> main() async {
  await schedulerEdges();
  for (final duplicate in [false, true]) {
    final host = InProcessTransport();
    const method = Method('/test.Calls/Protocol', responseStream: true);
    final ready = Completer<void>();
    host.register(method, (call) async {
      await call.send(Uint8List.fromList([1]));
      ready.complete();
      await call.context.cancelled;
    });
    try {
      final call = await host.open(method);
      if (duplicate) await call.send(Uint8List(0));
      await ready.future;
      await expectCode(
          duplicate ? call.send(Uint8List(0)) : call.halfClose(), 3);
      await expectCode(call.recv(), 3);
      await call.close();
    } finally {
      await host.close();
    }
  }
  final codec =
      Codec<Uint8List>(encode: (bytes) => bytes, decode: (bytes) => bytes);
  const empty = Method('/test.Calls/Empty');
  const lateError = Method('/test.Calls/LateError');
  const multiple = Method('/test.Calls/Multiple');
  const wait =
      Method('/test.Calls/Wait', requestStream: true, responseStream: true);
  const reject = Method('/test.Calls/Reject', requestStream: true);
  const early = Method('/test.Calls/Early');
  const earlyFailure = Method('/test.Calls/EarlyFailure');
  final host = InProcessTransport(capacity: 1);
  final contextCancelled = Completer<void>();
  final completed = <Method, Completer<void>>{};
  for (final method in [early, earlyFailure]) {
    final terminal = completed[method] = Completer<void>();
    host.register(method, (call) async {
      unawaited(call.context.cancelled.then((_) => terminal.complete()));
      await call.recv();
      await call.send(Uint8List.fromList([1, 2, 3]));
      if (method == earlyFailure) throw RpcError(7, 'Early terminal error');
    });
  }
  host.register(empty, (call) async {
    await call.recv();
  });
  host.register(lateError, (call) async {
    await call.recv();
    await call.send(Uint8List(0));
    throw RpcError(7, 'After response', Uint8List.fromList([18, 1, 120]));
  });
  host.register(multiple, (call) async {
    await call.recv();
    await call.send(Uint8List(0));
    await call.send(Uint8List(0));
  });
  host.register(wait, (call) async {
    await call.context.cancelled;
    contextCancelled.complete();
  });
  host.register(reject, (call) async {
    await call.recv();
    throw RpcError(7, 'Early rejection');
  });
  try {
    for (final method in [early, earlyFailure]) {
      final call = await host.open(method);
      await call.send(Uint8List(0));
      // Observe provider completion before half-close, as happens across a
      // worker/message boundary. Terminal errors belong to receive.
      await completed[method]!.future;
      await call.halfClose();
      await call.halfClose();
      expect((await call.recv())!.join(',') == '1,2,3', 'Lost early response');
      if (method == earlyFailure) {
        await expectCode(call.recv(), 7);
      } else {
        expect(await call.recv() == null, 'Expected successful EOF');
      }
      await call.close();
    }
    await expectCode(unary(host, empty, Uint8List(0), codec, codec), 13);
    try {
      await unary(host, lateError, Uint8List(0), codec, codec);
      throw StateError('Expected late failure');
    } on RpcError catch (error) {
      expect(error.code == 7 && error.details.last == 120,
          'Lost terminal status or protobuf details');
    }
    await expectCode(unary(host, multiple, Uint8List(0), codec, codec), 13);
    final call = await host.open(wait);
    await call.send(Uint8List(0));
    var sent = false;
    final blocked = call.send(Uint8List(0)).then((_) {
      sent = true;
    });
    final cancelled = expectCode(blocked, 1);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(!sent, 'Bounded input queue did not apply backpressure');
    call.cancel();
    await expectCode(call.halfClose(), 1);
    await cancelled;
    await contextCancelled.future;
    await call.close();

    var sourceCancelled = false;
    final source = StreamController<Uint8List>(onCancel: () {
      sourceCancelled = true;
    });
    final rejected =
        expectCode(clientStream(host, reject, source.stream, codec, codec), 7);
    source.add(Uint8List(0));
    await rejected;
    expect(sourceCancelled,
        'Early terminal status did not cancel request subscription');
    await source.close();
  } finally {
    await host.close();
  }
  print(
      'Dart cancellation, cardinality, bounded queues and late status passed');
}
