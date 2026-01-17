import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:synurang/synurang.dart';
import 'package:test/test.dart';

/// Test suite for synurang cache functionality
///
/// Run with: dart test test/synurang_test.dart
void main() {
  group('Cache Service', () {
    late Directory tmpDir;

    setUpAll(() async {
      prewarmIsolate();
      tmpDir = Directory.systemTemp.createTempSync('synura_cache_test_');
      await startGrpcServerAsync(
        cachePath: tmpDir.path,
        token: 'test-cache',
      );
    });

    tearDownAll(() async {
      await stopGrpcServerAsync();
      resetCoreState();
      if (tmpDir.existsSync()) {
        tmpDir.deleteSync(recursive: true);
      }
    });

    test('cachePutPtr (Zero-Copy) works correctly', () async {
      const store = 'test_store';
      const key = 'zero_copy_key';
      // Create some data
      final data = Uint8List.fromList([1, 2, 3, 4, 5, 10, 20, 30]);

      // 1. Manually allocate C memory
      final ptr = calloc<Uint8>(data.length);
      final ptrList = ptr.asTypedList(data.length);
      ptrList.setAll(0, data);

      // 2. Put using pointer (Zero-Copy path)
      // Note: We are responsible for freeing ptr, but NOT until the Future completes!
      // The implementation of cachePutPtr waits for the isolate to process it.
      final success = await cachePutPtr(store, key, ptr, data.length, 60);
      expect(success, isTrue);

      // 3. Free C memory
      calloc.free(ptr);

      // 4. Verify we can read it back
      final result = await cacheGetRaw(store, key);
      expect(result, isNotNull);
      expect(result, equals(data));
    });

    test('cachePutRaw works correctly', () async {
      const store = 'test_store';
      const key = 'raw_key';
      final data = Uint8List.fromList([10, 20, 30]);

      final success = await cachePutRaw(store, key, data, 60);
      expect(success, isTrue);

      final result = await cacheGetRaw(store, key);
      expect(result, equals(data));
    });

    test('cacheContainsRaw works correctly', () async {
      const store = 'test_store';
      const key = 'exists_key';
      final data = Uint8List.fromList([1]);
      await cachePutRaw(store, key, data, 60);

      expect(await cacheContainsRaw(store, key), isTrue);
      expect(await cacheContainsRaw(store, 'missing_key'), isFalse);
    });

    test('cacheDeleteRaw works correctly', () async {
      const store = 'test_store';
      const key = 'delete_key';
      final data = Uint8List.fromList([1]);
      await cachePutRaw(store, key, data, 60);

      expect(await cacheContainsRaw(store, key), isTrue);

      final deleted = await cacheDeleteRaw(store, key);
      expect(deleted, isTrue);
      expect(await cacheContainsRaw(store, key), isFalse);
    });
  });
}
