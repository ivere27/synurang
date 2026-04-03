import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:synurang/synurang.dart' as synurang;
import 'package:test/test.dart';

const _goGreeterService = 'GoGreeterService';
const _barMethod = '/example.v1.GoGreeterService/Bar';
const _barServerStreamMethod = '/example.v1.GoGreeterService/BarServerStream';
const _barClientStreamMethod = '/example.v1.GoGreeterService/BarClientStream';
const _barBidiStreamMethod = '/example.v1.GoGreeterService/BarBidiStream';

class _OpenBidiStream {
  final StreamController<Uint8List> input;
  final StreamSubscription<Uint8List> subscription;

  const _OpenBidiStream({
    required this.input,
    required this.subscription,
  });
}

class _OpenClientStream {
  final StreamController<Uint8List> input;
  final Future<Uint8List> response;

  const _OpenClientStream({
    required this.input,
    required this.response,
  });
}

Uint8List _encodeHelloRequest(String name, {String language = 'en'}) {
  final nameBytes = Uint8List.fromList(name.codeUnits);
  final languageBytes = Uint8List.fromList(language.codeUnits);
  final data = BytesBuilder(copy: false)
    ..addByte(0x0a)
    ..addByte(nameBytes.length)
    ..add(nameBytes)
    ..addByte(0x12)
    ..addByte(languageBytes.length)
    ..add(languageBytes);
  return data.toBytes();
}

String? _decodeHelloMessage(Uint8List data) {
  if (data.length < 2 || data[0] != 0x0a) return null;
  final len = data[1];
  if (data.length < 2 + len) return null;
  return String.fromCharCodes(data.sublist(2, 2 + len));
}

Future<_OpenBidiStream> _openLongLivedBidi(String marker) async {
  final input = StreamController<Uint8List>();
  final firstMessage = Completer<void>();
  final stream =
      synurang.invokeBackendBidiStream(_barBidiStreamMethod, input.stream);
  final subscription = stream.listen(
    (data) {
      final msg = _decodeHelloMessage(data);
      if (msg == null || !msg.contains(marker)) {
        if (!firstMessage.isCompleted) {
          firstMessage.completeError(
            StateError('unexpected bidi response for $marker: $msg'),
          );
        }
        return;
      }
      if (!firstMessage.isCompleted) {
        firstMessage.complete();
      }
    },
    onError: (Object error, StackTrace stackTrace) {
      if (!firstMessage.isCompleted) {
        firstMessage.completeError(error, stackTrace);
      }
    },
  );

  input.add(_encodeHelloRequest(marker));
  await firstMessage.future.timeout(const Duration(seconds: 5));

  return _OpenBidiStream(input: input, subscription: subscription);
}

Future<_OpenClientStream> _openLongLivedClientStream(String marker) async {
  final input = StreamController<Uint8List>();
  final response =
      synurang.invokeBackendClientStream(_barClientStreamMethod, input.stream);
  input.add(_encodeHelloRequest(marker));

  // Give the async controller a turn so the plugin side enters its recv loop
  // before we probe with another stream open.
  await Future<void>.delayed(Duration.zero);

  return _OpenClientStream(input: input, response: response);
}

Future<void> _expectServerStreamFirstMessage(
  String marker, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final firstMessage = Completer<void>();
  final subscription = synurang
      .invokeBackendServerStream(_barServerStreamMethod, _encodeHelloRequest(marker))
      .listen(
    (data) {
      final msg = _decodeHelloMessage(data);
      if (msg == null || !msg.contains(marker)) {
        if (!firstMessage.isCompleted) {
          firstMessage.completeError(
            StateError('unexpected server-stream response for $marker: $msg'),
          );
        }
        return;
      }
      if (!firstMessage.isCompleted) {
        firstMessage.complete();
      }
    },
    onError: (Object error, StackTrace stackTrace) {
      if (!firstMessage.isCompleted) {
        firstMessage.completeError(error, stackTrace);
      }
    },
    onDone: () {
      if (!firstMessage.isCompleted) {
        firstMessage.completeError(
          StateError('server stream closed before first message for $marker'),
        );
      }
    },
  );

  try {
    await firstMessage.future.timeout(timeout);
  } finally {
    await subscription.cancel();
  }
}

Future<void> _expectUnaryResponse(String marker) async {
  final respBytes = await synurang
      .invokeBackendAsync(_barMethod, _encodeHelloRequest(marker))
      .timeout(const Duration(seconds: 5));
  final msg = _decodeHelloMessage(respBytes);
  expect(msg, isNotNull);
  expect(msg, contains(marker));
}

Future<void> _finishClientStream(
  _OpenClientStream stream,
  String marker,
) async {
  await stream.input.close();
  final respBytes = await stream.response.timeout(const Duration(seconds: 5));
  final msg = _decodeHelloMessage(respBytes);
  expect(msg, isNotNull);
  expect(msg, contains(marker));
}

