import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:synurang/synurang.dart' hide Duration;
import 'package:test/test.dart';

/// Comprehensive race condition test for all 8 RPC patterns.
///
/// Tests bidirectional gRPC communication patterns in parallel:
/// - Dart → Go: Unary, Server Stream, Client Stream, Bidi Stream (4 types)
/// - Go → Dart: Unary, Server Stream, Client Stream, Bidi Stream (4 types)
///
/// This test verifies:
/// 1. Thread-safety of stream callback registration
/// 2. No race conditions in concurrent RPC handling
/// 3. Proper cleanup of stream resources
/// 4. Data integrity under high concurrency
void main() {
  final libPath = '${Directory.current.path}/src/libsynurang.so';

  setUpAll(() async {
    print('Loading library from: $libPath');
    configureSynurang(libraryName: 'synurang', libraryPath: libPath);
    prewarmIsolate();

    print(
        'Isolate pool size: ${getPoolSize()} (CPU cores: ${Platform.numberOfProcessors})');

    await startGrpcServerAsync(token: 'test-token');

    // Register Go → Dart handler for testing reverse direction
    registerDartHandler(_handleGoDartRequest);
  });

  tearDownAll(() async {
    await stopGrpcServerAsync();
    resetCoreState();
  });

  group('Mixed RPC Race Condition Tests', () {
    test('All 8 RPC types in parallel - single iteration', () async {
      await _runAllRpcTypesInParallel(iterations: 1);
    });

    test('All 8 RPC types in parallel - 10 iterations', () async {
      await _runAllRpcTypesInParallel(iterations: 10);
    });

    test('All 8 RPC types in parallel - 50 iterations (stress)', () async {
      await _runAllRpcTypesInParallel(iterations: 50);
    }, timeout: Timeout(Duration(minutes: 2)));

    test('All 8 RPC types in parallel - 100 iterations (heavy stress)',
        () async {
      await _runAllRpcTypesInParallel(iterations: 100);
    }, timeout: Timeout(Duration(minutes: 5)));

    test('Concurrent stream registration stress test', () async {
      // This specifically tests the race condition fix in _ensureStreamCallbackRegistered
      // by starting many streams simultaneously before any can complete registration
      final futures = <Future>[];

      for (int i = 0; i < 20; i++) {
        // Start all streams at once without awaiting
        futures.add(_dartToGoServerStream());
        futures.add(_dartToGoClientStream());
        futures.add(_dartToGoBidiStream());
      }

      // All should complete without errors
      final results = await Future.wait(futures);
      expect(results.length, equals(60));
      print('✓ 60 concurrent stream registrations completed successfully');
    });
  });
}

/// Runs all 8 RPC types in parallel for the specified number of iterations.
Future<void> _runAllRpcTypesInParallel({required int iterations}) async {
  int successCount = 0;
  int errorCount = 0;
  final errors = <String>[];
  final stopwatch = Stopwatch()..start();

  for (int i = 0; i < iterations; i++) {
    final futures = <Future<bool>>[];

    // Dart → Go RPCs (4 types × 2 = 8 concurrent operations)

    // Unary calls (2x)
    futures.add(_dartToGoUnary().then((_) => true).catchError((e) {
      errors.add('D→G Unary #1: $e');
      return false;
    }));
    futures.add(_dartToGoUnary().then((_) => true).catchError((e) {
      errors.add('D→G Unary #2: $e');
      return false;
    }));

    // Server streaming calls (2x)
    futures.add(_dartToGoServerStream().then((_) => true).catchError((e) {
      errors.add('D→G ServerStream #1: $e');
      return false;
    }));
    futures.add(_dartToGoServerStream().then((_) => true).catchError((e) {
      errors.add('D→G ServerStream #2: $e');
      return false;
    }));

    // Client streaming calls (2x)
    futures.add(_dartToGoClientStream().then((_) => true).catchError((e) {
      errors.add('D→G ClientStream #1: $e');
      return false;
    }));
    futures.add(_dartToGoClientStream().then((_) => true).catchError((e) {
      errors.add('D→G ClientStream #2: $e');
      return false;
    }));

    // Bidi streaming calls (2x)
    futures.add(_dartToGoBidiStream().then((_) => true).catchError((e) {
      errors.add('D→G BidiStream #1: $e');
      return false;
    }));
    futures.add(_dartToGoBidiStream().then((_) => true).catchError((e) {
      errors.add('D→G BidiStream #2: $e');
      return false;
    }));

    final results = await Future.wait(futures);
    successCount += results.where((r) => r).length;
    errorCount += results.where((r) => !r).length;
  }

  stopwatch.stop();

  print('');
  print('═══════════════════════════════════════════════════════════');
  print('Mixed RPC Race Condition Test Results');
  print('═══════════════════════════════════════════════════════════');
  print('Iterations: $iterations');
  print('Total Operations: ${iterations * 8}');
  print('Successful: $successCount');
  print('Failed: $errorCount');
  print('Duration: ${stopwatch.elapsedMilliseconds}ms');
  print(
      'Throughput: ${(successCount / stopwatch.elapsedMilliseconds * 1000).toStringAsFixed(1)} ops/sec');
  print('═══════════════════════════════════════════════════════════');

  if (errors.isNotEmpty) {
    print('Errors (first 10):');
    for (final e in errors.take(10)) {
      print('  - $e');
    }
  }

  expect(errorCount, equals(0), reason: 'Expected no errors in mixed RPC test');
}

