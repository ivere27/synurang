import 'dart:core';
import 'dart:io';

import 'package:grpc/grpc.dart' as grpc;
import 'package:synurang/synurang.dart' hide Duration;
import 'lib/src/dart_greeter_service.dart';
import 'lib/src/generated/example.pbgrpc.dart' as pbgrpc;
import 'lib/src/generated/example.pb.dart' as pb;

/// Transport mode for the example
enum TransportMode { ffi, uds, tcp }

/// Synurang Console Example - Demonstrates all transport modes with bidirectional gRPC
///
/// Usage:
///   dart run example/console_main.dart                    # FFI mode (default)
///   dart run example/console_main.dart --mode=uds         # UDS mode (spawns Go process)
///   dart run example/console_main.dart --mode=tcp         # TCP mode (spawns Go process)
///   dart run example/console_main.dart --mode=tcp --port=18000
///   dart run example/console_main.dart --mode=uds --socket=/tmp/my.sock
void main(List<String> args) async {
  // Parse command line arguments
  final mode = _parseMode(args);
  final goPort = _parseArg(args, 'golang-port', '18000');
  final goSocket = _parseArg(args, 'golang-socket', '/tmp/synurang_go.sock');
  final dartPort = _parseArg(args, 'flutter-port', '10050');
  final dartSocket = _parseArg(
    args,
    'flutter-socket',
    '/tmp/synurang_flutter.sock',
  );
  final token = _parseArg(args, 'token', 'demo-token');
  final goServerPath = _parseArg(args, 'server', 'example/cmd/server/main.go');

  print('╔════════════════════════════════════════════════════════════════╗');
  print('║     Synurang Console Demo - Bidirectional gRPC Transport     ║');
  print('╚════════════════════════════════════════════════════════════════╝');
  print('');
  print('Mode: ${mode.name.toUpperCase()}');
  if (mode == TransportMode.tcp) {
    print('Go TCP Port: $goPort');
    print('Dart TCP Port: $dartPort');
  }
  if (mode == TransportMode.uds) {
    print('Go Socket: $goSocket');
    print('Dart Socket: $dartSocket');
  }
  print('');

  Process? goProcess;
  grpc.ClientChannel? goChannel;
  grpc.Server? dartServer;

  try {
    if (mode == TransportMode.ffi) {
      // =======================================================================
      // FFI Mode: Embedded Go server via shared library
      // =======================================================================
      await _runFfiMode(token);
    } else {
      // =======================================================================
      // UDS/TCP Mode: Spawn Go server + Start Dart server for bidirectional
      // =======================================================================

      // Step 1: Start Dart gRPC server (Go will connect to this)
      print(
        '┌─ Starting Dart gRPC Server ─────────────────────────────────────',
      );
      final dartService = DartGreeterServiceImplForGrpc(
        onLog: (msg) => print('│  📥 $msg'),
      );
      dartServer = grpc.Server.create(
        services: [dartService],
        codecRegistry: grpc.CodecRegistry(
          codecs: const [grpc.GzipCodec(), grpc.IdentityCodec()],
        ),
      );

      if (mode == TransportMode.tcp) {
        await dartServer.serve(port: int.parse(dartPort));
        print('│  ✓ Dart gRPC server listening on TCP port $dartPort');
      } else {
        final socketFile = File(dartSocket);
        if (await socketFile.exists()) await socketFile.delete();
        await dartServer.serve(
          address: InternetAddress(dartSocket, type: InternetAddressType.unix),
          port: 0,
        );
        print('│  ✓ Dart gRPC server listening on UDS: $dartSocket');
      }
      print(
        '└────────────────────────────────────────────────────────────────────',
      );
      print('');

      // Step 2: Spawn Go server process
      print(
        '┌─ Spawning Go Server (Separate Process) ──────────────────────────',
      );

      // Check if server path is a pre-built binary or source file
      String binaryPath;
      if (goServerPath.endsWith('.go')) {
        // Build the Go server binary first
        binaryPath = '/tmp/synurang_console_server';
        print('│  Building: go build -o $binaryPath $goServerPath');
        final buildResult = await Process.run('go', [
          'build',
          '-o',
          binaryPath,
          goServerPath,
        ]);
        if (buildResult.exitCode != 0) {
          print('│  ✗ Build failed: ${buildResult.stderr}');
          return;
        }
        print('│  ✓ Build complete');
      } else {
        // Use pre-built binary directly
        binaryPath = goServerPath;
        print('│  Using pre-built binary: $binaryPath');
      }

      // Prepare server arguments
      final serverArgs = <String>['--token=$token'];
      if (mode == TransportMode.tcp) {
        serverArgs.add('--golang-port=$goPort');
        serverArgs.add('--golang-socket=');
        serverArgs.add(
          '--flutter-port=$dartPort',
        ); // Go connects to Dart via TCP
        serverArgs.add('--flutter-socket=');
      } else {
        serverArgs.add('--golang-socket=$goSocket');
        serverArgs.add('--golang-port=');
        serverArgs.add(
          '--flutter-socket=$dartSocket',
        ); // Go connects to Dart via UDS
        serverArgs.add('--flutter-port=');
      }

      print('│  Command: $binaryPath ${serverArgs.join(' ')}');
      goProcess = await Process.start(binaryPath, serverArgs);
      print('│');
      print('│  ┌────────────────────────────────────────┐');
      print(
        '│  │  GO SERVER PID: ${goProcess.pid.toString().padLeft(10)}        │',
      );
      print('│  └────────────────────────────────────────┘');
      print('│');

      // Forward server output to console
      goProcess.stdout.listen((data) => stdout.add(data));
      goProcess.stderr.listen((data) => stderr.add(data));

      // Wait for server to be ready
      print('│  Waiting for Go server to be ready...');
      await _waitForServer(mode, goPort, goSocket);

      // Create gRPC client channel to Go
      if (mode == TransportMode.tcp) {
        goChannel = grpc.ClientChannel(
          'localhost',
          port: int.parse(goPort),
          options: const grpc.ChannelOptions(
            credentials: grpc.ChannelCredentials.insecure(),
          ),
        );
        print('│  ✓ Connected to Go via TCP localhost:$goPort');
      } else {
        goChannel = grpc.ClientChannel(
          InternetAddress(goSocket, type: InternetAddressType.unix),
          port: 0,
          options: const grpc.ChannelOptions(
            credentials: grpc.ChannelCredentials.insecure(),
          ),
        );
        print('│  ✓ Connected to Go via UDS $goSocket');
      }
      print(
        '└────────────────────────────────────────────────────────────────────',
      );
      print('');

      // Step 3: Run bidirectional tests
      await _runBidirectionalGrpcTests(goChannel, token);
    }
  } finally {
    // Cleanup
    print('');
    print('Cleaning up...');

    if (goChannel != null) {
      await goChannel.shutdown();
      print('  ✓ Go gRPC channel closed');
    }

    if (dartServer != null) {
      await dartServer.shutdown();
      print('  ✓ Dart gRPC server stopped');

      // Cleanup Dart socket file
      if (mode == TransportMode.uds) {
        final socketFile = File(dartSocket);
        if (await socketFile.exists()) {
          await socketFile.delete();
          print('  ✓ Dart socket file removed');
        }
      }
    }

    if (goProcess != null) {
      goProcess.kill(ProcessSignal.sigterm);
      await goProcess.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          goProcess!.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
      print('  ✓ Go server process terminated');

      // Cleanup Go socket file
      if (mode == TransportMode.uds) {
        final socketFile = File(goSocket);
        if (await socketFile.exists()) {
          await socketFile.delete();
          print('  ✓ Go socket file removed');
        }
      }
    }

    if (mode == TransportMode.ffi) {
      await stopGrpcServerAsync();
      resetCoreState();
      print('  ✓ FFI server stopped');
    }

    print('Done.');
    exit(0);
  }
}

