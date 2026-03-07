import 'package:synurang/synurang.dart' as synurang;
import 'package:test/test.dart';

void main() {
  group('FfiError', () {
    test('preserves core.v1.Error fields', () {
      final proto = synurang.Error()
        ..code = 409
        ..message = 'conflict'
        ..grpcCode = 6;

      final error = synurang.FfiError.fromProto(proto);

      expect(error.code, 409);
      expect(error.message, 'conflict');
      expect(error.grpcCode, 6);
      expect(error.toProto().writeToBuffer(), proto.writeToBuffer());
    });

    test('decodes protobuf payloads from bytes', () {
      final proto = synurang.Error()
        ..code = 503
        ..message = 'service unavailable'
        ..grpcCode = 14;

      final error = synurang.FfiError.fromBuffer(proto.writeToBuffer());

      expect(error.code, 503);
      expect(error.message, 'service unavailable');
      expect(error.grpcCode, 14);
    });

    test('falls back to raw text for non-protobuf payloads', () {
      final error = synurang.FfiError.fromBuffer('plain ffi error'.codeUnits);

      expect(error.code, 0);
      expect(error.message, 'plain ffi error');
      expect(error.grpcCode, 0);
    });
  });
}
