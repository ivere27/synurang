import 'dart:convert';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:synurang/synurang.dart';

void main() {
  group('Rust Integration Test', () {
    test('Should communicate with Rust backend', () async {
      // 1. Configure synurang to load our specific Rust library
      // The library path is passed via LD_LIBRARY_PATH
      configureSynurang(libraryName: 'synurang_test_rust');

      // 2. Start Server (calls Rust StartGrpcServer)
      final startResult = await startGrpcServerAsync(
        token: "rust-test-token",
      );
      expect(startResult, equals(0));

      // 3. Invoke Backend (calls Rust InvokeBackend)
      final method = "test_method";
      final data = Uint8List.fromList(utf8.encode("ping"));
      
      final responseBytes = await invokeBackendAsync(method, data);
      final responseString = utf8.decode(responseBytes);

      print("Received from Rust: $responseString");

      expect(responseString, equals("Hello from Rust Backend!"));

      // 4. Stop Server
      await stopGrpcServerAsync();
    });
  });
}
