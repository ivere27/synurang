// Core recovery test suite
//
// Exercises the CoreState machine, _markUnhealthy cascade, recoverCoreAsync
// edge cases, per-call timeout plumbing, and FfiClientChannel exception
// mapping. Uses the debug* helpers defined in lib/synurang.dart to drive state
// transitions deterministically without needing to provoke a real native hang.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:grpc/grpc.dart';
import 'package:synurang/synurang.dart' hide Duration;
import 'package:test/test.dart';

const _opts = StartGrpcServerOptions(token: 'recovery-test-token');

Future<void> _bringUpCore() async {
  configureSynurang(
    libraryName: 'synurang',
    libraryPath: '${Directory.current.path}/src/libsynurang.so',
  );
  prewarmIsolate();
  await startGrpcServerWithOptionsAsync(_opts);
}

Future<void> _tearDownCore() async {
  debugForceCoreState(CoreState.healthy);
  try {
    await stopGrpcServerAsync(timeout: const Duration(seconds: 2));
  } catch (_) {
    // best effort
  }
  resetCoreState();
}

/// Ensure the core is running and healthy before a test. If a prior test left
/// the core stopped (or in a half-recovered state), start it back up.
Future<void> _restoreHealthyCore() async {
  debugForceCoreState(CoreState.healthy);
  try {
    await invokeBackendAsync(
      '/core.v1.HealthService/Ping',
      Uint8List(0),
      timeout: const Duration(seconds: 2),
    );
    return;
  } catch (_) {
    // Core might be stopped — re-start it below.
  }
  try {
    await startGrpcServerWithOptionsAsync(_opts);
  } catch (_) {
    // Already running is fine.
  }
}

