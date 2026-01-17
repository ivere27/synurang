import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:grpc/grpc.dart' as grpc;
import 'package:synurang/synurang.dart' hide Duration;
import 'package:synurang/src/generated/core.pbgrpc.dart' as pbgrpc;
import 'package:test/test.dart';

// =============================================================================
// Full Verification and Benchmark Test Suite
// =============================================================================
//
// This test suite validates all RPC patterns (unary, server stream, client
// stream, bidi stream) and benchmarks throughput across different transports:
//   - FFI: Direct in-process calls via shared library
//   - TCP: Network socket communication (localhost only)
//   - UDS: Unix Domain Socket communication
//
// All benchmarks run on localhost for fair comparison of transport overhead.
// =============================================================================

/// Transport mode for benchmarking
enum TransportMode { ffi, tcp, uds }

void main() {
  final libPath = '${Directory.current.path}/src/libsynurang.so';
  final serverBinaryPath = '${Directory.current.path}/bin/synurang_server';

  setUpAll(() async {
    print('Loading library from: $libPath');
    configureSynurang(libraryName: 'synurang', libraryPath: libPath);
    prewarmIsolate();

    // Start the Go server (runs in the shared library process space)
    // This server is accessible from ALL isolates in this process
    await startGrpcServerAsync(token: 'test-token');
  });

  tearDownAll(() async {
    await stopGrpcServerAsync();
    resetCoreState();
  });

  group('Verification Tests (FFI)', () {
    test('Unary Call (Health.Ping)', () async {
      final req = Empty();
      final respBytes =
          invokeBackend('/core.v1.HealthService/Ping', req.writeToBuffer());
      final resp = PingResponse.fromBuffer(respBytes);

      expect(resp.version, equals('0.1.0'));
      expect(resp.timestamp, isNotNull);
    });

    test('Server Stream (test/server_stream)', () async {
      final stream =
          invokeBackendServerStream('test/server_stream', Uint8List(0));
      final events = <int>[];

      await for (final data in stream) {
        expect(data.length, equals(1));
        events.add(data[0]);
      }

      expect(events, equals([1, 2, 3, 4, 5]));
    });

    test('Client Stream (test/client_stream)', () async {
      // Stream that yields 1, 2, 3, 4, 5
      final inputController = StreamController<Uint8List>();
      final responseFuture = invokeBackendClientStream(
          'test/client_stream', inputController.stream);

      for (int i = 1; i <= 5; i++) {
        inputController.add(Uint8List.fromList([i]));
        await Future.delayed(Duration(milliseconds: 10));
      }
      await inputController.close();

      final resp = await responseFuture;
      expect(resp.length, equals(1));
      expect(resp[0], equals(15)); // 1+2+3+4+5 = 15
    });

    test('Bidi Stream (test/bidi_stream)', () async {
      final inputController = StreamController<Uint8List>();
      final outputStream =
          invokeBackendBidiStream('test/bidi_stream', inputController.stream);

      final received = <int>[];
      final completer = Completer<void>();

      outputStream.listen((data) {
        received.add(data[0]);
        if (received.length == 5) completer.complete();
      });

      for (int i = 1; i <= 5; i++) {
        inputController.add(Uint8List.fromList([i]));
        await Future.delayed(Duration(milliseconds: 10));
      }
      await inputController.close();

      await completer.future;
      expect(received, equals([1, 2, 3, 4, 5]));
    });
  });

  // ===========================================================================
  // BENCHMARKS: Compare FFI, TCP, and UDS transport performance
  // ===========================================================================

  group('Benchmarks - FFI Transport', () {
    for (int isolateCount = 1; isolateCount <= 4; isolateCount++) {
      test('FFI with $isolateCount isolates', () async {
        await _runIsolateBenchmark(
          TransportMode.ffi,
          isolateCount,
          libPath: libPath,
        );
      }, timeout: Timeout(Duration(minutes: 1)));
    }
  });

  group('Benchmarks - TCP Transport', () {
    const tcpPort = 28001;
    Process? goProcess;
    grpc.ClientChannel? channel;

    setUpAll(() async {
      // Start external Go server for TCP benchmarks
      goProcess = await _startGoServer(
        serverBinaryPath,
        mode: TransportMode.tcp,
        goPort: tcpPort,
      );
      await _waitForTcpServer(tcpPort);

      channel = grpc.ClientChannel(
        'localhost',
        port: tcpPort,
        options: const grpc.ChannelOptions(
          credentials: grpc.ChannelCredentials.insecure(),
        ),
      );
    });

    tearDownAll(() async {
      await channel?.shutdown();
      goProcess?.kill(ProcessSignal.sigterm);
      await goProcess?.exitCode.timeout(
        Duration(seconds: 5),
        onTimeout: () {
          goProcess?.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
    });

    for (int isolateCount = 1; isolateCount <= 4; isolateCount++) {
      test('TCP with $isolateCount isolates', () async {
        await _runGrpcBenchmark(
          TransportMode.tcp,
          isolateCount,
          tcpPort: tcpPort,
        );
      }, timeout: Timeout(Duration(minutes: 1)));
    }
  });

  group('Benchmarks - UDS Transport', () {
    const udsSocket = '/tmp/synurang_benchmark.sock';
    Process? goProcess;
    grpc.ClientChannel? channel;

    setUpAll(() async {
      // Clean up any existing socket
      final socketFile = File(udsSocket);
      if (await socketFile.exists()) await socketFile.delete();

      // Start external Go server for UDS benchmarks
      goProcess = await _startGoServer(
        serverBinaryPath,
        mode: TransportMode.uds,
        goSocket: udsSocket,
      );
      await _waitForUdsServer(udsSocket);

      channel = grpc.ClientChannel(
        InternetAddress(udsSocket, type: InternetAddressType.unix),
        port: 0,
        options: const grpc.ChannelOptions(
          credentials: grpc.ChannelCredentials.insecure(),
        ),
      );
    });

    tearDownAll(() async {
      await channel?.shutdown();
      goProcess?.kill(ProcessSignal.sigterm);
      await goProcess?.exitCode.timeout(
        Duration(seconds: 5),
        onTimeout: () {
          goProcess?.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
      // Clean up socket file
      final socketFile = File(udsSocket);
      if (await socketFile.exists()) await socketFile.delete();
    });

    for (int isolateCount = 1; isolateCount <= 4; isolateCount++) {
      test('UDS with $isolateCount isolates', () async {
        await _runGrpcBenchmark(
          TransportMode.uds,
          isolateCount,
          udsSocket: udsSocket,
        );
      }, timeout: Timeout(Duration(minutes: 1)));
    }
  });

  // ===========================================================================
  // SUMMARY: Side-by-side comparison
  // ===========================================================================
  group('Benchmark Summary', () {
    test('Compare all transports (single isolate baseline)', () async {
      print('\n');
      print(
          '╔════════════════════════════════════════════════════════════════╗');
      print(
          '║           Transport Benchmark Summary (1 Isolate)              ║');
      print(
          '╠════════════════════════════════════════════════════════════════╣');

      // FFI benchmark
      final ffiOps =
          await _singleBenchmark(TransportMode.ffi, libPath: libPath);
      print('║  FFI:  ${_formatOps(ffiOps)} ops/sec'.padRight(65) + '║');

      // TCP benchmark (spawn server inline)
      const tcpPort = 28002;
      final tcpProcess = await _startGoServer(
        serverBinaryPath,
        mode: TransportMode.tcp,
        goPort: tcpPort,
      );
      await _waitForTcpServer(tcpPort);
      final tcpOps =
          await _singleGrpcBenchmark(TransportMode.tcp, tcpPort: tcpPort);
      tcpProcess.kill(ProcessSignal.sigterm);
      await tcpProcess.exitCode
          .timeout(Duration(seconds: 2), onTimeout: () => -1);
      print('║  TCP:  ${_formatOps(tcpOps)} ops/sec'.padRight(65) + '║');

      // UDS benchmark (spawn server inline)
      const udsSocket = '/tmp/synurang_summary.sock';
      final socketFile = File(udsSocket);
      if (await socketFile.exists()) await socketFile.delete();
      final udsProcess = await _startGoServer(
        serverBinaryPath,
        mode: TransportMode.uds,
        goSocket: udsSocket,
      );
      await _waitForUdsServer(udsSocket);
      final udsOps =
          await _singleGrpcBenchmark(TransportMode.uds, udsSocket: udsSocket);
      udsProcess.kill(ProcessSignal.sigterm);
      await udsProcess.exitCode
          .timeout(Duration(seconds: 2), onTimeout: () => -1);
      if (await socketFile.exists()) await socketFile.delete();
      print('║  UDS:  ${_formatOps(udsOps)} ops/sec'.padRight(65) + '║');

      print(
          '╠════════════════════════════════════════════════════════════════╣');
      final ffiVsTcp = (ffiOps / tcpOps).toStringAsFixed(1);
      final ffiVsUds = (ffiOps / udsOps).toStringAsFixed(1);
      final udsVsTcp = (udsOps / tcpOps).toStringAsFixed(1);
      print('║  FFI vs TCP: ${ffiVsTcp}x faster'.padRight(65) + '║');
      print('║  FFI vs UDS: ${ffiVsUds}x faster'.padRight(65) + '║');
      print('║  UDS vs TCP: ${udsVsTcp}x faster'.padRight(65) + '║');
      print(
          '╚════════════════════════════════════════════════════════════════╝');
      print('\n');
    }, timeout: Timeout(Duration(minutes: 2)));
  });
}

// =============================================================================
// Benchmark Infrastructure
// =============================================================================

String _formatOps(int ops) {
  final perSec = ops / 2.0;
  if (perSec >= 1000) {
    return '${(perSec / 1000).toStringAsFixed(1)}k';
  }
  return perSec.toStringAsFixed(0);
}

/// Start a Go server process for TCP or UDS benchmarks
Future<Process> _startGoServer(
  String binaryPath, {
  required TransportMode mode,
  int goPort = 0,
  String goSocket = '',
}) async {
  final serverArgs = <String>['--token=test-token'];

  if (mode == TransportMode.tcp) {
    serverArgs.add('--golang-port=$goPort');
    serverArgs.add('--golang-socket='); // Empty to disable UDS
  } else {
    serverArgs.add('--golang-socket=$goSocket');
    serverArgs.add('--golang-port='); // Empty to disable TCP
  }

  final process = await Process.start(binaryPath, serverArgs);

  // Forward output for debugging
  process.stdout.listen((data) => stdout.add(data));
  process.stderr.listen((data) => stderr.add(data));

  return process;
}

/// Wait for TCP server to be ready
Future<void> _waitForTcpServer(int port) async {
  for (int i = 0; i < 40; i++) {
    try {
      final conn = await Socket.connect(
        'localhost',
        port,
        timeout: Duration(milliseconds: 250),
      );
      await conn.close();
      return;
    } catch (_) {
      await Future.delayed(Duration(milliseconds: 100));
    }
  }
  throw Exception('TCP server did not start on port $port');
}

/// Wait for UDS server to be ready
Future<void> _waitForUdsServer(String socketPath) async {
  for (int i = 0; i < 40; i++) {
    if (await File(socketPath).exists()) {
      await Future.delayed(Duration(milliseconds: 100));
      return;
    }
    await Future.delayed(Duration(milliseconds: 100));
  }
  throw Exception('UDS server did not create socket at $socketPath');
}

/// Run FFI benchmark with multiple isolates
Future<void> _runIsolateBenchmark(
  TransportMode mode,
  int isolateCount, {
  required String libPath,
}) async {
  print(
      '\n[${mode.name.toUpperCase()}] Starting benchmark with $isolateCount isolates...');
  final ports = <ReceivePort>[];

  for (int i = 0; i < isolateCount; i++) {
    final rp = ReceivePort();
    ports.add(rp);
    await Isolate.spawn(
      _ffiBenchmarkWorker,
      _FfiBenchmarkMsg(rp.sendPort, libPath),
    );
  }

  final results = await Future.wait(ports.map((rp) => rp.first));

  int totalOps = 0;
  for (final r in results) {
    totalOps += (r as int);
  }

  print(
      '[${mode.name.toUpperCase()}] Total: $totalOps ops in 2s | ${totalOps / 2.0} ops/sec | ${(totalOps / 2.0 / isolateCount).toStringAsFixed(0)} ops/sec/isolate');
}

/// Run gRPC benchmark with multiple isolates (for TCP/UDS)
Future<void> _runGrpcBenchmark(
  TransportMode mode,
  int isolateCount, {
  int tcpPort = 0,
  String udsSocket = '',
}) async {
  print(
      '\n[${mode.name.toUpperCase()}] Starting benchmark with $isolateCount isolates...');
  final ports = <ReceivePort>[];

  for (int i = 0; i < isolateCount; i++) {
    final rp = ReceivePort();
    ports.add(rp);
    await Isolate.spawn(
      _grpcBenchmarkWorker,
      _GrpcBenchmarkMsg(rp.sendPort, mode, tcpPort, udsSocket),
    );
  }

  final results = await Future.wait(ports.map((rp) => rp.first));

  int totalOps = 0;
  for (final r in results) {
    totalOps += (r as int);
  }

  print(
      '[${mode.name.toUpperCase()}] Total: $totalOps ops in 2s | ${totalOps / 2.0} ops/sec | ${(totalOps / 2.0 / isolateCount).toStringAsFixed(0)} ops/sec/isolate');
}

/// Single-thread FFI benchmark for summary
Future<int> _singleBenchmark(TransportMode mode,
    {required String libPath}) async {
  final stopwatch = Stopwatch()..start();
  int ops = 0;

  while (stopwatch.elapsedMilliseconds < 2000) {
    final req = Empty();
    invokeBackend('/core.v1.HealthService/Ping', req.writeToBuffer());
    ops++;
  }

  return ops;
}

/// Single-thread gRPC benchmark for summary
Future<int> _singleGrpcBenchmark(
  TransportMode mode, {
  int tcpPort = 0,
  String udsSocket = '',
}) async {
  grpc.ClientChannel channel;

  if (mode == TransportMode.tcp) {
    channel = grpc.ClientChannel(
      'localhost',
      port: tcpPort,
      options: const grpc.ChannelOptions(
        credentials: grpc.ChannelCredentials.insecure(),
      ),
    );
  } else {
    channel = grpc.ClientChannel(
      InternetAddress(udsSocket, type: InternetAddressType.unix),
      port: 0,
      options: const grpc.ChannelOptions(
        credentials: grpc.ChannelCredentials.insecure(),
      ),
    );
  }

  final client = pbgrpc.HealthServiceClient(
    channel,
    options: grpc.CallOptions(metadata: {'authorization': 'Bearer test-token'}),
  );

  final stopwatch = Stopwatch()..start();
  int ops = 0;

  while (stopwatch.elapsedMilliseconds < 2000) {
    await client.ping(Empty());
    ops++;
  }

  await channel.shutdown();
  return ops;
}

// =============================================================================
// Isolate Worker Functions
// =============================================================================

class _FfiBenchmarkMsg {
  final SendPort sendPort;
  final String libPath;
  _FfiBenchmarkMsg(this.sendPort, this.libPath);
}

class _GrpcBenchmarkMsg {
  final SendPort sendPort;
  final TransportMode mode;
  final int tcpPort;
  final String udsSocket;
  _GrpcBenchmarkMsg(this.sendPort, this.mode, this.tcpPort, this.udsSocket);
}

/// FFI benchmark worker
void _ffiBenchmarkWorker(_FfiBenchmarkMsg msg) async {
  configureSynurang(libraryName: 'synurang', libraryPath: msg.libPath);
  prewarmIsolate();

  await Future.delayed(Duration(milliseconds: 100));

  final stopwatch = Stopwatch()..start();
  int ops = 0;
  int errors = 0;

  while (stopwatch.elapsedMilliseconds < 2000) {
    try {
      final req = Empty();
      invokeBackend('/core.v1.HealthService/Ping', req.writeToBuffer());
      ops++;
    } catch (e) {
      errors++;
      if (errors <= 3) print('FFI error: $e');
    }
  }

  if (errors > 3) print('... and ${errors - 3} more FFI errors');
  msg.sendPort.send(ops);
}

/// gRPC benchmark worker (for TCP/UDS)
void _grpcBenchmarkWorker(_GrpcBenchmarkMsg msg) async {
  grpc.ClientChannel channel;

  if (msg.mode == TransportMode.tcp) {
    channel = grpc.ClientChannel(
      'localhost',
      port: msg.tcpPort,
      options: const grpc.ChannelOptions(
        credentials: grpc.ChannelCredentials.insecure(),
      ),
    );
  } else {
    channel = grpc.ClientChannel(
      InternetAddress(msg.udsSocket, type: InternetAddressType.unix),
      port: 0,
      options: const grpc.ChannelOptions(
        credentials: grpc.ChannelCredentials.insecure(),
      ),
    );
  }

  final client = pbgrpc.HealthServiceClient(
    channel,
    options: grpc.CallOptions(metadata: {'authorization': 'Bearer test-token'}),
  );

  await Future.delayed(Duration(milliseconds: 100));

  final stopwatch = Stopwatch()..start();
  int ops = 0;
  int errors = 0;

  while (stopwatch.elapsedMilliseconds < 2000) {
    try {
      await client.ping(Empty());
      ops++;
    } catch (e) {
      errors++;
      if (errors <= 3) print('gRPC error: $e');
    }
  }

  await channel.shutdown();
  if (errors > 3) print('... and ${errors - 3} more gRPC errors');
  msg.sendPort.send(ops);
}