/// Run FFI mode (embedded Go server)
Future<void> _runFfiMode(String token) async {
  configureSynurang(libraryName: 'synura_example');
  prewarmIsolate();

  print('┌─ Starting Embedded Go Server (FFI) ──────────────────────────────');
  final result = await startGrpcServerAsync(token: token);
  print('│  Server started with result: $result');
  print('│  Transport: Direct FFI (in-process)');
  print(
    '└────────────────────────────────────────────────────────────────────',
  );
  print('');

  // Register Dart handler for Go → Dart calls
  print('┌─ Registering Dart Handler ────────────────────────────────────────');
  startDartGreeterHandler();
  print('│  Dart gRPC handler registered for Go → Dart calls');
  print(
    '└────────────────────────────────────────────────────────────────────',
  );
  print('');

  // Test D2G (Dart → Go)
  print('┌─ Testing Dart → Go (FFI) ─────────────────────────────────────────');
  try {
    print('│  [Ping] Health check:');
    final pingResp = await GoGreeterClient.ping();
    print('│    ✓ version=${pingResp.version}');

    print('│  [Unary] Bar():');
    for (final lang in ['en', 'ko']) {
      final resp = await GoGreeterClient.bar('World', language: lang);
      print('│    ✓ ${resp.from}: ${resp.message}');
    }

    print('│  [ServerStream] BarServerStream():');
    var count = 0;
    await for (final resp in GoGreeterClient.barServerStream('Stream')) {
      count++;
      print('│    [$count] ${resp.message}');
      if (count >= 3) break; // Early exit to demo partial stream consumption
    }
    print('│    ✓ Received $count of 5 messages (partial consumption demo)');
  } catch (e) {
    print('│  ✗ Error: $e');
  }
  print(
    '└────────────────────────────────────────────────────────────────────',
  );
}

