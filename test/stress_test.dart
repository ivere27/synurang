import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:synurang/synurang.dart' hide Duration;

/// Stress test for synurang FFI + streaming implementation.
///
/// Tests concurrent unary and streaming calls over 30 seconds while monitoring
/// memory usage. This validates:
/// - Memory stability (no leaks from FFI or stream callbacks)
/// - Throughput under sustained load
/// - Zero-copy buffer handling correctness
///
/// Note: Workers run as async tasks in the same isolate (single-threaded),
/// so counter increments are atomic by nature. We use this simple approach
/// rather than Isolates for cleaner stress testing of the FFI layer itself.
void main() async {
  final libPath = '${Directory.current.path}/src/libsynurang.so';
  print('Loading library from: $libPath');
  configureSynurang(libraryName: 'synurang', libraryPath: libPath);
  prewarmIsolate();

  // Start the server (embedded)
  await startGrpcServerAsync(token: 'test-token');

  // Register dummy handler for streams
  registerDartHandler((method, data) => Uint8List(0));

  print('Starting stress test (Duration: 30s)...');
  print('PID: $pid');

  final stopwatch = Stopwatch()..start();
  final duration = Duration(seconds: 30);

  // Counter tracking - safe as these async workers run in the same isolate
  int unaryOps = 0;
  int streamOps = 0;
  int errorCount = 0;

  // Memory tracking
  final initialRss = _getRss();
  print('Initial RSS: ${_formatBytes(initialRss)}');

  // Launch parallel async workers (same isolate, interleaved execution)
  final workers = <Future>[];
  const workerCount = 4;
  for (int i = 0; i < workerCount; i++) {
    workers.add(_stressWorker(
      id: i,
      duration: duration,
      onUnary: () => unaryOps++,
      onStream: () => streamOps++,
      onError: () => errorCount++,
    ));
  }

  // Monitor loop
  Timer.periodic(Duration(seconds: 1), (timer) {
    if (stopwatch.elapsed > duration) {
      timer.cancel();
      return;
    }
    final currentRss = _getRss();
    final delta = currentRss - initialRss;
    print('[${stopwatch.elapsed.inSeconds}s] RSS: ${_formatBytes(currentRss)} '
        '(Delta: ${_formatBytes(delta)}) | Unary: $unaryOps | Stream: $streamOps | Errors: $errorCount');
  });

  await Future.wait(workers);

  print('\\nStress test complete.');
  print('Total Unary Ops: $unaryOps');
  print('Total Stream Ops: $streamOps');
  print('Total Errors: $errorCount');
  print('Throughput: ${(unaryOps + streamOps) / 30.0} ops/sec');

  final finalRss = _getRss();
  print(
      'Final RSS: ${_formatBytes(finalRss)} (Total Growth: ${_formatBytes(finalRss - initialRss)})');

  await stopGrpcServerAsync();
  resetCoreState();
  exit(0);
}

Future<void> _stressWorker({
  required int id,
  required Duration duration,
  required Function onUnary,
  required Function onStream,
  required Function onError,
}) async {
  final stopwatch = Stopwatch()..start();

  while (stopwatch.elapsed < duration) {
    // 1. Unary Call
    try {
      final req = Empty();
      invokeBackend('/core.v1.HealthService/Ping', req.writeToBuffer());
      onUnary();
    } catch (e) {
      print('[Worker $id] Unary error: $e');
      onError();
    }

    // 2. Stream Call (Create and consume)
    try {
      final stream =
          invokeBackendServerStream('test/server_stream', Uint8List(0));
      await for (final _ in stream) {
        // Consume all stream data
      }
      onStream();
    } catch (e) {
      print('[Worker $id] Stream error: $e');
      onError();
    }

    // Yield to allow other async tasks to run (prevents starvation)
    await Future.delayed(Duration.zero);
  }
}

int _getRss() {
  final result = Process.runSync('ps', ['-p', '$pid', '-o', 'rss=']);
  if (result.exitCode == 0) {
    return int.parse(result.stdout.toString().trim()) * 1024; // ps returns kB
  }
  return 0;
}

String _formatBytes(int bytes) {
  const suffixes = ['B', 'KB', 'MB', 'GB'];
  var i = 0;
  double v = bytes.toDouble();
  while (v > 1024 && i < suffixes.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(2)} ${suffixes[i]}';
}
