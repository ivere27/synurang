import 'dart:async';
import 'dart:io';

import 'package:synurang/synurang.dart' hide Duration;
import 'package:test/test.dart';

/// Helper to find a free port
Future<int> findFreePort() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = server.port;
  await server.close();
  return port;
}

void main() {
  group('Initialization Tests', () {
    late Directory tmpDir;

    setUpAll(() {
      configureSynurang(
          libraryName: 'synurang',
          libraryPath: '${Directory.current.path}/src/libsynurang.so');
      prewarmIsolate();
      tmpDir = Directory.systemTemp.createTempSync('synura_init_test_');
    });

    tearDownAll(() {
      if (tmpDir.existsSync()) {
        tmpDir.deleteSync(recursive: true);
      }
    });

    tearDown(() async {
      await stopGrpcServerAsync();
      resetCoreState();
    });

    test('Go server listens on TCP port', () async {
      final port = await findFreePort();
      final result = await startGrpcServerAsync(
        engineTcpPort: port.toString(),
        token: 'test-token',
        storagePath: tmpDir.path,
        cachePath: tmpDir.path,
      );

      expect(result, equals(0));

      // Wait a bit for server to start
      await Future.delayed(Duration(milliseconds: 200));

      // Verify connection
      final socket = await Socket.connect('127.0.0.1', port);
      expect(socket, isNotNull);
      socket.destroy();
    });

    test('Go server listens on UDS', () async {
      final socketPath =
          '${tmpDir.path}/engine_${DateTime.now().millisecondsSinceEpoch}.sock';
      final result = await startGrpcServerAsync(
        engineSocketPath: socketPath,
        token: 'test-token',
        storagePath: tmpDir.path,
        cachePath: tmpDir.path,
      );

      expect(result, equals(0));
      await Future.delayed(Duration(milliseconds: 200));

      final file = File(socketPath);
      expect(file.existsSync(), isTrue);

      // Verify connection
      final socket = await Socket.connect(
          InternetAddress(socketPath, type: InternetAddressType.unix), 0);
      expect(socket, isNotNull);
      socket.destroy();
    });

    test('Token is set for server startup', () async {
      final port = await findFreePort();
      final result = await startGrpcServerAsync(
        engineTcpPort: port.toString(),
        token: 'secret-token',
        storagePath: tmpDir.path,
        cachePath: tmpDir.path,
      );

      expect(result, equals(0));
      await Future.delayed(Duration(milliseconds: 200));

      // Verify server is reachable (token validation happens at gRPC layer)
      final socket = await Socket.connect('127.0.0.1', port);
      expect(socket, isNotNull);
      socket.destroy();
    });

    test('Server starts with cache enabled', () async {
      final port = await findFreePort();
      final result = await startGrpcServerAsync(
        engineTcpPort: port.toString(),
        token: 'test-token',
        storagePath: tmpDir.path,
        cachePath: tmpDir.path,
        enableCache: true,
      );

      expect(result, equals(0));
    });

    test('Server starts with stream timeout', () async {
      final port = await findFreePort();
      final result = await startGrpcServerAsync(
        engineTcpPort: port.toString(),
        token: 'test-token',
        storagePath: tmpDir.path,
        cachePath: tmpDir.path,
        streamTimeout: 30000, // 30 seconds
      );

      expect(result, equals(0));
    });
  });
}
