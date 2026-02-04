// Synurang Process Mode - Dart Parent
//
// Enables Dart/Flutter apps to spawn child processes (Go, C++, Rust) and
// communicate via gRPC over IPC (socketpair on Unix, named pipe on Windows).
//
// Usage:
//   final channel = await SynurangProcess.start('./go-child');
//   final client = GreeterClient(channel);
//   final resp = await client.bar(HelloRequest(name: 'Flutter'));
//   await channel.shutdown();
library;

import 'dart:async';
import 'dart:io';

import 'package:grpc/grpc.dart';

import 'process_stub.dart'
    if (dart.library.io) 'process_io.dart'
    as impl;

/// Environment variable name for IPC address (FD on Unix, pipe name on Windows).
const String envVarIPC = 'SYNURANG_IPC';

/// Process mode: spawn a child process and communicate via gRPC over IPC.
class SynurangProcess {
  final Process _process;
  final ClientChannel _channel;

  SynurangProcess._(this._process, this._channel);

  /// Internal factory for platform implementations.
  factory SynurangProcess.internal(Process process, ClientChannel channel) {
    return SynurangProcess._(process, channel);
  }

  /// Start a child process and return a gRPC channel to communicate with it.
  ///
  /// The child process should be a gRPC server that listens on the IPC address
  /// provided via the SYNURANG_IPC environment variable.
  ///
  /// [executable] - Path to the child executable
  /// [arguments] - Optional command line arguments
  /// [workingDirectory] - Optional working directory for the child process
  /// [environment] - Additional environment variables (SYNURANG_IPC is added automatically)
  static Future<SynurangProcess> start(
    String executable, {
    List<String>? arguments,
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    return impl.startProcess(
      executable,
      arguments: arguments,
      workingDirectory: workingDirectory,
      environment: environment,
    );
  }

  /// Get the underlying gRPC channel for creating service clients.
  ClientChannel get channel => _channel;

  /// Get the underlying process for monitoring.
  Process get process => _process;

  /// Send stdin input to the child process.
  void sendInput(String input) {
    _process.stdin.writeln(input);
  }

  /// Kill the child process and close the channel.
  Future<void> shutdown() async {
    await _channel.shutdown();
    _process.kill();
  }

  /// Wait for the child process to exit.
  Future<int> get exitCode => _process.exitCode;
}
