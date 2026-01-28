// FfiClientChannel Test Suite
//
// Tests the FfiClientChannel implementation that allows using standard gRPC
// client stubs over FFI transport.

import 'dart:io';

import 'package:fixnum/fixnum.dart';
import 'package:grpc/grpc.dart';
import 'package:synurang/synurang.dart' hide Duration;
import 'package:test/test.dart';

void main() {
  group('FfiClientChannel', () {
    setUpAll(() async {
      configureSynurang(
        libraryName: 'synurang',
        libraryPath: '${Directory.current.path}/src/libsynurang.so',
      );
      prewarmIsolate();
      await startGrpcServerAsync(token: 'test-token');
    });

    tearDownAll(() async {
      await stopGrpcServerAsync();
      resetCoreState();
    });

    test('creates channel with default options', () {
      final channel = FfiClientChannel();
      expect(channel.host, equals('ffi'));
      expect(channel.port, equals(0));
    });

    test('creates channel with custom options', () {
      final channel = FfiClientChannel(
        options: ChannelOptions(
          credentials: ChannelCredentials.insecure(),
        ),
      );
      expect(channel.host, equals('ffi'));
      expect(channel.options, isNotNull);
    });

    test('connection state is always ready', () async {
      final channel = FfiClientChannel();
      final state = await channel.onConnectionStateChanged.first;
      expect(state, equals(ConnectionState.ready));
    });

    test('shutdown completes without error', () async {
      final channel = FfiClientChannel();
      await expectLater(channel.shutdown(), completes);
    });

    test('terminate completes without error', () async {
      final channel = FfiClientChannel();
      await expectLater(channel.terminate(), completes);
    });

    group('with HealthService', () {
      late FfiClientChannel channel;
      late HealthServiceClient client;

      setUp(() {
        channel = FfiClientChannel();
        client = HealthServiceClient(channel);
      });

      tearDown(() async {
        await channel.shutdown();
      });

      test('unary call - Ping', () async {
        final response = await client.ping(Empty());
        expect(response, isA<PingResponse>());
        expect(response.hasTimestamp(), isTrue);
      });

      test('multiple sequential calls', () async {
        for (int i = 0; i < 10; i++) {
          final response = await client.ping(Empty());
          expect(response, isA<PingResponse>());
        }
      });

      test('concurrent calls', () async {
        final futures = List.generate(10, (_) => client.ping(Empty()));
        final responses = await Future.wait(futures);
        expect(responses.length, equals(10));
        for (final response in responses) {
          expect(response, isA<PingResponse>());
        }
      });
    });

    group('with CacheService', () {
      late FfiClientChannel channel;
      late CacheServiceClient client;

      setUpAll(() async {
        // Restart with cache enabled
        await stopGrpcServerAsync();
        resetCoreState();
        await startGrpcServerAsync(
          token: 'test-token',
          enableCache: true,
        );
      });

      setUp(() {
        channel = FfiClientChannel();
        client = CacheServiceClient(channel);
      });

      tearDown(() async {
        await channel.shutdown();
      });

      test('put and get', () async {
        final key = 'test-key-${DateTime.now().millisecondsSinceEpoch}';
        final value = 'test-value';

        // Put
        await client.put(PutCacheRequest()
          ..storeName = 'default'
          ..key = key
          ..value = value.codeUnits
          ..ttlSeconds = Int64(60));

        // Get
        final response = await client.get(GetCacheRequest()
          ..storeName = 'default'
          ..key = key);

        expect(String.fromCharCodes(response.value), equals(value));
      });

      test('contains', () async {
        final key = 'contains-key-${DateTime.now().millisecondsSinceEpoch}';

        // Should not exist
        var exists = await client.contains(GetCacheRequest()
          ..storeName = 'default'
          ..key = key);
        expect(exists.value, isFalse);

        // Put
        await client.put(PutCacheRequest()
          ..storeName = 'default'
          ..key = key
          ..value = 'value'.codeUnits
          ..ttlSeconds = Int64(60));

        // Should exist
        exists = await client.contains(GetCacheRequest()
          ..storeName = 'default'
          ..key = key);
        expect(exists.value, isTrue);
      });

      test('delete', () async {
        final key = 'delete-key-${DateTime.now().millisecondsSinceEpoch}';

        // Put
        await client.put(PutCacheRequest()
          ..storeName = 'default'
          ..key = key
          ..value = 'value'.codeUnits
          ..ttlSeconds = Int64(60));

        // Delete
        await client.delete(DeleteCacheRequest()
          ..storeName = 'default'
          ..key = key);

        // Should not exist
        final exists = await client.contains(GetCacheRequest()
          ..storeName = 'default'
          ..key = key);
        expect(exists.value, isFalse);
      });
    });

    group('error handling', () {
      late FfiClientChannel channel;

      setUp(() {
        channel = FfiClientChannel();
      });

      tearDown(() async {
        await channel.shutdown();
      });

      test('handles server error gracefully', () async {
        final client = CacheServiceClient(channel);

        // Try to get non-existent key
        final response = await client.get(GetCacheRequest()
          ..storeName = 'default'
          ..key = 'non-existent-key-12345');

        // Should return empty data, not throw
        expect(response.value, isEmpty);
      });
    });

    group('multiple channels', () {
      test('can create multiple independent channels', () async {
        final channel1 = FfiClientChannel();
        final channel2 = FfiClientChannel();

        final client1 = HealthServiceClient(channel1);
        final client2 = HealthServiceClient(channel2);

        final response1 = await client1.ping(Empty());
        final response2 = await client2.ping(Empty());

        expect(response1, isA<PingResponse>());
        expect(response2, isA<PingResponse>());

        await channel1.shutdown();
        await channel2.shutdown();
      });
    });
  });
}