/// Run bidirectional tests using gRPC (for UDS/TCP modes)
Future<void> _runBidirectionalGrpcTests(
  grpc.ClientChannel goChannel,
  String token,
) async {
  final goClient = pbgrpc.GoGreeterServiceClient(
    goChannel,
    options: grpc.CallOptions(metadata: {'authorization': 'Bearer $token'}),
  );

  // Test 1: Dart → Go
  print('┌─ Testing Dart → Go (gRPC) ────────────────────────────────────────');
  try {
    print('│  [Unary] Bar():');
    for (final lang in ['en', 'ko']) {
      final resp = await goClient.bar(
        pb.HelloRequest()
          ..name = 'World'
          ..language = lang,
      );
      print('│    ✓ ${resp.from}: ${resp.message}');
    }

    print('│  [ServerStream] BarServerStream():');
    var count = 0;
    await for (final resp in goClient.barServerStream(
      pb.HelloRequest()..name = 'Stream',
    )) {
      count++;
      print('│    [$count] ${resp.message}');
      if (count >= 3) break; // Early exit to demo partial stream consumption
    }
    print('│    ✓ Received $count of 5 messages (partial consumption demo)');

    print('│  [ClientStream] BarClientStream():');
    final requests = Stream.fromIterable([
      pb.HelloRequest()..name = 'Alice',
      pb.HelloRequest()..name = 'Bob',
      pb.HelloRequest()..name = 'Charlie',
    ]);
    final clientStreamResp = await goClient.barClientStream(requests);
    print('│    ✓ ${clientStreamResp.message}');

    print('│  [BidiStream] BarBidiStream():');
    final bidiRequests = Stream.fromIterable([
      pb.HelloRequest()
        ..name = 'One'
        ..language = 'en',
      pb.HelloRequest()
        ..name = 'Two'
        ..language = 'ko',
    ]);
    count = 0;
    await for (final resp in goClient.barBidiStream(bidiRequests)) {
      count++;
      print('│    [$count] ${resp.message}');
    }
    print('│    ✓ Bidi complete with $count responses');
  } catch (e) {
    print('│  ✗ Error: $e');
  }
  print(
    '└────────────────────────────────────────────────────────────────────',
  );
  print('');

  // Test 2: Go → Dart (triggered via Trigger RPC)
  print('┌─ Testing Go → Dart (gRPC) ────────────────────────────────────────');
  try {
    print('│  [Trigger] Go calls Dart\'s Foo():');
    final triggerResp = await goClient.trigger(
      pb.TriggerRequest()
        ..action = pb.TriggerRequest_Action.UNARY
        ..payload = (pb.HelloRequest()
          ..name = 'FromGo'
          ..language = 'en'),
    );
    print('│    ✓ Go triggered Dart: ${triggerResp.message}');

    print('│  [Trigger] Go calls Dart\'s FooServerStream():');
    final streamTriggerResp = await goClient.trigger(
      pb.TriggerRequest()
        ..action = pb.TriggerRequest_Action.SERVER_STREAM
        ..payload = (pb.HelloRequest()..name = 'StreamTest'),
    );
    print('│    ✓ ${streamTriggerResp.message.split('\n').first}');
  } catch (e) {
    print('│  ✗ Error: $e');
  }
  print(
    '└────────────────────────────────────────────────────────────────────',
  );
}

// =============================================================================
// Argument Parsing Helpers
// =============================================================================

TransportMode _parseMode(List<String> args) {
  for (final arg in args) {
    if (arg.startsWith('--mode=')) {
      final value = arg.substring('--mode='.length).toLowerCase();
      switch (value) {
        case 'uds':
          return TransportMode.uds;
        case 'tcp':
          return TransportMode.tcp;
        case 'ffi':
        default:
          return TransportMode.ffi;
      }
    }
  }
  return TransportMode.ffi;
}

String _parseArg(List<String> args, String name, String defaultValue) {
  for (final arg in args) {
    if (arg.startsWith('--$name=')) {
      return arg.substring('--$name='.length);
    }
  }
  return defaultValue;
}

/// Wait for the server to be ready by polling the TCP port or UDS socket
Future<void> _waitForServer(
  TransportMode mode,
  String port,
  String socket,
) async {
  const maxAttempts = 20;
  const delay = Duration(milliseconds: 250);

  for (var i = 0; i < maxAttempts; i++) {
    try {
      if (mode == TransportMode.tcp) {
        // Try TCP connection
        final conn = await Socket.connect(
          'localhost',
          int.parse(port),
          timeout: const Duration(milliseconds: 500),
        );
        await conn.close();
        print('│  ✓ Server ready (attempt ${i + 1})');
        return;
      } else {
        // Check if UDS socket file exists
        if (await File(socket).exists()) {
          print('│  ✓ Socket file ready (attempt ${i + 1})');
          return;
        }
      }
    } catch (_) {
      // Server not ready yet
    }
    await Future.delayed(delay);
  }
  print('│  ⚠ Server may not be ready, proceeding anyway...');
}
