// Platform-specific process mode implementation for dart:io platforms
//
// Uses TCP loopback for IPC on both Unix and Windows.
// The child process runs a gRPC server and reports its port via stdout.
//
// Protocol:
// 1. Parent sets SYNURANG_IPC=tcp://127.0.0.1:0 (port 0 = child picks)
// 2. Child binds to port 0, gets assigned port, prints "SYNURANG_PORT:<port>\n"
// 3. Parent reads port from stdout and connects
//
// Note: Dart's gRPC library only supports TCP transport, so we use TCP loopback
// for IPC. While not as efficient as socketpair/named pipes, the latency difference
// is negligible for localhost communication.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:grpc/grpc.dart';

import 'process.dart';

/// Marker prefix for child to report its listening port
const String _portMarker = 'SYNURANG_PORT:';

/// Start a child process with IPC channel.
///
/// Uses TCP loopback on all platforms since Dart's gRPC library only supports TCP.
/// The child receives `tcp://127.0.0.1:0` via SYNURANG_IPC environment variable,
/// binds to an available port, and reports it via stdout as "SYNURANG_PORT:<port>".
Future<SynurangProcess> startProcess(
  String executable, {
  List<String>? arguments,
  String? workingDirectory,
  Map<String, String>? environment,
}) async {
  // Prepare environment - child will pick its own port
  final env = <String, String>{
    ...Platform.environment,
    ...?environment,
    envVarIPC: 'tcp://127.0.0.1:0',
  };

  // Start child process
  final process = await Process.start(
    executable,
    arguments ?? [],
    workingDirectory: workingDirectory,
    environment: env,
  );

  // Forward stderr for debugging
  process.stderr.listen((data) => stderr.add(data));

  // Parse stdout to find the port, forward everything else
  final portCompleter = Completer<int>();
  final stdoutLines = process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter());

  stdoutLines.listen((line) {
    if (!portCompleter.isCompleted && line.startsWith(_portMarker)) {
      final portStr = line.substring(_portMarker.length).trim();
      final port = int.tryParse(portStr);
      if (port != null && port > 0) {
        portCompleter.complete(port);
      } else {
        portCompleter.completeError(
          StateError('Invalid port from child: $portStr'),
        );
      }
    } else {
      // Forward non-port lines to stdout
      stdout.writeln(line);
    }
  });

  // Wait for child to report its port (with timeout)
  int port;
  try {
    port = await portCompleter.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        process.kill();
        throw TimeoutException(
          'Child process did not report listening port within 10s. '
          'Ensure child prints "$_portMarker<port>" to stdout after binding.',
        );
      },
    );
  } catch (e) {
    // Check if child exited
    final exitCode = await process.exitCode.timeout(
      const Duration(milliseconds: 100),
      onTimeout: () => -1,
    );
    if (exitCode != -1) {
      throw StateError('Child process exited with code $exitCode before reporting port');
    }
    rethrow;
  }

  // Connect to child's gRPC server
  final channel = ClientChannel(
    '127.0.0.1',
    port: port,
    options: const ChannelOptions(
      credentials: ChannelCredentials.insecure(),
    ),
  );

  // Verify connection
  try {
    await channel.getConnection().timeout(const Duration(seconds: 5));
  } catch (e) {
    process.kill();
    throw StateError('Failed to connect to child gRPC server on port $port: $e');
  }

  return SynurangProcess.internal(process, channel);
}
