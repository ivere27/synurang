// test/cross_proto_import_test.dart
//
// Test that one proto file can import types from another proto file.
// example.proto imports core.proto and uses core.v1.Error and core.v1.PingResponse.

import 'package:test/test.dart';
import 'package:fixnum/fixnum.dart';
import 'package:synurang/synurang.dart';
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart'
    as timestamp_pb;

// Import generated files from example
import '../example/lib/src/generated/example.pb.dart' as example;
import '../example/lib/src/generated/core.pb.dart' as core;

void main() {
  group('Cross-Proto Import Tests', () {
    test('Error from core.proto can be used in example.proto message', () {
      // Create an Error message from core.proto
      final error = core.Error()
        ..code = 500
        ..message = 'Internal Server Error'
        ..grpcCode = 13; // INTERNAL

      // Use it in CrossProtoTestMessage from example.proto
      final msg = example.CrossProtoTestMessage()
        ..error = error
        ..description = 'Test message with imported Error type';

      expect(msg.error, isNotNull);
      expect(msg.error.code, 500);
      expect(msg.error.message, 'Internal Server Error');
      expect(msg.error.grpcCode, 13);
    });

    test('PingResponse from core.proto can be used in example.proto message', () {
      // Create a PingResponse message from core.proto
      final pingResp = core.PingResponse()
        ..timestamp = (timestamp_pb.Timestamp()
          ..seconds = Int64(1234567890)
          ..nanos = 123456789)
        ..version = '1.0.0';

      // Use it in CrossProtoTestMessage from example.proto
      final msg = example.CrossProtoTestMessage()
        ..pingResponse = pingResp
        ..description = 'Test message with imported PingResponse type';

      expect(msg.pingResponse, isNotNull);
      expect(msg.pingResponse.version, '1.0.0');
      expect(msg.pingResponse.timestamp.seconds.toInt(), 1234567890);
      expect(msg.pingResponse.timestamp.nanos, 123456789);
    });

    test('Both imported types can be used together', () {
      // Create a message that uses both imported types
      final msg = example.CrossProtoTestMessage()
        ..error = (core.Error()
          ..code = 404
          ..message = 'Not Found'
          ..grpcCode = 5)
        ..pingResponse = (core.PingResponse()
          ..timestamp = (timestamp_pb.Timestamp()
            ..seconds = Int64(9876543210)
            ..nanos = 0)
          ..version = '2.0.0')
        ..description = 'Combined test with both imported types';

      expect(msg.error.code, 404);
      expect(msg.error.message, 'Not Found');
      expect(msg.pingResponse.version, '2.0.0');
      expect(msg.pingResponse.timestamp.seconds.toInt(), 9876543210);
      expect(msg.description, 'Combined test with both imported types');
    });

    test('Serialization roundtrip with imported types works', () {
      // Create a full message
      final original = example.CrossProtoTestMessage()
        ..error = (core.Error()
          ..code = 400
          ..message = 'Bad Request'
          ..grpcCode = 3)
        ..pingResponse = (core.PingResponse()
          ..timestamp = (timestamp_pb.Timestamp()
            ..seconds = Int64(1111111111)
            ..nanos = 222222222)
          ..version = '3.0.0-beta')
        ..description = 'Serialization test';

      // Serialize
      final bytes = original.writeToBuffer();
      print('Serialized size: ${bytes.length} bytes');

      // Deserialize
      final decoded = example.CrossProtoTestMessage.fromBuffer(bytes);

      // Verify Error field
      expect(decoded.error, isNotNull);
      expect(decoded.error.code, original.error.code);
      expect(decoded.error.message, original.error.message);
      expect(decoded.error.grpcCode, original.error.grpcCode);

      // Verify PingResponse field
      expect(decoded.pingResponse, isNotNull);
      expect(decoded.pingResponse.version, original.pingResponse.version);
      expect(decoded.pingResponse.timestamp.seconds.toInt(),
          original.pingResponse.timestamp.seconds.toInt());
      expect(decoded.pingResponse.timestamp.nanos,
          original.pingResponse.timestamp.nanos);

      // Verify Description field
      expect(decoded.description, original.description);
    });

    test('Factory constructors work with imported types', () {
      // Use factory constructor with named parameters
      final msg = example.CrossProtoTestMessage(
        error: core.Error(code: 503, message: 'Service Unavailable'),
        pingResponse: core.PingResponse(version: '4.0.0'),
        description: 'Factory constructor test',
      );

      expect(msg.error.code, 503);
      expect(msg.error.message, 'Service Unavailable');
      expect(msg.pingResponse.version, '4.0.0');
      expect(msg.description, 'Factory constructor test');
    });

    test('Type compatibility - imported types are correct Dart types', () {
      // Verify that the imported types are the expected types
      final error = core.Error()..code = 1;
      final pingResp = core.PingResponse()..version = 'v1';

      final msg = example.CrossProtoTestMessage()
        ..error = error
        ..pingResponse = pingResp;

      // Type assertions
      expect(msg.error, isA<core.Error>());
      expect(msg.pingResponse, isA<core.PingResponse>());

      // Verify we can access core-specific methods
      expect(msg.error.hasCode(), isTrue);
      expect(msg.pingResponse.hasVersion(), isTrue);
    });

    test('Clear and ensure methods work on imported type fields', () {
      final msg = example.CrossProtoTestMessage()
        ..error = (core.Error()..code = 123)
        ..pingResponse = (core.PingResponse()..version = 'test');

      // Verify has methods
      expect(msg.hasError(), isTrue);
      expect(msg.hasPingResponse(), isTrue);

      // Clear fields
      msg.clearError();
      msg.clearPingResponse();

      expect(msg.hasError(), isFalse);
      expect(msg.hasPingResponse(), isFalse);

      // Use ensure to get/create default instances
      final ensuredError = msg.ensureError();
      final ensuredPing = msg.ensurePingResponse();

      expect(ensuredError, isA<core.Error>());
      expect(ensuredPing, isA<core.PingResponse>());
      expect(msg.hasError(), isTrue);
      expect(msg.hasPingResponse(), isTrue);
    });

    test('Proto-to-proto import chain works (core imports google protos)', () {
      // core.proto imports google/protobuf/timestamp.proto
      // example.proto imports core.proto
      // This tests the full import chain works

      final timestamp = timestamp_pb.Timestamp()
        ..seconds = Int64(DateTime.now().millisecondsSinceEpoch ~/ 1000)
        ..nanos = 0;

      final coreMsg = core.PingResponse()
        ..timestamp = timestamp
        ..version = 'chain-test';

      final exampleMsg = example.CrossProtoTestMessage()
        ..pingResponse = coreMsg
        ..description = 'Import chain test';

      // The timestamp should be accessible through the chain
      expect(exampleMsg.pingResponse.timestamp.seconds.toInt(), isPositive);
      expect(exampleMsg.pingResponse.version, 'chain-test');
    });
  });
}