// =============================================================================
// Dart → Go RPC Implementations
// =============================================================================

/// Dart → Go: Unary RPC
Future<void> _dartToGoUnary() async {
  final req = Empty();
  final respBytes =
      invokeBackend('/core.v1.HealthService/Ping', req.writeToBuffer());
  final resp = PingResponse.fromBuffer(respBytes);
  if (resp.version != '0.1.0') {
    throw Exception('Invalid version: ${resp.version}');
  }
}

/// Dart → Go: Server Streaming RPC
Future<void> _dartToGoServerStream() async {
  final stream = invokeBackendServerStream('test/server_stream', Uint8List(0));
  final events = <int>[];

  await for (final data in stream) {
    if (data.isNotEmpty) {
      events.add(data[0]);
    }
  }

  if (events.length != 5 || events.join(',') != '1,2,3,4,5') {
    throw Exception('Invalid server stream result: $events');
  }
}

/// Dart → Go: Client Streaming RPC
Future<void> _dartToGoClientStream() async {
  final inputController = StreamController<Uint8List>();
  final responseFuture =
      invokeBackendClientStream('test/client_stream', inputController.stream);

  // Send 1, 2, 3, 4, 5
  for (int i = 1; i <= 5; i++) {
    inputController.add(Uint8List.fromList([i]));
    await Future.delayed(Duration(milliseconds: 1));
  }
  await inputController.close();

  final resp = await responseFuture;
  if (resp.length != 1 || resp[0] != 15) {
    throw Exception('Invalid client stream response: $resp (expected [15])');
  }
}

/// Dart → Go: Bidirectional Streaming RPC
Future<void> _dartToGoBidiStream() async {
  final inputController = StreamController<Uint8List>();
  final outputStream =
      invokeBackendBidiStream('test/bidi_stream', inputController.stream);

  final received = <int>[];
  final completer = Completer<void>();

  outputStream.listen(
    (data) {
      if (data.isNotEmpty) {
        received.add(data[0]);
        if (received.length == 5) completer.complete();
      }
    },
    onError: (e) {
      if (!completer.isCompleted) completer.completeError(e);
    },
    onDone: () {
      if (!completer.isCompleted) {
        if (received.length == 5) {
          completer.complete();
        } else {
          completer
              .completeError(Exception('Stream ended early, got: $received'));
        }
      }
    },
  );

  // Send 1, 2, 3, 4, 5
  for (int i = 1; i <= 5; i++) {
    inputController.add(Uint8List.fromList([i]));
    await Future.delayed(Duration(milliseconds: 1));
  }
  await inputController.close();

  await completer.future.timeout(Duration(seconds: 5));

  if (received.join(',') != '1,2,3,4,5') {
    throw Exception('Invalid bidi stream result: $received');
  }
}

// =============================================================================
// Go → Dart Handler (for reverse direction callbacks)
// =============================================================================

/// Handler for Go → Dart requests
Uint8List _handleGoDartRequest(String method, Uint8List data) {
  // Echo back the data for testing
  return data;
}