void main() {
  final pluginPath = '${Directory.current.path}/bin/libplugin_go.so';
  final pluginMissing = !File(pluginPath).existsSync();
  final skipReason = pluginMissing
      ? 'missing plugin binary: $pluginPath (run `make build_plugin_go`)'
      : null;

  setUpAll(() {
    if (pluginMissing) {
      return;
    }
    synurang.configurePoolSize(2);
    synurang.registerPlugin(pluginPath, const [_goGreeterService]);
  });

  tearDownAll(() {
    synurang.resetCoreState();
  });

  group('Plugin mode stream scheduling', () {
    test(
      'opening a third stream succeeds while two bidi streams stay open',
      () async {
        final bidiA = await _openLongLivedBidi('occupied-a');
        final bidiB = await _openLongLivedBidi('occupied-b');

        try {
          await _expectServerStreamFirstMessage('probe-third');
          await _expectUnaryResponse('probe-unary');
        } finally {
          await Future.wait([
            bidiA.subscription.cancel(),
            bidiA.input.close(),
            bidiB.subscription.cancel(),
            bidiB.input.close(),
          ]);
        }
      },
      timeout: const Timeout(Duration(minutes: 1)),
      skip: skipReason,
    );

    test(
      'rapid cancel and reopen does not stall later stream opens',
      () async {
        final cleanup = <Future<void>>[];

        Future<void> scheduleCleanup(_OpenBidiStream bidi) async {
          cleanup.add(bidi.subscription.cancel());
          cleanup.add(bidi.input.close());
        }

        try {
          for (var i = 0; i < 12; i++) {
            final oldBidi = await _openLongLivedBidi('old-$i');
            await _expectServerStreamFirstMessage('old-server-$i');

            final oldCancel = oldBidi.subscription.cancel();
            final oldClose = oldBidi.input.close();
            unawaited(oldCancel);
            unawaited(oldClose);
            cleanup.add(oldCancel);
            cleanup.add(oldClose);

            final newBidi = await _openLongLivedBidi('new-$i');
            await _expectServerStreamFirstMessage('new-server-$i');
            await _expectUnaryResponse('new-unary-$i');
            await scheduleCleanup(newBidi);
          }
        } finally {
          await Future.wait(
            cleanup.map((future) => future.catchError((_) {})),
          );
        }
      },
      timeout: const Timeout(Duration(minutes: 2)),
      skip: skipReason,
    );

    test(
      'opening a bidi stream succeeds while two client streams stay open',
      () async {
        final clientA = await _openLongLivedClientStream('client-a');
        final clientB = await _openLongLivedClientStream('client-b');
        final bidiProbe = await _openLongLivedBidi('probe-bidi');

        try {
          await _expectServerStreamFirstMessage('probe-server');
          await _expectUnaryResponse('probe-unary-after-client');
        } finally {
          await Future.wait([
            bidiProbe.subscription.cancel(),
            bidiProbe.input.close(),
          ]);
          await _finishClientStream(clientA, 'client-a');
          await _finishClientStream(clientB, 'client-b');
        }
      },
      timeout: const Timeout(Duration(minutes: 1)),
      skip: skipReason,
    );

    test(
      'mixed bidi and client streams do not block later opens during churn',
      () async {
        final cleanup = <Future<void>>[];

        Future<void> scheduleClientCleanup(_OpenClientStream stream) async {
          cleanup.add(stream.input.close());
          cleanup.add(
            stream.response.timeout(const Duration(seconds: 5)).then((respBytes) {
              final msg = _decodeHelloMessage(respBytes);
              expect(msg, isNotNull);
            }),
          );
        }

        Future<void> scheduleBidiCleanup(_OpenBidiStream stream) async {
          cleanup.add(stream.subscription.cancel());
          cleanup.add(stream.input.close());
        }

        try {
          for (var i = 0; i < 8; i++) {
            final oldClient = await _openLongLivedClientStream('mixed-old-client-$i');
            final oldBidi = await _openLongLivedBidi('mixed-old-bidi-$i');

            final oldClientClose = oldClient.input.close();
            final oldClientResp = oldClient.response.timeout(
              const Duration(seconds: 5),
            );
            final oldBidiCancel = oldBidi.subscription.cancel();
            final oldBidiClose = oldBidi.input.close();
            unawaited(oldClientClose);
            unawaited(oldClientResp);
            unawaited(oldBidiCancel);
            unawaited(oldBidiClose);
            cleanup.add(oldClientClose);
            cleanup.add(oldClientResp.then((respBytes) {
              final msg = _decodeHelloMessage(respBytes);
              expect(msg, isNotNull);
            }));
            cleanup.add(oldBidiCancel);
            cleanup.add(oldBidiClose);

            final newClient = await _openLongLivedClientStream('mixed-new-client-$i');
            final newBidi = await _openLongLivedBidi('mixed-new-bidi-$i');

            await _expectServerStreamFirstMessage('mixed-server-$i');
            await _expectUnaryResponse('mixed-unary-$i');

            await scheduleClientCleanup(newClient);
            await scheduleBidiCleanup(newBidi);
          }
        } finally {
          await Future.wait(
            cleanup.map((future) => future.catchError((_) {})),
          );
        }
      },
      timeout: const Timeout(Duration(minutes: 2)),
      skip: skipReason,
    );
  });
}
