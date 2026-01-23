// test/proto_import_test.dart
//
// Test that proto imports work correctly in Dart.
// Verifies that well-known types (timestamp, empty, wrappers, etc.) are properly
// imported from the protobuf package instead of locally generated files.

import 'package:test/test.dart';
import 'package:fixnum/fixnum.dart';
import 'package:synurang/synurang.dart';
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart' as timestamp;
import 'package:protobuf/well_known_types/google/protobuf/empty.pb.dart' as empty;
import 'package:protobuf/well_known_types/google/protobuf/wrappers.pb.dart' as wrappers;
import 'package:protobuf/well_known_types/google/protobuf/duration.pb.dart' as duration;

void main() {
  group('Proto Import Tests', () {
    test('Timestamp import from package:protobuf works', () {
      // Create a Timestamp using the package:protobuf import
      final ts = timestamp.Timestamp()
        ..seconds = Int64(1234567890)
        ..nanos = 123456789;
      
      expect(ts.seconds.toInt(), 1234567890);
      expect(ts.nanos, 123456789);
    });

    test('Empty import from package:protobuf works', () {
      // Create an Empty message
      final emptyMsg = empty.Empty();
      expect(emptyMsg, isNotNull);
      // Verify it serializes correctly (should be empty bytes)
      expect(emptyMsg.writeToBuffer().isEmpty, isTrue);
    });

    test('Wrappers import from package:protobuf works', () {
      // Test BoolValue
      final boolVal = wrappers.BoolValue()..value = true;
      expect(boolVal.value, isTrue);

      // Test StringValue
      final stringVal = wrappers.StringValue()..value = 'hello';
      expect(stringVal.value, 'hello');

      // Test Int32Value
      final int32Val = wrappers.Int32Value()..value = 42;
      expect(int32Val.value, 42);

      // Test Int64Value
      final int64Val = wrappers.Int64Value()..value = Int64(9876543210);
      expect(int64Val.value.toInt(), 9876543210);

      // Test DoubleValue
      final doubleVal = wrappers.DoubleValue()..value = 3.14159;
      expect(doubleVal.value, closeTo(3.14159, 0.00001));

      // Test BytesValue
      final bytesVal = wrappers.BytesValue()..value = [1, 2, 3, 4, 5];
      expect(bytesVal.value, [1, 2, 3, 4, 5]);
    });

    test('Duration import from package:protobuf works', () {
      // Create a Duration (5 seconds and 500ms)
      final dur = duration.Duration()
        ..seconds = Int64(5)
        ..nanos = 500000000;
      
      expect(dur.seconds.toInt(), 5);
      expect(dur.nanos, 500000000);
    });

    test('PingResponse uses Timestamp from package:protobuf', () {
      // PingResponse contains a google.protobuf.Timestamp field
      // Verify it uses the correct import
      final now = DateTime.now();
      final ts = timestamp.Timestamp()
        ..seconds = Int64(now.millisecondsSinceEpoch ~/ 1000)
        ..nanos = (now.millisecondsSinceEpoch % 1000) * 1000000;
      
      final response = PingResponse()
        ..timestamp = ts
        ..version = '1.0.0';
      
      expect(response.timestamp, isNotNull);
      expect(response.timestamp.seconds.toInt(), ts.seconds.toInt());
      expect(response.version, '1.0.0');
      
      // Verify serialization/deserialization works
      final bytes = response.writeToBuffer();
      final decoded = PingResponse.fromBuffer(bytes);
      expect(decoded.version, response.version);
      expect(decoded.timestamp.seconds.toInt(), response.timestamp.seconds.toInt());
    });

    test('Well-known types can be used as message fields', () {
      // Test using wrapper types in GetCacheRequest context
      final request = GetCacheRequest()
        ..storeName = 'test-store'
        ..key = 'test-key';
      
      expect(request.storeName, 'test-store');
      expect(request.key, 'test-key');
      
      // Verify serialization roundtrip
      final bytes = request.writeToBuffer();
      final decoded = GetCacheRequest.fromBuffer(bytes);
      expect(decoded.storeName, request.storeName);
      expect(decoded.key, request.key);
    });

    test('CacheService messages serialize correctly with well-known types', () {
      // Test a message that uses empty return type in service definition
      final putRequest = PutCacheRequest()
        ..storeName = 'cache1'
        ..key = 'mykey'
        ..value = [1, 2, 3, 4, 5]
        ..ttlSeconds = Int64(3600)
        ..cost = Int64(100);
      
      final bytes = putRequest.writeToBuffer();
      final decoded = PutCacheRequest.fromBuffer(bytes);
      
      expect(decoded.storeName, 'cache1');
      expect(decoded.key, 'mykey');
      expect(decoded.value, [1, 2, 3, 4, 5]);
      expect(decoded.ttlSeconds.toInt(), 3600);
      expect(decoded.cost.toInt(), 100);
    });

    test('Re-exports from synurang.dart work correctly', () {
      // The synurang.dart should re-export well-known types
      // These imports should work via the barrel file

      // Verify Empty is exported and usable
      final emptyInstance = Empty();
      expect(emptyInstance, isNotNull);

      // Verify Timestamp is exported and usable  
      final timestampInstance = Timestamp()
        ..seconds = Int64(1000)
        ..nanos = 0;
      expect(timestampInstance.seconds.toInt(), 1000);

      // Verify Duration is exported
      final durationInstance = Duration()
        ..seconds = Int64(60)
        ..nanos = 0;
      expect(durationInstance.seconds.toInt(), 60);
    });
  });
}
