// FFI API Test (Dart) — No gRPC stubs
//
// Tests all 4 RPC types using synurang FFI functions directly with
// raw protobuf bytes. No gRPC stubs or FfiClientChannel used.
//
// Build (from project root):
//   make shared_linux shared_example_linux
//
// Run (from project root):
//   LD_LIBRARY_PATH=src:example/linux/lib flutter test test/ffi/dart/ffi_api_test.dart
//
// Requires: libsynurang.so (core) + libsynura_example.so (GoGreeterService)

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:synurang/synurang.dart' as synurang;
// No gRPC stubs — raw bytes only

// =============================================================================
// Protobuf helpers (hand-crafted, no protobuf library needed)
// =============================================================================

/// Encode HelloRequest { name = value }
Uint8List encodeHelloRequest(String name) {
  final nameBytes = Uint8List.fromList(name.codeUnits);
  final data = Uint8List(2 + nameBytes.length);
  data[0] = 0x0a; // field 1, wire type 2
  data[1] = nameBytes.length;
  data.setRange(2, 2 + nameBytes.length, nameBytes);
  return data;
}

/// Decode HelloResponse.message (field 1, string)
String? decodeHelloMessage(Uint8List data) {
  if (data.length < 2 || data[0] != 0x0a) return null;
  final len = data[1];
  if (data.length < 2 + len) return null;
  return String.fromCharCodes(data.sublist(2, 2 + len));
}

// =============================================================================
// Tests
// =============================================================================

void main() {
  // Configure to use the example library (includes GoGreeterService)
  // Core libsynurang.so only has HealthService/CacheService
  setUpAll(() async {
    synurang.configureSynurang(
      libraryName: 'synura_example',
      libraryPath: '${Directory.current.path}/example/linux/lib/libsynura_example.so',
    );
    await synurang.startGrpcServerAsync();
  });

  tearDownAll(() async {
    await synurang.stopGrpcServerAsync();
  });

  group('FFI API (no gRPC)', () {
    test('Unary RPC', () async {
      final reqBytes = encodeHelloRequest('DartFFI');
      final respBytes = await synurang.invokeBackendAsync(
          '/example.v1.GoGreeterService/Bar', reqBytes);

      final msg = decodeHelloMessage(respBytes);
      expect(msg, isNotNull);
      expect(msg, isNotEmpty);
    });

    test('Server Streaming', () async {
      final reqBytes = encodeHelloRequest('StreamTest');
      final stream = synurang.invokeBackendServerStream(
          '/example.v1.GoGreeterService/BarServerStream', reqBytes);

      int count = 0;
      await for (final data in stream) {
        final msg = decodeHelloMessage(data);
        expect(msg, isNotNull, reason: 'bad message at index $count');
        count++;
      }

      expect(count, greaterThan(0), reason: 'received 0 messages');
    });

    test('Client Streaming', () async {
      final dataStream = Stream.fromIterable([
        encodeHelloRequest('Msg0'),
        encodeHelloRequest('Msg1'),
        encodeHelloRequest('Msg2'),
      ]);

      final respBytes = await synurang.invokeBackendClientStream(
          '/example.v1.GoGreeterService/BarClientStream', dataStream);

      final msg = decodeHelloMessage(respBytes);
      expect(msg, isNotNull);
      expect(msg, isNotEmpty);
    });

    test('Bidi Streaming', () async {
      final inputStream = Stream.fromIterable([
        encodeHelloRequest('Ping0'),
        encodeHelloRequest('Ping1'),
        encodeHelloRequest('Ping2'),
      ]);

      final outputStream = synurang.invokeBackendBidiStream(
          '/example.v1.GoGreeterService/BarBidiStream', inputStream);

      int count = 0;
      await for (final data in outputStream) {
        final msg = decodeHelloMessage(data);
        expect(msg, isNotNull, reason: 'bad message at index $count');
        count++;
      }

      expect(count, greaterThan(0), reason: 'received 0 messages');
    });
  });
}
