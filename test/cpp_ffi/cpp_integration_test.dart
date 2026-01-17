import 'dart:convert';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:synurang/synurang.dart';

void main() {
  group('C++ Integration Test', () {
    test('Should communicate with C++ backend', () async {
      // 1. Configure synurang to load our specific C++ library
      // The library path is passed via environment variable or assumed relative
      // Here we assume the test runner sets LD_LIBRARY_PATH correctly
      configureSynurang(libraryName: 'synurang_test_cpp');

      // 2. Start Server (calls C++ StartGrpcServer)
      final startResult = await startGrpcServerAsync(
        token: "cpp-test-token",
      );
      expect(startResult, equals(0));

      // 3. Invoke Backend (calls C++ InvokeBackend)
      final method = "test_method";
      final data = Uint8List.fromList(utf8.encode("ping"));
      
      final responseBytes = await invokeBackendAsync(method, data);
      final responseString = utf8.decode(responseBytes);

      print("Received from C++: $responseString");

      expect(responseString, equals("Hello from C++ Backend!"));

      // 4. Stop Server
      await stopGrpcServerAsync();
    });
  });
}