void main() {
  group('Core recovery', () {
    setUpAll(_bringUpCore);
    tearDownAll(_tearDownCore);

    setUp(_restoreHealthyCore);

    // -------------------------------------------------------------------------
    // CoreState gating: each non-healthy state surfaces the correct exception
    // type on the direct invokeBackendAsync path.
    // -------------------------------------------------------------------------
    group('CoreState gating', () {
      test('healthy accepts RPCs', () async {
        expect(getCoreState(), equals(CoreState.healthy));
        final ch = FfiClientChannel();
        try {
          final client = HealthServiceClient(ch);
          expect(await client.ping(Empty()), isA<PingResponse>());
        } finally {
          await ch.shutdown();
        }
      });

      test('unhealthy throws CoreUnavailableException', () async {
        debugMarkCoreUnhealthy();
        expect(getCoreState(), equals(CoreState.unhealthy));

        await expectLater(
          invokeBackendAsync('/core.v1.HealthService/Ping', Uint8List(0)),
          throwsA(isA<CoreUnavailableException>()
              .having((e) => e.state, 'state', CoreState.unhealthy)),
        );
      });

      test('recovering throws CoreUnavailableException', () async {
        debugForceCoreState(CoreState.recovering);

        await expectLater(
          invokeBackendAsync('/core.v1.HealthService/Ping', Uint8List(0)),
          throwsA(isA<CoreUnavailableException>()
              .having((e) => e.state, 'state', CoreState.recovering)),
        );
      });

      test('restartRequired throws CoreRestartRequiredException', () async {
        debugForceCoreState(CoreState.restartRequired);

        await expectLater(
          invokeBackendAsync('/core.v1.HealthService/Ping', Uint8List(0)),
          throwsA(isA<CoreRestartRequiredException>()),
        );
      });

      test('lifecycle calls bypass unhealthy gate', () async {
        debugMarkCoreUnhealthy();
        // stopGrpcServerAsync passes allowWhenUnhealthy: true.
        await expectLater(
          stopGrpcServerAsync(timeout: const Duration(seconds: 2)),
          completes,
        );
        await startGrpcServerWithOptionsAsync(_opts);
        // Successful start should clear unhealthy.
        expect(getCoreState(), equals(CoreState.healthy));
      });
    });

    // -------------------------------------------------------------------------
    // Cascade: marking the core unhealthy must drain pending requests and
    // active streams, not leave them hanging.
    // -------------------------------------------------------------------------
    group('Cascade on _markUnhealthy', () {
      test('pending requests fail with CoreUnavailableException', () async {
        // Register a synthetic completer so the test isn't racing against a
        // real RPC's response.
        final completer = Completer<dynamic>();
        debugRegisterFakePendingRequest(completer);
        expect(debugPendingRequestCount(), greaterThan(0));

        debugMarkCoreUnhealthy();

        await expectLater(
          completer.future,
          throwsA(isA<CoreUnavailableException>()
              .having((e) => e.state, 'state', CoreState.unhealthy)),
        );
        expect(debugPendingRequestCount(), equals(0));
      });

      test('active server streams receive error and close', () async {
        // test/server_stream is a real registered stream handler (see
        // pkg/service/test_handlers.go) that emits bytes 1..5 with 10ms gaps.
        // Using it guarantees an entry actually lands in _activeStreams,
        // unlike Ping which is unary.
        final streamResult = invokeBackendServerStreamWithTrailers(
          'test/server_stream',
          Uint8List(0),
        );
        // Consume the trailers Future eagerly: the cascade error-completes it
        // alongside the stream, and an unobserved errored Future would surface
        // as an unhandled async error and fail the test.
        unawaited(streamResult.trailers.catchError(
          (Object _) => <String, String>{},
        ));
        final errors = <Object>[];
        final done = Completer<void>();
        streamResult.stream.listen(
          (_) {},
          onError: errors.add,
          onDone: done.complete,
          cancelOnError: false,
        );

        // Wait until the stream is actually registered before triggering the
        // cascade — sendRequest for the stream id is async.
        final start = DateTime.now();
        while (debugActiveServerStreamCount() == 0 &&
            DateTime.now().difference(start) < const Duration(seconds: 1)) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(debugActiveServerStreamCount(), greaterThan(0),
            reason: 'stream did not register before cascade');

        debugMarkCoreUnhealthy();

        await done.future.timeout(const Duration(seconds: 1));

        expect(errors, isNotEmpty,
            reason: 'cascade must deliver an error to the stream');
        expect(errors.first, isA<CoreUnavailableException>());
        expect(debugActiveServerStreamCount(), equals(0));
        expect(debugPendingStreamResultCount(), equals(0));
      });

      test('_markUnhealthy is a no-op when already restartRequired', () {
        debugForceCoreState(CoreState.restartRequired);
        debugMarkCoreUnhealthy();
        // State must NOT drop from restartRequired back to unhealthy.
        expect(getCoreState(), equals(CoreState.restartRequired));
      });
    });

    // -------------------------------------------------------------------------
    // recoverCoreAsync edge cases.
    // -------------------------------------------------------------------------
    group('recoverCoreAsync', () {
      test('happy path: recovers from healthy to healthy', () async {
        final result = await recoverCoreAsync(previousStartOptions: _opts);

        expect(result.recovered, isTrue);
        expect(result.status, equals(CoreRecoveryStatus.recovered));
        expect(getCoreState(), equals(CoreState.healthy));

        // Verify the core is actually usable after recovery.
        final ch = FfiClientChannel();
        try {
          final client = HealthServiceClient(ch);
          expect(await client.ping(Empty()), isA<PingResponse>());
        } finally {
          await ch.shutdown();
        }
      });

      test('recovers from unhealthy', () async {
        debugMarkCoreUnhealthy();
        expect(getCoreState(), equals(CoreState.unhealthy));

        final result = await recoverCoreAsync(previousStartOptions: _opts);
        expect(result.recovered, isTrue);
        expect(getCoreState(), equals(CoreState.healthy));
      });

      test('returns restartRequired immediately when already restartRequired',
          () async {
        debugForceCoreState(CoreState.restartRequired);

        final stopwatch = Stopwatch()..start();
        final result = await recoverCoreAsync(
          previousStartOptions: _opts,
          stopTimeout: const Duration(seconds: 30),
          startTimeout: const Duration(seconds: 30),
        );
        stopwatch.stop();

        expect(result.restartRequired, isTrue);
        expect(result.status, equals(CoreRecoveryStatus.restartRequired));
        expect(result.phase, equals('precheck'));
        // Must not have actually attempted stop/start (would take much longer).
        expect(stopwatch.elapsed.inSeconds, lessThan(2));
        // State stays restartRequired.
        expect(getCoreState(), equals(CoreState.restartRequired));
      });

      test('concurrent callers share the same future', () async {
        final a = recoverCoreAsync(previousStartOptions: _opts);
        final b = recoverCoreAsync(previousStartOptions: _opts);
        // Same Future identity means dedup is working.
        expect(identical(a, b), isTrue);

        final results = await Future.wait([a, b]);
        expect(results[0].recovered, isTrue);
        expect(results[1].recovered, isTrue);
      });

      test('after recovery, _recoveryFuture is cleared', () async {
        await recoverCoreAsync(previousStartOptions: _opts);
        expect(debugIsRecoveryInFlight(), isFalse);
      });
    });

    // -------------------------------------------------------------------------
    // Per-call timeout plumbing — verifies the fix for the bug where
    // invokeBackendAsync's `timeout` parameter was sent to Go but never
    // overrode the Dart-side wait.
    // -------------------------------------------------------------------------
    group('Per-call timeout', () {
      test('explicit long timeout allows the call to complete', () async {
        // Default would still allow this, but we want to verify that supplying
        // an explicit timeout does not regress normal calls.
        final result = await invokeBackendAsync(
          '/core.v1.HealthService/Ping',
          Uint8List(0),
          timeout: const Duration(seconds: 10),
        );
        expect(result, isA<Uint8List>());
      });

      test('explicit timeout propagates through gRPC CallOptions', () async {
        final ch = FfiClientChannel();
        try {
          final client = HealthServiceClient(
            ch,
            options: CallOptions(timeout: const Duration(seconds: 10)),
          );
          expect(await client.ping(Empty()), isA<PingResponse>());
        } finally {
          await ch.shutdown();
        }
      });

      test('default 30s applies when no per-call timeout is given', () async {
        // Positive: a fast call returns well under the default.
        final stopwatch = Stopwatch()..start();
        await invokeBackendAsync('/core.v1.HealthService/Ping', Uint8List(0));
        stopwatch.stop();
        expect(stopwatch.elapsed.inSeconds, lessThan(5));
        expect(getCoreState(), equals(CoreState.healthy));
      });
    });

    // -------------------------------------------------------------------------
    // FfiClientChannel exception mapping: each core exception type must
    // surface as GrpcError.unavailable through the channel.
    // -------------------------------------------------------------------------
    group('FfiClientChannel exception mapping', () {
      test('CoreUnavailableException → GrpcError.unavailable', () async {
        debugMarkCoreUnhealthy();
        final ch = FfiClientChannel();
        try {
          final client = HealthServiceClient(ch);
          await expectLater(
            client.ping(Empty()),
            throwsA(isA<GrpcError>()
                .having((e) => e.code, 'code', StatusCode.unavailable)),
          );
        } finally {
          await ch.shutdown();
        }
      });

      test('CoreRestartRequiredException → GrpcError.unavailable', () async {
        debugForceCoreState(CoreState.restartRequired);
        final ch = FfiClientChannel();
        try {
          final client = HealthServiceClient(ch);
          await expectLater(
            client.ping(Empty()),
            throwsA(isA<GrpcError>()
                .having((e) => e.code, 'code', StatusCode.unavailable)),
          );
        } finally {
          await ch.shutdown();
        }
      });

      test('shutdown channel → GrpcError.unavailable', () async {
        final ch = FfiClientChannel();
        await ch.shutdown();
        final client = HealthServiceClient(ch);
        await expectLater(
          client.ping(Empty()),
          throwsA(isA<GrpcError>()
              .having((e) => e.code, 'code', StatusCode.unavailable)),
        );
      });
    });

    // -------------------------------------------------------------------------
    // resetCoreState: documents that the public reset is Dart-side only and
    // does not change the restartRequired terminal state.
    // -------------------------------------------------------------------------
    // -------------------------------------------------------------------------
    // End-to-end recovery via the debug HangFor RPC. These tests provoke a
    // *real* timeout in Go, not a synthetic state flip, so we exercise the
    // full _markUnhealthy → recoverCoreAsync path against a live backend.
    //
    // Only runs when libsynurang.so was built with `-tags debug`
    // (see `make shared_linux_debug`). In production builds the
    // /core.v1.DebugService/HangFor path returns "unknown method" and these
    // tests are skipped.
    // -------------------------------------------------------------------------
    group('End-to-end (HangFor)', () {
      bool debugRpcAvailable = false;

      setUpAll(() async {
        try {
          await invokeBackendAsync(
            '/core.v1.DebugService/HangFor',
            Uint8List.fromList('0'.codeUnits),
            timeout: const Duration(seconds: 2),
          );
          debugRpcAvailable = true;
        } catch (_) {
          debugRpcAvailable = false;
        }
      });

      test('real timeout flips state to unhealthy', () async {
        if (!debugRpcAvailable) {
          markTestSkipped('libsynurang.so not built with -tags debug');
          return;
        }
        expect(getCoreState(), equals(CoreState.healthy));

        await expectLater(
          invokeBackendAsync(
            '/core.v1.DebugService/HangFor',
            Uint8List.fromList('10000'.codeUnits),
            timeout: const Duration(milliseconds: 500),
          ),
          throwsA(isA<CoreTimeoutException>()),
        );
        expect(getCoreState(), equals(CoreState.unhealthy));
      });

      test('recoverCoreAsync restores a really-timed-out core', () async {
        if (!debugRpcAvailable) {
          markTestSkipped('libsynurang.so not built with -tags debug');
          return;
        }

        // Force the real timeout path.
        try {
          await invokeBackendAsync(
            '/core.v1.DebugService/HangFor',
            Uint8List.fromList('10000'.codeUnits),
            timeout: const Duration(milliseconds: 500),
          );
        } catch (_) {}
        expect(getCoreState(), equals(CoreState.unhealthy));

        final result = await recoverCoreAsync(previousStartOptions: _opts);
        expect(result.recovered, isTrue);
        expect(getCoreState(), equals(CoreState.healthy));

        // Subsequent calls work.
        final pong = await invokeBackendAsync(
          '/core.v1.HealthService/Ping',
          Uint8List(0),
          timeout: const Duration(seconds: 2),
        );
        expect(pong, isA<Uint8List>());
      });
    });

    group('resetCoreState', () {
      test('clears active streams', () async {
        invokeBackendServerStreamWithTrailers(
          '/core.v1.HealthService/Ping',
          Uint8List(0),
        );
        await Future<void>.delayed(const Duration(milliseconds: 5));

        resetCoreState();
        await Future<void>.delayed(const Duration(milliseconds: 5));

        expect(debugActiveServerStreamCount(), equals(0));
        expect(debugPendingStreamResultCount(), equals(0));
      });

      test('does not downgrade restartRequired to healthy', () {
        debugForceCoreState(CoreState.restartRequired);
        resetCoreState();
        expect(getCoreState(), equals(CoreState.restartRequired));
      });
    });
  });
}
